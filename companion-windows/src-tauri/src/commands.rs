//! Tauri-Commands für das Einstellungsfenster.

use crate::poll;
use crate::settings::Settings;
use crate::state::{current_snapshot, AppState};
use crate::window;
use aimonitor_core::{Provider, Snapshot};
use chrono::Utc;
use serde::Serialize;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_autostart::ManagerExt;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    key: &'static str,
    label: &'static str,
    login_label: &'static str,
}

/// Provider wechseln, Einstellungen speichern, Abruf anstoßen.
/// Wird von Tray und Frontend benutzt.
pub fn apply_provider(app: &AppHandle, provider: Provider) {
    let state = app.state::<AppState>();
    let changed = state.source.lock().unwrap().set_provider(provider, Utc::now());
    {
        let mut settings = state.settings.lock().unwrap();
        if settings.provider != provider {
            settings.provider = provider;
            settings.save(app);
        }
    }
    if changed {
        poll::emit_snapshot(app);
    }
    poll::start_fetch(app);
}

/// Autostart über das Plugin setzen. Fehler werden gemeldet, nicht verschluckt.
fn apply_autostart(app: &AppHandle, enabled: bool) -> Result<(), String> {
    let manager = app.autolaunch();
    let result = if enabled { manager.enable() } else { manager.disable() };
    result.map_err(|e| format!("Autostart: {e}"))
}

#[tauri::command]
pub fn get_snapshot(app: AppHandle) -> Snapshot {
    current_snapshot(&app)
}

#[tauri::command]
pub fn set_provider(app: AppHandle, provider: Provider) {
    apply_provider(&app, provider);
}

#[tauri::command]
pub fn refresh(app: AppHandle) {
    poll::start_fetch(&app);
}

#[tauri::command]
pub fn get_settings(state: State<'_, AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
pub fn set_settings(app: AppHandle, settings: Settings) -> Result<Settings, String> {
    let state = app.state::<AppState>();
    let previous = state.settings.lock().unwrap().clone();

    let mut next = settings;
    let mut error = None;
    if next.autostart != previous.autostart {
        if let Err(e) = apply_autostart(&app, next.autostart) {
            eprintln!("[aimonitor] {e}");
            next.autostart = previous.autostart;
            error = Some(e);
        }
    }

    *state.settings.lock().unwrap() = next.clone();
    next.save(&app);

    if next.provider != previous.provider {
        apply_provider(&app, next.provider);
    } else {
        // Prozentmodus oder Sprache: Snapshot und Tray neu aufbauen.
        poll::emit_snapshot(&app);
    }

    match error {
        Some(e) => Err(e),
        None => Ok(next),
    }
}

#[tauri::command]
pub fn list_providers() -> Vec<ProviderInfo> {
    Provider::ALL
        .iter()
        .map(|p| ProviderInfo {
            key: p.key(),
            label: p.display_label(),
            login_label: p.login_label(),
        })
        .collect()
}

#[tauri::command]
pub fn rescan_cli(app: AppHandle) {
    app.state::<AppState>().source.lock().unwrap().rescan_cli();
    poll::emit_snapshot(&app);
}

#[tauri::command]
pub fn open_settings(app: AppHandle) {
    window::open_settings(&app);
}
