//! Persistente Einstellungen der App als JSON unter `app_config_dir()/settings.json`.

use aimonitor_core::{PercentMode, Provider};
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
