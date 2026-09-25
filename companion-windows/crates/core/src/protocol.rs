//! Drahtformat zwischen App und Firmware, ohne I/O.
//! Quelle: `docs/serial-protocol.md`, Abschnitte 1, 3, 4, 5.1, 5.5, 8.
//!
//! Hier stehen die Nachrichten vom Gerät (Parser), die Kommandos zum Gerät
//! (Builder), das AIM1-Framing, die Versionsgrenzen und die Textregeln.
//! Die Envelopes für Datenframes baut [`crate::envelope`].

use crate::semver;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

pub const BAUD_RATE: u32 = 115_200;
pub const SCHEMA_VERSION: u32 = 1;
/// Default, wenn das Gerät kein `maxFrameBytes` meldet (Spec 1).
pub const MAX_FRAME_BYTES: usize = 4095;

/// Firmware ab dieser Version versteht AIM1-Framing (Spec 3.3).
pub const FRAMED_MIN_VERSION: &str = "2.12.3";
/// Firmware ab dieser Version bestätigt Datenframes mit `ack` (Spec 8.2).
pub const ACK_MIN_VERSION: &str = "2.12.1";
/// Firmware ab dieser Version akzeptiert `set_brightness` mit `persist:false`.
pub const BRIGHTNESS_PREVIEW_MIN_VERSION: &str = "2.12.4";
/// Firmware ab dieser Version rendert `notice`-Frames.
pub const NOTICE_MIN_VERSION: &str = "2.15.0";
/// Pseudo-MAC für Firmware ohne `mac` im `info` (Spec 4.1).
pub const LEGACY_DEVICE_MAC: &str = "legacy-device";

pub const SCAN_INTERVAL: Duration = Duration::from_secs(3);
pub const RECONNECT_BLOCK_WINDOW: Duration = Duration::from_secs(1);
pub const BOOT_DELAY: Duration = Duration::from_millis(200);
pub const GET_INFO_TIMEOUT: Duration = Duration::from_secs(5);
pub const LATE_INFO_WINDOW: Duration = Duration::from_secs(8);
pub const READ_SLICE: Duration = Duration::from_millis(100);
pub const DRAIN_SLICE: Duration = Duration::from_millis(10);
pub const FRAME_ACK_TIMEOUT: Duration = Duration::from_millis(800);
pub const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
pub const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(60);
pub const SEND_DEBOUNCE: Duration = Duration::from_millis(120);
pub const BRIGHTNESS_PERSIST_DEBOUNCE: Duration = Duration::from_millis(450);
pub const DIAGNOSTIC_AFTER_CONNECT: Duration = Duration::from_secs(1);
pub const DIAGNOSTIC_RESTORE: Duration = Duration::from_secs(20);
pub const REPAIR_THRESHOLD: u32 = 3;
pub const REPAIR_COOLDOWN: Duration = Duration::from_secs(60);
pub const REPAIR_RECONNECT_DELAY: Duration = Duration::from_millis(1200);
pub const FRAME_ID_MAX: i64 = 999_999;

// ---------------------------------------------------------------------------
// Aufzählungen mit Drahtwerten
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Orientation {
    #[default]
    Portrait,
    LandscapeLeft,
    LandscapeRight,
}

impl Orientation {
    pub fn wire(self) -> &'static str {
        match self {
            Orientation::Portrait => "portrait",
            Orientation::LandscapeLeft => "landscape_left",
            Orientation::LandscapeRight => "landscape_right",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "portrait" => Some(Self::Portrait),
            "landscape_left" | "landscape" => Some(Self::LandscapeLeft),
            "landscape_right" => Some(Self::LandscapeRight),
            _ => None,
        }
    }
}

/// Wert, den das Gerät kennt. `system` löst die App vorher auf.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
    Dark,
    Light,
}

impl Theme {
    pub fn wire(self) -> &'static str {
        match self {
            Theme::Dark => "dark",
            Theme::Light => "light",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "dark" => Some(Self::Dark),
            "light" => Some(Self::Light),
            _ => None,
        }
    }
}

/// Einstellung im Profil: folgt dem System oder ist fest.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ThemeSetting {
    #[default]
    System,
    Dark,
    Light,
}

