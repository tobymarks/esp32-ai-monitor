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

use crate::model::{Entry, ExtraWindow, Window};
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

    let extras: Vec<ExtraWindow> = usage
        .extra_rate_windows
        .unwrap_or_default()
        .into_iter()
        .filter_map(|raw| {
            let id = raw.id?;
            let window = raw.window?;
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
        primary: usage.primary.map(to_window),
        secondary: usage.secondary.map(to_window),
        tertiary: usage.tertiary.map(to_window),
        extra_windows: extras,
        login_method: usage.login_method,
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
    fn garbage_is_parse_error() {
        assert!(matches!(parse_output(b"not json"), Err(Status::ParseError { .. })));
        assert!(matches!(parse_output(b"[]"), Err(Status::ParseError { .. })));
    }
}
