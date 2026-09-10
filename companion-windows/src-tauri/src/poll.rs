//! Abrufzyklus: beim Start und alle `POLL_INTERVAL`, dazu auf Anforderung.
//! Der CLI-Aufruf läuft in `spawn_blocking`, die Sperren werden davor und
//! danach jeweils nur kurz gehalten.

use crate::state::{current_snapshot, AppState};
use crate::tray;
use aimonitor_core::{source, POLL_INTERVAL};
use tauri::{AppHandle, Emitter, Manager};

pub const SNAPSHOT_EVENT: &str = "snapshot-changed";

/// Snapshot ans Frontend schicken und Tray-Tooltip nachziehen.
pub fn emit_snapshot(app: &AppHandle) {
    let snap = current_snapshot(app);
    if let Err(e) = app.emit(SNAPSHOT_EVENT, &snap) {
        eprintln!("[aimonitor] Event nicht gesendet: {e}");
    }
    tray::refresh(app);
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
            std::thread::sleep(POLL_INTERVAL);
        })
        .expect("Poll-Thread");
}
