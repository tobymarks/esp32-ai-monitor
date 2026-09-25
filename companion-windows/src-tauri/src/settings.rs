//! Persistente Einstellungen der App als JSON unter `app_config_dir()/settings.json`.

use aimonitor_core::release::UpdateChannel;
use aimonitor_core::{PercentMode, Provider};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

/// Sprache der Oberfläche. `System` folgt der Betriebssystemsprache.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Language {
    #[default]
    System,
    De,
    En,
}

/// Inhalt eines Display-Fensters. Eine Quelle darf in mehreren Fenstern liegen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "provider", rename_all = "lowercase")]
pub enum ViewContent {
    Clock,
    Provider(Provider),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ViewMode {
    #[default]
    Manual,
    Automatic,
}

pub const MAX_VIEWS: usize = 8;
fn default_views() -> Vec<ViewContent> { vec![ViewContent::Provider(Provider::DEFAULT)] }
fn default_view_interval() -> u16 { 10 }

impl Language {
    /// Tatsächlich zu verwendende Sprache: "de" oder "en".
    pub fn effective(self) -> &'static str {
        match self {
            Language::De => "de",
            Language::En => "en",
            Language::System => {
                let locale = sys_locale::get_locale().unwrap_or_default().to_ascii_lowercase();
                if locale.starts_with("de") {
                    "de"
                } else {
                    "en"
                }
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default = "default_provider")]
    pub provider: Provider,
    #[serde(default = "default_views")]
    pub views: Vec<ViewContent>,
    #[serde(default)]
    pub view_mode: ViewMode,
    #[serde(default = "default_view_interval")]
    pub view_interval_seconds: u16,
    #[serde(default)]
    pub active_view: usize,
    #[serde(default)]
    pub percent_mode: PercentMode,
    #[serde(default)]
    pub language: Language,
    #[serde(default)]
    pub autostart: bool,
    /// Fest gewählter serieller Port; `None` heißt automatische Wahl.
    #[serde(default)]
    pub manual_port: Option<String>,
    /// `auto` (Systemzeitzone) oder ein IANA-Name wie `Europe/Berlin`.
    #[serde(default = "default_timezone")]
    pub timezone: String,
    /// Release-Kanal für App und Firmware (Phase 3).
    #[serde(default)]
    pub update_channel: UpdateChannel,
    /// Version der zuletzt aus dieser App geflashten Firmware (Tag ohne Präfix).
    #[serde(default)]
    pub installed_firmware_version: Option<String>,
    /// Zeitpunkt der letzten erfolgreichen Release-Abfrage.
    #[serde(default)]
    pub last_update_check: Option<DateTime<Utc>>,
}

fn default_timezone() -> String {
    "auto".into()
}

fn default_provider() -> Provider {
    Provider::DEFAULT
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            provider: Provider::DEFAULT,
            views: default_views(),
            view_mode: ViewMode::Manual,
            view_interval_seconds: default_view_interval(),
            active_view: 0,
            percent_mode: PercentMode::Used,
            language: Language::System,
            autostart: false,
            manual_port: None,
            timezone: default_timezone(),
            update_channel: UpdateChannel::Stable,
            installed_firmware_version: None,
            last_update_check: None,
        }
    }
}

impl Settings {
    fn path(app: &AppHandle) -> Option<PathBuf> {
        app.path().app_config_dir().ok().map(|d| d.join("settings.json"))
    }

    /// Laden; bei fehlender oder unlesbarer Datei die Defaults.
    pub fn load(app: &AppHandle) -> Settings {
        let Some(path) = Self::path(app) else {
            return Settings::default();
        };
        match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Settings>(&bytes).map(|mut s| {
                // Vor der Fensterverwaltung war `provider` die einzige Anzeige.
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                    if v.get("views").is_none() { s.views = vec![ViewContent::Provider(s.provider)]; }
                }
                s.normalize_views();
                s
            }).unwrap_or_else(|e| {
                eprintln!("[aimonitor] settings.json unlesbar ({e}), Defaults");
                Settings::default()
            }),
            Err(_) => Settings::default(),
        }
    }

    pub fn normalize_views(&mut self) {
        if self.views.is_empty() { self.views = default_views(); }
        self.views.truncate(MAX_VIEWS);
        self.view_interval_seconds = self.view_interval_seconds.clamp(2, 3600);
        self.active_view = self.active_view.min(self.views.len() - 1);
    }

    pub fn save(&self, app: &AppHandle) {
        let Some(path) = Self::path(app) else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        match serde_json::to_vec_pretty(self) {
            Ok(bytes) => {
                if let Err(e) = std::fs::write(&path, bytes) {
                    eprintln!("[aimonitor] Einstellungen nicht gespeichert: {e}");
                }
            }
            Err(e) => eprintln!("[aimonitor] Einstellungen nicht serialisierbar: {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn view_settings_keep_one_window_and_clamp_limits() {
        let mut settings = Settings::default();
        settings.views.clear();
        settings.active_view = 99;
        settings.view_interval_seconds = 1;
        settings.normalize_views();
        assert_eq!(settings.views, vec![ViewContent::Provider(Provider::Claude)]);
        assert_eq!(settings.active_view, 0);
        assert_eq!(settings.view_interval_seconds, 2);

        settings.views = vec![ViewContent::Clock; MAX_VIEWS + 2];
        settings.active_view = MAX_VIEWS + 1;
        settings.normalize_views();
        assert_eq!(settings.views.len(), MAX_VIEWS);
        assert_eq!(settings.active_view, MAX_VIEWS - 1);
    }

    #[test]
    fn view_content_has_a_stable_wire_shape() {
        assert_eq!(serde_json::to_value(ViewContent::Clock).unwrap(), serde_json::json!({"kind":"clock"}));
        assert_eq!(serde_json::to_value(ViewContent::Provider(Provider::Codex)).unwrap(),
                   serde_json::json!({"kind":"provider","provider":"codex"}));
    }
}
