//! Serielle Verbindung zum Gerät als eigener Thread (Spec 6.1, 6.2, 6.5).
//!
//! Der Thread besitzt den `Link` allein; niemand sonst fasst den Port an.
//! Aufträge kommen über einen mpsc-Kanal, der Zustand geht als
//! `ConnectionSnapshot` über das Event `connection-changed` ans Frontend und
//! in `AppState::connection`. Die Sperren auf Registry, Einstellungen und
//! Quelle werden nur kurz gehalten, nie über einen blockierenden seriellen
//! Zugriff hinweg.

use crate::registry;
use crate::poll;
use crate::settings::{ViewContent, ViewMode};
use crate::state::{current_snapshot, AppState};
use crate::timezone;
use crate::tray;
use aimonitor_core::envelope::{diagnostic_envelope, notice_envelope, usage_envelope, FrameContext};
use aimonitor_core::protocol::{
    Command, FrameIdCounter, Language, Orientation, ThemeSetting, DIAGNOSTIC_AFTER_CONNECT, DIAGNOSTIC_RESTORE,
    GET_INFO_TIMEOUT, HEARTBEAT_INTERVAL, LATE_INFO_WINDOW, RECONNECT_BLOCK_WINDOW, REPAIR_COOLDOWN,
    REPAIR_RECONNECT_DELAY, REPAIR_THRESHOLD, SCAN_INTERVAL, SEND_DEBOUNCE,
};
use aimonitor_core::{DeviceInfo, DeviceProfile, Snapshot};
use aimonitor_core::protocol::{DeviceMessage, ViewState};
use aimonitor_serial::{list_ports, ports::choose_port, FrameReceipt, Link, LinkError};
use chrono::{DateTime, Local, Utc};
use serde::Serialize;
use serde_json::json;
use std::collections::VecDeque;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

pub const CONNECTION_EVENT: &str = "connection-changed";
pub const SETTINGS_EVENT: &str = "settings-changed";
/// Zeilen im veröffentlichten Protokoll.
const LOG_LINES: usize = 50;
/// Wie lange der Thread höchstens blockiert, bevor er wieder Aufträge liest.
const IDLE_SLICE: Duration = Duration::from_millis(250);
/// Kurze Lesescheibe für die späte `info` nach `foreignFirmware`.
const LATE_INFO_SLICE: Duration = Duration::from_millis(200);

// ---------------------------------------------------------------------------
// Aufträge und veröffentlichter Zustand
// ---------------------------------------------------------------------------

