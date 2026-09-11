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
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                eprintln!("[aimonitor] settings.json unlesbar ({e}), Defaults");
                Settings::default()
            }),
            Err(_) => Settings::default(),
        }
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
