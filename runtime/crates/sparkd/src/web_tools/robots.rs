//! Honour a site's robots file for the pages the Spark reads on the owner's behalf.

/// The product identifies itself so a site owner can recognise and refuse it.
pub const USER_AGENT: &str = "SparkPilot/1 (+https://spark.invalid/automations)";
/// The token a site uses to address this reader specifically.
const OWN_TOKEN: &str = "sparkpilot";

/// The rules that apply to this reader on one host.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Robots {
    disallow: Vec<String>,
    allow: Vec<String>,
}

impl Robots {
    /// A host with no robots file, or one that could not be read, permits everything.
    pub fn permissive() -> Self {
        Self::default()
    }

    /// Take the group addressed to this reader if there is one, otherwise the wildcard group.
    pub fn parse(body: &str) -> Self {
        if let Some(own) = group(body, OWN_TOKEN) {
            return own;
        }
        group(body, "*").unwrap_or_default()
    }

    /// Longest matching rule wins, and an explicit allow beats a disallow of the same length.
    pub fn permits(&self, path: &str) -> bool {
        let path = if path.is_empty() { "/" } else { path };
        let longest = |rules: &[String]| {
            rules
                .iter()
                .filter(|rule| rule_matches(rule, path))
                .map(|rule| rule.bytes().filter(|c| !matches!(c, b'*' | b'$')).count())
                .max()
        };
        match (longest(&self.disallow), longest(&self.allow)) {
            (Some(blocked), Some(allowed)) => allowed >= blocked,
            (Some(_), None) => false,
            _ => true,
        }
    }
}

/// Linear glob matching with a fixed prefix and optional end anchor, avoiding backtracking expressions.
fn rule_matches(rule: &str, path: &str) -> bool {
    let (pattern, anchored) = rule.strip_suffix('$').map_or((rule, false), |p| (p, true));
    let parts: Vec<&str> = pattern.split('*').collect();
    let Some(first) = parts.first() else {
        return false;
    };
    if !path.starts_with(first) {
        return false;
    }
    let mut rest = &path[first.len()..];
    if parts.len() == 1 {
        return !anchored || rest.is_empty();
    }
    for (index, part) in parts.iter().enumerate().skip(1) {
        if anchored && index == parts.len() - 1 {
            return rest.ends_with(part);
        }
        let Some(at) = rest.find(part) else {
            return false;
        };
        rest = &rest[at + part.len()..];
    }
    true
}

/// Collect the rules of every group whose user-agent list contains `token`.
fn group(body: &str, token: &str) -> Option<Robots> {
    let mut rules = Robots::default();
    let mut addressed = false;
    let mut naming = false;
    let mut matched_any = false;
    for line in body.lines().take(2_000) {
        let line = line.split('#').next().unwrap_or_default().trim();
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim();
        match key.as_str() {
            "user-agent" => {
                if !naming {
                    addressed = false;
                    naming = true;
                }
                if value.eq_ignore_ascii_case(token) {
                    addressed = true;
                    matched_any = true;
                }
            }
            "disallow" | "allow" => {
                naming = false;
                if !addressed {
                    continue;
                }
                if key == "disallow" {
                    // An empty Disallow permits everything and adds no rule.
                    if !value.is_empty() {
                        rules.disallow.push(value.to_owned());
                    }
                } else if !value.is_empty() {
                    rules.allow.push(value.to_owned());
                }
            }
            _ => naming = false,
        }
    }
    matched_any.then_some(rules)
}

#[cfg(test)]
#[path = "robots/tests.rs"]
mod tests;
