//! Geteilter Zustand der App. Die Mutexe werden nur kurz gehalten, nie über
//! den blockierenden CLI-Aufruf oder einen seriellen Zugriff hinweg (siehe
//! `poll` und `serial_service`).

use crate::serial_service::{ConnectionSnapshot, Job};
use crate::settings::Settings;
use crate::updates::ReleaseCache;
use aimonitor_core::{DeviceRegistry, Snapshot, Source};
use aimonitor_core::Provider;
use std::collections::HashMap;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::Sender;
use std::sync::{Condvar, Mutex};
use tauri::{tray::TrayIcon, AppHandle, Manager};

pub struct AppState {
    pub source: Mutex<Source>,
    pub view_sources: Mutex<HashMap<Provider, Snapshot>>,
    pub view_fetching: AtomicBool,
    pub view_refresh_pending: AtomicBool,
    pub settings: Mutex<Settings>,
    pub tray: Mutex<Option<TrayIcon>>,
    pub registry: Mutex<DeviceRegistry>,
    /// Zuletzt veröffentlichter Verbindungszustand, geschrieben vom Serial-Thread.
    pub connection: Mutex<ConnectionSnapshot>,
    /// Aufträge an den Serial-Thread.
    pub serial: Sender<Job>,
    /// Zuletzt geladene GitHub-Releases mit Zeitstempel (Phase 3).
    pub releases: Mutex<ReleaseCache>,
    /// `true`, solange eine Release-Abfrage läuft; parallele Aufrufe warten
    /// über die Condvar auf das Ergebnis, statt selbst zu laden.
    pub release_check: (Mutex<bool>, Condvar),
    /// Ein Flash-Vorgang läuft; ein zweiter wird abgewiesen.
    pub flashing: AtomicBool,
    /// Ein App-Update wird gerade geladen oder installiert.
    pub installing: AtomicBool,
}

impl AppState {
    pub fn new(source: Source, settings: Settings, registry: DeviceRegistry, serial: Sender<Job>) -> Self {
        Self {
            source: Mutex::new(source),
            view_sources: Mutex::new(HashMap::new()),
            view_fetching: AtomicBool::new(false),
            view_refresh_pending: AtomicBool::new(false),
            settings: Mutex::new(settings),
            tray: Mutex::new(None),
            registry: Mutex::new(registry),
            connection: Mutex::new(ConnectionSnapshot::default()),
            serial,
            releases: Mutex::new(ReleaseCache::default()),
            release_check: (Mutex::new(false), Condvar::new()),
            flashing: AtomicBool::new(false),
            installing: AtomicBool::new(false),
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
