//! Internes Datenmodell, unabhängig vom JSON der CLI.
//! Entspricht `CodexBarWindow`, `CodexBarExtraWindow`, `CodexBarEntry` der Mac-App.

use crate::provider::Provider;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Ein Nutzungsfenster: verbrauchte Prozent plus Reset-Zeitpunkt und Länge.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub used_percent: f64,
    pub resets_at: Option<DateTime<Utc>>,
    pub window_minutes: Option<u32>,
    pub reset_description: Option<String>,
}

/// Benanntes Zusatzfenster (`extraRateWindows` bzw. `extra_rate_windows`),
/// z. B. das separate Fable-Wochenlimit bei Claude oder die Modell-Kontingente
/// bei Antigravity.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtraWindow {
    pub id: String,
    pub title: String,
    pub window: Window,
}

/// Zusatz-Credits (Codex): ob ein Credit-Pool gemeldet ist und, falls
/// lesbar, wie viel übrig ist. Den Workspace-Stand bekommen nur Owner und
/// Admins; für Mitglieder ist `balance` deshalb meist `None`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credits {
    pub available: bool,
    pub balance: Option<f64>,
}

/// Einlösbare Limit-Zurücksetzungen (Codex „Reset credits"): Anzahl plus
/// Ablauf des nächsten Credits. Kein Nutzungsfenster, daher kein Balken.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCredits {
    pub count: u32,
    pub next_expires_at: Option<DateTime<Utc>>,
}

/// Ein erfolgreich gelesener Stand eines Providers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub provider: Provider,
    pub updated_at: Option<DateTime<Utc>>,
    pub primary: Option<Window>,
    pub secondary: Option<Window>,
    pub tertiary: Option<Window>,
    #[serde(default)]
    pub extra_windows: Vec<ExtraWindow>,
    /// Vom CLI gemeldete Anmeldeart, nur zur Anzeige. Zum Gerät geht immer
    /// `Provider::login_label`, wie in der Mac-App.
    pub login_method: Option<String>,
    #[serde(default)]
    pub credits: Option<Credits>,
    #[serde(default)]
    pub reset_credits: Option<ResetCredits>,
}

impl Entry {
    /// Alle drei Fenster fehlen und keine Zusatzfenster: nichts Verwertbares.
    pub fn is_empty(&self) -> bool {
        self.primary.is_none()
            && self.secondary.is_none()
            && self.tertiary.is_none()
            && self.extra_windows.is_empty()
    }

    /// Fenster in Indexreihenfolge primary, secondary, tertiary.
    pub fn windows(&self) -> [Option<&Window>; 3] {
        [
            self.primary.as_ref(),
            self.secondary.as_ref(),
            self.tertiary.as_ref(),
        ]
    }
}
