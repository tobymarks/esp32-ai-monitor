//! Abrufzyklus: beim Start und alle `POLL_INTERVAL`, dazu auf Anforderung.
//! Der CLI-Aufruf läuft in `spawn_blocking`, die Sperren werden davor und
//! danach jeweils nur kurz gehalten.

use crate::serial_service;
use crate::settings::ViewContent;
use crate::state::{current_snapshot, AppState};
use crate::tray;
use aimonitor_core::{source, POLL_INTERVAL, Provider, Source};
use std::sync::atomic::Ordering;
use tauri::{AppHandle, Emitter, Manager};

pub const SNAPSHOT_EVENT: &str = "snapshot-changed";

/// Snapshot ans Frontend schicken, Tray-Tooltip nachziehen und dem Gerät
/// einen Datenframe über den Debounce anbieten.
pub fn emit_snapshot(app: &AppHandle) {
    let snap = current_snapshot(app);
    if let Err(e) = app.emit(SNAPSHOT_EVENT, &snap) {
        eprintln!("[aimonitor] Event nicht gesendet: {e}");
    }
    tray::refresh(app);
    serial_service::request_resend(app);
}

/// Abruf starten, falls keiner läuft (sonst wird er in der Quelle vorgemerkt).
pub fn start_fetch(app: &AppHandle) {
    let state = app.state::<AppState>();
    let (provider, cli) = {
        let mut src = state.source.lock().unwrap();
        let provider = src.begin_fetch();
        (provider, src.cli_path().map(|p| p.to_path_buf()))
    };
    emit_snapshot(app);
    let Some(provider) = provider else { return };

    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let outcome =
            tauri::async_runtime::spawn_blocking(move || source::fetch(cli.as_deref(), provider)).await;
        let Ok(outcome) = outcome else {
            eprintln!("[aimonitor] Abruf-Thread abgebrochen");
            return;
        };
        let again = {
            let state = app.state::<AppState>();
            let mut src = state.source.lock().unwrap();
            src.apply(outcome)
        };
        {
            let snap = current_snapshot(&app);
            println!(
                "[aimonitor] {} → {} ({} Zeilen)",
                snap.provider,
                snap.status.short_label(),
                snap.rows.len()
            );
        }
        emit_snapshot(&app);
        if again {
            start_fetch(&app);
        }
    });
}

/// Timer-Thread: sofort abrufen, dann im festen Intervall.
pub fn start_timer(app: AppHandle) {
    std::thread::Builder::new()
        .name("aimonitor-poll".into())
        .spawn(move || loop {
            start_fetch(&app);
            refresh_views(&app);
            std::thread::sleep(POLL_INTERVAL);
        })
        .expect("Poll-Thread");
}

/// Zusätzliche Fenster unabhängig von der in der Übersicht gewählten Quelle
/// abrufen. Das Gerät erhält jeden Fensterstand einzeln, damit das 4-KiB-
/// Framelimit auch bei acht Fenstern eingehalten wird.
pub fn refresh_views(app: &AppHandle) {
    let state = app.state::<AppState>();
    if state.view_fetching.swap(true, Ordering::SeqCst) {
        state.view_refresh_pending.store(true, Ordering::SeqCst);
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let (views, selected, mode) = {
            let state = app.state::<AppState>();
            let s = state.settings.lock().unwrap();
            (s.views.clone(), s.provider, s.percent_mode)
        };
        let mut providers: Vec<Provider> = Vec::new();
        for view in views {
            if let ViewContent::Provider(p) = view {
                if p != selected && !providers.contains(&p) { providers.push(p); }
            }
        }
        let mut updated = false;
        for provider in providers {
            // Source wiederverwenden: Source::new sucht die CLI und startet `--version`.
            let kept = app.state::<AppState>().view_clients.lock().unwrap().remove(&provider);
            let result = tauri::async_runtime::spawn_blocking(move || {
                let mut src = kept.unwrap_or_else(|| Source::new(provider));
                src.begin_fetch();
                let outcome = source::fetch(src.cli_path(), provider);
                src.apply(outcome);
                let snapshot = src.snapshot(mode);
                (src, snapshot)
            }).await;
            if let Ok((src, snapshot)) = result {
                let state = app.state::<AppState>();
                state.view_clients.lock().unwrap().insert(provider, src);
                state.view_sources.lock().unwrap().insert(provider, snapshot);
                updated = true;
            }
        }
        if updated {
            serial_service::request_resend(&app);
        }
        let state = app.state::<AppState>();
        state.view_fetching.store(false, Ordering::SeqCst);
        if state.view_refresh_pending.swap(false, Ordering::SeqCst) {
            refresh_views(&app);
        }
    });
}
