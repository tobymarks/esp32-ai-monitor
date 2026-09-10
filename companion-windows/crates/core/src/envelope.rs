//! Datenframes zum Gerät: Usage-, Notice- und Diagnose-Frame (Spec 5.2 bis 5.4).
//! Port von `buildUsageEnvelope`, `sendNoticeToESP32` und
//! `sendDiagnosticTestFrame` aus `main.swift`.

use crate::model::{Entry, Window};
use crate::protocol::{display_safe_text, SCHEMA_VERSION};
use crate::provider::Provider;
use crate::rows::{build_rows, PercentMode};
use chrono::{DateTime, Duration as ChronoDuration, FixedOffset, Utc};
use serde_json::{json, Value};

/// Zeitkontext eines Frames: `time` setzt die Geräteuhr, `displayTime` und
/// `tzOffsetMinutes` die lokale Anzeige.
#[derive(Debug, Clone)]
pub struct FrameContext {
    pub now: DateTime<Utc>,
    pub tz_offset_minutes: i32,
    pub fetching: bool,
}

impl FrameContext {
    pub fn new(now: DateTime<Utc>, tz_offset_minutes: i32, fetching: bool) -> Self {
        Self { now, tz_offset_minutes, fetching }
    }

    /// Exakt `YYYY-MM-DDTHH:MM:SSZ`, der Geräteparser liest per `sscanf` (Spec 9.6).
    pub fn time_iso(&self) -> String {
        self.now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
    }

    /// Lokale Uhrzeit `HH:MM` in der gewählten Zeitzone, maximal 5 Zeichen.
    pub fn display_time(&self) -> String {
        let offset = FixedOffset::east_opt(self.tz_offset_minutes * 60).unwrap_or_else(|| FixedOffset::east_opt(0).unwrap());
        self.now.with_timezone(&offset).format("%H:%M").to_string()
    }
}

fn iso(d: Option<DateTime<Utc>>) -> String {
    d.map(|d| d.format("%Y-%m-%dT%H:%M:%SZ").to_string()).unwrap_or_default()
}

fn display_percent(used: f64, mode: PercentMode) -> i64 {
    let clamped = (used.round() as i64).clamp(0, 100);
    match mode {
        PercentMode::Used => clamped,
        PercentMode::Remaining => 100 - clamped,
    }
}

/// Fenster-Objekt für `usage.primary` usw.: nur senden, wenn die Quelle es liefert.
fn window_value(w: &Window, index: usize, provider: Provider, mode: PercentMode) -> Value {
    json!({
        "usedPercent": display_percent(w.used_percent, mode),
        "resetsAt": iso(w.resets_at),
        "windowMinutes": w.window_minutes.unwrap_or_else(|| provider.default_window_minutes(index)),
    })
}

fn envelope(frame_id: i64, ctx: &FrameContext, data0: Value) -> String {
    let time = ctx.time_iso();
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "frameId": frame_id,
        "sentAt": time,
        "time": time,
        "displayTime": ctx.display_time(),
        "tzOffsetMinutes": ctx.tz_offset_minutes,
        "data": [data0],
    })
    .to_string()
}

/// Usage-Frame mit Zeilen, Fenstern und Login-Label (Spec 5.2).
pub fn usage_envelope(entry: &Entry, mode: PercentMode, ctx: &FrameContext, frame_id: i64) -> String {
    let provider = entry.provider;
    let rows: Vec<Value> = build_rows(entry, mode)
        .into_iter()
        .map(|r| {
            json!({
                "id": r.id,
                "title": r.title,
                "usedPercent": r.used_percent,
                "resetsAt": iso(r.resets_at),
                "windowMinutes": r.window_minutes,
            })
        })
        .collect();

    let mut usage = serde_json::Map::new();
    usage.insert("rows".into(), Value::Array(rows));
    usage.insert("loginMethod".into(), Value::String(provider.login_label().into()));
    for (idx, key) in ["primary", "secondary", "tertiary"].iter().enumerate() {
        if let Some(w) = entry.windows()[idx] {
            usage.insert((*key).into(), window_value(w, idx, provider, mode));
        }
    }

    envelope(
        frame_id,
        ctx,
        json!({
            "source": "codexbar",
            "provider": provider.key(),
            "fetching": ctx.fetching,
            "usage": Value::Object(usage),
        }),
    )
}

