use super::*;

#[test]
fn a_host_with_no_rules_permits_everything() {
    assert!(Robots::permissive().permits("/anything"));
    assert!(Robots::parse("").permits("/anything"));
    assert!(Robots::parse("# just a comment").permits("/anything"));
    assert!(Robots::parse("Sitemap: https://example.com/s.xml").permits("/anything"));
}

#[test]
fn the_wildcard_group_is_honoured() {
    let robots = Robots::parse("User-agent: *\nDisallow: /private\nDisallow: /admin\n");
    assert!(!robots.permits("/private"));
    assert!(!robots.permits("/private/page"));
    assert!(!robots.permits("/admin/x"));
    assert!(robots.permits("/news"));
    assert!(robots.permits("/"));
}

#[test]
fn a_group_addressed_to_this_reader_replaces_the_wildcard_group() {
    let body = "User-agent: *\nDisallow: /\n\nUser-agent: SparkPilot\nDisallow: /private\n";
    let robots = Robots::parse(body);
    assert!(robots.permits("/news"), "the specific group must win");
    assert!(!robots.permits("/private"));
}

#[test]
fn rules_for_other_readers_are_ignored() {
    let body = "User-agent: GPTBot\nDisallow: /\n\nUser-agent: *\nDisallow: /private\n";
    let robots = Robots::parse(body);
    assert!(robots.permits("/news"));
    assert!(!robots.permits("/private"));
}

#[test]
fn several_agents_can_share_one_group() {
    let body = "User-agent: GPTBot\nUser-agent: SparkPilot\nDisallow: /paywall\n";
    let robots = Robots::parse(body);
    assert!(!robots.permits("/paywall/story"));
    assert!(robots.permits("/free"));
}

#[test]
fn an_explicit_allow_carves_a_path_out_of_a_broader_disallow() {
    let body = "User-agent: *\nDisallow: /news\nAllow: /news/public\n";
    let robots = Robots::parse(body);
    assert!(!robots.permits("/news/paid"));
    assert!(robots.permits("/news/public/story"));
}

#[test]
fn an_empty_disallow_permits_everything_for_that_group() {
    let robots = Robots::parse("User-agent: *\nDisallow:\n");
    assert!(robots.permits("/anything"));
}

#[test]
fn a_disallow_of_everything_is_honoured() {
    let robots = Robots::parse("User-agent: *\nDisallow: /\n");
    assert!(!robots.permits("/"));
    assert!(!robots.permits("/news"));
}

#[test]
fn comments_case_and_stray_whitespace_do_not_defeat_the_rules() {
    let body = "  # header\nuser-agent:  *   # everyone\n  DISALLOW:  /private   # secret\n";
    let robots = Robots::parse(body);
    assert!(!robots.permits("/private"));
    assert!(robots.permits("/news"));
}

#[test]
fn the_reader_identifies_itself_so_a_site_can_refuse_it() {
    assert!(USER_AGENT.starts_with("SparkPilot/"));
    assert!(USER_AGENT.contains("+http"));
}

/// BH-09: `*` stands for any run of characters and `$` anchors the end of the path.
#[test]
fn a_wildcard_rule_matches_the_paths_it_names_and_no_others() {
    let rules = Robots::parse("User-agent: *\nDisallow: /*.pdf$\n");
    assert!(!rules.permits("/reports/2026.pdf"));
    assert!(rules.permits("/reports/2026.pdf.html"));
    assert!(rules.permits("/reports/2026.html"));
    let folder = Robots::parse("User-agent: *\nDisallow: /private/*/secret\n");
    assert!(!folder.permits("/private/a/secret"));
    assert!(!folder.permits("/private/a/b/secret/more"));
    assert!(folder.permits("/private/a/public"));
    let exact = Robots::parse("User-agent: *\nDisallow: /draft$\n");
    assert!(!exact.permits("/draft"));
    assert!(exact.permits("/drafts"));
}

/// BH-09: an explicit allow still wins on the longer pattern, wildcards included.
#[test]
fn a_wildcard_allow_still_beats_a_shorter_disallow() {
    let rules = Robots::parse("User-agent: *\nDisallow: /docs\nAllow: /docs/*/public\n");
    assert!(rules.permits("/docs/a/public"));
    assert!(!rules.permits("/docs/a/private"));
}
