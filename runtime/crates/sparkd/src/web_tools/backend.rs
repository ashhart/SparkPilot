//! Which search service the Spark asks, how the question is addressed to it, and how its answer is read.
use reqwest::Url;
use serde_json::Value;
use uuid::Uuid;

use super::extract;
use super::policy::{WebAccessPolicy, validate_domains};

/// How many results one search returns to the model.
pub const MAX_RESULTS: usize = 8;
/// The DuckDuckGo endpoint that needs no account and no key.
const DUCKDUCKGO: &str = "https://html.duckduckgo.com/html/";
const BRAVE: &str = "https://api.search.brave.com/res/v1/web/search";
/// Where the Spark's own SearXNG answers once the signed recipe is installed.
pub const SEARXNG_LOCAL_URL: &str = "http://127.0.0.1:18119";
/// The port in that address, which is the only one cleartext is ever accepted on.
pub const SEARXNG_LOCAL_PORT: u16 = 18119;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchBackend {
    DuckDuckGo,
    Searxng,
    Brave,
    Disabled,
}

impl SearchBackend {
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "duckduckgo" => SearchBackend::DuckDuckGo,
            "searxng" => SearchBackend::Searxng,
            "brave" => SearchBackend::Brave,
            "disabled" => SearchBackend::Disabled,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            SearchBackend::DuckDuckGo => "duckduckgo",
            SearchBackend::Searxng => "searxng",
            SearchBackend::Brave => "brave",
            SearchBackend::Disabled => "disabled",
        }
    }

    /// Whether choosing this backend needs anything else from the owner.
    pub fn needs_secret(self) -> bool {
        self == SearchBackend::Brave
    }
}

/// The owner's standing web-access configuration, stored once per node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebAccessSettings {
    /// What the model may reach at all. Off until an owner changes it.
    pub policy: WebAccessPolicy,
    /// Whether the OpenAI-compatible gateway may also use the web tools.
    pub harness_access: bool,
    pub backend: SearchBackend,
    pub searxng_url: Option<String>,
    pub brave_credential_id: Option<Uuid>,
    /// When non-empty, only these domains and their subdomains may be reached.
    pub allow_domains: Vec<String>,
    /// Always refused, even inside an allowed domain.
    pub deny_domains: Vec<String>,
    pub updated_at: i64,
}

impl Default for WebAccessSettings {
    fn default() -> Self {
        Self {
            policy: WebAccessPolicy::Off,
            harness_access: false,
            backend: SearchBackend::Searxng,
            searxng_url: Some(SEARXNG_LOCAL_URL.to_owned()),
            brave_credential_id: None,
            allow_domains: Vec::new(),
            deny_domains: Vec::new(),
            updated_at: 0,
        }
    }
}

impl WebAccessSettings {
    /// Refuse a configuration that cannot work before it is stored.
    pub fn validate(&self) -> Result<(), &'static str> {
        validate_domains(&self.allow_domains)?;
        validate_domains(&self.deny_domains)?;
        match self.backend {
            SearchBackend::Searxng => {
                let url = self
                    .searxng_url
                    .as_deref()
                    .ok_or("WEB_SEARCH_BACKEND_INCOMPLETE")?;
                let parsed = Url::parse(url).map_err(|_| "WEB_SEARCH_BACKEND_INVALID")?;
                if !parsed.username().is_empty()
                    || parsed.password().is_some()
                    || parsed.host_str().is_none_or(str::is_empty)
                    || parsed.query().is_some()
                    || parsed.fragment().is_some()
                    || (parsed.scheme() == "http" && !is_packaged_searxng(parsed.as_str()))
                    || (parsed.scheme() == "https" && parsed.port_or_known_default() != Some(443))
                {
                    return Err("WEB_SEARCH_BACKEND_INVALID");
                }
                // Cleartext is only ever this Spark's own packaged search; everything else is TLS.
                match parsed.scheme() {
                    "https" => Ok(()),
                    "http" if packaged_searxng(&parsed) => Ok(()),
                    _ => Err("WEB_SEARCH_BACKEND_INVALID"),
                }
            }
            SearchBackend::Brave => self
                .brave_credential_id
                .map(|_| ())
                .ok_or("WEB_SEARCH_BACKEND_INCOMPLETE"),
            SearchBackend::DuckDuckGo | SearchBackend::Disabled => Ok(()),
        }
    }
}