/// Notice-Frame: leere Zeilen plus Hinweistext, transliteriert (Spec 5.3).
pub fn notice_envelope(provider: Provider, notice: &str, ctx: &FrameContext, frame_id: i64) -> String {
    envelope(
        frame_id,
        ctx,
        json!({
            "source": "codexbar",
            "provider": provider.key(),
            "notice": display_safe_text(notice),
            "fetching": ctx.fetching,
            "usage": {
                "rows": [],
                "loginMethod": provider.login_label(),
            },
        }),
    )
}

/// Diagnose-Testframe mit festen Werten 42/68/17 (Spec 5.4).
pub fn diagnostic_envelope(provider: Provider, ctx: &FrameContext, frame_id: i64) -> String {
    let now = ctx.now;
    let primary_reset = iso(Some(now + ChronoDuration::minutes(35)));
    let secondary_reset = iso(Some(now + ChronoDuration::hours(52)));
    let tertiary_reset = iso(Some(now + ChronoDuration::hours(6)));

    let title = |index: usize| -> String {
        if provider.uses_model_rows() {
            provider.default_row_title(index).to_string()
        } else {
            match index {
                0 => "Test Session".into(),
                1 => "Test Weekly".into(),
                _ => "Test Extra".into(),
            }
        }
    };

    envelope(
        frame_id,
        ctx,
        json!({
            "source": "diagnostic",
            "provider": provider.key(),
            "usage": {
                "primary":   {"usedPercent": 42, "resetsAt": primary_reset,   "windowMinutes": 300},
                "secondary": {"usedPercent": 68, "resetsAt": secondary_reset, "windowMinutes": 10080},
                "tertiary":  {"usedPercent": 17, "resetsAt": tertiary_reset,  "windowMinutes": 1440},
                "rows": [
                    {"id": "primary",   "title": title(0), "usedPercent": 42, "resetsAt": primary_reset,   "windowMinutes": 300},
                    {"id": "secondary", "title": title(1), "usedPercent": 68, "resetsAt": secondary_reset, "windowMinutes": 10080},
                    {"id": "tertiary",  "title": title(2), "usedPercent": 17, "resetsAt": tertiary_reset,  "windowMinutes": 1440},
                ],
                "loginMethod": "AI Monitor Test",
            },
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ExtraWindow;
    use chrono::TimeZone;

    fn ctx() -> FrameContext {
        FrameContext::new(Utc.with_ymd_and_hms(2026, 9, 10, 13, 30, 0).unwrap(), 120, false)
    }

    fn win(used: f64, minutes: Option<u32>, resets: Option<DateTime<Utc>>) -> Window {
        Window { used_percent: used, resets_at: resets, window_minutes: minutes, reset_description: None }
    }

    #[test]
    fn context_formats_time_and_display_time() {
        let c = ctx();
        assert_eq!(c.time_iso(), "2026-09-10T13:30:00Z");
        assert_eq!(c.display_time(), "15:30");
        let neg = FrameContext::new(c.now, -300, false);
        assert_eq!(neg.display_time(), "08:30");
    }

    #[test]
    fn usage_frame_matches_spec_example() {
        let now = ctx().now;
        let entry = Entry {
            provider: Provider::Claude,
            updated_at: None,
            primary: Some(win(37.0, Some(300), Some(now + ChronoDuration::hours(3) + ChronoDuration::minutes(30)))),
            secondary: Some(win(62.0, Some(10080), Utc.with_ymd_and_hms(2026, 9, 14, 9, 0, 0).single())),
            tertiary: None,
            extra_windows: vec![ExtraWindow {
                id: "fable-weekly".into(),
                title: "Fable weekly".into(),
                window: win(12.0, Some(10080), Utc.with_ymd_and_hms(2026, 9, 14, 9, 0, 0).single()),
            }],
            login_method: None,
        };
        let s = usage_envelope(&entry, PercentMode::Used, &ctx(), 42);
        let v: Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["schemaVersion"], 1);
        assert_eq!(v["frameId"], 42);
        assert_eq!(v["time"], "2026-09-10T13:30:00Z");
        assert_eq!(v["displayTime"], "15:30");
        assert_eq!(v["tzOffsetMinutes"], 120);
        let d = &v["data"][0];
        assert_eq!(d["source"], "codexbar");
        assert_eq!(d["provider"], "claude");
        assert_eq!(d["fetching"], false);
        let u = &d["usage"];
        assert_eq!(u["loginMethod"], "Claude Max");
        assert_eq!(u["rows"].as_array().unwrap().len(), 3);
        assert_eq!(u["rows"][0]["title"], "Session");
        assert_eq!(u["rows"][0]["resetsAt"], "2026-09-10T17:00:00Z");
        assert_eq!(u["rows"][2]["id"], "fable-weekly");
        assert_eq!(u["primary"]["usedPercent"], 37);
        assert_eq!(u["secondary"]["windowMinutes"], 10080);
        assert!(u.get("tertiary").is_none(), "fehlende Fenster nicht senden");
        assert!(!s.contains('\n'));
    }

    #[test]
    fn remaining_mode_applies_to_windows_and_rows() {
        let entry = Entry {
            provider: Provider::Codex,
            updated_at: None,
            primary: Some(win(30.0, None, None)),
            secondary: None,
            tertiary: None,
            extra_windows: vec![],
            login_method: None,
        };
        let v: Value = serde_json::from_str(&usage_envelope(&entry, PercentMode::Remaining, &ctx(), 1)).unwrap();
        let u = &v["data"][0]["usage"];
        assert_eq!(u["primary"]["usedPercent"], 70);
        assert_eq!(u["primary"]["windowMinutes"], 300, "Default für Codex Index 0");
        assert_eq!(u["primary"]["resetsAt"], "");
        assert_eq!(u["rows"][0]["usedPercent"], 70);
    }

    #[test]
    fn notice_frame_is_transliterated_and_rowless() {
        let s = notice_envelope(Provider::Gemini, "Lade Provider …", &ctx(), 43);
        let v: Value = serde_json::from_str(&s).unwrap();
        let d = &v["data"][0];
        assert_eq!(d["notice"], "Lade Provider ...");
        assert_eq!(d["usage"]["rows"].as_array().unwrap().len(), 0);
        assert_eq!(d["usage"]["loginMethod"], "Gemini CLI");
        assert!(d["usage"].get("primary").is_none());
    }

    #[test]
    fn diagnostic_frame_has_fixed_values() {
        let v: Value = serde_json::from_str(&diagnostic_envelope(Provider::Antigravity, &ctx(), 7)).unwrap();
        let u = &v["data"][0]["usage"];
        assert_eq!(v["data"][0]["source"], "diagnostic");
        assert_eq!(u["rows"][0]["title"], "Claude");
        assert_eq!(u["rows"][1]["usedPercent"], 68);
        assert_eq!(u["primary"]["resetsAt"], "2026-09-10T14:05:00Z");
        assert_eq!(u["loginMethod"], "AI Monitor Test");
        let v: Value = serde_json::from_str(&diagnostic_envelope(Provider::Claude, &ctx(), 8)).unwrap();
        assert_eq!(v["data"][0]["usage"]["rows"][2]["title"], "Test Extra");
    }
}
