//! Geteilter Zustand der App. Die Mutexe werden nur kurz gehalten, nie über
//! den blockierenden CLI-Aufruf hinweg (siehe `poll`).

use crate::settings::Settings;
use aimonitor_core::{Snapshot, Source};
use std::sync::Mutex;
use tauri::{tray::TrayIcon, AppHandle, Manager};

pub struct AppState {
    pub source: Mutex<Source>,
    pub settings: Mutex<Settings>,
    pub tray: Mutex<Option<TrayIcon>>,
}

impl AppState {
    pub fn new(source: Source, settings: Settings) -> Self {
        Self {
            source: Mutex::new(source),
            settings: Mutex::new(settings),
            tray: Mutex::new(None),
        }
    }
}

/// Aktueller Snapshot mit dem Prozentmodus aus den Einstellungen.
/// Sperrreihenfolge: erst Einstellungen, dann Quelle, nie beide gleichzeitig.
pub fn current_snapshot(app: &AppHandle) -> Snapshot {
    let state = app.state::<AppState>();
    let mode = state.settings.lock().unwrap().percent_mode;
    let snap = state.source.lock().unwrap().snapshot(mode);
    snap
}