impl ThemeSetting {
    /// Auflösen mit dem aktuellen System-Erscheinungsbild.
    pub fn resolve(self, system_is_dark: bool) -> Theme {
        match self {
            ThemeSetting::System => {
                if system_is_dark {
                    Theme::Dark
                } else {
                    Theme::Light
                }
            }
            ThemeSetting::Dark => Theme::Dark,
            ThemeSetting::Light => Theme::Light,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Language {
    #[default]
    De,
    En,
}

impl Language {
    pub fn wire(self) -> &'static str {
        match self {
            Language::De => "de",
            Language::En => "en",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "de" => Some(Self::De),
            "en" => Some(Self::En),
            _ => None,
        }
    }
}

/// Display-Controller der Board-Variante; bestimmt das Firmware-Asset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DisplayVariant {
    Ili9341,
    St7789,
}

impl DisplayVariant {
    pub fn wire(self) -> &'static str {
        match self {
            DisplayVariant::Ili9341 => "ili9341",
            DisplayVariant::St7789 => "st7789",
        }
    }

    /// Nur bekannte Varianten; `unknown` und Fremdwerte ergeben `None`.
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "ili9341" => Some(Self::Ili9341),
            "st7789" => Some(Self::St7789),
            _ => None,
        }
    }

    /// Asset-Name im GitHub-Release (main.swift:53-56).
    pub fn firmware_asset(self) -> &'static str {
        match self {
            DisplayVariant::Ili9341 => "ai-monitor.bin",
            DisplayVariant::St7789 => "ai-monitor-st7789.bin",
        }
    }
}

// ---------------------------------------------------------------------------
// Nachrichten vom Gerät
// ---------------------------------------------------------------------------

/// Antwort auf `get_info` (Spec 4.1). Nur `version` ist Pflicht.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub version: String,
    /// Kleingeschrieben; `legacy-device`, wenn das Gerät keine MAC meldet.
    pub mac: String,
    pub display: Option<DisplayVariant>,
    pub orientation: Option<Orientation>,
    pub theme: Option<Theme>,
    pub language: Option<Language>,
    pub brightness: Option<i64>,
    /// Kleingeschrieben und getrimmt, z. B. `aim1`.
    pub serial_transport: Option<String>,
    pub max_frame_bytes: Option<usize>,
    pub wifi_configured: Option<bool>,
    pub wifi_connected: Option<bool>,
    pub time_synced: Option<bool>,
    pub uptime: Option<i64>,
    pub heap: Option<i64>,
}

impl DeviceInfo {
    pub fn from_value(v: &Value) -> Option<Self> {
        if v.get("type")?.as_str()? != "info" {
            return None;
        }
        let version = v.get("version")?.as_str()?.trim().to_string();
        let mac = v
            .get("mac")
            .and_then(Value::as_str)
            .map(|m| m.trim().to_ascii_lowercase())
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| LEGACY_DEVICE_MAC.to_string());
        Some(Self {
            version,
            mac,
            display: v.get("display").and_then(Value::as_str).and_then(DisplayVariant::parse),
            orientation: v.get("orientation").and_then(Value::as_str).and_then(Orientation::parse),
            theme: v.get("theme").and_then(Value::as_str).and_then(Theme::parse),
            language: v.get("language").and_then(Value::as_str).and_then(Language::parse),
            brightness: v.get("brightness").and_then(Value::as_i64),
            serial_transport: v
                .get("serialTransport")
                .and_then(Value::as_str)
                .map(|s| s.trim().to_ascii_lowercase()),
            max_frame_bytes: v.get("maxFrameBytes").and_then(Value::as_u64).map(|n| n as usize),
            wifi_configured: v.get("wifiConfigured").and_then(Value::as_bool),
            wifi_connected: v.get("wifiConnected").and_then(Value::as_bool),
            time_synced: v.get("timeSynced").and_then(Value::as_bool),
            uptime: v.get("uptime").and_then(Value::as_i64),
            heap: v.get("heap").and_then(Value::as_i64),
        })
    }

    /// AIM1, wenn `serialTransport` gleich `aim1` oder Version >= 2.12.3 (Spec 3.3).
    pub fn supports_framed(&self) -> bool {
        self.serial_transport.as_deref() == Some("aim1")
            || semver::at_least(&self.version, FRAMED_MIN_VERSION)
    }

    pub fn supports_ack(&self) -> bool {
        semver::at_least(&self.version, ACK_MIN_VERSION)
    }

    pub fn supports_brightness_preview(&self) -> bool {
        semver::at_least(&self.version, BRIGHTNESS_PREVIEW_MIN_VERSION)
    }

    pub fn supports_notice(&self) -> bool {
        semver::at_least(&self.version, NOTICE_MIN_VERSION)
    }

    pub fn supports_views(&self) -> bool {
        semver::at_least(&self.version, "2.19.0-dev")
    }

    pub fn max_frame_bytes(&self) -> usize {
        self.max_frame_bytes.unwrap_or(MAX_FRAME_BYTES)
    }
}

