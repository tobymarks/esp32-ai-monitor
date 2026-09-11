//! Firmware-Flash aus der App (Spec 6.4): Port der aktiven Verbindung
//! nehmen, Serial-Service anhalten, Image mit `aimonitor_flash` schreiben,
//! Service fortsetzen. Fortschritt geht als Event `flash-progress` ans
//! Frontend; Fehler tragen Zusammenfassung und Detail als i18n-Schlüssel
//! (flash.err.*), dazu die Rohmeldung.
//!
//! Blockierend; der Command ruft [`run`] in `spawn_blocking` auf.

use crate::registry;
use crate::serial_service::{self, Job};
use crate::state::AppState;
use crate::updates;
use aimonitor_core::protocol::DisplayVariant;
use aimonitor_flash::{flash_image, FlashError, FlashEvent, FLASH_BAUD};
use serde::Serialize;
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

pub const FLASH_EVENT: &str = "flash-progress";
/// Wartezeit zwischen Port-Freigabe und Flash-Start (main.swift:1412).
const SETTLE_DELAY: Duration = Duration::from_millis(500);
/// Bestätigung des Serial-Threads für die Pause.
const PAUSE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlashProgress {
    /// downloading, connecting, connected, erasing, writing, verifying, rebooting, done, failed
    pub phase: &'static str,
    pub variant: DisplayVariant,
    pub percent: Option<u32>,
    /// Freitext, z. B. Chipname oder Rohfehler.
    pub message: Option<String>,
    /// Nur bei `failed`: i18n-Schlüssel flash.err.*.
    pub summary: Option<&'static str>,
    pub detail: Option<&'static str>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlashOutcome {
    pub variant: DisplayVariant,
    pub version: String,
    pub tag: String,
    pub port: String,
    pub seconds: f64,
}

/// Fehlerzuordnung wie `classifyFlashError` der Mac-App (main.swift:1570).
fn classify(error: &FlashError) -> (&'static str, &'static str) {
    match error {
        FlashError::Open(_) => ("flash.err.busy", "flash.err.busy.fix"),
        FlashError::Connect(_) => ("flash.err.nobootmode", "flash.err.bootmode.detail"),
        FlashError::Write(_) => ("flash.err.aborted", "flash.err.aborted.detail"),
        FlashError::EmptyImage => ("flash.err.nofile.title", "flash.err.nofile.detail"),
    }
}

fn emit(app: &AppHandle, progress: FlashProgress) {
    if let Err(e) = app.emit(FLASH_EVENT, &progress) {
        eprintln!("[flash] Event nicht gesendet: {e}");
    }
}

fn emit_phase(app: &AppHandle, variant: DisplayVariant, phase: &'static str, percent: Option<u32>, message: Option<String>) {
    emit(app, FlashProgress { phase, variant, percent, message, summary: None, detail: None });
}

fn emit_failed(app: &AppHandle, variant: DisplayVariant, summary: &'static str, detail: &'static str, message: String) {
    eprintln!("[flash] Fehlgeschlagen: {summary} ({message})");
    emit(app, FlashProgress { phase: "failed", variant, percent: None, message: Some(message), summary: Some(summary), detail: Some(detail) });
}

/// Setzt das Flash-Flag beim Verlassen zurück, auch bei frühem `return`.
struct FlashGuard<'a>(&'a AppState);

impl Drop for FlashGuard<'_> {
    fn drop(&mut self) {
        self.0.flashing.store(false, Ordering::SeqCst);
    }
}

