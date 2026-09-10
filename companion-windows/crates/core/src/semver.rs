//! Versionsvergleich wie `enum SemVer` in `main.swift` (Spec 8.1).
//!
//! Präfixe `fw-beta-v`, `fw-beta-`, `app-beta-v`, `app-v`, `v` werden entfernt.
//! Die numerischen Stellen werden stellenweise verglichen, fehlende Stellen
//! gelten als 0. Ein finales Release ist neuer als jedes Prerelease derselben
//! Nummer. Prerelease-Felder werden numerisch oder lexikalisch verglichen.

use std::cmp::Ordering;

const PREFIXES: [&str; 5] = ["fw-beta-v", "fw-beta-", "app-beta-v", "app-v", "v"];

fn strip_prefix(raw: &str) -> String {
    let cleaned = raw.trim().to_ascii_lowercase();
    for p in PREFIXES {
        if let Some(rest) = cleaned.strip_prefix(p) {
            return rest.to_string();
        }
    }
    cleaned
}

/// Nur die numerischen Stellen, ohne Prerelease.
pub fn core_parts(raw: &str) -> Vec<u64> {
    let cleaned = strip_prefix(raw);
    let core = cleaned.split('-').next().unwrap_or("");
    core.split('.').map(|c| c.parse().unwrap_or(0)).collect()
}

/// Prerelease-Teil hinter dem ersten `-`, z. B. `beta.3`. Leer bei finalem Release.
pub fn prerelease(raw: &str) -> String {
    let cleaned = strip_prefix(raw);
    match cleaned.find('-') {
        Some(i) => cleaned[i + 1..].to_string(),
        None => String::new(),
    }
}

pub fn compare(a: &str, b: &str) -> Ordering {
    let ap = core_parts(a);
    let bp = core_parts(b);
    for i in 0..ap.len().max(bp.len()) {
        let av = ap.get(i).copied().unwrap_or(0);
        let bv = bp.get(i).copied().unwrap_or(0);
        match av.cmp(&bv) {
            Ordering::Equal => continue,
            other => return other,
        }
    }

    let a_pre = prerelease(a);
    let b_pre = prerelease(b);
    if a_pre == b_pre {
        return Ordering::Equal;
    }
    if a_pre.is_empty() {
        return Ordering::Greater;
    }
    if b_pre.is_empty() {
        return Ordering::Less;
    }

    let af: Vec<&str> = a_pre.split('.').collect();
    let bf: Vec<&str> = b_pre.split('.').collect();
    for i in 0..af.len().max(bf.len()) {
        let (Some(x), Some(y)) = (af.get(i), bf.get(i)) else {
            // Fehlendes Feld ist kleiner: beta < beta.1
            return if af.get(i).is_none() { Ordering::Less } else { Ordering::Greater };
        };
        if x == y {
            continue;
        }
        return match (x.parse::<u64>(), y.parse::<u64>()) {
            (Ok(xn), Ok(yn)) => xn.cmp(&yn),
            _ => x.cmp(y),
        };
    }
    Ordering::Equal
}

/// `version >= minimum`.
pub fn at_least(version: &str, minimum: &str) -> bool {
    compare(version, minimum) != Ordering::Less
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_mac_rules() {
        assert_eq!(compare("2.15.0-beta.3", "2.15.0"), Ordering::Less);
        assert_eq!(compare("2.12.3", "2.12.3"), Ordering::Equal);
        assert_eq!(compare("v2.17.0", "2.16.9"), Ordering::Greater);
        assert_eq!(compare("2.15.0-beta.10", "2.15.0-beta.9"), Ordering::Greater);
        assert_eq!(compare("2.15.0-beta", "2.15.0-beta.1"), Ordering::Less);
        assert_eq!(compare("2.12", "2.12.0"), Ordering::Equal);
        assert_eq!(compare("fw-beta-v2.18.0-beta.1", "app-v2.17.0"), Ordering::Greater);
        assert!(at_least("2.12.3", "2.12.3"));
        assert!(!at_least("2.12.2", "2.12.3"));
        assert!(!at_least("garbage", "2.12.3"));
    }
}
