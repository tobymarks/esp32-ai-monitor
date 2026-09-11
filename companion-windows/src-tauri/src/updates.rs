//! Updates (Phase 3): GitHub-Releases laden und cachen, Firmware-Assets in
//! den lokalen Cache holen, App-Update laden, prüfen und starten.
//!
//! Alle Funktionen hier blockieren (ureq) und laufen aus den Commands in
//! `spawn_blocking` oder aus eigenen Threads. Die Sperren auf `AppState`
//! werden nur kurz gehalten, nie über einen Netzzugriff hinweg.

use crate::serial_service;
use crate::state::AppState;
use aimonitor_core::protocol::DisplayVariant;
use aimonitor_core::release::{
    self, GitHubAsset, GitHubRelease, UpdateChannel, RELEASES_API, RELEASES_PAGE, WINDOWS_APP_ASSET,
};
use chrono::{DateTime, Utc};
use serde::Serialize;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

pub const UPDATES_EVENT: &str = "updates-changed";
pub const FIRMWARE_DOWNLOAD_EVENT: &str = "firmware-download";
pub const UPDATE_PROGRESS_EVENT: &str = "update-progress";

const USER_AGENT: &str = concat!("AI-Monitor-Windows/", env!("CARGO_PKG_VERSION"));
const GITHUB_ACCEPT: &str = "application/vnd.github+json";
/// Gesamtlimit für die Releases-Abfrage.
const API_TIMEOUT: Duration = Duration::from_secs(15);
/// Downloads: Verbindungsaufbau kurz, Body-Empfang großzügig (Installer bis ~50 MB).
const DOWNLOAD_CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const DOWNLOAD_BODY_TIMEOUT: Duration = Duration::from_secs(600);
const MAX_JSON_BYTES: u64 = 16 * 1024 * 1024;
const MAX_FIRMWARE_BYTES: u64 = 16 * 1024 * 1024;
const MAX_INSTALLER_BYTES: u64 = 256 * 1024 * 1024;
/// Automatische Prüfung: erste nach dem Start, danach im Intervall.
const FIRST_CHECK_DELAY: Duration = Duration::from_secs(10);
const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
/// Fortschrittsereignisse höchstens so oft.
const PROGRESS_SLICE: Duration = Duration::from_millis(100);
const CHUNK: usize = 64 * 1024;

// ---------------------------------------------------------------------------
// Cache und Statusmodelle
// ---------------------------------------------------------------------------

/// Zuletzt geladene Releases. `error` beschreibt den letzten fehlgeschlagenen
/// Versuch; die Releases davor bleiben dabei erhalten.
#[derive(Debug, Clone, Default)]
pub struct ReleaseCache {
    pub releases: Vec<GitHubRelease>,
    pub checked_at: Option<DateTime<Utc>>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUpdate {
    pub current_version: String,
    pub latest_version: Option<String>,
    pub latest_tag: Option<String>,
    pub has_update: bool,
    pub html_url: Option<String>,
    pub asset_available: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct CachedFirmware {
    pub ili9341: bool,
    pub st7789: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FirmwareUpdate {
    pub latest_tag: Option<String>,
    pub latest_version: Option<String>,
    pub device_version: Option<String>,
    pub device_variant: Option<DisplayVariant>,
    pub installed_version: Option<String>,
    pub has_update: bool,
    pub missing_assets: Vec<String>,
    pub cached: CachedFirmware,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub checked_at: Option<DateTime<Utc>>,
    pub error: Option<String>,
    pub channel: UpdateChannel,
    pub checking: bool,
    pub app: AppUpdate,
    pub firmware: FirmwareUpdate,
}

/// Fortschritt eines Downloads (Firmware oder Installer).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgress {
    pub asset: String,
    pub received: u64,
    pub total: Option<u64>,
    pub done: bool,
}

/// Ergebnis von [`download_firmware`].
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FirmwareFile {
    pub path: PathBuf,
    pub tag: String,
    pub version: String,
    pub asset: String,
    /// Das Release hat kein Asset für die Variante, es wurde das Standard-Asset genommen.
    pub fallback: bool,
    pub from_cache: bool,
    pub bytes: u64,
}

/// Ergebnis von [`install_app_update`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InstallOutcome {
    /// Installer gestartet, die App beendet sich gleich.
    InstallerStarted,
    /// Kein passendes Asset oder keine Windows-Plattform: Release-Seite im Browser.
    OpenedBrowser,
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

fn api_agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(API_TIMEOUT))
        .user_agent(USER_AGENT)
        .http_status_as_error(true)
        .build();
    ureq::Agent::new_with_config(config)
}

