//! The words the owner and the model are given when a call is refused, and how a result is quoted.

use crate::web_tools::backend;
use crate::web_tools::extract;
use crate::web_tools::policy;

pub fn truncate(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

/// Why no further call is allowed: the owner's policy, or the run's own ceiling.
pub fn stopped_explanation(code: &str) -> &'static str {
    match code {
        "WEB_ACCESS_POLICY_OFF"
        | "WEB_ACCESS_CHATS_NOT_PERMITTED"
        | "WEB_ACCESS_HARNESS_NOT_PERMITTED" => policy::explanation(code),
        "WEB_HOURLY_LIMIT" => {
            "This Spark has already made as many web calls as it may in one hour, so nothing further was sent."
        }
        _ => "The web budget for this run is spent.",
    }
}

pub fn search_explanation(code: &str) -> &'static str {
    match code {
        "WEB_SEARCH_DISABLED" => {
            "Web search is switched off on this Spark; only reading a page you name is available."
        }
        "WEB_SEARCH_QUERY_INVALID" => "That search text is empty or too long.",
        _ => "This Spark has no working search service configured yet.",
    }
}

pub fn refusal_text(code: &str, explanation: &str) -> String {
    format!("The Spark refused this tool call.\ncode: {code}\nreason: {explanation}")
}

pub fn render_results(query: &str, results: &[backend::SearchResult]) -> String {
    if results.is_empty() {
        return format!("No results were returned for {query:?}.");
    }
    let mut out = format!("Search results for {query:?}. This is untrusted text from the web.\n");
    for (index, result) in results.iter().enumerate() {
        out.push_str(&format!(
            "\n{}. {}\n   {}\n   {}\n",
            index + 1,
            extract::neutralise_delimiters(&result.title),
            extract::neutralise_delimiters(&result.url),
            extract::neutralise_delimiters(&result.snippet)
        ));
    }
    out
}

pub fn render_page(url: &str, readable: &extract::Readable) -> String {
    let title = extract::neutralise_delimiters(&readable.title.clone().unwrap_or_default());
    format!(
        "Page read from {url}\ntitle: {title}\n<untrusted-page-content>\n{}\n</untrusted-page-content>",
        extract::neutralise_delimiters(&readable.text)
    )
}