/// Auftrag an den Thread. Alles, was das Frontend oder andere Threads auslösen.
#[derive(Debug)]
pub enum Job {
    SetManualPort(Option<String>),
    /// Datenframe über den Debounce anfordern (neue Daten, Provider, Einstellungen).
    Resend,
    ConfigureViews,
    SendDiagnostic,
    /// Nur die geänderten Werte sind `Some`; das Profil selbst liegt in der Registry.
    ApplyProfile {
        theme: Option<ThemeSetting>,
        orientation: Option<Orientation>,
        language: Option<Language>,
    },
    SetBrightness {
        value: i64,
        persist: bool,
    },
    /// Profil aus der Registry neu lesen und veröffentlichen (z. B. nach Umbenennen).
    RefreshProfile,
    /// Standby-Uhr zeigen, Port bleibt offen. Wird ab Phase 3 vor dem Flash benutzt.
    #[allow(dead_code)]
    Standby,
    /// `standby` senden, Port schließen, dann den Sender benachrichtigen.
    Shutdown(Sender<()>),
    /// Für den Flash (Spec 6.4): trennen, Scan stoppen, Port schließen,
    /// dann den Sender benachrichtigen. Bis `Resume` passiert nichts mehr.
    Pause(Sender<()>),
    /// Scan wieder an. Mit `diagnostic_after_connect` geht nach dem nächsten
    /// Connect verzögert der Diagnose-Frame raus, danach der echte Snapshot.
    Resume { diagnostic_after_connect: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ConnectionState {
    #[default]
    Disconnected,
    Probing,
    Connected,
    ForeignFirmware,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionSnapshot {
    pub state: ConnectionState,
    /// Scan angehalten, weil gerade geflasht wird.
    pub paused: bool,
    pub port: Option<String>,
    pub manual_port: Option<String>,
    pub info: Option<DeviceInfo>,
    /// Profil des verbundenen, sonst des zuletzt bekannten Geräts.
    pub profile: Option<DeviceProfile>,
    pub last_receipt: Option<FrameReceipt>,
    pub last_frame_bytes: Option<usize>,
    pub last_frame_at: Option<DateTime<Utc>>,
    pub unacked_count: u32,
    pub frames_sent: u64,
    pub frames_acked: u64,
    /// Letzte Zeilen: Gerätezeilen mit `<-`, eigene Ereignisse ohne Präfix.
    pub log: Vec<String>,
}

// ---------------------------------------------------------------------------
// Öffentliche Helfer für Commands, Tray und Poll
// ---------------------------------------------------------------------------

pub fn send(app: &AppHandle, job: Job) {
    if let Err(e) = app.state::<AppState>().serial.send(job) {
        eprintln!("[aimonitor] Serial-Thread nimmt keine Aufträge mehr an: {e}");
    }
}

pub fn request_resend(app: &AppHandle) {
    send(app, Job::Resend);
}

/// Beenden aus dem Tray: `standby` senden, Port schließen, dann die App beenden.
/// Läuft in einem eigenen Thread, damit der Menü-Handler nicht blockiert.
pub fn shutdown_and_exit(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let (tx, rx) = mpsc::channel();
        send(&app, Job::Shutdown(tx));
        let _ = rx.recv_timeout(Duration::from_secs(3));
        app.exit(0);
    });
}

/// Thread starten. Der Sender gehört in den `AppState`.
pub fn start(app: AppHandle, rx: Receiver<Job>, manual_port: Option<String>) {
    std::thread::Builder::new()
        .name("aimonitor-serial".into())
        .spawn(move || Service::new(app, manual_port).run(rx))
        .expect("Serial-Thread");
}

// ---------------------------------------------------------------------------
// Hinweistexte fürs Display in der Sprache des Geräteprofils (dsp.notice.*)
// ---------------------------------------------------------------------------

fn notice_text(key: &str, language: Language) -> &'static str {
    match (language, key) {
        (Language::De, "dsp.notice.climissing") => "CodexBar-CLI fehlt",
        (Language::De, "dsp.notice.failed") => "Abruf fehlgeschlagen",
        (Language::De, "dsp.notice.loading") => "Lade Provider ...",
        (Language::De, "dsp.notice.parse") => "Datenfehler",
        (Language::De, "dsp.notice.stale") => "Daten veraltet",
        (Language::De, "dsp.notice.startapp") => "Bitte App starten",
        (Language::En, "dsp.notice.climissing") => "CodexBar CLI missing",
        (Language::En, "dsp.notice.failed") => "Fetch failed",
        (Language::En, "dsp.notice.loading") => "Loading provider ...",
        (Language::En, "dsp.notice.parse") => "Data error",
        (Language::En, "dsp.notice.stale") => "Data outdated",
        (Language::En, "dsp.notice.startapp") => "Please start the app",
        _ => "",
    }
}

/// Systemerscheinungsbild für `ThemeSetting::System`; unbekannt gilt als hell.
fn system_is_dark() -> bool {
    matches!(dark_light::detect(), Ok(dark_light::Mode::Dark))
}

// ---------------------------------------------------------------------------
// Der Thread
// ---------------------------------------------------------------------------

enum LinkState {
    Disconnected,
    Probing,
    Connected(DeviceInfo),
    ForeignFirmware,
}

struct Service {
    app: AppHandle,
    link: Option<Link>,
    state: LinkState,
    manual_port: Option<String>,
    profile: Option<DeviceProfile>,
    frame_ids: FrameIdCounter,
    /// Während des Flashs: kein Scan, kein Port.
    paused: bool,
    /// Nach dem nächsten Connect den Diagnose-Frame einplanen (nach Flash).
    diagnostic_after_connect: bool,
    /// Fälligkeit des Diagnose-Frames nach dem Connect.
    diagnostic_due: Option<Instant>,

    next_scan: Instant,
    last_disconnect: Option<Instant>,
    /// Fenster für eine späte `info` nach `foreignFirmware`.
    late_info_until: Option<Instant>,
    /// Fälligkeit des gebündelten Datenframes.
    send_due: Option<Instant>,
    heartbeat_due: Option<Instant>,
    /// Bis dahin bleibt der Diagnose-Testframe auf dem Display.
    diagnostic_until: Option<Instant>,
    last_repair: Option<Instant>,

