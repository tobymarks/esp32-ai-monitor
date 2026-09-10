//! Geräteprofile als JSON unter `app_config_dir()/devices.json`. Die Logik
//! (Auflösen nach MAC, Auto-Namen) liegt in `aimonitor_core::device`.

use aimonitor_core::DeviceRegistry;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

fn path(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("devices.json"))
}

/// Laden; bei fehlender oder unlesbarer Datei eine leere Registry.
pub fn load(app: &AppHandle) -> DeviceRegistry {
    let Some(path) = path(app) else {
        return DeviceRegistry::default();
    };
    match std::fs::read_to_string(&path) {
        Ok(text) => DeviceRegistry::from_json(&text).unwrap_or_else(|e| {
            eprintln!("[aimonitor] devices.json unlesbar ({e}), leere Registry");
            DeviceRegistry::default()
        }),
        Err(_) => DeviceRegistry::default(),
    }
}

pub fn save(app: &AppHandle, registry: &DeviceRegistry) {
    let Some(path) = path(app) else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Err(e) = std::fs::write(&path, registry.to_json()) {
        eprintln!("[aimonitor] Geräteprofile nicht gespeichert: {e}");
    }
}