/// Is this the packaged SearXNG on this Spark's own loopback, the one service cleartext is allowed to?
pub fn is_packaged_searxng(url: &str) -> bool {
    Url::parse(url).is_ok_and(|parsed| parsed.scheme() == "http" && packaged_searxng(&parsed))
}

fn packaged_searxng(url: &Url) -> bool {
    url.port() == Some(SEARXNG_LOCAL_PORT)
        && url.host_str().is_some_and(is_loopback_literal)
        && url.username().is_empty()
        && url.password().is_none()
        && matches!(url.path(), "" | "/" | "/search")
        && url.fragment().is_none()
}

/// The loopback address itself, never a name that might answer with something else.
fn is_loopback_literal(host: &str) -> bool {
    let bare = host.strip_prefix('[').and_then(|v| v.strip_suffix(']'));
    bare.unwrap_or(host)
        .parse::<std::net::IpAddr>()
        .is_ok_and(|address| address.is_loopback())
}

/// The address the packaged search answers on, so the connection is pinned rather than resolved.
pub fn packaged_addresses(url: &str) -> Vec<std::net::IpAddr> {
    Url::parse(url)
        .ok()
        .and_then(|parsed| parsed.host_str().map(str::to_owned))
        .map(|host| {
            host.trim_start_matches('[')
                .trim_end_matches(']')
                .to_owned()
        })
        .and_then(|host| host.parse::<std::net::IpAddr>().ok())
        .into_iter()
        .collect()
}

/// One addressed search request, ready for the transport.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchRequest {
    pub url: String,
    pub accept: &'static str,
    /// Only ever the owner's own API key, and only for the backend that needs one.
    pub secret_header: Option<(&'static str, String)>,
}
/// The host the configured search service answers on, so an audit row can say who saw the query.
pub fn backend_host(settings: &WebAccessSettings) -> Option<String> {
    let base = match settings.backend {
        SearchBackend::Disabled => return None,
        SearchBackend::DuckDuckGo => DUCKDUCKGO.to_owned(),
        SearchBackend::Brave => BRAVE.to_owned(),
        SearchBackend::Searxng => settings.searxng_url.clone()?,
    };
    Url::parse(&base)
        .ok()
        .and_then(|url| url.host_str().map(str::to_owned))
}

/// One result the model is shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchResult {
    pub title: String,
    pub url: String,
    pub snippet: String,
}

/// Build the request for the configured backend, or say why it cannot be built.
pub fn search_request(
    settings: &WebAccessSettings,
    query: &str,
    secret: Option<&str>,
) -> Result<SearchRequest, &'static str> {
    settings.validate()?;
    let query = query.trim();
    if query.is_empty() || query.chars().count() > 400 {
        return Err("WEB_SEARCH_QUERY_INVALID");
    }
    match settings.backend {
        SearchBackend::Disabled => Err("WEB_SEARCH_DISABLED"),
        SearchBackend::DuckDuckGo => Ok(SearchRequest {
            url: with_params(DUCKDUCKGO, &[("q", query), ("kl", "wt-wt")])?,
            accept: "text/html",
            secret_header: None,
        }),
        SearchBackend::Searxng => {
            let base = settings
                .searxng_url
                .as_deref()
                .ok_or("WEB_SEARCH_BACKEND_INCOMPLETE")?;
            let base = format!("{}/search", base.trim_end_matches('/'));
            Ok(SearchRequest {
                url: with_params(&base, &[("q", query), ("format", "json")])?,
                accept: "application/json",
                secret_header: None,
            })
        }
        SearchBackend::Brave => {
            let secret = secret.ok_or("WEB_SEARCH_BACKEND_INCOMPLETE")?;
            if secret.trim().is_empty() {
                return Err("WEB_SEARCH_BACKEND_INCOMPLETE");
            }
            Ok(SearchRequest {
                url: with_params(BRAVE, &[("q", query), ("count", "8")])?,
                accept: "application/json",
                secret_header: Some(("x-subscription-token", secret.trim().to_owned())),
            })
        }
    }
}

