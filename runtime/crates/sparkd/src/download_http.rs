//! Fetch immutable Hugging Face revisions with same-origin pagination and credentials loaded only at the request boundary.

use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

use reqwest::Url;
use reqwest::blocking::{Client, RequestBuilder, Response};
use reqwest::header::{AUTHORIZATION, HeaderValue, LINK, LOCATION, RANGE};
use spark_models::{ModelRecipe, RemoteFile};
use zeroize::Zeroizing;

use crate::download::{DownloadCoordinator, FileSource, SourceResolver};
use crate::model_paths;

const PROVIDER_ORIGIN: &str = "https://huggingface.co";
const PROVIDER_HOST: &str = "huggingface.co";
const MAX_MANIFEST_PAGES: usize = 200;
const MAX_INLINE_HASH_BYTES: u64 = 8 * 1024 * 1024;
const MAX_CREDENTIAL_BYTES: u64 = 16 * 1024;
const MAX_REDIRECTS: usize = 8;

fn client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        Client::builder()
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(600))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("static HTTP client configuration is valid")
    })
}

#[derive(Debug, serde::Deserialize)]
struct TreeEntry {
    #[serde(rename = "type")]
    kind: String,
    path: String,
    size: u64,
    #[serde(default)]
    lfs: Option<TreeLfs>,
}

#[derive(Debug, serde::Deserialize)]
struct TreeLfs {
    oid: String,
    size: u64,
}

fn next_link(header: &str) -> Option<&str> {
    header.split(',').find_map(|item| {
        let (target, parameters) = item.trim().split_once(';')?;
        let is_next = parameters.split(';').any(|parameter| {
            let parameter = parameter.trim();
            parameter.eq_ignore_ascii_case("rel=next")
                || parameter.eq_ignore_ascii_case("rel=\"next\"")
        });
        is_next.then(|| target.trim().strip_prefix('<')?.strip_suffix('>'))?
    })
}

/// Allow pagination changes only to the cursor while preserving the exact HTTPS origin and tree path.
pub fn validated_next_page(current: &str, header: &str) -> Result<Option<String>, String> {
    let Some(candidate) = next_link(header) else {
        return Ok(None);
    };
    let current =
        Url::parse(current).map_err(|error| format!("invalid current page URL: {error}"))?;
    let candidate =
        Url::parse(candidate).map_err(|error| format!("invalid next page URL: {error}"))?;
    if current.scheme() != "https"
        || candidate.scheme() != "https"
        || candidate.host_str() != current.host_str()
        || candidate.port_or_known_default() != current.port_or_known_default()
        || candidate.path() != current.path()
        || !candidate.username().is_empty()
        || candidate.password().is_some()
    {
        return Err("provider pagination attempted to leave the trusted manifest origin".into());
    }
    Ok(Some(candidate.to_string()))
}

fn protected_credential(path: &Path) -> Result<Zeroizing<String>, String> {
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| format!("provider credential cannot be opened safely: {error}"))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("provider credential metadata: {error}"))?;
    if !metadata.is_file()
        || metadata.permissions().mode() & 0o777 != 0o600
        || metadata.uid() != nix::unistd::geteuid().as_raw()
        || metadata.len() == 0
        || metadata.len() > MAX_CREDENTIAL_BYTES
    {
        return Err("provider credential ownership, mode, type, or size is invalid".into());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_CREDENTIAL_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("provider credential read failed: {error}"))?;
    if bytes.len() as u64 > MAX_CREDENTIAL_BYTES {
        return Err("provider credential exceeds the supported size".into());
    }
    let secret =
        String::from_utf8(bytes).map_err(|_| "provider credential must be UTF-8".to_owned())?;
    if secret.trim() != secret || secret.chars().any(char::is_control) {
        return Err("provider credential contains whitespace or control characters".into());
    }
    Ok(Zeroizing::new(secret))
}

