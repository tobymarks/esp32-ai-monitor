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
use aimonitor_flash::{flash_image, validate_merged_image, FlashError, FlashEvent, MAX_IMAGE_BYTES, FLASH_BAUD};
use serde::Serialize;
use std::path::PathBuf;
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
    emit(app, FlashProgress { phase: "failed", variant, percent: None, message: (!message.is_empty()).then_some(message), summary: Some(summary), detail: Some(detail) });
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
    run_with_image(app, variant, None)
}

pub fn run_with_image(app: &AppHandle, variant: DisplayVariant, local_path: Option<PathBuf>) -> Result<FlashOutcome, String> {
    let state = app.state::<AppState>();
    if state.flashing.swap(true, Ordering::SeqCst) {
        return Err("flash.err.running".into());
    }
    let _guard = FlashGuard(&state);

    let port = state.connection.lock().unwrap().port.clone().ok_or_else(|| "esp32.none.info".to_string())?;
    println!("[flash] Start: Variante {} auf {port}", variant.wire());

    // Firmware-Datei sicherstellen; der Download meldet sich über firmware-download.
    let (image, release) = if let Some(path) = local_path {
        let valid_extension = path.extension().and_then(|ext| ext.to_str()).is_some_and(|ext| ext.eq_ignore_ascii_case("bin"));
        let metadata = std::fs::metadata(&path).map_err(|e| {
            let msg = e.to_string();
            emit_failed(app, variant, "flash.err.nofile.title", "flash.err.nofile.detail", msg.clone());
            msg
        })?;
        if !valid_extension || !metadata.is_file() || metadata.len() > MAX_IMAGE_BYTES {
            emit_failed(app, variant, "flash.err.invalid.title", "flash.local.format", String::new());
            return Err("flash.local.format".into());
        }
        let image = std::fs::read(&path).map_err(|e| {
            let msg = e.to_string();
            emit_failed(app, variant, "flash.err.nofile.title", "flash.err.nofile.detail", msg.clone());
            msg
        })?;
        (image, None)
    } else {
        emit_phase(app, variant, "downloading", None, None);
        let file = updates::download_firmware(app, variant).map_err(|e| {
            emit_failed(app, variant, "flash.err.nofile.title", "flash.err.nofile.detail", e.clone());
            e
        })?;
        if file.fallback {
            println!("[flash] Hinweis: kein Asset für {}, Standard-Image {} wird verwendet", variant.wire(), file.asset);
        }
        let image = std::fs::read(&file.path).map_err(|e| {
            let msg = format!("{}: {e}", file.path.display());
            emit_failed(app, variant, "flash.err.nofile.title", "flash.err.nofile.detail", msg.clone());
            msg
        })?;
        (image, Some(file))
    };
    if let Err(reason) = validate_merged_image(&image) {
        eprintln!("[flash] Ungültiges Image: {reason:?}");
        let detail = if let Some(file) = &release {
            if let Err(e) = std::fs::remove_file(&file.path) {
                eprintln!("[flash] Ungültige Cache-Datei konnte nicht gelöscht werden: {e}");
            }
            "flash.release.corrupt"
        } else {
            "flash.local.format"
        };
        emit_failed(app, variant, "flash.err.invalid.title", detail, String::new());
        return Err(detail.into());
    }

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
            println!("[flash] Fertig nach {seconds:.1} s: {}", variant.wire());
            {
                let mut settings = state.settings.lock().unwrap();
                settings.installed_firmware_version = release.as_ref().map(|file| file.version.clone());
                settings.save(app);
            }
            {
                let mut reg = state.registry.lock().unwrap();
                if let Some(profile) = reg.current_profile_mut() {
                    profile.display_variant = Some(variant);
                    registry::save(app, &reg);
                }
            }
            Ok(FlashOutcome { variant, version: release.as_ref().map_or("local".to_string(), |file| file.version.clone()), tag: release.as_ref().map_or("local".to_string(), |file| file.tag.clone()), port: port.clone(), seconds })
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
