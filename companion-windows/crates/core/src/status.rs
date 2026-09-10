//! Zustand der Datenquelle. Entspricht `CodexBarStatus` der Mac-App.
//!
//! Die Texte für Oberfläche und Gerät liefert nicht dieses Modul, sondern die
//! Lokalisierung der App anhand von `kind`. Hier stehen nur die Fakten.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Status {
    Ok,
    /// Initialzustand vor dem ersten Lauf.
    NotYet,
    /// codexbar-Binary nicht gefunden.
    CliMissing,
    /// CLI erreichbar, aber der Provider liefert nicht.
    ProviderUnavailable { message: String },
    /// Aufruf fehlgeschlagen oder Timeout.
    CliFailed { message: String },
    /// Daten vorhanden, aber älter als die Stale-Schwelle.
    Stale { age_seconds: u64 },
    /// Antwort nicht lesbar.
    ParseError { message: String },
}

impl Status {
    pub fn is_ok(&self) -> bool {
        matches!(self, Status::Ok)
    }

    /// Kurzform für Logs und Diagnose, bewusst nicht lokalisiert.
    pub fn short_label(&self) -> String {
        match self {
            Status::Ok => "OK".into(),
            Status::NotYet => "…".into(),
            Status::CliMissing => "CLI missing".into(),
            Status::ProviderUnavailable { .. } => "offline".into(),
            Status::CliFailed { .. } => "failed".into(),
            Status::Stale { age_seconds } => format!("stale ({}m alt)", age_seconds / 60),
            Status::ParseError { .. } => "parse error".into(),
        }
    }

    /// Schlüssel des Hinweistexts fürs Display, wie `displayNotice` der Mac-App.
    /// `None` heißt: kein Hinweis, Daten normal anzeigen.
    pub fn display_notice_key(&self) -> Option<&'static str> {
        match self {
            Status::Ok | Status::NotYet => None,
            Status::CliMissing => Some("dsp.notice.climissing"),
            Status::ProviderUnavailable { .. } => Some("dsp.notice.startapp"),
            Status::CliFailed { .. } => Some("dsp.notice.failed"),
            Status::Stale { .. } => Some("dsp.notice.stale"),
            Status::ParseError { .. } => Some("dsp.notice.parse"),
        }
    }
}