    last_receipt: Option<FrameReceipt>,
    last_frame_bytes: Option<usize>,
    last_frame_at: Option<DateTime<Utc>>,
    unacked: u32,
    frames_sent: u64,
    frames_acked: u64,
    log: VecDeque<String>,
}

impl Service {
    fn new(app: AppHandle, manual_port: Option<String>) -> Self {
        Self {
            app,
            link: None,
            state: LinkState::Disconnected,
            manual_port,
            profile: None,
            frame_ids: FrameIdCounter::new(),
            paused: false,
            diagnostic_after_connect: false,
            diagnostic_due: None,
            next_scan: Instant::now(),
            last_disconnect: None,
            late_info_until: None,
            send_due: None,
            heartbeat_due: None,
            diagnostic_until: None,
            last_repair: None,
            last_receipt: None,
            last_frame_bytes: None,
            last_frame_at: None,
            unacked: 0,
            frames_sent: 0,
            frames_acked: 0,
            log: VecDeque::new(),
        }
    }

    fn run(mut self, rx: Receiver<Job>) {
        self.profile = self.registry_profile();
        self.publish();
        loop {
            let wait = self
                .next_deadline()
                .map(|d| d.saturating_duration_since(Instant::now()))
                .unwrap_or(IDLE_SLICE)
                .min(IDLE_SLICE);
            match rx.recv_timeout(wait) {
                Ok(job) => {
                    if !self.handle(job) {
                        break;
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
            self.tick();
        }
        self.close_port();
    }

    // -- Protokoll und Veröffentlichung ------------------------------------

    fn log_event(&mut self, text: impl AsRef<str>) {
        let line = format!("{} {}", Local::now().format("%H:%M:%S"), text.as_ref());
        println!("[serial] {}", text.as_ref());
        if self.log.len() >= 200 {
            self.log.pop_front();
        }
        self.log.push_back(line);
    }

    /// Zeilen, die der Link nebenbei gelesen hat (ok, error, Fremdes), übernehmen.
    fn absorb_link_log(&mut self) {
        let lines: Vec<String> = match self.link.as_mut() {
            Some(link) => link.log.drain(..).collect(),
            None => return,
        };
        for l in lines {
            self.log_event(format!("<- {l}"));
        }
    }

    fn registry_profile(&self) -> Option<DeviceProfile> {
        self.app.state::<AppState>().registry.lock().unwrap().current_profile().cloned()
    }

    fn snapshot(&self) -> ConnectionSnapshot {
        let (state, info) = match &self.state {
            LinkState::Disconnected => (ConnectionState::Disconnected, None),
            LinkState::Probing => (ConnectionState::Probing, None),
            LinkState::Connected(info) => (ConnectionState::Connected, Some(info.clone())),
            LinkState::ForeignFirmware => (ConnectionState::ForeignFirmware, None),
        };
        let skip = self.log.len().saturating_sub(LOG_LINES);
        ConnectionSnapshot {
            state,
            paused: self.paused,
            port: self.link.as_ref().map(|l| l.name().to_string()),
            manual_port: self.manual_port.clone(),
            info,
            profile: self.profile.clone(),
            last_receipt: self.last_receipt.clone(),
            last_frame_bytes: self.last_frame_bytes,
            last_frame_at: self.last_frame_at,
            unacked_count: self.unacked,
            frames_sent: self.frames_sent,
            frames_acked: self.frames_acked,
            log: self.log.iter().skip(skip).cloned().collect(),
        }
    }

    fn publish(&mut self) {
        self.absorb_link_log();
        let snap = self.snapshot();
        *self.app.state::<AppState>().connection.lock().unwrap() = snap.clone();
        if let Err(e) = self.app.emit(CONNECTION_EVENT, &snap) {
            eprintln!("[aimonitor] Verbindungs-Event nicht gesendet: {e}");
        }
        tray::refresh(&self.app);
    }

    // -- Zeitsteuerung -----------------------------------------------------

    fn next_deadline(&self) -> Option<Instant> {
        [
            Some(self.next_scan),
            self.send_due,
            self.heartbeat_due,
            self.diagnostic_until,
            self.diagnostic_due,
            self.late_info_until,
        ]
        .into_iter()
        .flatten()
        .min()
    }

    fn tick(&mut self) {
        let now = Instant::now();

        if self.paused {
            return;
        }
        if now >= self.next_scan {
            self.next_scan = now + SCAN_INTERVAL;
            match self.state {
                LinkState::Disconnected => {
                    let blocked = self
                        .last_disconnect
                        .map(|t| now.duration_since(t) < RECONNECT_BLOCK_WINDOW)
                        .unwrap_or(false);
                    if !blocked {
                        self.scan_and_connect();
                    }
                }
                _ => self.check_port_still_present(),
            }
        }

        if let (LinkState::ForeignFirmware, Some(until)) = (&self.state, self.late_info_until) {
            if now < until {
                self.poll_late_info();
            } else {
                self.late_info_until = None;
                self.log_event("Keine späte info, Gerät bleibt als fremde Firmware markiert");
                self.publish();
            }
        }

        if !matches!(self.state, LinkState::Connected(_)) {
            return;
        }
        self.poll_view_events();
        let now = Instant::now();
        if let Some(due) = self.diagnostic_due {
            if now >= due {
                self.diagnostic_due = None;
                self.log_event("Diagnose-Frame nach Flash und Reconnect");
                self.send_diagnostic_frame();
            }
        }
        if let Some(until) = self.diagnostic_until {
            if now >= until {
                self.diagnostic_until = None;
                self.log_event("Diagnose beendet, echter Snapshot folgt");
                self.send_due = None;
                self.send_data_frame("Rueckkehr zum Snapshot");
            }
        }
        if let Some(due) = self.send_due {
            if now >= due {
                self.send_due = None;
                if self.diagnostic_until.is_none() {
                    self.send_data_frame("Snapshot");
                }
            }
        }
        if let Some(due) = self.heartbeat_due {
            if now >= due && matches!(self.state, LinkState::Connected(_)) {
                self.heartbeat_due = Some(now + HEARTBEAT_INTERVAL);
                if self.diagnostic_until.is_none() {
                    self.send_data_frame("Heartbeat");
                }
            }
        }
    }

    /// Datenframe über den Debounce anfordern; mehrere Auslöser ergeben einen Frame.
    fn schedule_send(&mut self) {
        if matches!(self.state, LinkState::Connected(_)) && self.send_due.is_none() {
            self.send_due = Some(Instant::now() + SEND_DEBOUNCE);
        }
    }

    // -- Verbindung --------------------------------------------------------

    fn scan_and_connect(&mut self) {
        let ports = list_ports();
        let Some(candidate) = choose_port(&ports, self.manual_port.as_deref()).cloned() else {
            return;
        };
        self.state = LinkState::Probing;
        self.log_event(format!("Öffne {} ({})", candidate.name, candidate.chip.unwrap_or("unbekannter Chip")));
        let mut link = match Link::open(&candidate.name) {
            Ok(l) => l,
            Err(e) => {
                self.log_event(format!("{e}"));
                self.state = LinkState::Disconnected;
                self.publish();
                return;
            }
        };
        self.publish();
        match link.handshake(GET_INFO_TIMEOUT) {
            Ok(info) => {
                self.link = Some(link);
                self.on_connected(info);
            }
            Err(LinkError::HandshakeTimeout(_)) => {
                self.link = Some(link);
                self.state = LinkState::ForeignFirmware;
                self.late_info_until = Some(Instant::now() + LATE_INFO_WINDOW);
                self.log_event(format!("Keine info innerhalb von {GET_INFO_TIMEOUT:?}, warte {LATE_INFO_WINDOW:?} auf eine späte Antwort"));
                self.publish();
            }
            Err(e) => {
                self.log_event(format!("Handshake fehlgeschlagen: {e}"));
                self.link = Some(link);
                self.disconnect("Handshake-Fehler");
            }
        }
    }

    fn poll_late_info(&mut self) {
        let Some(link) = self.link.as_mut() else { return };
        match link.wait_for_info(LATE_INFO_SLICE) {
            Ok(info) => {
                self.late_info_until = None;
                self.log_event("Späte info empfangen");
                self.on_connected(info);
            }
            Err(LinkError::HandshakeTimeout(_)) => {}
            Err(e) => {
                self.log_event(format!("{e}"));
                self.disconnect("Lesefehler");
            }
        }
    }

    /// Verbindung trennen, wenn der Port aus der Liste verschwunden ist oder
    /// ein Lesefehler aufgetreten ist. Ein Gerät, das sich kurz am USB
    /// abmeldet, kommt unter demselben COM-Namen zurück; der alte Handle
    /// bleibt aber tot und muss neu geöffnet werden.
    fn check_port_still_present(&mut self) {
        let Some((name, lost)) = self.link.as_ref().map(|l| (l.name().to_string(), l.is_lost())) else { return };
        if lost {
            self.disconnect("Lesefehler, Port wird neu geöffnet");
        } else if !list_ports().iter().any(|p| p.name == name) {
            self.disconnect("Port nicht mehr vorhanden");
        }
    }

    fn on_connected(&mut self, info: DeviceInfo) {
        self.log_event(format!(
            "Verbunden: Firmware {} MAC {} transport {} max {} B",
            info.version,
            info.mac,
            info.serial_transport.as_deref().unwrap_or("-"),
            info.max_frame_bytes()
        ));
        let (profile, outcome) = {
            let state = self.app.state::<AppState>();
            let mut registry = state.registry.lock().unwrap();
            let resolved = registry.resolve(&info, Utc::now());
            registry::save(&self.app, &registry);
            resolved
        };
        self.log_event(format!("Profil {:?}: {} ({})", outcome, profile.friendly_name, profile.mac));
        self.state = LinkState::Connected(info);
        self.profile = Some(profile.clone());
        self.unacked = 0;
        self.late_info_until = None;
        self.diagnostic_until = None;
        if self.diagnostic_after_connect {
            self.diagnostic_after_connect = false;
            self.diagnostic_due = Some(Instant::now() + DIAGNOSTIC_AFTER_CONNECT);
            self.log_event(format!("Diagnose-Frame in {DIAGNOSTIC_AFTER_CONNECT:?} eingeplant"));
        }
        self.publish();

        // Spec 6.1: vier set_*-Kommandos ohne Antwortauswertung, dann ein Frame.
        let theme = profile.theme.resolve(system_is_dark());
        let commands = [
            Command::set_theme(theme),
            Command::set_language(profile.language),
            Command::set_orientation(profile.orientation),
            Command::set_brightness(profile.brightness, true),
        ];
        for cmd in commands {
            if !self.send_command(&cmd) {
                return;
            }
        }
        self.restore_touch_selection();
        self.configure_views();
        self.heartbeat_due = Some(Instant::now() + HEARTBEAT_INTERVAL);
        self.schedule_send();
        self.publish();
    }

    /// Kommando schreiben; Schreibfehler trennen die Verbindung. Gibt `false`
    /// zurück, wenn danach keine Verbindung mehr besteht.
    fn send_command(&mut self, line: &str) -> bool {
        let Some(link) = self.link.as_mut() else { return false };
        let result = link.send_command(line);
        self.log_event(format!("-> {}", line.trim_end()));
        match result {
            Ok(()) => true,
            Err(e) => {
                self.log_event(format!("Schreibfehler: {e}"));
                self.disconnect("Schreibfehler");
                false
            }
        }
    }

    fn close_port(&mut self) {
        self.absorb_link_log();
        self.link = None;
    }

    fn disconnect(&mut self, reason: &str) {
        let was_open = self.link.is_some();
        self.close_port();
        if was_open || !matches!(self.state, LinkState::Disconnected) {
            self.log_event(format!("Getrennt: {reason}"));
        }
        self.state = LinkState::Disconnected;
        self.last_disconnect = Some(Instant::now());
        self.late_info_until = None;
        self.send_due = None;
        self.heartbeat_due = None;
        self.diagnostic_until = None;
        self.diagnostic_due = None;
        self.unacked = 0;
        {
            let state = self.app.state::<AppState>();
            let mut registry = state.registry.lock().unwrap();
            registry.disconnected();
            registry::save(&self.app, &registry);
        }
        self.profile = self.registry_profile();
        self.publish();
    }

    // -- Datenframes -------------------------------------------------------

    fn frame_context(&self, snap: &Snapshot) -> FrameContext {
        let now = Utc::now();
        let tz = self.app.state::<AppState>().settings.lock().unwrap().timezone.clone();
        FrameContext::new(now, timezone::offset_minutes(&tz, now), snap.fetching)
    }

    /// Usage- oder Notice-Frame aus dem aktuellen Snapshot; `None`, wenn es
    /// nichts zu zeigen gibt (Spec 5.3).
    fn build_payload(&mut self, info: &DeviceInfo, snap: Snapshot, view_index: Option<usize>) -> Option<(String, &'static str, i64)> {
        let ctx = self.frame_context(&snap);
        let frame_id = self.frame_ids.next();
        let (payload, kind) = if let Some(entry) = &snap.entry {
            (usage_envelope(entry, snap.percent_mode, &ctx, frame_id), "usage")
        } else {
            let key = snap.status.display_notice_key()
                .or_else(|| snap.fetching.then_some("dsp.notice.loading"))
                .unwrap_or("dsp.notice.loading");
            if !info.supports_notice() { return None; }
            let language = self.profile.as_ref().map(|p| p.language).unwrap_or_default();
            (notice_envelope(snap.provider, notice_text(key, language), &ctx, frame_id), "notice")
        };
        if let Some(index) = view_index {
            let mut value: serde_json::Value = serde_json::from_str(&payload).ok()?;
            value["data"][0]["viewIndex"] = json!(index);
            return Some((value.to_string(), kind, frame_id));
        }
        Some((payload, kind, frame_id))
    }

    fn configure_views(&mut self) {
        let LinkState::Connected(info) = &self.state else { return };
        if !info.supports_views() { return; }
        let settings = self.app.state::<AppState>().settings.lock().unwrap().clone();
        let contents: Vec<&str> = settings.views.iter().map(|v| match v {
            ViewContent::Clock => "clock",
            ViewContent::Provider(p) => p.key(),
        }).collect();
        let line = json!({
            "cmd": "set_views", "views": contents,
            "mode": match settings.view_mode { ViewMode::Manual => "manual", ViewMode::Automatic => "automatic" },
            "interval": settings.view_interval_seconds,
            "active": settings.active_view,
        }).to_string() + "\n";
        self.send_command(&line);
    }

    /// Nur eine passende Gerätekonfiguration darf die lokale Auswahl übernehmen.
    /// So überschreibt ein Reconnect keinen inzwischen am ESP gewählten Tab.
    fn restore_touch_selection(&mut self) {
        let LinkState::Connected(info) = &self.state else { return };
        if !info.supports_views() { return; }
        let result = self.link.as_mut().unwrap().command_with_response(
            "{\"cmd\":\"get_views\"}\n", "view_state", Duration::from_millis(500));
        match result {
            Ok(Some(DeviceMessage::ViewState(view))) => self.apply_device_selection(view),
            Ok(_) => self.log_event("Keine Fensterantwort vom Gerät"),
            Err(e) => self.log_event(format!("Fensterabfrage fehlgeschlagen: {e}")),
        }
        self.absorb_link_log();
    }

    fn poll_view_events(&mut self) {
        let Some(link) = self.link.as_mut() else { return };
        link.poll_input();
        let events = link.take_view_events();
        self.absorb_link_log();
        for view in events { self.apply_device_selection(view); }
        if self.link.as_ref().is_some_and(Link::is_lost) {
            self.disconnect("Lesefehler beim Fensterereignis");
        }
    }

    fn apply_device_selection(&mut self, view: ViewState) {
        let app_state = self.app.state::<AppState>();
        let (changed, provider) = {
            let mut settings = app_state.settings.lock().unwrap();
            let expected: Vec<&str> = settings.views.iter().map(|v| match v {
                ViewContent::Clock => "clock", ViewContent::Provider(p) => p.key(),
            }).collect();
            let mode = match settings.view_mode { ViewMode::Manual => "manual", ViewMode::Automatic => "automatic" };
            if view.views.iter().map(String::as_str).collect::<Vec<_>>() != expected
                || view.mode != mode || view.interval != settings.view_interval_seconds
                || view.active >= settings.views.len() || view.active == settings.active_view {
                return;
            }
            settings.active_view = view.active;
            let provider = match settings.views[view.active] {
                ViewContent::Clock => None,
                ViewContent::Provider(p) => { settings.provider = p; Some(p) },
            };
            settings.save(&self.app);
            (true, provider)
        };
        if changed {
            if let Some(provider) = provider {
                app_state.source.lock().unwrap().set_provider(provider, Utc::now());
                poll::start_fetch(&self.app);
                poll::refresh_views(&self.app);
            }
            let settings = app_state.settings.lock().unwrap().clone();
            let _ = self.app.emit(SETTINGS_EVENT, settings);
            self.log_event(format!("Touch-Auswahl übernommen: Fenster {}", view.active + 1));
            self.publish();
        }
    }

    fn send_data_frame(&mut self, trigger: &str) {
        let LinkState::Connected(info) = &self.state else { return };
        let info = info.clone();
        let selected = current_snapshot(&self.app);
        if !info.supports_views() {
            if let Some((payload, kind, frame_id)) = self.build_payload(&info, selected, None) {
                self.transmit(&info, payload, frame_id, kind, trigger);
            }
            return;
        }
        let views = self.app.state::<AppState>().settings.lock().unwrap().views.clone();
        let cached = self.app.state::<AppState>().view_sources.lock().unwrap().clone();
        for (index, view) in views.iter().enumerate() {
            let ViewContent::Provider(provider) = view else { continue };
            let snap = if *provider == selected.provider { Some(selected.clone()) } else { cached.get(provider).cloned() };
            let Some(snap) = snap else { continue };
            if let Some((payload, kind, frame_id)) = self.build_payload(&info, snap, Some(index)) {
                self.transmit(&info, payload, frame_id, kind, trigger);
            }
            if !matches!(self.state, LinkState::Connected(_)) { break; }
        }
    }

    fn send_diagnostic_frame(&mut self) {
        let LinkState::Connected(info) = &self.state else {
            self.log_event("Testframe nicht gesendet, kein Gerät verbunden");
            self.publish();
            return;
        };
        let info = info.clone();
        let snap = current_snapshot(&self.app);
        let ctx = self.frame_context(&snap);
        let frame_id = self.frame_ids.next();
        let payload = diagnostic_envelope(snap.provider, &ctx, frame_id);
        self.send_due = None;
        self.diagnostic_until = Some(Instant::now() + DIAGNOSTIC_RESTORE);
        self.transmit(&info, payload, frame_id, "diagnostic", "Testframe");
    }

    fn transmit(&mut self, info: &DeviceInfo, payload: String, frame_id: i64, kind: &str, trigger: &str) {
        let Some(link) = self.link.as_mut() else { return };
        let result = link.send_frame(&payload, frame_id, info.supports_framed(), info.max_frame_bytes());
        self.absorb_link_log();
        match result {
            Ok(receipt) => {
                self.frames_sent += 1;
                self.last_frame_bytes = Some(payload.len());
                self.last_frame_at = Some(Utc::now());
                let summary = match &receipt {
                    FrameReceipt::Ack { bytes, rows, .. } => format!("ack bytes={bytes} rows={rows}"),
                    FrameReceipt::Error { message, .. } => format!("error: {message}"),
                    FrameReceipt::Timeout { .. } => "timeout, kein ACK".into(),
                };
                self.log_event(format!("Frame {frame_id} {kind} ({trigger}, {} B) -> {summary}", payload.len()));
                self.last_receipt = Some(receipt.clone());
                self.account_receipt(info, &receipt);
                self.publish();
            }
            Err(LinkError::Frame(e)) => {
                self.log_event(format!("Frame {frame_id} nicht gesendet: {e}"));
                self.publish();
            }
            Err(e) => {
                self.log_event(format!("Frame {frame_id} Schreibfehler: {e}"));
                self.disconnect("Schreibfehler");
            }
        }
    }

    /// ACK-Buchführung nach Spec 6.5.
    fn account_receipt(&mut self, info: &DeviceInfo, receipt: &FrameReceipt) {
        match receipt {
            FrameReceipt::Ack { .. } => {
                self.unacked = 0;
                self.frames_acked += 1;
            }
            FrameReceipt::Error { .. } => self.unacked = 0,
            FrameReceipt::Timeout { .. } => {
                if !info.supports_ack() {
                    return;
                }
                self.unacked += 1;
                if self.unacked < REPAIR_THRESHOLD {
                    return;
                }
                let cooled = self.last_repair.map(|t| t.elapsed() >= REPAIR_COOLDOWN).unwrap_or(true);
                if !cooled {
                    self.log_event(format!("{} unbestätigte Frames, Reparatur noch in Abkühlung", self.unacked));
                    return;
                }
                self.log_event(format!("{} unbestätigte Frames in Folge, Verbindung wird neu aufgebaut", self.unacked));
                self.last_repair = Some(Instant::now());
                self.disconnect("Auto-Reparatur");
                self.next_scan = Instant::now() + REPAIR_RECONNECT_DELAY;
            }
        }
    }

    // -- Aufträge ----------------------------------------------------------

    /// Gibt `false` zurück, wenn der Thread enden soll.
    fn handle(&mut self, job: Job) -> bool {
        match job {
            Job::SetManualPort(port) => {
                if self.manual_port != port {
                    self.log_event(match &port {
                        Some(p) => format!("Manueller Port: {p}"),
                        None => "Port: automatisch".into(),
                    });
                    self.manual_port = port;
                    let current = self.link.as_ref().map(|l| l.name().to_string());
                    let keep = match (&self.manual_port, &current) {
                        (Some(m), Some(c)) => m == c,
                        (None, Some(_)) => true,
                        _ => false,
                    };
                    if !keep {
                        self.disconnect("Portwahl geändert");
                    }
                    self.next_scan = Instant::now() + RECONNECT_BLOCK_WINDOW;
                    self.publish();
                }
            }
            Job::Resend => self.schedule_send(),
            Job::ConfigureViews => {
                self.configure_views();
                self.schedule_send();
            }
            Job::SendDiagnostic => self.send_diagnostic_frame(),
            Job::ApplyProfile { theme, orientation, language } => {
                self.profile = self.registry_profile();
                if matches!(self.state, LinkState::Connected(_)) {
                    let mut ok = true;
                    if let Some(t) = theme {
                        ok = self.send_command(&Command::set_theme(t.resolve(system_is_dark())));
                    }
                    if ok {
                        if let Some(o) = orientation {
                            ok = self.send_command(&Command::set_orientation(o));
                        }
                    }
                    if ok {
                        if let Some(l) = language {
                            self.send_command(&Command::set_language(l));
                        }
                    }
                    self.schedule_send();
                }
                self.publish();
            }
            Job::SetBrightness { value, persist } => {
                self.profile = self.registry_profile();
                if let LinkState::Connected(info) = &self.state {
                    if persist || info.supports_brightness_preview() {
                        self.send_command(&Command::set_brightness(value, persist));
                    }
                }
                if persist {
                    self.publish();
                }
            }
            Job::RefreshProfile => {
                self.profile = self.registry_profile();
                self.publish();
            }
            Job::Standby => {
                if self.link.is_some() {
                    self.send_command(&Command::standby());
                    self.publish();
                }
            }
            Job::Pause(done) => {
                self.paused = true;
                self.disconnect("Pause für Flash");
                self.log_event("Angehalten: Scan gestoppt, Port frei");
                self.publish();
                let _ = done.send(());
            }
            Job::Resume { diagnostic_after_connect } => {
                self.paused = false;
                self.diagnostic_after_connect = diagnostic_after_connect;
                self.last_disconnect = None;
                self.next_scan = Instant::now();
                self.log_event(format!(
                    "Fortgesetzt: Scan läuft wieder{}",
                    if diagnostic_after_connect { ", Diagnose-Frame nach dem nächsten Connect" } else { "" }
                ));
                self.publish();
            }
            Job::Shutdown(done) => {
                if self.link.is_some() {
                    self.send_command(&Command::standby());
                }
                self.close_port();
                self.log_event("Beendet, Port geschlossen");
                let _ = done.send(());
                return false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notice_texts_exist_in_both_languages() {
        for key in [
            "dsp.notice.climissing",
            "dsp.notice.failed",
            "dsp.notice.loading",
            "dsp.notice.parse",
            "dsp.notice.stale",
            "dsp.notice.startapp",
        ] {
            assert!(!notice_text(key, Language::De).is_empty(), "{key} de");
            assert!(!notice_text(key, Language::En).is_empty(), "{key} en");
            assert!(aimonitor_core::protocol::display_safe_text(notice_text(key, Language::De)).len() <= 63);
        }
        assert_eq!(notice_text("dsp.notice.nope", Language::De), "");
    }
}