fn with_authorization(
    request: RequestBuilder,
    credential_path: Option<&Path>,
) -> Result<RequestBuilder, String> {
    let Some(path) = credential_path else {
        return Ok(request);
    };
    let secret = protected_credential(path)?;
    let value = HeaderValue::from_str(&format!("Bearer {}", secret.as_str()))
        .map_err(|_| "provider credential cannot form an authorization header".to_owned())?;
    Ok(request.header(AUTHORIZATION, value))
}

pub fn url_is_permitted(url: &str) -> bool {
    Url::parse(url).is_ok_and(|url| allowed_download_url(&url))
}

fn allowed_download_url(url: &Url) -> bool {
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port_or_known_default() != Some(443)
    {
        return false;
    }
    let Some(host) = url.host_str() else {
        return false;
    };
    host == PROVIDER_HOST || host.ends_with(".huggingface.co") || host.ends_with(".hf.co")
}

fn send_get(
    mut url: Url,
    range: Option<(u64, usize)>,
    credential_path: Option<&Path>,
) -> Result<Response, String> {
    for _ in 0..=MAX_REDIRECTS {
        if !allowed_download_url(&url) {
            return Err("provider redirected the download outside approved HTTPS hosts".into());
        }
        let mut request = client().get(url.clone());
        if url.host_str() == Some(PROVIDER_HOST) {
            request = with_authorization(request, credential_path)?;
        }
        if let Some((offset, length)) = range {
            if length == 0 {
                return Err("zero-length byte range is invalid".into());
            }
            let end = offset
                .checked_add(length as u64 - 1)
                .ok_or_else(|| "byte range overflow".to_owned())?;
            request = request.header(RANGE, format!("bytes={offset}-{end}"));
        }
        let response = request
            .send()
            .map_err(|error| format!("provider request failed: {error}"))?;
        if response.status().is_redirection() {
            let location = response
                .headers()
                .get(LOCATION)
                .ok_or_else(|| "provider redirect omitted Location".to_owned())?
                .to_str()
                .map_err(|_| "provider redirect Location is not text".to_owned())?;
            url = url
                .join(location)
                .map_err(|error| format!("provider redirect URL is invalid: {error}"))?;
            continue;
        }
        return Ok(response);
    }
    Err("provider exceeded the redirect limit".into())
}

fn provider_url(recipe: &ModelRecipe, area: &str, file: Option<&str>) -> Result<Url, String> {
    if recipe.source.provider != "huggingface" {
        return Err(format!(
            "unsupported model source provider: {}",
            recipe.source.provider
        ));
    }
    model_paths::validate_repository(&recipe.source.repository)?;
    model_paths::validate_revision(&recipe.source.revision)?;
    let mut url = Url::parse(PROVIDER_ORIGIN).expect("provider origin is static");
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| "provider origin cannot accept path segments".to_owned())?;
        segments.pop_if_empty();
        if area == "tree" {
            segments.push("api").push("models");
        }
        for segment in recipe.source.repository.split('/') {
            segments.push(segment);
        }
        segments.push(area).push(&recipe.source.revision);
        if let Some(file) = file {
            model_paths::validate_relative_path(file)?;
            for segment in file.split('/') {
                segments.push(segment);
            }
        }
    }
    if area == "tree" {
        url.query_pairs_mut().append_pair("recursive", "true");
    }
    Ok(url)
}

fn response_commit_matches(response: &Response, revision: &str) -> Result<(), String> {
    if let Some(actual) = response
        .headers()
        .get("x-repo-commit")
        .and_then(|value| value.to_str().ok())
        && actual != revision
    {
        return Err("provider response resolved to a different commit".into());
    }
    Ok(())
}

