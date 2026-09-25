//! JSON der CodexBar-CLI lesen und bewerten.
//!
//! Unterstützt beide Schreibweisen:
//! - Win-CodexBar (`codexbar-cli.exe usage -p <p> --json`): snake_case,
//!   Fehler als String im Feld `error`
//! - Upstream-CLI (macOS/Linux, `codexbar usage --provider <p> --json`):
//!   camelCase, Fehler als Objekt `{code, message, kind}`
//!
//! Beide liefern ein Array mit einem Element je Provider:
//! `[{ provider, source, usage: { primary, secondary, tertiary, updated_at,
//!    extra_rate_windows: [{ id, title, window }] } }]`.

use crate::model::{Credits, Entry, ExtraWindow, ResetCredits, Window};
use crate::provider::Provider;
use crate::status::Status;
use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::time::Duration;

#[derive(Debug, Clone, Deserialize)]
pub struct CliWindow {
    #[serde(default, alias = "usedPercent")]
    pub used_percent: Option<f64>,
    #[serde(default, alias = "resetsAt")]
    pub resets_at: Option<String>,
    #[serde(default, alias = "windowMinutes")]
    pub window_minutes: Option<u32>,
    #[serde(default, alias = "resetDescription")]
    pub reset_description: Option<String>,
    /// Win-CodexBar: Fenster ohne echte Nutzungszahl, nur Beschreibung.
    #[serde(default, alias = "isInformational")]
    pub is_informational: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CliExtraWindow {
    pub id: Option<String>,
    pub title: Option<String>,
    pub window: Option<CliWindow>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CliUsage {
    pub primary: Option<CliWindow>,
    pub secondary: Option<CliWindow>,
    pub tertiary: Option<CliWindow>,
    #[serde(default, alias = "updatedAt")]
    pub updated_at: Option<String>,
    #[serde(default, alias = "extraRateWindows")]
    pub extra_rate_windows: Option<Vec<CliExtraWindow>>,
    #[serde(default, alias = "loginMethod")]
    pub login_method: Option<String>,
    /// Upstream: Reset Credits als eigener Block statt als Zusatzfenster.
    #[serde(default, alias = "codexResetCredits")]
    pub codex_reset_credits: Option<CliResetCredits>,
}

/// Upstream-Block `usage.codexResetCredits`.
#[derive(Debug, Clone, Deserialize)]
pub struct CliResetCredits {
    #[serde(default, alias = "availableCount")]
    pub available_count: Option<u32>,
    #[serde(default)]
    pub credits: Vec<CliResetCredit>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CliResetCredit {
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default, alias = "expiresAt")]
    pub expires_at: Option<String>,
}

/// Upstream-Block `credits` auf oberster Ebene (nur Codex).
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CliCredits {
    #[serde(default)]
    pub remaining: Option<f64>,
    /// Fehlt bei älteren CLI-Versionen; dann galt jeder Wert als gelesen.
    #[serde(default)]
    pub balance_read_succeeded: Option<bool>,
    /// `true`: Pool vorhanden, auch wenn der Stand zurückgehalten wird.
    #[serde(default)]
    pub credits_available: Option<bool>,
    #[serde(default)]
    pub balance_is_workspace: Option<bool>,
    #[serde(default)]
    pub codex_credit_limit: Option<CliCreditLimit>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CliCreditLimit {
    #[serde(default)]
    pub remaining: Option<f64>,
}

/// Win-CodexBar-Block `cost` auf oberster Ebene. Bei Codex steht er nur da,
/// wenn ein Credit-Pool gemeldet ist; `used` trägt dann den Kontostand.
#[derive(Debug, Clone, Deserialize)]
pub struct CliCost {
    #[serde(default)]
    pub used: Option<f64>,
    #[serde(default)]
    pub limit: Option<f64>,
    #[serde(default)]
    pub period: Option<String>,
}

/// Upstream meldet ein Objekt, Win-CodexBar einen String.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum CliError {
    Text(String),
    Object {
        code: Option<i64>,
        message: Option<String>,
        kind: Option<String>,
    },
}

impl CliError {
    pub fn message(&self) -> String {
        match self {
            CliError::Text(s) => s.clone(),
            CliError::Object { message, kind, code } => message
                .clone()
                .or_else(|| kind.clone())
                .or_else(|| code.map(|c| format!("error {c}")))
                .unwrap_or_else(|| "unknown error".into()),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct CliResult {
    pub provider: Option<String>,
    pub source: Option<String>,
    pub usage: Option<CliUsage>,
    pub error: Option<CliError>,
    /// Win-CodexBar schreibt seine Version in jedes Ergebnis.
    pub version: Option<String>,
    #[serde(default)]
    pub credits: Option<CliCredits>,
    #[serde(default)]
    pub cost: Option<CliCost>,
}

/// Rohausgabe der CLI in das erste Ergebnis übersetzen.
/// Leere Ausgabe behandelt der Aufrufer, weil dort stderr und Exit-Code vorliegen.
pub fn parse_output(stdout: &[u8]) -> Result<CliResult, Status> {
    let results: Vec<CliResult> = serde_json::from_slice(stdout).map_err(|e| Status::ParseError {
        message: e.to_string(),
    })?;
    results.into_iter().next().ok_or(Status::ParseError {
        message: "Leeres Ergebnis-Array".into(),
    })
}

/// ISO-8601 mit oder ohne Sekundenbruchteile, mit `Z` oder Offset.
pub fn parse_timestamp(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s.trim())
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

fn to_window(w: CliWindow) -> Window {
    Window {
        used_percent: w.used_percent.unwrap_or(0.0),
        resets_at: w.resets_at.as_deref().and_then(parse_timestamp),
        window_minutes: w.window_minutes,
        reset_description: w.reset_description,
    }
}

/// Win-CodexBar-ID des Reset-Credits-Zusatzfensters.
const RESET_CREDITS_WINDOW_ID: &str = "reset-credits";

/// Zusatz-Credits aus dem Upstream-Block `credits` oder dem Win-CodexBar-Block
/// `cost`. `None` heißt: die Quelle sagt nichts dazu, nicht „keine Credits".
fn credits_from(credits: Option<&CliCredits>, cost: Option<&CliCost>) -> Option<Credits> {
    if let Some(c) = credits {
        // Wie `CreditsSnapshot.displayRemaining` in CodexBar: ein nicht
        // gelesener Stand ist unbekannt, keine Null.
        let read = c.balance_read_succeeded.unwrap_or(true);
        let balance = if read && c.balance_is_workspace == Some(true) {
            c.remaining
        } else {
            c.codex_credit_limit
                .as_ref()
                .and_then(|l| l.remaining)
                .or(if read { c.remaining } else { None })
        };
        let available = c.credits_available == Some(true) || balance.is_some_and(|b| b > 0.0);
        if !available && c.credits_available != Some(false) {
            return None;
        }
        return Some(Credits { available, balance: balance.filter(|_| available) });
    }

    // Win-CodexBar setzt einen fehlenden Stand auf 0, deshalb zählt nur ein
    // positiver Wert. Andere Perioden gehören zu anderen Kostenarten.
    let cost = cost?;
    let balance = match cost.period.as_deref()? {
        "Credits" => cost.used.filter(|b| *b > 0.0),
        "Monthly credits" => cost.limit.zip(cost.used).map(|(l, u)| (l - u).max(0.0)),
        _ => return None,
    };
    Some(Credits { available: true, balance })
}

/// Win-CodexBar: Anzahl steht nur im Beschreibungstext („2 reset credits
/// available"), der Zeitpunkt ist der Ablauf des nächsten Credits.
fn reset_credits_from_window(w: &CliWindow) -> Option<ResetCredits> {
    let digits: String = w
        .reset_description
        .as_deref()?
        .trim_start()
        .chars()
        .take_while(char::is_ascii_digit)
        .collect();
    let count: u32 = digits.parse().ok()?;
    Some(ResetCredits {
        count,
        next_expires_at: w.resets_at.as_deref().and_then(parse_timestamp),
    })
}

fn reset_credits_from_upstream(r: &CliResetCredits, now: DateTime<Utc>) -> Option<ResetCredits> {
    let count = r.available_count?;
    let next_expires_at = r
        .credits
        .iter()
        .filter(|c| c.status.as_deref() == Some("available"))
        .filter_map(|c| c.expires_at.as_deref().and_then(parse_timestamp))
        .filter(|d| *d > now)
        .min();
    Some(ResetCredits { count, next_expires_at })
}

/// Ergebnis der Bewertung: Status plus, falls verwertbar, der Eintrag.
#[derive(Debug, Clone)]
pub struct Evaluation {
    pub status: Status,
    pub entry: Option<Entry>,
    pub source: Option<String>,
}

/// Bewertet ein CLI-Ergebnis nach den Regeln von `CodexBarSource.handle(outcome:)`.
pub fn evaluate(
    result: CliResult,
    requested: Provider,
    now: DateTime<Utc>,
    stale_after: Duration,
) -> Evaluation {
    let source = result.source.clone();

    if let Some(err) = result.error {
        return Evaluation {
            status: Status::ProviderUnavailable {
                message: err.message(),
            },
            entry: None,
            source,
        };
    }

    let Some(usage) = result.usage else {
        return Evaluation {
            status: Status::ParseError {
                message: "Antwort ohne usage-Objekt".into(),
            },
            entry: None,
            source,
        };
    };

    let credits = credits_from(result.credits.as_ref(), result.cost.as_ref());
    let mut reset_credits = usage
        .codex_reset_credits
        .as_ref()
        .and_then(|r| reset_credits_from_upstream(r, now));

    // Informational-Fenster (Win-CodexBar) tragen nur einen Text, keinen
    // Prozentwert, etwa „No active 5h session" bei reinen Wochenplänen oder
    // die Reset Credits. Als Balken wären sie irreführend (0 % bzw. 100 %).
    let extras: Vec<ExtraWindow> = usage
        .extra_rate_windows
        .unwrap_or_default()
        .into_iter()
        .filter_map(|raw| {
            let id = raw.id?;
            let window = raw.window?;
            if window.is_informational {
                if id == RESET_CREDITS_WINDOW_ID && reset_credits.is_none() {
                    reset_credits = reset_credits_from_window(&window);
                }
                return None;
            }
            Some(ExtraWindow {
                title: raw.title.unwrap_or_else(|| id.clone()),
                id,
                window: to_window(window),
            })
        })
        .collect();

    let provider = result
        .provider
        .as_deref()
        .and_then(|p| p.parse().ok())
        .unwrap_or(requested);

    let updated_at = usage.updated_at.as_deref().and_then(parse_timestamp);

    let entry = Entry {
        provider,
        updated_at,
        primary: usage.primary.filter(|w| !w.is_informational).map(to_window),
        secondary: usage.secondary.filter(|w| !w.is_informational).map(to_window),
        tertiary: usage.tertiary.filter(|w| !w.is_informational).map(to_window),
        extra_windows: extras,
        login_method: usage.login_method,
        credits,
        reset_credits: reset_credits.filter(|r| r.count > 0),
    };

    // Alle Fenster leer? Dann hat der Provider zwar geantwortet, aber nichts
    // Verwertbares. Genauso behandeln wie „nicht verfügbar", damit das Display
    // nicht stumm alte Werte weiterzeigt.
    if entry.is_empty() {
        return Evaluation {
            status: Status::ProviderUnavailable {
                message: "no quota data".into(),
            },
            entry: None,
            source,
        };
    }

    if let Some(ref_time) = updated_at {
        let age = now.signed_duration_since(ref_time);
        let age_secs = age.num_seconds().max(0) as u64;
        if age_secs > stale_after.as_secs() {
            return Evaluation {
                status: Status::Stale {
                    age_seconds: age_secs,
                },
                entry: Some(entry),
                source,
            };
        }
    }

    Evaluation {
        status: Status::Ok,
        entry: Some(entry),
        source,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 8, 5, 0).unwrap()
    }

    #[test]
    fn reads_snake_case_from_win_codexbar() {
        let json = br#"[{"provider":"claude","source":"oauth","usage":{
            "primary":{"used_percent":37.4,"window_minutes":300,"resets_at":"2026-09-11T12:00:00.123456Z"},
            "secondary":{"used_percent":62,"window_minutes":10080,"resets_at":"2026-09-14T09:00:00Z"},
            "extra_rate_windows":[{"id":"fable-weekly","title":"Fable weekly","window":{"used_percent":12,"window_minutes":10080}}],
            "updated_at":"2026-09-11T08:00:00Z","login_method":"oauth"}}]"#;
        let result = parse_output(json).unwrap();
        let eval = evaluate(result, Provider::Claude, now(), Duration::from_secs(900));
        assert_eq!(eval.status, Status::Ok);
        let entry = eval.entry.unwrap();
        assert_eq!(entry.primary.as_ref().unwrap().used_percent, 37.4);
        assert_eq!(entry.primary.as_ref().unwrap().window_minutes, Some(300));
        assert!(entry.primary.as_ref().unwrap().resets_at.is_some());
        assert_eq!(entry.extra_windows.len(), 1);
        assert_eq!(entry.extra_windows[0].title, "Fable weekly");
        assert_eq!(eval.source.as_deref(), Some("oauth"));
    }