/// Eine JSON-Zeile vom Gerät, nach `type` sortiert (Spec 4).
#[derive(Debug, Clone, PartialEq)]
pub enum DeviceMessage {
    Info(DeviceInfo),
    ViewState(ViewState),
    Ack {
        frame_id: i64,
        schema_version: i64,
        message: String,
        bytes: i64,
        provider: String,
        rows: i64,
    },
    Error {
        frame_id: Option<i64>,
        message: String,
    },
    Ok {
        cmd: String,
        value: Value,
    },
    WifiStatus(Value),
    WifiScan(Value),
    Other(Value),
}

impl DeviceMessage {
    /// `None` für Log-Zeilen und alles, was kein JSON-Objekt ist (Spec 1).
    pub fn parse_line(line: &str) -> Option<Self> {
        let line = line.trim_end_matches(['\r', '\n']).trim_start();
        if !line.starts_with('{') {
            return None;
        }
        let v: Value = serde_json::from_str(line).ok()?;
        let ty = v.get("type").and_then(Value::as_str).unwrap_or("");
        Some(match ty {
            "info" => match DeviceInfo::from_value(&v) {
                Some(info) => DeviceMessage::Info(info),
                None => DeviceMessage::Other(v),
            },
            "view_state" => match serde_json::from_value::<ViewState>(v.clone()) {
                Ok(state) => DeviceMessage::ViewState(state),
                Err(_) => DeviceMessage::Other(v),
            },
            "ack" => DeviceMessage::Ack {
                frame_id: v.get("frameId").and_then(Value::as_i64).unwrap_or(-1),
                schema_version: v.get("schemaVersion").and_then(Value::as_i64).unwrap_or(0),
                message: v.get("message").and_then(Value::as_str).unwrap_or("").to_string(),
                bytes: v.get("bytes").and_then(Value::as_i64).unwrap_or(0),
                provider: v.get("provider").and_then(Value::as_str).unwrap_or("").to_string(),
                rows: v.get("rows").and_then(Value::as_i64).unwrap_or(0),
            },
            "error" => DeviceMessage::Error {
                frame_id: v.get("frameId").and_then(Value::as_i64),
                message: v.get("message").and_then(Value::as_str).unwrap_or("").to_string(),
            },
            "ok" => DeviceMessage::Ok {
                cmd: v.get("cmd").and_then(Value::as_str).unwrap_or("").to_string(),
                value: v.get("value").cloned().unwrap_or(Value::Null),
            },
            "wifi_status" => DeviceMessage::WifiStatus(v),
            "wifi_scan" => DeviceMessage::WifiScan(v),
            _ => DeviceMessage::Other(v),
        })
    }

    pub fn type_name(&self) -> &'static str {
        match self {
            DeviceMessage::Info(_) => "info",
            DeviceMessage::ViewState(_) => "view_state",
            DeviceMessage::Ack { .. } => "ack",
            DeviceMessage::Error { .. } => "error",
            DeviceMessage::Ok { .. } => "ok",
            DeviceMessage::WifiStatus(_) => "wifi_status",
            DeviceMessage::WifiScan(_) => "wifi_scan",
            DeviceMessage::Other(_) => "other",
        }
    }
}

/// Aktuelle Fensterwahl des Geräts; wird auf Anfrage und nach einem Touch gesendet.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct ViewState {
    pub views: Vec<String>,
    pub mode: String,
    pub interval: u16,
    pub active: usize,
}

// ---------------------------------------------------------------------------
// Kommandos zum Gerät (Spec 5.1), immer als Zeile
// ---------------------------------------------------------------------------

pub struct Command;

impl Command {
    fn line(v: Value) -> String {
        let mut s = v.to_string();
        s.push('\n');
        s
    }

    pub fn get_info() -> String {
        Self::line(serde_json::json!({"cmd": "get_info"}))
    }

    pub fn set_theme(theme: Theme) -> String {
        Self::line(serde_json::json!({"cmd": "set_theme", "value": theme.wire()}))
    }