fn download_agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .timeout_connect(Some(DOWNLOAD_CONNECT_TIMEOUT))
        .timeout_recv_response(Some(DOWNLOAD_CONNECT_TIMEOUT))
        .timeout_recv_body(Some(DOWNLOAD_BODY_TIMEOUT))
        .user_agent(USER_AGENT)
        .http_status_as_error(true)
        .build();
    ureq::Agent::new_with_config(config)
}

/// Releases von GitHub laden und parsen.
pub fn fetch_releases() -> Result<Vec<GitHubRelease>, String> {
    let mut response = api_agent()
        .get(RELEASES_API)
        .header("Accept", GITHUB_ACCEPT)
        .call()
        .map_err(|e| format!("GitHub: {e}"))?;
    let bytes = response
        .body_mut()
        .with_config()
        .limit(MAX_JSON_BYTES)
        .read_to_vec()
        .map_err(|e| format!("GitHub: {e}"))?;
    release::parse_releases(&bytes).map_err(|e| format!("Releases unlesbar: {e}"))
}

/// Datei streamend laden; `on_progress` bekommt empfangene und erwartete
/// Bytes. Geschrieben wird erst in `<ziel>.part`, dann umbenannt.
fn download_to(
    url: &str,
    expected: Option<u64>,
    limit: u64,
    target: &Path,
    on_progress: &mut dyn FnMut(u64, Option<u64>),
) -> Result<u64, String> {
    if let Some(dir) = target.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    let response = download_agent().get(url).call().map_err(|e| format!("Download: {e}"))?;
    let total = response
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .or(expected)
        .filter(|n| *n > 0);
    let mut reader = response.into_body().into_with_config().limit(limit).reader();

    let part = target.with_extension("part");
    let mut file = std::fs::File::create(&part).map_err(|e| format!("{}: {e}", part.display()))?;
    let mut buf = vec![0u8; CHUNK];
    let mut received = 0u64;
    let mut last_emit = Instant::now() - PROGRESS_SLICE;
    on_progress(0, total);
    loop {
        let n = reader.read(&mut buf).map_err(|e| format!("Download: {e}"))?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| format!("{}: {e}", part.display()))?;
        received += n as u64;
        if last_emit.elapsed() >= PROGRESS_SLICE {
            last_emit = Instant::now();
            on_progress(received, total);
        }
    }
    file.flush().map_err(|e| e.to_string())?;
    drop(file);
    if let Some(t) = total {
        if received != t {
            let _ = std::fs::remove_file(&part);
            return Err(format!("Download unvollständig: {received} von {t} Bytes"));
        }
    }
    std::fs::rename(&part, target).map_err(|e| format!("{}: {e}", target.display()))?;
    on_progress(received, total);
    Ok(received)
}

// ---------------------------------------------------------------------------
// Release-Prüfung
// ---------------------------------------------------------------------------

fn firmware_dir(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok().map(|d| d.join("firmware"))
}

fn firmware_release(app: &AppHandle) -> Option<GitHubRelease> {
    let state = app.state::<AppState>();
    let channel = state.settings.lock().unwrap().update_channel;
    let cache = state.releases.lock().unwrap();
    release::select_firmware_release(&cache.releases, channel).cloned()
}

