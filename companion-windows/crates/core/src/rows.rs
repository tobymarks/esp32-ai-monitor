//! Anzeigezeilen aus einem Eintrag bauen.
//! Port von `buildUsageEnvelope` in `main.swift` (Zeilenaufbau), ohne den
//! `usageRows`-Zweig: die Quelle liefert dort seit v1.24.0 immer `nil`.
//!
//! Das Gerät liest maximal drei Zeilen. Der Prozentwert ist bereits der
//! Anzeigewert: im Modus `Used` die verbrauchten, im Modus `Remaining` die
//! verbleibenden Prozent. Das Feld heißt auf dem Draht trotzdem `usedPercent`.

use crate::model::{Entry, Window};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum PercentMode {
    #[default]
    Used,
    Remaining,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    pub title: String,
    /// Anzeigeprozent 0..100, je nach Modus verbraucht oder verbleibend.
    pub used_percent: i32,
    pub resets_at: Option<DateTime<Utc>>,
    /// 0, wenn die Quelle keine Länge liefert und kein Default greift
    /// (Zusatzfenster), wie in der Mac-App.
    pub window_minutes: u32,
}

pub const MAX_ROWS: usize = 3;

fn rounded_used(w: &Window) -> i32 {
    w.used_percent.round() as i32
}

fn display_percent(used: i32, mode: PercentMode) -> i32 {
    let clamped = used.clamp(0, 100);
    match mode {
        PercentMode::Used => clamped,
        PercentMode::Remaining => 100 - clamped,
    }
}

