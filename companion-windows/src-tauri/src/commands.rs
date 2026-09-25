//! Tauri-Commands für das Einstellungsfenster.

use crate::flash::{self, FlashOutcome};
use crate::poll;
use crate::registry;
use crate::serial_service::{self, ConnectionSnapshot, Job};
use crate::settings::Settings;
use crate::state::{current_snapshot, AppState};
use crate::timezone::{self, TimeZoneOption};
use crate::updates::{self, FirmwareFile, InstallOutcome, UpdateStatus};
use crate::window;
use aimonitor_core::protocol::{DisplayVariant, Language as DisplayLanguage, Orientation, ThemeSetting};
use aimonitor_core::{DeviceProfile, Provider, Snapshot};
use aimonitor_serial::PortCandidate;
use chrono::Utc;
use serde::Serialize;
use tauri::{AppHandle, Manager, State};
use tauri_plugin_autostart::ManagerExt;

/// Längste erlaubte Gerätebezeichnung (SettingsWindow+Display.swift).
const MAX_DEVICE_NAME: usize = 30;

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
    if next.percent_mode != previous.percent_mode {
        serial_service::request_resend(&app);
    }
    if next.manual_port != previous.manual_port {
        serial_service::send(&app, Job::SetManualPort(next.manual_port.clone()));
    }
    if next.timezone != previous.timezone {
        serial_service::request_resend(&app);
    }
    if next.update_channel != previous.update_channel {
        // Anderer Kanal, andere Auswahl aus demselben Cache: Status neu melden.
        updates::emit_status(&app);
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

// ---------------------------------------------------------------------------
// Verbindung und Display (Phase 2)
// ---------------------------------------------------------------------------

#[tauri::command]
pub fn get_connection(state: State<'_, AppState>) -> ConnectionSnapshot {
    state.connection.lock().unwrap().clone()
}

#[tauri::command]
pub fn list_ports() -> Vec<PortCandidate> {
    aimonitor_serial::list_ports()
}

/// `None` oder leerer String heißt automatische Portwahl.
#[tauri::command]
pub fn set_manual_port(app: AppHandle, port: Option<String>) {
    let port = port.filter(|p| !p.trim().is_empty());
    let state = app.state::<AppState>();
    {
        let mut settings = state.settings.lock().unwrap();
        if settings.manual_port == port {
            return;
        }
        settings.manual_port = port.clone();
        settings.save(&app);
    }
    serial_service::send(&app, Job::SetManualPort(port));
}

#[tauri::command]
pub fn get_devices(state: State<'_, AppState>) -> Vec<DeviceProfile> {
    state.registry.lock().unwrap().devices.values().cloned().collect()
}

/// Gerät umbenennen. Fehler kommen als i18n-Schlüssel zurück (disp.name.err.*).
#[tauri::command]
pub fn rename_device(app: AppHandle, mac: String, name: String) -> Result<DeviceProfile, String> {
    let name = name.trim().to_string();
    if name.is_empty() {
        return Err("disp.name.err.empty".into());
    }
    if name.chars().count() > MAX_DEVICE_NAME {
        return Err("disp.name.err.long".into());
    }
    let profile = {
        let state = app.state::<AppState>();
        let mut registry = state.registry.lock().unwrap();
        if registry.is_name_taken(&name, Some(&mac)) {
            return Err("disp.name.err.dup".into());
        }
        let profile = registry.profile_mut(&mac).ok_or_else(|| "disp.profile.none".to_string())?;
        profile.friendly_name = name;
        let profile = profile.clone();
        registry::save(&app, &registry);
        profile
    };
    serial_service::send(&app, Job::RefreshProfile);
    Ok(profile)
}

/// Theme, Orientierung und Sprache eines Profils setzen. Ist das Gerät
/// verbunden, gehen nur die geänderten `set_*`-Kommandos raus.
#[tauri::command]
pub fn update_profile(
    app: AppHandle,
    mac: String,
    theme: ThemeSetting,
    orientation: Orientation,
    language: DisplayLanguage,
) -> Result<DeviceProfile, String> {
    let (profile, job) = {
        let state = app.state::<AppState>();
        let mut registry = state.registry.lock().unwrap();
        let is_current = registry.current_mac.as_deref() == Some(mac.as_str());
        let profile = registry.profile_mut(&mac).ok_or_else(|| "disp.profile.none".to_string())?;
        let job = Job::ApplyProfile {
            theme: (profile.theme != theme).then_some(theme),
            orientation: (profile.orientation != orientation).then_some(orientation),
            language: (profile.language != language).then_some(language),
        };
        profile.theme = theme;
        profile.orientation = orientation;
        profile.language = language;
        let profile = profile.clone();
        registry::save(&app, &registry);
        let job = if is_current { job } else { Job::RefreshProfile };
        (profile, job)
    };
    serial_service::send(&app, job);
    Ok(profile)
}

/// Helligkeit 5..100. `persist:false` ist die Vorschau während des Ziehens,
/// `persist:true` schreibt ins Profil und ins NVS des Geräts.
#[tauri::command]
pub fn set_brightness(app: AppHandle, value: i64, persist: bool) {
    let value = value.clamp(5, 100);
    if persist {
        let state = app.state::<AppState>();
        let mut registry = state.registry.lock().unwrap();
        if let Some(profile) = registry.current_profile_mut() {
            profile.brightness = value;
            registry::save(&app, &registry);
        }
    }
    serial_service::send(&app, Job::SetBrightness { value, persist });
}

#[tauri::command]
pub fn get_timezones(state: State<'_, AppState>) -> Vec<TimeZoneOption> {
    let current = state.settings.lock().unwrap().timezone.clone();
    timezone::options(&current)
}

#[tauri::command]
pub fn set_timezone(app: AppHandle, timezone: String) -> Result<(), String> {
    if !timezone::is_valid(&timezone) {
        return Err(format!("Unbekannte Zeitzone: {timezone}"));
    }
    let state = app.state::<AppState>();
    {
        let mut settings = state.settings.lock().unwrap();
        if settings.timezone == timezone {
            return Ok(());
        }
        settings.timezone = timezone;
        settings.save(&app);
    }
    serial_service::request_resend(&app);
    Ok(())
}

#[tauri::command]
pub fn send_diagnostic_frame(app: AppHandle) {
    serial_service::send(&app, Job::SendDiagnostic);
}

// ---------------------------------------------------------------------------
// Updates und Firmware-Flash (Phase 3)
// ---------------------------------------------------------------------------

/// Releases prüfen. `force:false` liefert den Cache, wenn schon geprüft wurde.
#[tauri::command]
pub async fn check_updates(app: AppHandle, force: bool) -> Result<UpdateStatus, String> {
    tauri::async_runtime::spawn_blocking(move || updates::check(&app, force))
        .await
        .map_err(|e| e.to_string())
}

/// Status ohne Netzzugriff, z. B. beim Öffnen der Seite.
#[tauri::command]
pub fn get_update_status(app: AppHandle) -> UpdateStatus {
    updates::status(&app)
}

/// Firmware-Asset der Variante in den Cache laden (Event `firmware-download`).
#[tauri::command]
pub async fn download_firmware(app: AppHandle, variant: DisplayVariant) -> Result<FirmwareFile, String> {
    tauri::async_runtime::spawn_blocking(move || updates::download_firmware(&app, variant))
        .await
        .map_err(|e| e.to_string())?
}

/// Firmware flashen (Event `flash-progress`). Fehler als Schlüssel flash.err.*.
#[tauri::command]
pub async fn flash_firmware(app: AppHandle, variant: DisplayVariant) -> Result<FlashOutcome, String> {
    tauri::async_runtime::spawn_blocking(move || flash::run(&app, variant))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn flash_local_firmware(app: AppHandle, variant: DisplayVariant, path: String) -> Result<FlashOutcome, String> {
    tauri::async_runtime::spawn_blocking(move || flash::run_with_image(&app, variant, Some(path.into())))
        .await.map_err(|e| e.to_string())?
}

/// Installer laden, prüfen, starten (Event `update-progress`); sonst Browser.
#[tauri::command]
pub async fn install_app_update(app: AppHandle) -> Result<InstallOutcome, String> {
    tauri::async_runtime::spawn_blocking(move || updates::install_app_update(&app))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn open_release_page(app: AppHandle) -> Result<(), String> {
    updates::open_release_page(&app)
}

/// Entwicklung: Startseite des Fensters aus AIMONITOR_OPEN_PAGE
/// (overview, connection, display, updates, diagnostics). Sonst leer.
#[tauri::command]
pub fn get_initial_page() -> String {
    std::env::var("AIMONITOR_OPEN_PAGE").unwrap_or_default()
}
