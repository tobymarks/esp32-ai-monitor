//! Geteilter Zustand der App. Die Mutexe werden nur kurz gehalten, nie über
//! den blockierenden CLI-Aufruf oder einen seriellen Zugriff hinweg (siehe
//! `poll` und `serial_service`).

use crate::serial_service::{ConnectionSnapshot, Job};
use crate::settings::Settings;
use aimonitor_core::{DeviceRegistry, Snapshot, Source};
use std::sync::mpsc::Sender;
use std::sync::Mutex;
use tauri::{tray::TrayIcon, AppHandle, Manager};

pub struct AppState {
    pub source: Mutex<Source>,
    pub settings: Mutex<Settings>,
    pub tray: Mutex<Option<TrayIcon>>,
    pub registry: Mutex<DeviceRegistry>,
    /// Zuletzt veröffentlichter Verbindungszustand, geschrieben vom Serial-Thread.
    pub connection: Mutex<ConnectionSnapshot>,
    /// Aufträge an den Serial-Thread.
    pub serial: Sender<Job>,
}

impl AppState {
    pub fn new(source: Source, settings: Settings, registry: DeviceRegistry, serial: Sender<Job>) -> Self {
        Self {
            source: Mutex::new(source),
            settings: Mutex::new(settings),
            tray: Mutex::new(None),
            registry: Mutex::new(registry),
            connection: Mutex::new(ConnectionSnapshot::default()),
            serial,
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