pub fn build_rows(entry: &Entry, mode: PercentMode) -> Vec<Row> {
    let provider = entry.provider;
    let windows = entry.windows();
    let mut rows: Vec<Row> = Vec::with_capacity(MAX_ROWS);

    if provider.uses_model_rows() {
        // Modell-Kontingente kommen aus den Zusatzfenstern, inklusive Titel.
        if !entry.extra_windows.is_empty() {
            for extra in entry.extra_windows.iter().take(MAX_ROWS) {
                rows.push(Row {
                    id: extra.id.clone(),
                    title: extra.title.clone(),
                    used_percent: display_percent(rounded_used(&extra.window), mode),
                    resets_at: extra.window.resets_at,
                    window_minutes: extra.window.window_minutes.unwrap_or(0),
                });
            }
        } else {
            // Ohne Zusatzfenster drei feste Zeilen aus den Fenstern, auch wenn leer.
            let ids = ["primary", "secondary", "tertiary"];
            for (idx, id) in ids.iter().enumerate() {
                let w = windows[idx];
                rows.push(Row {
                    id: (*id).to_string(),
                    title: provider.default_row_title(idx).to_string(),
                    used_percent: display_percent(w.map(rounded_used).unwrap_or(0), mode),
                    resets_at: w.and_then(|w| w.resets_at),
                    window_minutes: w.and_then(|w| w.window_minutes).unwrap_or(0),
                });
            }
        }
        return rows;
    }

    // Generische Provider: nur Fenster, die die Quelle geliefert hat.
    for (idx, w) in windows.iter().enumerate() {
        let Some(w) = w else { continue };
        rows.push(Row {
            id: format!("row{idx}"),
            title: provider.default_row_title(idx).to_string(),
            used_percent: display_percent(rounded_used(w), mode),
            resets_at: w.resets_at,
            window_minutes: w
                .window_minutes
                .unwrap_or_else(|| provider.default_window_minutes(idx)),
        });
    }

    // Freie Plätze mit Zusatzfenstern auffüllen (z. B. Fable-Wochenlimit bei Claude).
    if rows.len() < MAX_ROWS {
        for extra in entry.extra_windows.iter().take(MAX_ROWS - rows.len()) {
            rows.push(Row {
                id: extra.id.clone(),
                title: extra.title.clone(),
                used_percent: display_percent(rounded_used(&extra.window), mode),
                resets_at: extra.window.resets_at,
                window_minutes: extra.window.window_minutes.unwrap_or(0),
            });
        }
    }

    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::ExtraWindow;
    use crate::provider::Provider;

    fn win(used: f64, minutes: Option<u32>) -> Window {
        Window {
            used_percent: used,
            resets_at: None,
            window_minutes: minutes,
            reset_description: None,
        }
    }

    fn extra(id: &str, title: &str, used: f64, minutes: Option<u32>) -> ExtraWindow {
        ExtraWindow {
            id: id.into(),
            title: title.into(),
            window: win(used, minutes),
        }
    }

    fn entry(provider: Provider) -> Entry {
        Entry {
            provider,
            updated_at: None,
            primary: None,
            secondary: None,
            tertiary: None,
            extra_windows: vec![],
            login_method: None,
        }
    }

    #[test]
    fn claude_two_windows_plus_extra() {
        let mut e = entry(Provider::Claude);
        e.primary = Some(win(37.4, Some(300)));
        e.secondary = Some(win(62.0, None));
        e.extra_windows = vec![extra("fable-weekly", "Fable weekly", 12.0, Some(10080))];
        let rows = build_rows(&e, PercentMode::Used);
        assert_eq!(rows.len(), 3);
        assert_eq!((rows[0].id.as_str(), rows[0].title.as_str(), rows[0].used_percent, rows[0].window_minutes), ("row0", "Session", 37, 300));
        assert_eq!((rows[1].id.as_str(), rows[1].title.as_str(), rows[1].used_percent, rows[1].window_minutes), ("row1", "Weekly", 62, 10080));
        assert_eq!((rows[2].id.as_str(), rows[2].title.as_str(), rows[2].used_percent), ("fable-weekly", "Fable weekly", 12));
    }

    #[test]
    fn remaining_mode_inverts_and_clamps() {
        let mut e = entry(Provider::Codex);
        e.primary = Some(win(137.0, Some(300)));
        e.secondary = Some(win(-4.0, Some(10080)));
        let rows = build_rows(&e, PercentMode::Remaining);
        assert_eq!(rows[0].used_percent, 0);
        assert_eq!(rows[1].used_percent, 100);
    }

    #[test]
    fn copilot_chat_only_yields_single_chat_row_with_month_default() {
        let mut e = entry(Provider::Copilot);
        e.secondary = Some(win(40.0, None));
        let rows = build_rows(&e, PercentMode::Used);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "row1");
        assert_eq!(rows[0].title, "Chat");
        assert_eq!(rows[0].window_minutes, 43200);
    }

    #[test]
    fn antigravity_uses_extra_windows_with_their_titles() {
        let mut e = entry(Provider::Antigravity);
        e.primary = Some(win(5.0, Some(300)));
        e.extra_windows = vec![
            extra("claude", "Claude/GPT weekly", 20.0, Some(10080)),
            extra("gemini-pro", "Gemini 5-hour", 55.0, Some(300)),
            extra("gemini-flash", "Gemini Flash", 1.0, None),
            extra("ignored", "Vierte", 99.0, None),
        ];
        let rows = build_rows(&e, PercentMode::Used);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].title, "Claude/GPT weekly");
        assert_eq!(rows[2].window_minutes, 0);
    }

    #[test]
    fn antigravity_without_extras_has_three_fixed_rows() {
        let mut e = entry(Provider::Antigravity);
        e.secondary = Some(win(50.0, Some(10080)));
        let rows = build_rows(&e, PercentMode::Used);
        assert_eq!(rows.len(), 3);
        assert_eq!(rows.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["primary", "secondary", "tertiary"]);
        assert_eq!(rows[0].used_percent, 0);
        assert_eq!(rows[1].used_percent, 50);
        assert_eq!(rows[1].title, "Gemini Pro");
    }

    #[test]
    fn gemini_three_daily_windows() {
        let mut e = entry(Provider::Gemini);
        e.primary = Some(win(62.0, Some(1440)));
        e.secondary = Some(win(18.5, Some(1440)));
        e.tertiary = Some(win(3.0, None));
        let rows = build_rows(&e, PercentMode::Used);
        assert_eq!(rows.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(), ["Pro", "Flash", "Flash Lite"]);
        assert_eq!(rows[1].used_percent, 19, "Rundung wie Swift .rounded()");
        assert_eq!(rows[2].window_minutes, 1440);
    }
}
