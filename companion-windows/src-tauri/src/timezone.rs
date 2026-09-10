//! Zeitzone für `displayTime` und `tzOffsetMinutes` im Datenframe (Spec 5.2).
//! `auto` folgt der Systemzeitzone, sonst ein IANA-Name über `chrono-tz`.

use chrono::{DateTime, Local, Offset, TimeZone, Utc};
use chrono_tz::Tz;
use serde::Serialize;

pub const AUTO: &str = "auto";

/// Kurzliste wie `kTimeZonePopupIdentifiers` der Mac-App, ohne `auto`.
pub const POPULAR: [&str; 6] = [
    "Europe/Berlin",
    "Europe/London",
    "America/New_York",
    "America/Los_Angeles",
    "Asia/Tokyo",
    "Australia/Sydney",
];

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeZoneOption {
    pub id: String,
    /// Anzeigetext ohne Lokalisierung, z. B. `Europe/Berlin (UTC+02:00)`.
    pub label: String,
    pub offset_minutes: i32,
}

/// Prüft, ob die Kennung gültig ist (`auto` oder bekannter IANA-Name).
pub fn is_valid(id: &str) -> bool {
    id == AUTO || id.parse::<Tz>().is_ok()
}

/// Offset zu UTC in Minuten zum Zeitpunkt `now`. Unbekannte Namen fallen
/// auf die Systemzeitzone zurück.
pub fn offset_minutes(id: &str, now: DateTime<Utc>) -> i32 {
    if id != AUTO {
        if let Ok(tz) = id.parse::<Tz>() {
            return tz.offset_from_utc_datetime(&now.naive_utc()).fix().local_minus_utc() / 60;
        }
    }
    Local.offset_from_utc_datetime(&now.naive_utc()).fix().local_minus_utc() / 60
}

pub fn format_offset(minutes: i32) -> String {
    let sign = if minutes < 0 { '-' } else { '+' };
    let abs = minutes.abs();
    format!("UTC{sign}{:02}:{:02}", abs / 60, abs % 60)
}

/// `auto` plus Kurzliste; ein abweichend gespeicherter Wert wird angehängt,
/// damit die Auswahl im Frontend immer einen passenden Eintrag hat.
pub fn options(current: &str) -> Vec<TimeZoneOption> {
    let now = Utc::now();
    let mut ids: Vec<String> = std::iter::once(AUTO.to_string())
        .chain(POPULAR.iter().map(|s| s.to_string()))
        .collect();
    if current != AUTO && !ids.iter().any(|i| i == current) && is_valid(current) {
        ids.push(current.to_string());
    }
    ids.into_iter()
        .map(|id| {
            let offset = offset_minutes(&id, now);
            let label = if id == AUTO {
                format_offset(offset)
            } else {
                format!("{id} ({})", format_offset(offset))
            };
            TimeZoneOption { id, label, offset_minutes: offset }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn berlin_offset_in_summer_and_winter() {
        let summer = Utc.with_ymd_and_hms(2026, 7, 1, 12, 0, 0).unwrap();
        let winter = Utc.with_ymd_and_hms(2026, 1, 1, 12, 0, 0).unwrap();
        assert_eq!(offset_minutes("Europe/Berlin", summer), 120);
        assert_eq!(offset_minutes("Europe/Berlin", winter), 60);
        assert_eq!(offset_minutes("America/Los_Angeles", winter), -480);
        assert_eq!(format_offset(-480), "UTC-08:00");
        assert_eq!(format_offset(330), "UTC+05:30");
    }

    #[test]
    fn options_start_with_auto_and_append_custom() {
        let list = options("Asia/Kolkata");
        assert_eq!(list[0].id, AUTO);
        assert_eq!(list.len(), 1 + POPULAR.len() + 1);
        assert_eq!(list.last().unwrap().id, "Asia/Kolkata");
        assert!(!is_valid("Mars/Olympus"));
        assert_eq!(options("Mars/Olympus").len(), 1 + POPULAR.len());
    }
}