    pub fn set_language(language: Language) -> String {
        Self::line(serde_json::json!({"cmd": "set_language", "value": language.wire()}))
    }

    pub fn set_orientation(orientation: Orientation) -> String {
        Self::line(serde_json::json!({"cmd": "set_orientation", "value": orientation.wire()}))
    }

    /// Clampt vorher auf 5..100 wie der Host (main.swift:2645).
    pub fn set_brightness(value: i64, persist: bool) -> String {
        let v = value.clamp(5, 100);
        Self::line(serde_json::json!({"cmd": "set_brightness", "value": v, "persist": persist}))
    }

    pub fn standby() -> String {
        Self::line(serde_json::json!({"cmd": "standby"}))
    }

    pub fn wifi_status() -> String {
        Self::line(serde_json::json!({"cmd": "wifi_status"}))
    }

    pub fn wifi_scan() -> String {
        Self::line(serde_json::json!({"cmd": "wifi_scan"}))
    }

    pub fn wifi_set(ssid: &str, password: &str) -> String {
        Self::line(serde_json::json!({"cmd": "wifi_set", "ssid": ssid, "password": password}))
    }

    pub fn wifi_forget() -> String {
        Self::line(serde_json::json!({"cmd": "wifi_forget"}))
    }

    pub fn reboot() -> String {
        Self::line(serde_json::json!({"cmd": "reboot"}))
    }
}

// ---------------------------------------------------------------------------
// Framing (Spec 3)
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum FrameError {
    #[error("Payload zu groß für das Gerät ({size} > {max} Bytes)")]
    TooLarge { size: usize, max: usize },
}

/// Datenframe kodieren. Mit `framed` als `AIM1 <len> <id>\n<payload>\n`,
/// sonst als eine Zeile. Kommandos gehen nie hier durch.
pub fn encode_frame(payload: &str, frame_id: i64, framed: bool, max_bytes: usize) -> Result<Vec<u8>, FrameError> {
    let bytes = payload.as_bytes();
    if framed && bytes.len() > max_bytes {
        return Err(FrameError::TooLarge { size: bytes.len(), max: max_bytes });
    }
    let mut out = Vec::with_capacity(bytes.len() + 32);
    if framed {
        out.extend_from_slice(format!("AIM1 {} {}\n", bytes.len(), frame_id).as_bytes());
    }
    out.extend_from_slice(bytes);
    out.push(b'\n');
    Ok(out)
}

/// Fortlaufende Frame-IDs 1..999999, dann wieder 1 (Spec 5.2).
#[derive(Debug, Default)]
pub struct FrameIdCounter {
    last: i64,
}

impl FrameIdCounter {
    pub fn new() -> Self {
        Self { last: 0 }
    }

    pub fn next(&mut self) -> i64 {
        self.last = if self.last >= FRAME_ID_MAX { 1 } else { self.last + 1 };
        self.last
    }
}

// ---------------------------------------------------------------------------
// Textregeln (Spec 5.5)
// ---------------------------------------------------------------------------

