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