    #[test]
    fn reads_camel_case_from_upstream() {
        let json = br#"[{"provider":"gemini","source":"auto","usage":{
            "primary":{"usedPercent":62.0,"resetsAt":"2026-09-11T17:12:00Z","windowMinutes":1440},
            "updatedAt":"2026-09-11T08:00:00Z"}}]"#;
        let result = parse_output(json).unwrap();
        let eval = evaluate(result, Provider::Gemini, now(), Duration::from_secs(900));
        assert_eq!(eval.status, Status::Ok);
        assert_eq!(eval.entry.unwrap().primary.unwrap().window_minutes, Some(1440));
    }

    #[test]
    fn error_string_and_error_object_both_mean_unavailable() {
        let win = br#"[{"provider":"cursor","error":"No credentials found for cursor"}]"#;
        let eval = evaluate(parse_output(win).unwrap(), Provider::Cursor, now(), Duration::from_secs(900));
        assert_eq!(
            eval.status,
            Status::ProviderUnavailable { message: "No credentials found for cursor".into() }
        );

        let mac = br#"[{"provider":"cursor","source":"web","error":{"code":1,"message":"not logged in","kind":"auth"}}]"#;
        let eval = evaluate(parse_output(mac).unwrap(), Provider::Cursor, now(), Duration::from_secs(900));
        assert_eq!(eval.status, Status::ProviderUnavailable { message: "not logged in".into() });
    }

    #[test]
    fn stale_when_updated_at_is_old() {
        let json = br#"[{"provider":"codex","source":"oauth","usage":{
            "primary":{"used_percent":10},"updated_at":"2026-09-11T07:00:00Z"}}]"#;
        let eval = evaluate(parse_output(json).unwrap(), Provider::Codex, now(), Duration::from_secs(900));
        assert_eq!(eval.status, Status::Stale { age_seconds: 3900 });
        assert!(eval.entry.is_some(), "stale behält den Eintrag");
    }

    #[test]
    fn empty_usage_is_unavailable() {
        let json = br#"[{"provider":"copilot","source":"auto","usage":{"updated_at":"2026-09-11T08:00:00Z"}}]"#;
        let eval = evaluate(parse_output(json).unwrap(), Provider::Copilot, now(), Duration::from_secs(900));
        assert!(matches!(eval.status, Status::ProviderUnavailable { .. }));
    }

    #[test]
    fn win_codexbar_informational_windows_become_flags_not_rows() {
        // Business-Mitglied mit reinem Wochenplan: Session-Platzhalter und
        // Reset Credits sind informational, der Pool-Stand ist nicht lesbar (0).
        let json = br#"[{"provider":"codex","source":"oauth","usage":{
            "primary":{"used_percent":0,"window_minutes":300,"reset_description":"No active 5h session","is_informational":true},
            "secondary":{"used_percent":15,"window_minutes":10080,"resets_at":"2026-10-01T09:00:00Z","is_informational":false},
            "extra_rate_windows":[{"id":"reset-credits","title":"Reset credits","window":{"used_percent":0,
                "resets_at":"2026-10-03T12:00:00Z","reset_description":"2 reset credits available","is_informational":true}}],
            "updated_at":"2026-09-11T08:00:00Z"},
            "cost":{"used":0.0,"currency_code":"USD","period":"Credits","updated_at":"2026-09-11T08:00:00Z"}}]"#;
        let eval = evaluate(parse_output(json).unwrap(), Provider::Codex, now(), Duration::from_secs(900));
        assert_eq!(eval.status, Status::Ok);
        let entry = eval.entry.unwrap();
        assert!(entry.primary.is_none(), "Session-Platzhalter ist kein Fenster");
        assert!(entry.extra_windows.is_empty(), "Reset Credits sind kein Fenster");
        assert_eq!(entry.credits, Some(Credits { available: true, balance: None }));
        let reset = entry.reset_credits.unwrap();
        assert_eq!(reset.count, 2);
        assert_eq!(reset.next_expires_at, parse_timestamp("2026-10-03T12:00:00Z"));
    }

    #[test]
    fn win_codexbar_credit_balance_and_monthly_cap() {
        let with_cost = |cost: &str| {
            let json = format!(r#"[{{"provider":"codex","usage":{{"secondary":{{"used_percent":5}},
                "updated_at":"2026-09-11T08:00:00Z"}},"cost":{cost}}}]"#);
            evaluate(parse_output(json.as_bytes()).unwrap(), Provider::Codex, now(), Duration::from_secs(900))
                .entry
                .unwrap()
                .credits
        };
        assert_eq!(with_cost(r#"{"used":412.5,"period":"Credits"}"#), Some(Credits { available: true, balance: Some(412.5) }));
        assert_eq!(with_cost(r#"{"used":300,"limit":1000,"period":"Monthly credits"}"#), Some(Credits { available: true, balance: Some(700.0) }));
        assert_eq!(with_cost(r#"{"used":12,"period":"This month (API key)"}"#), None);
        assert_eq!(with_cost("null"), None);
    }

    #[test]
    fn upstream_credits_distinguish_hidden_pool_from_known_balance() {
        let with_credits = |credits: &str| {
            let json = format!(r#"[{{"provider":"codex","usage":{{"secondary":{{"usedPercent":5}},
                "updatedAt":"2026-09-11T08:00:00Z"}},"credits":{credits}}}]"#);
            evaluate(parse_output(json.as_bytes()).unwrap(), Provider::Codex, now(), Duration::from_secs(900))
                .entry
                .unwrap()
                .credits
        };
        // Admin: Workspace-Stand lesbar.
        assert_eq!(
            with_credits(r#"{"remaining":237.75,"balanceReadSucceeded":true,"creditsAvailable":true,"balanceIsWorkspace":true,"events":[]}"#),
            Some(Credits { available: true, balance: Some(237.75) })
        );
        // Mitglied: Pool gemeldet, Stand zurückgehalten.
        assert_eq!(
            with_credits(r#"{"remaining":0,"balanceReadSucceeded":false,"creditsAvailable":true,"balanceIsWorkspace":false,"events":[]}"#),
            Some(Credits { available: true, balance: None })
        );
        // Ausdrücklich kein Pool.
        assert_eq!(
            with_credits(r#"{"remaining":0,"balanceReadSucceeded":true,"creditsAvailable":false,"events":[]}"#),
            Some(Credits { available: false, balance: None })
        );
        // Persönliches Monatslimit ohne Workspace-Stand.
        assert_eq!(
            with_credits(r#"{"remaining":0,"balanceReadSucceeded":false,"creditsAvailable":true,"codexCreditLimit":{"used":300,"limit":1000,"remaining":700},"events":[]}"#),
            Some(Credits { available: true, balance: Some(700.0) })
        );
    }

    #[test]
    fn upstream_reset_credits_count_and_next_expiry() {
        let json = br#"[{"provider":"codex","usage":{"secondary":{"usedPercent":5},"updatedAt":"2026-09-11T08:00:00Z",
            "codexResetCredits":{"availableCount":2,"updatedAt":"2026-09-11T08:00:00Z","credits":[
                {"id":"a","reset_type":"x","status":"redeemed","granted_at":"2026-09-01T00:00:00Z","expires_at":"2026-09-12T00:00:00Z"},
                {"id":"b","reset_type":"x","status":"available","granted_at":"2026-09-01T00:00:00Z","expires_at":"2026-09-20T00:00:00Z"},
                {"id":"c","reset_type":"x","status":"available","granted_at":"2026-09-01T00:00:00Z","expires_at":"2026-09-15T00:00:00Z"}]}}}]"#;
        let entry = evaluate(parse_output(json).unwrap(), Provider::Codex, now(), Duration::from_secs(900)).entry.unwrap();
        let reset = entry.reset_credits.unwrap();
        assert_eq!(reset.count, 2);
        assert_eq!(reset.next_expires_at, parse_timestamp("2026-09-15T00:00:00Z"));

        let none = br#"[{"provider":"codex","usage":{"secondary":{"usedPercent":5},"updatedAt":"2026-09-11T08:00:00Z",
            "codexResetCredits":{"availableCount":0,"updatedAt":"2026-09-11T08:00:00Z","credits":[]}}}]"#;
        let entry = evaluate(parse_output(none).unwrap(), Provider::Codex, now(), Duration::from_secs(900)).entry.unwrap();
        assert!(entry.reset_credits.is_none(), "0 Reset Credits nicht senden");
    }

    #[test]
    fn garbage_is_parse_error() {
        assert!(matches!(parse_output(b"not json"), Err(Status::ParseError { .. })));
        assert!(matches!(parse_output(b"[]"), Err(Status::ParseError { .. })));
    }
}
