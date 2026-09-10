use super::*;

const PAGE: &str = r#"<!doctype html>
<html><head><title>  Today's   headlines </title>
<style>body { color: red; font: "</p>"; }</style>
<script>var leak = "<p>never read this</p>";</script>
</head>
<body>
<nav><a href="/">Home</a></nav>
<h1>Rates held</h1>
<p>The bank held rates at 4&nbsp;per cent &amp; signalled a pause.</p>
<!-- an editor's note that is not reading matter -->
<ul><li>First point</li><li>Second point</li></ul>
<noscript>Enable JavaScript</noscript>
</body></html>"#;

#[test]
fn a_page_becomes_its_title_and_its_reading_matter() {
    let readable = readable(PAGE, 4_000);
    assert_eq!(readable.title.as_deref(), Some("Today's headlines"));
    assert!(readable.text.contains("Rates held"), "{}", readable.text);
    assert!(
        readable
            .text
            .contains("held rates at 4 per cent & signalled a pause."),
        "{}",
        readable.text
    );
    assert!(readable.text.contains("First point"), "{}", readable.text);
    assert!(readable.text.contains("Second point"), "{}", readable.text);
}

#[test]
fn script_style_noscript_and_comments_never_reach_the_model() {
    let readable = readable(PAGE, 4_000);
    for leak in [
        "never read this",
        "color: red",
        "var leak",
        "editor's note",
        "Enable JavaScript",
        "<p>",
        "href",
    ] {
        assert!(
            !readable.text.contains(leak),
            "{leak:?} leaked into {}",
            readable.text
        );
    }
}

#[test]
fn block_elements_become_line_breaks_and_inline_ones_do_not_glue_words() {
    let readable = readable("<p>One</p><p>Two</p><span>a</span><span>b</span>", 4_000);
    let lines: Vec<&str> = readable.text.lines().collect();
    assert_eq!(lines[0], "One");
    assert_eq!(lines[1], "Two");
    assert!(readable.text.contains("a b"), "{}", readable.text);
}

#[test]
fn entities_are_decoded_including_numeric_and_unknown_ones() {
    let readable = readable(
        "<p>&lt;tag&gt; &#65;&#x42; &hellip; &notareal; 5 &gt; 3</p>",
        400,
    );
    assert_eq!(readable.text, "<tag> AB … &notareal; 5 > 3");
}

#[test]
fn a_long_page_is_cut_at_the_limit_and_says_so() {
    let long = format!("<p>{}</p>", "word ".repeat(5_000));
    let readable = readable(&long, 200);
    assert!(
        readable.text.ends_with("\n[truncated]"),
        "{}",
        readable.text
    );
    assert!(readable.text.chars().count() <= 200 + "\n[truncated]".chars().count());
}

#[test]
fn a_page_with_no_title_or_no_body_still_produces_something_usable() {
    assert_eq!(readable("<p>Body only</p>", 400).title, None);
    assert_eq!(readable("<html></html>", 400).text, "");
    assert_eq!(readable("", 400).text, "");
    assert_eq!(readable("<title></title><p>x</p>", 400).title, None);
}

#[test]
fn plain_text_is_passed_through_with_its_whitespace_collapsed() {
    let readable = readable_text("  one   two\n\n three  ", 400);
    assert_eq!(readable.text, "one two three");
    assert_eq!(readable.title, None);
}

#[test]
fn an_unterminated_tag_or_comment_cannot_hang_the_extractor() {
    assert_eq!(readable("<p>before<script>after", 400).text, "before");
    assert_eq!(readable("<p>before<!-- unterminated", 400).text, "before");
    assert_eq!(readable("<p>before<div", 400).text, "before");
}
