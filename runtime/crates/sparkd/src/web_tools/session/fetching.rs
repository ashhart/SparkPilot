//! Read one page for the model: check every hop, honour the site's robots file, and quote what came back.

use super::super::extract;
use super::super::policy;
use super::super::robots::Robots;
use super::wording::{refusal_text, render_page, stopped_explanation};
use super::{
    MAX_FETCH_BYTES, MAX_PAGE_CHARACTERS, MAX_REDIRECTS, MAX_REQUEST_SECONDS, Session, Source,
    TransportRequest,
};
use crate::web_tools::outbound;

impl Session {
    /// Read one page, following at most a few redirects and re-checking every hop.
    pub async fn fetch(&mut self, url: &str) -> String {
        if let Some(code) = self.exhausted() {
            return refusal_text(code, stopped_explanation(code));
        }
        self.spent += 1;
        let started = self.millis();
        let mut next = url.trim().to_owned();
        for _ in 0..=MAX_REDIRECTS {
            if let Some(finding) = outbound::scan_url(&next, &self.own) {
                self.record(
                    "web_fetch",
                    None,
                    Some(&next),
                    "refused",
                    Some(outbound::BLOCKED_CODE),
                    None,
                    started,
                );
                return refusal_text(outbound::BLOCKED_CODE, finding.explanation());
            }
            let destination = match self.checked_destination(&next).await {
                Ok(destination) => destination,
                Err(refusal) => {
                    self.record(
                        "web_fetch",
                        None,
                        Some(&next),
                        "refused",
                        Some(refusal.code()),
                        None,
                        started,
                    );
                    return refusal_text(refusal.code(), refusal.explanation());
                }
            };
            if !policy::domain_permitted(&self.settings, &destination.host) {
                self.record(
                    "web_fetch",
                    None,
                    Some(destination.url.as_str()),
                    "refused",
                    Some("WEB_DOMAIN_BLOCKED"),
                    None,
                    started,
                );
                return refusal_text(
                    "WEB_DOMAIN_BLOCKED",
                    policy::explanation("WEB_DOMAIN_BLOCKED"),
                );
            }
            match self
                .robots_permit(&destination.url, &destination.addresses)
                .await
            {
                Ok(true) => {}
                Ok(false) => {
                    self.record(
                        "web_fetch",
                        None,
                        Some(destination.url.as_str()),
                        "refused",
                        Some("WEB_FETCH_ROBOTS_DENIED"),
                        None,
                        started,
                    );
                    return refusal_text(
                        "WEB_FETCH_ROBOTS_DENIED",
                        "That site asks automated readers not to read this page, so it was not read.",
                    );
                }
                Err(code) => {
                    self.record(
                        "web_fetch",
                        None,
                        Some(destination.url.as_str()),
                        "refused",
                        Some(code),
                        None,
                        started,
                    );
                    return refusal_text(code, stopped_explanation(code));
                }
            }
            if !self.reserve() {
                self.record(
                    "web_fetch",
                    None,
                    Some(destination.url.as_str()),
                    "refused",
                    Some("WEB_HOURLY_LIMIT"),
                    None,
                    started,
                );
                return refusal_text("WEB_HOURLY_LIMIT", stopped_explanation("WEB_HOURLY_LIMIT"));
            }
            let request = TransportRequest {
                url: destination.url.to_string(),
                accept: "text/html,text/plain",
                secret_header: None,
                max_bytes: MAX_FETCH_BYTES,
                timeout_seconds: MAX_REQUEST_SECONDS,
                addresses: destination.addresses.clone(),
            };
            let response = match self.transport.get(&request).await {
                Ok(response) => response,
                Err(_) => {
                    self.record(
                        "web_fetch",
                        None,
                        Some(destination.url.as_str()),
                        "failed",
                        Some("WEB_FETCH_UNREACHABLE"),
                        None,
                        started,
                    );
                    return refusal_text(
                        "WEB_FETCH_UNREACHABLE",
                        "That page could not be reached.",
                    );
                }
            };
            self.bytes_used = self.bytes_used.saturating_add(response.bytes);
            if (300..400).contains(&response.status) {
                match response.location {
                    Some(location) => {
                        next = destination
                            .url
                            .join(&location)
                            .map(|joined| joined.to_string())
                            .unwrap_or(location);
                        continue;
                    }
                    None => {
                        self.record(
                            "web_fetch",
                            None,
                            Some(destination.url.as_str()),
                            "failed",
                            Some("WEB_FETCH_UNREACHABLE"),
                            None,
                            started,
                        );
                        return refusal_text(
                            "WEB_FETCH_UNREACHABLE",
                            "That page could not be reached.",
                        );
                    }
                }
            }
            if !(200..300).contains(&response.status) {
                self.record(
                    "web_fetch",
                    None,
                    Some(destination.url.as_str()),
                    "failed",
                    Some("WEB_FETCH_STATUS"),
                    Some(response.bytes as u64),
                    started,
                );
                return refusal_text(
                    "WEB_FETCH_STATUS",
                    "That page answered with an error rather than content.",
                );
            }
            let readable = if response.content_type.contains("html") {
                extract::readable(&response.body, MAX_PAGE_CHARACTERS)
            } else {
                extract::readable_text(&response.body, MAX_PAGE_CHARACTERS)
            };
            let final_url = destination.url.to_string();
            self.record(
                "web_fetch",
                None,
                Some(&final_url),
                "succeeded",
                None,
                Some(response.bytes as u64),
                started,
            );
            if !self.sources.iter().any(|source| source.url == final_url) {
                self.sources.push(Source {
                    url: final_url.clone(),
                    title: readable.title.clone(),
                });
            }
            return render_page(&final_url, &readable);
        }
        self.record(
            "web_fetch",
            None,
            Some(&next),
            "refused",
            Some("WEB_FETCH_TOO_MANY_REDIRECTS"),
            None,
            started,
        );
        refusal_text(
            "WEB_FETCH_TOO_MANY_REDIRECTS",
            "That address kept redirecting, so it was not read.",
        )
    }