fn app_release(app: &AppHandle) -> Option<GitHubRelease> {
    let state = app.state::<AppState>();
    let channel = state.settings.lock().unwrap().update_channel;
    let cache = state.releases.lock().unwrap();
    release::select_windows_app_release(&cache.releases, channel).cloned()
}

/// Status aus Cache, Einstellungen und Verbindung zusammensetzen; kein Netz.
pub fn status(app: &AppHandle) -> UpdateStatus {
    let state = app.state::<AppState>();
    let (channel, installed_version, checking) = {
        let s = state.settings.lock().unwrap();
        let checking = *state.release_check.0.lock().unwrap();
        (s.update_channel, s.installed_firmware_version.clone(), checking)
    };
    let (device_version, device_variant) = {
        let conn = state.connection.lock().unwrap();
        let profile = conn.profile.as_ref();
        let version = profile.and_then(|p| p.firmware_version.clone());
        let variant = profile
            .and_then(|p| p.display_variant)
            .or_else(|| conn.info.as_ref().and_then(|i| i.display));
        (version, variant)
    };
    let (checked_at, error, fw_release, app_release) = {
        let cache = state.releases.lock().unwrap();
        (
            cache.checked_at,
            cache.error.clone(),
            release::select_firmware_release(&cache.releases, channel).cloned(),
            release::select_windows_app_release(&cache.releases, channel).cloned(),
        )
    };

    let current_version = env!("CARGO_PKG_VERSION").to_string();
    let app_update = AppUpdate {
        has_update: app_release
            .as_ref()
            .map(|r| release::is_newer(&current_version, &r.version()))
            .unwrap_or(false),
        latest_version: app_release.as_ref().map(|r| r.version()),
        latest_tag: app_release.as_ref().map(|r| r.tag_name.clone()),
        html_url: app_release.as_ref().and_then(|r| r.html_url.clone()),
        asset_available: app_release.as_ref().map(|r| r.asset(WINDOWS_APP_ASSET).is_some()).unwrap_or(false),
        current_version,
    };

    let cached = fw_release
        .as_ref()
        .zip(firmware_dir(app))
        .map(|(r, dir)| CachedFirmware {
            ili9341: dir.join(release::cached_firmware_name(DisplayVariant::Ili9341, &r.tag_name)).is_file(),
            st7789: dir.join(release::cached_firmware_name(DisplayVariant::St7789, &r.tag_name)).is_file(),
        })
        .unwrap_or_default();
    let latest_version = fw_release.as_ref().map(|r| r.version());
    let firmware = FirmwareUpdate {
        has_update: match (&latest_version, &device_version) {
            (Some(latest), Some(device)) => latest != device,
            _ => false,
        },
        latest_tag: fw_release.as_ref().map(|r| r.tag_name.clone()),
        latest_version,
        device_version,
        device_variant,
        installed_version,
        missing_assets: fw_release
            .as_ref()
            .map(|r| release::missing_firmware_assets(r).iter().map(|s| s.to_string()).collect())
            .unwrap_or_default(),
        cached,
    };

    UpdateStatus { checked_at, error, channel, checking, app: app_update, firmware }
}

pub fn emit_status(app: &AppHandle) -> UpdateStatus {
    let status = status(app);
    if let Err(e) = app.emit(UPDATES_EVENT, &status) {
        eprintln!("[aimonitor] Update-Event nicht gesendet: {e}");
    }
    status
}