fn with_params(base: &str, params: &[(&str, &str)]) -> Result<String, &'static str> {
    Url::parse_with_params(base, params)
        .map(|url| url.to_string())
        .map_err(|_| "WEB_SEARCH_BACKEND_INVALID")
}

/// Read a backend's answer into results, ignoring anything it does not recognise.
pub fn parse_results(backend: SearchBackend, body: &str) -> Vec<SearchResult> {
    let results = match backend {
        SearchBackend::DuckDuckGo => parse_duckduckgo(body),
        SearchBackend::Searxng => parse_json(body, "results", "content"),
        SearchBackend::Brave => parse_brave(body),
        SearchBackend::Disabled => Vec::new(),
    };
    results.into_iter().take(MAX_RESULTS).collect()
}

fn parse_json(body: &str, key: &str, snippet_key: &str) -> Vec<SearchResult> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    let Some(items) = value.get(key).and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| result(item, snippet_key))
        .collect()
}

fn parse_brave(body: &str) -> Vec<SearchResult> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    let Some(items) = value
        .get("web")
        .and_then(|web| web.get("results"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|item| result(item, "description"))
        .collect()
}

fn result(item: &Value, snippet_key: &str) -> Option<SearchResult> {
    let url = item.get("url")?.as_str()?.trim().to_owned();
    if !url.starts_with("http") {
        return None;
    }
    Some(SearchResult {
        title: field(item, "title", 300),
        url,
        snippet: field(item, snippet_key, 600),
    })
}

fn field(item: &Value, key: &str, limit: usize) -> String {
    let raw = item.get(key).and_then(Value::as_str).unwrap_or_default();
    extract::readable(raw, limit).text
}

/// Read DuckDuckGo's keyless HTML answer, unwrapping its click-through addresses.
fn parse_duckduckgo(body: &str) -> Vec<SearchResult> {
    let mut results: Vec<SearchResult> = Vec::new();
    let mut snippets: Vec<String> = Vec::new();
    for anchor in body.split("<a ").skip(1) {
        let Some(end) = anchor.find('>') else {
            continue;
        };
        let (attributes, rest) = anchor.split_at(end);
        let label = rest
            .strip_prefix('>')
            .and_then(|value| value.find("</a>").map(|at| &value[..at]))
            .unwrap_or_default();
        let text = extract::readable(label, 600).text;
        if attributes.contains("result__snippet") {
            snippets.push(text);
            continue;
        }
        if !attributes.contains("result__a") {
            continue;
        }
        let Some(href) = attribute(attributes, "href") else {
            continue;
        };
        let Some(url) = direct_url(&href) else {
            continue;
        };
        if text.is_empty() {
            continue;
        }
        results.push(SearchResult {
            title: text,
            url,
            snippet: String::new(),
        });
    }
    for (index, result) in results.iter_mut().enumerate() {
        if let Some(snippet) = snippets.get(index) {
            result.snippet = snippet.clone();
        }
    }
    results
}

fn attribute(attributes: &str, name: &str) -> Option<String> {
    let needle = format!("{name}=\"");
    let start = attributes.find(&needle)? + needle.len();
    let end = attributes[start..].find('"')? + start;
    Some(attributes[start..end].to_owned())
}

/// Turn `//duckduckgo.com/l/?uddg=<encoded>` into the address the model is actually being shown.
fn direct_url(href: &str) -> Option<String> {
    let absolute = if href.starts_with("//") {
        format!("https:{href}")
    } else {
        href.to_owned()
    };
    let parsed = Url::parse(&absolute).ok()?;
    if let Some((_, target)) = parsed.query_pairs().find(|(key, _)| key == "uddg") {
        let target = target.into_owned();
        return target.starts_with("http").then_some(target);
    }
    matches!(parsed.scheme(), "http" | "https").then(|| parsed.to_string())
}

#[cfg(test)]
#[path = "backend/tests.rs"]
mod tests;