/// Kompletter Ablauf: Download (falls nötig), Pause, Flash, Resume.
/// Fehler kommen als i18n-Schlüssel zurück; das Detail steht im Event.
pub fn run(app: &AppHandle, variant: DisplayVariant) -> Result<FlashOutcome, String> {
    let state = app.state::<AppState>();
    if state.flashing.swap(true, Ordering::SeqCst) {
        return Err("flash.err.running".into());
    }
    let _guard = FlashGuard(&state);

    let port = state.connection.lock().unwrap().port.clone().ok_or_else(|| "esp32.none.info".to_string())?;
    println!("[flash] Start: Variante {} auf {port}", variant.wire());

    // Firmware-Datei sicherstellen; der Download meldet sich über firmware-download.
    emit_phase(app, variant, "downloading", None, None);
    let file = match updates::download_firmware(app, variant) {
        Ok(f) => f,
        Err(e) => {
            emit_failed(app, variant, "flash.err.nofile.title", "flash.err.nofile.detail", e.clone());
            return Err(e);
        }
    };
    if file.fallback {
        println!("[flash] Hinweis: kein Asset für {}, Standard-Image {} wird verwendet", variant.wire(), file.asset);
    }
    let image = match std::fs::read(&file.path) {
        Ok(bytes) => bytes,
        Err(e) => {
            let msg = format!("{}: {e}", file.path.display());
            emit_failed(app, variant, "flash.err.nofile.title", "flash.err.nofile.detail", msg.clone());
            return Err(msg);
        }
    };

    // Serial-Service anhalten und auf die Freigabe des Ports warten.
    let (tx, rx) = mpsc::channel();
    serial_service::send(app, Job::Pause(tx));
    if rx.recv_timeout(PAUSE_TIMEOUT).is_err() {
        let msg = "Serial-Service hat die Pause nicht bestätigt".to_string();
        emit_failed(app, variant, "flash.err.busy", "flash.err.busy.fix", msg.clone());
        serial_service::send(app, Job::Resume { diagnostic_after_connect: false });
        return Err(msg);
    }
    println!("[flash] Pause bestätigt, Port {port} frei; {} B ab 0x0 mit {FLASH_BAUD} Baud", image.len());
    std::thread::sleep(SETTLE_DELAY);

    let started = Instant::now();
    let app_events = app.clone();
    let mut last_percent: Option<u32> = None;
    let result = flash_image(&port, &image, FLASH_BAUD, &mut |event| {
        let (phase, percent, message) = match &event {
            FlashEvent::Connecting => ("connecting", None, None),
            FlashEvent::Connected { chip } => ("connected", None, Some(chip.clone())),
            FlashEvent::Erasing => ("erasing", None, None),
            FlashEvent::Writing { .. } => ("writing", event.percent(), None),
            FlashEvent::Verifying => ("verifying", None, None),
            FlashEvent::Rebooting => ("rebooting", None, None),
            FlashEvent::Done => ("done", Some(100), None),
        };
        // Schreibfortschritt nur bei geänderter Prozentzahl, Log alle 10 %.
        if phase == "writing" {
            if percent == last_percent {
                return;
            }
            if percent.map(|p| p % 10 == 0).unwrap_or(false) {
                println!("[flash] {:>6.1?} writing {}%", started.elapsed(), percent.unwrap_or(0));
            }
            last_percent = percent;
        } else {
            println!("[flash] {:>6.1?} {phase}{}", started.elapsed(), message.as_deref().map(|m| format!(" ({m})")).unwrap_or_default());
        }
        emit_phase(&app_events, variant, phase, percent, message);
    });

    let outcome = match result {
        Ok(()) => {
            let seconds = started.elapsed().as_secs_f64();
            println!("[flash] Fertig nach {seconds:.1} s: {} {}", file.tag, variant.wire());
            {
                let mut settings = state.settings.lock().unwrap();
                settings.installed_firmware_version = Some(file.version.clone());
                settings.save(app);
            }
            {
                let mut reg = state.registry.lock().unwrap();
                if let Some(profile) = reg.current_profile_mut() {
                    profile.display_variant = Some(variant);
                    registry::save(app, &reg);
                }
            }
            Ok(FlashOutcome { variant, version: file.version.clone(), tag: file.tag.clone(), port: port.clone(), seconds })
        }
        Err(e) => {
            let (summary, detail) = classify(&e);
            emit_failed(app, variant, summary, detail, e.to_string());
            Err(summary.to_string())
        }
    };

    // Service in jedem Fall fortsetzen; Diagnose-Frame nur nach Erfolg.
    serial_service::send(app, Job::Resume { diagnostic_after_connect: outcome.is_ok() });
    updates::emit_status(app);
    outcome
}