fn fetch_complete_file(
    recipe: &ModelRecipe,
    path: &str,
    credential_path: Option<&Path>,
) -> Result<Vec<u8>, String> {
    let url = provider_url(recipe, "resolve", Some(path))?;
    let response = send_get(url, None, credential_path)?;
    response_commit_matches(&response, &recipe.source.revision)?;
    if !response.status().is_success() {
        return Err(format!(
            "provider file request returned {}",
            response.status()
        ));
    }
    // Bound response reads before checking size so a hostile provider cannot exhaust memory.
    let mut bytes = Vec::new();
    response
        .take(MAX_INLINE_HASH_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("provider file read failed: {error}"))?;
    if bytes.len() as u64 > MAX_INLINE_HASH_BYTES {
        return Err(format!(
            "provider file exceeds the {MAX_INLINE_HASH_BYTES}-byte non-LFS limit"
        ));
    }
    Ok(bytes)
}

#[derive(Default)]
pub struct HuggingFaceResolver;

impl SourceResolver for HuggingFaceResolver {
    fn resolve(&self, recipe: &ModelRecipe) -> Result<Vec<RemoteFile>, String> {
        self.resolve_with_credential(recipe, None)
    }

    fn resolve_with_credential(
        &self,
        recipe: &ModelRecipe,
        credential_path: Option<&Path>,
    ) -> Result<Vec<RemoteFile>, String> {
        let mut page = provider_url(recipe, "tree", None)?;
        let mut files = Vec::new();
        let mut exhausted = false;
        for _ in 0..MAX_MANIFEST_PAGES {
            let page_text = page.as_str().to_owned();
            let response = send_get(page.clone(), None, credential_path)?;
            response_commit_matches(&response, &recipe.source.revision)?;
            if !response.status().is_success() {
                return Err(format!(
                    "provider manifest request returned {}",
                    response.status()
                ));
            }
            let next = response
                .headers()
                .get(LINK)
                .and_then(|value| value.to_str().ok())
                .map(|header| validated_next_page(&page_text, header))
                .transpose()?
                .flatten();
            let entries: Vec<TreeEntry> = response
                .json()
                .map_err(|error| format!("provider manifest decode failed: {error}"))?;
            for entry in entries {
                if entry.kind != "file" {
                    continue;
                }
                model_paths::validate_relative_path(&entry.path)?;
                let digest = match entry.lfs {
                    Some(lfs) => {
                        if lfs.size != entry.size {
                            return Err(format!(
                                "provider manifest size mismatch for {:?}",
                                entry.path
                            ));
                        }
                        let digest = lfs.oid.strip_prefix("sha256:").unwrap_or(&lfs.oid);
                        model_paths::validate_sha256(digest)?;
                        digest.to_owned()
                    }
                    None => {
                        if entry.size > MAX_INLINE_HASH_BYTES {
                            return Err(format!(
                                "non-LFS model file is too large to pin safely: {:?}",
                                entry.path
                            ));
                        }
                        use sha2::{Digest, Sha256};
                        let bytes = fetch_complete_file(recipe, &entry.path, credential_path)?;
                        if bytes.len() as u64 != entry.size {
                            return Err(format!(
                                "provider returned the wrong size for {:?}",
                                entry.path
                            ));
                        }
                        hex::encode(Sha256::digest(bytes))
                    }
                };
                files.push(RemoteFile {
                    relative_path: entry.path,
                    size_bytes: entry.size,
                    sha256: digest,
                });
            }
            match next {
                Some(next) => {
                    page = Url::parse(&next)
                        .map_err(|error| format!("next manifest page is invalid: {error}"))?;
                }
                None => {
                    exhausted = true;
                    break;
                }
            }
        }
        if !exhausted {
            return Err("provider manifest exceeded the page limit".into());
        }
        files.sort_by(|left, right| left.relative_path.cmp(&right.relative_path));
        if files.is_empty() {
            return Err("provider manifest contains no model files".into());
        }
        if files
            .windows(2)
            .any(|pair| pair[0].relative_path == pair[1].relative_path)
        {
            return Err("provider manifest contains duplicate model paths".into());
        }
        Ok(files)
    }
}