/// Macht Text für die LVGL-Montserrat-Fonts darstellbar: Umlaute und
/// typografische Zeichen werden ersetzt, alles außerhalb 0x20..0x7E entfernt.
pub fn display_safe_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            'ä' => out.push_str("ae"),
            'ö' => out.push_str("oe"),
            'ü' => out.push_str("ue"),
            'Ä' => out.push_str("Ae"),
            'Ö' => out.push_str("Oe"),
            'Ü' => out.push_str("Ue"),
            'ß' => out.push_str("ss"),
            '…' => out.push_str("..."),
            '–' | '—' | '·' => out.push('-'),
            '„' | '“' | '”' => out.push('"'),
            '‚' | '‘' | '’' => out.push('\''),
            '→' => out.push_str("->"),
            c if (' '..='~').contains(&c) => out.push(c),
            _ => {}
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_info_with_defaults() {
        let line = r#"{"type":"info","version":"2.17.0","mac":"A4:CF:12:34:56:78","display":"ili9341","orientation":"landscape_right","theme":"dark","language":"de","brightness":80,"serialTransport":"AIM1","maxFrameBytes":4095,"uptime":12,"heap":180000}"#;
        let Some(DeviceMessage::Info(info)) = DeviceMessage::parse_line(line) else { panic!() };
        assert_eq!(info.mac, "a4:cf:12:34:56:78");
        assert_eq!(info.display, Some(DisplayVariant::Ili9341));
        assert_eq!(info.orientation, Some(Orientation::LandscapeRight));
        assert_eq!(info.serial_transport.as_deref(), Some("aim1"));
        assert!(info.supports_framed());
        assert!(info.supports_ack());
        assert!(info.supports_brightness_preview());
        assert!(info.supports_notice());
    }

    #[test]
    fn old_firmware_without_mac_is_legacy_and_line_mode() {
        let line = r#"{"type":"info","version":"2.9.0","display":"unknown"}"#;
        let Some(DeviceMessage::Info(info)) = DeviceMessage::parse_line(line) else { panic!() };
        assert_eq!(info.mac, LEGACY_DEVICE_MAC);
        assert_eq!(info.display, None);
        assert!(!info.supports_framed());
        assert!(!info.supports_ack());
        assert_eq!(info.max_frame_bytes(), 4095);
    }

    #[test]
    fn log_lines_are_ignored_and_messages_typed() {
        assert_eq!(DeviceMessage::parse_line("[Serial] Command received: get_info"), None);
        assert_eq!(DeviceMessage::parse_line("====="), None);
        assert_eq!(DeviceMessage::parse_line(""), None);
        let ack = DeviceMessage::parse_line(r#"{"type":"ack","frameId":17,"schemaVersion":1,"message":"accepted","bytes":812,"provider":"CLAUDE","rows":3,"heap":176000}"#).unwrap();
        assert!(matches!(ack, DeviceMessage::Ack { frame_id: 17, rows: 3, .. }));
        let err = DeviceMessage::parse_line(r#"{"type":"error","message":"frame timeout"}"#).unwrap();
        assert_eq!(err, DeviceMessage::Error { frame_id: None, message: "frame timeout".into() });
        let ok = DeviceMessage::parse_line(r#"{"type":"ok","cmd":"set_brightness","value":80,"persist":true}"#).unwrap();
        assert!(matches!(ok, DeviceMessage::Ok { ref cmd, .. } if cmd == "set_brightness"));
    }

    #[test]
    fn parses_touch_view_state_and_rejects_incomplete_state() {
        let line = r#"{"type":"view_state","mode":"manual","interval":10,"active":1,"views":["codex","clock"]}"#;
        let Some(DeviceMessage::ViewState(state)) = DeviceMessage::parse_line(line) else { panic!() };
        assert_eq!(state.active, 1);
        assert_eq!(state.views, ["codex", "clock"]);
        assert_eq!(DeviceMessage::parse_line(line).unwrap().type_name(), "view_state");
        assert!(matches!(DeviceMessage::parse_line(r#"{"type":"view_state","active":1}"#), Some(DeviceMessage::Other(_))));
    }

    #[test]
    fn commands_are_single_lines() {
        assert_eq!(Command::get_info(), "{\"cmd\":\"get_info\"}\n");
        assert_eq!(Command::set_brightness(140, false), "{\"cmd\":\"set_brightness\",\"persist\":false,\"value\":100}\n");
        assert_eq!(Command::set_orientation(Orientation::LandscapeLeft), "{\"cmd\":\"set_orientation\",\"value\":\"landscape_left\"}\n");
    }

    #[test]
    fn framing_matches_spec_example() {
        let payload = r#"{"schemaVersion":1,"frameId":17,"data":[{"x":1}]}"#;
        let out = encode_frame(payload, 17, true, 4095).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), format!("AIM1 {} 17\n{payload}\n", payload.len()));
        let legacy = encode_frame(payload, 17, false, 4095).unwrap();
        assert_eq!(String::from_utf8(legacy).unwrap(), format!("{payload}\n"));
        assert_eq!(encode_frame(&"x".repeat(5000), 1, true, 4095).unwrap_err(), FrameError::TooLarge { size: 5000, max: 4095 });
    }

    #[test]
    fn frame_ids_wrap() {
        let mut c = FrameIdCounter::new();
        assert_eq!(c.next(), 1);
        c.last = FRAME_ID_MAX;
        assert_eq!(c.next(), 1);
    }

    #[test]
    fn safe_text_transliterates() {
        assert_eq!(display_safe_text("Größe … → Übersicht „x“"), "Groesse ... -> Uebersicht \"x\"");
        assert_eq!(display_safe_text("Lade Provider …"), "Lade Provider ...");
        assert_eq!(display_safe_text("日本"), "");
    }
}