/// Releases laden und cachen. Ohne `force` genügt ein vorhandener Cache.
/// Läuft schon eine Abfrage, wartet der Aufrufer auf deren Ergebnis.
pub fn check(app: &AppHandle, force: bool) -> UpdateStatus {
    let state = app.state::<AppState>();
    {
        let (lock, cv) = &state.release_check;
        let mut busy = lock.lock().unwrap();
        if *busy {
            while *busy {
                busy = cv.wait(busy).unwrap();
            }
            return status(app);
        }
        if !force && state.releases.lock().unwrap().checked_at.is_some() {
            return status(app);
        }
        *busy = true;
    }
    emit_status(app);

    println!("[updates] Prüfe Releases ({RELEASES_API})");
    let started = Instant::now();
    let result = fetch_releases();
    let now = Utc::now();
    {
        let mut cache = state.releases.lock().unwrap();
        cache.checked_at = Some(now);
        match result {
            Ok(releases) => {
                println!("[updates] {} Releases nach {:?}", releases.len(), started.elapsed());
                cache.releases = releases;
                cache.error = None;
                drop(cache);
                let mut settings = state.settings.lock().unwrap();
                settings.last_update_check = Some(now);
                settings.save(app);
            }
            Err(e) => {
                eprintln!("[updates] Abfrage fehlgeschlagen: {e}");
                cache.error = Some(e);
            }
        }
    }
    {
        let (lock, cv) = &state.release_check;
        *lock.lock().unwrap() = false;
        cv.notify_all();
    }
    emit_status(app)
}

/// Automatische Prüfung: 10 s nach dem Start, danach alle 6 h.
pub fn start_timer(app: AppHandle) {
    std::thread::Builder::new()
        .name("aimonitor-updates".into())
        .spawn(move || {
            std::thread::sleep(FIRST_CHECK_DELAY);
            loop {
                check(&app, true);
                std::thread::sleep(CHECK_INTERVAL);
            }
        })
        .expect("Update-Thread");
}

// ---------------------------------------------------------------------------
// Firmware-Download
// ---------------------------------------------------------------------------

/// Firmware-Asset der Variante in den Cache laden. Liegt die Datei schon
/// vor, wird sie nicht erneut geladen. Fehler als i18n-Schlüssel oder Text.
pub fn download_firmware(app: &AppHandle, variant: DisplayVariant) -> Result<FirmwareFile, String> {
    if app.state::<AppState>().releases.lock().unwrap().checked_at.is_none() {
        check(app, false);
    }
    let release = firmware_release(app).ok_or_else(|| "release.none.info".to_string())?;
    let (asset, fallback) = release::firmware_asset(&release, variant).ok_or_else(|| "flash.err.nofile".to_string())?;
    let asset: GitHubAsset = asset.clone();
    let dir = firmware_dir(app).ok_or_else(|| "app_data_dir unbekannt".to_string())?;
    // Beim Fallback landet das Standard-Image unter dem Namen der gewählten
    // Variante, damit die Cache-Prüfung im Status dazu passt.
    let path = dir.join(release::cached_firmware_name(variant, &release.tag_name));
    let name = asset.name.clone();
    let mut file = FirmwareFile {
        path: path.clone(),
        tag: release.tag_name.clone(),
        version: release.version(),
        asset: name.clone(),
        fallback,
        from_cache: true,
        bytes: 0,
    };
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() > 0 {
            file.bytes = meta.len();
            println!("[updates] Firmware {} liegt im Cache ({} B)", path.display(), meta.len());
            return Ok(file);
        }
    }
    println!("[updates] Lade {} ({} B) aus {}", name, asset.size, release.tag_name);
    let app2 = app.clone();
    let asset_name = name.clone();
    let mut on_progress = |received: u64, total: Option<u64>| {
        let done = total.map(|t| received >= t).unwrap_or(false);
        let _ = app2.emit(FIRMWARE_DOWNLOAD_EVENT, DownloadProgress { asset: asset_name.clone(), received, total, done });
    };
    let bytes = download_to(
        &asset.browser_download_url,
        (asset.size > 0).then_some(asset.size),
        MAX_FIRMWARE_BYTES,
        &path,
        &mut on_progress,
    )
    .map_err(|e| format!("download.failed: {e}"))?;
    println!("[updates] Firmware gespeichert: {} ({bytes} B)", path.display());
    file.from_cache = false;
    file.bytes = bytes;
    emit_status(app);
    Ok(file)
}

// ---------------------------------------------------------------------------
// App-Update
// ---------------------------------------------------------------------------

fn open_url(url: &str) -> Result<(), String> {
    open::that(url).map_err(|e| format!("Browser: {e}"))
}