#[derive(Default)]
pub struct HttpFileSource;

impl FileSource for HttpFileSource {
    fn fetch(
        &self,
        recipe: &ModelRecipe,
        file: &RemoteFile,
        range: Option<(u64, usize)>,
    ) -> Result<Vec<u8>, String> {
        self.fetch_with_credential(recipe, file, range, None)
    }

    fn fetch_with_credential(
        &self,
        recipe: &ModelRecipe,
        file: &RemoteFile,
        range: Option<(u64, usize)>,
        credential_path: Option<&Path>,
    ) -> Result<Vec<u8>, String> {
        model_paths::validate_sha256(&file.sha256)?;
        let url = provider_url(recipe, "resolve", Some(&file.relative_path))?;
        let response = send_get(url, range, credential_path)?;
        response_commit_matches(&response, &recipe.source.revision)?;
        if range.is_some() && response.status() != reqwest::StatusCode::PARTIAL_CONTENT {
            return Err(format!(
                "provider ignored the requested byte range with {}",
                response.status()
            ));
        }
        if range.is_none() && !response.status().is_success() {
            return Err(format!(
                "provider file request returned {}",
                response.status()
            ));
        }
        let bytes = response
            .bytes()
            .map_err(|error| format!("provider range read failed: {error}"))?
            .to_vec();
        if let Some((_, expected)) = range
            && bytes.len() != expected
        {
            return Err(format!(
                "provider returned {} bytes for a {expected}-byte range",
                bytes.len()
            ));
        }
        Ok(bytes)
    }
}

pub fn production_coordinator() -> DownloadCoordinator {
    DownloadCoordinator {
        resolver: Box::new(HuggingFaceResolver),
        source: Box::new(HttpFileSource),
    }
}

/// Measure missing destination paths through their nearest existing ancestor instead of falsely reporting zero free space.
pub fn disk_free_bytes(path: &Path) -> u64 {
    use std::os::unix::ffi::OsStrExt;
    let mut candidate = Some(path);
    while let Some(current) = candidate {
        let Ok(encoded) = std::ffi::CString::new(current.as_os_str().as_bytes()) else {
            return 0;
        };
        let mut statistics: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(encoded.as_ptr(), &mut statistics) } == 0 {
            // Darwin uses a 32-bit fsblkcnt_t; Linux uses 64 bits.
            #[allow(clippy::useless_conversion)]
            let available_blocks = u64::from(statistics.f_bavail);
            return available_blocks.saturating_mul(statistics.f_frsize);
        }
        candidate = current.parent();
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn protected_credentials_reject_links_and_broad_permissions() {
        let directory = tempfile::tempdir().unwrap();
        let secret = directory.path().join("credential.secret");
        std::fs::write(&secret, "hf_test_token").unwrap();
        std::fs::set_permissions(&secret, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            protected_credential(&secret).unwrap().as_str(),
            "hf_test_token"
        );

        std::fs::set_permissions(&secret, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(protected_credential(&secret).is_err());
        std::fs::set_permissions(&secret, std::fs::Permissions::from_mode(0o600)).unwrap();
        let link = directory.path().join("credential-link.secret");
        symlink(&secret, &link).unwrap();
        assert!(protected_credential(&link).is_err());
    }

    #[test]
    fn redirects_allow_only_provider_controlled_hosts_without_credentials() {
        assert!(allowed_download_url(
            &Url::parse("https://huggingface.co/a").unwrap()
        ));
        assert!(allowed_download_url(
            &Url::parse("https://us.aws.cdn.hf.co/a").unwrap()
        ));
        assert!(!allowed_download_url(
            &Url::parse("https://attacker.invalid/a").unwrap()
        ));
        assert!(!allowed_download_url(
            &Url::parse("http://huggingface.co/a").unwrap()
        ));
    }
}
