use super::*;

impl Session {
    /// Ask the configured search service and return the results as the model's tool turn.
    pub async fn search(&mut self, query: &str) -> String {
        if let Some(code) = self.exhausted() {
            return refusal_text(code, stopped_explanation(code));
        }
        let started = self.millis();
        if let Some(finding) = outbound::scan_query(query, &self.own) {
            self.record(
                "web_search",
                Some(query),
                None,
                "refused",
                Some(outbound::BLOCKED_CODE),
                None,
                started,
            );
            return refusal_text(outbound::BLOCKED_CODE, finding.explanation());
        }
        let request = match backend::search_request(&self.settings, query, self.secret.as_deref()) {
            Ok(request) => request,
            Err(code) => {
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "refused",
                    Some(code),
                    None,
                    started,
                );
                return refusal_text(code, search_explanation(code));
            }
        };
        let addresses = if reqwest::Url::parse(&request.url)
            .ok()
            .as_ref()
            .is_some_and(backend::is_packaged_searxng)
        {
            Vec::new()
        } else {
            let guard = self.guard.clone();
            let resolver = Arc::clone(&self.resolver);
            let url = request.url.clone();
            match tokio::task::spawn_blocking(move || guard.check(&url, resolver.as_ref())).await {
                Ok(Ok(destination)) => destination.addresses,
                _ => {
                    self.record(
                        "web_search",
                        Some(query),
                        None,
                        "refused",
                        Some("WEB_SEARCH_BACKEND_INVALID"),
                        None,
                        started,
                    );
                    return refusal_text(
                        "WEB_SEARCH_BACKEND_INVALID",
                        "The search service must use a safe public HTTPS address or the search service installed on this Spark.",
                    );
                }
            }
        };
        let transport = TransportRequest {
            url: request.url.clone(),
            accept: request.accept,
            secret_header: request.secret_header,
            max_bytes: MAX_FETCH_BYTES,
            timeout_seconds: MAX_REQUEST_SECONDS,
            addresses,
        };
        match self.transport.get(&transport).await {
            Ok(response) if (200..300).contains(&response.status) => {
                self.bytes_used = self.bytes_used.saturating_add(response.bytes);
                let results = backend::parse_results(self.settings.backend, &response.body);
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "succeeded",
                    None,
                    Some(response.bytes as u64),
                    started,
                );
                render_results(query, &results)
            }
            Ok(response) => {
                self.bytes_used = self.bytes_used.saturating_add(response.bytes);
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "failed",
                    Some("WEB_SEARCH_UNAVAILABLE"),
                    None,
                    started,
                );
                refusal_text(
                    "WEB_SEARCH_UNAVAILABLE",
                    "The search service refused this request.",
                )
            }
            Err(error) => {
                let code = transport_failure(&error, "WEB_SEARCH_UNAVAILABLE");
                self.record(
                    "web_search",
                    Some(query),
                    None,
                    "failed",
                    Some(code),
                    None,
                    started,
                );
                refusal_text(code, "The search service could not be reached.")
            }
        }
    }
}