/// Release-Seite des gewählten App-Releases, sonst die Übersicht.
pub fn open_release_page(app: &AppHandle) -> Result<(), String> {
    let url = app_release(app)
        .and_then(|r| r.html_url)
        .unwrap_or_else(|| RELEASES_PAGE.to_string());
    println!("[updates] Öffne {url}");
    open_url(&url)
}

/// Installer laden, gegen die SHA-256-Sidecar prüfen, starten und die App
/// beenden. Ohne Windows oder ohne Asset öffnet sich die Release-Seite.
pub fn install_app_update(app: &AppHandle) -> Result<InstallOutcome, String> {
    let state = app.state::<AppState>();
    if state.installing.swap(true, Ordering::SeqCst) {
        return Err("update.err.running".into());
    }
    let result = install_inner(app);
    if result != Ok(InstallOutcome::InstallerStarted) {
        state.installing.store(false, Ordering::SeqCst);
    }
    result
}

fn install_inner(app: &AppHandle) -> Result<InstallOutcome, String> {
    let release = app_release(app).ok_or_else(|| "update.err.norelease".to_string())?;
    let asset = release.asset(WINDOWS_APP_ASSET).cloned();
    let (Some(asset), true) = (asset, cfg!(windows)) else {
        let url = release.html_url.clone().unwrap_or_else(|| RELEASES_PAGE.to_string());
        println!("[updates] Kein Installer für diese Plattform, öffne {url}");
        open_url(&url)?;
        return Ok(InstallOutcome::OpenedBrowser);
    };

    let dir = std::env::temp_dir().join("ai-monitor-update");
    let target = dir.join(&asset.name);
    let _ = std::fs::remove_file(&target);
    println!("[updates] Lade {} ({} B) nach {}", asset.name, asset.size, target.display());
    let app2 = app.clone();
    let asset_name = asset.name.clone();
    let mut on_progress = |received: u64, total: Option<u64>| {
        let done = total.map(|t| received >= t).unwrap_or(false);
        let _ = app2.emit(UPDATE_PROGRESS_EVENT, DownloadProgress { asset: asset_name.clone(), received, total, done });
    };
    download_to(
        &asset.browser_download_url,
        (asset.size > 0).then_some(asset.size),
        MAX_INSTALLER_BYTES,
        &target,
        &mut on_progress,
    )
    .map_err(|e| format!("download.failed: {e}"))?;

    // Sidecar `<asset>.sha256`, falls das Release eine hat.
    if let Some(sidecar) = release.asset(&format!("{}.sha256", asset.name)) {
        let mut response = download_agent()
            .get(&sidecar.browser_download_url)
            .call()
            .map_err(|e| format!("download.failed: {e}"))?;
        let text = response
            .body_mut()
            .with_config()
            .limit(4096)
            .read_to_string()
            .map_err(|e| format!("download.failed: {e}"))?;
        let expected = release::parse_sha256_sidecar(&text).ok_or_else(|| "update.err.sha256".to_string())?;
        let data = std::fs::read(&target).map_err(|e| e.to_string())?;
        let actual = release::sha256_hex(&data);
        if actual != expected {
            let _ = std::fs::remove_file(&target);
            eprintln!("[updates] SHA-256 weicht ab: erwartet {expected}, erhalten {actual}");
            return Err("update.err.sha256".into());
        }
        println!("[updates] SHA-256 geprüft: {actual}");
    } else {
        println!("[updates] Keine SHA-256-Sidecar im Release, Installer ungeprüft");
    }

    std::process::Command::new(&target)
        .args(["/SILENT", "/CLOSEAPPLICATIONS", "/RESTARTAPPLICATIONS"])
        .spawn()
        .map_err(|e| format!("update.err.start: {e}"))?;
    println!("[updates] Installer gestartet, App wird beendet");
    serial_service::shutdown_and_exit(app);
    Ok(InstallOutcome::InstallerStarted)
}