    /// Fetch a host's robots file once per run; an unreadable one permits reading.
    async fn robots_permit(
        &mut self,
        url: &reqwest::Url,
        addresses: &[std::net::IpAddr],
    ) -> Result<bool, &'static str> {
        let Some(host) = url.host_str().map(str::to_owned) else {
            return Ok(false);
        };
        if !self.robots.contains_key(&host) {
            // The robots file is an outbound request of its own, and is spent and recorded as one.
            if !self.reserve() {
                return Err("WEB_HOURLY_LIMIT");
            }
            let started = self.millis();
            let request = TransportRequest {
                url: format!("{}://{host}/robots.txt", url.scheme()),
                accept: "text/plain",
                secret_header: None,
                max_bytes: 256 * 1024,
                timeout_seconds: MAX_REQUEST_SECONDS,
                addresses: addresses.to_vec(),
            };
            let answer = self.transport.get(&request).await;
            let (rules, bytes, code) = match answer {
                Ok(response) if (200..300).contains(&response.status) => {
                    self.bytes_used = self.bytes_used.saturating_add(response.bytes);
                    (
                        Robots::parse(&response.body),
                        Some(response.bytes as u64),
                        None,
                    )
                }
                Ok(_) => (Robots::permissive(), None, Some("WEB_FETCH_STATUS")),
                Err(_) => (Robots::permissive(), None, Some("WEB_FETCH_UNREACHABLE")),
            };
            self.record(
                "web_fetch",
                None,
                Some(&request.url),
                "robots_checked",
                code,
                bytes,
                started,
            );
            self.robots.insert(host.clone(), rules);
        }
        Ok(self
            .robots
            .get(&host)
            .is_some_and(|rules| rules.permits(url.path())))
    }
}
