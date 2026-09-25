//! Eine offene Verbindung zum Gerät. Synchron, blockierend, ohne Threads;
//! die App serialisiert Zugriffe über einen Mutex.
//!
//! Öffnen nach dem Rezept aus Spec 9.1: 115200 8N1, keine Flusskontrolle,
//! DTR und RTS beim Öffnen nicht anfassen, 200 ms Boot-Delay, dann `get_info`.

use aimonitor_core::protocol::{self, Command, DeviceInfo, DeviceMessage};
use serialport::{DataBits, FlowControl, Parity, SerialPort, StopBits};
use std::io::{Read, Write};
use std::time::{Duration, Instant};

#[derive(Debug, thiserror::Error)]
pub enum LinkError {
    #[error("Port konnte nicht geöffnet werden: {0}")]
    Open(String),
    #[error("Schreibfehler: {0}")]
    Write(String),
    #[error("Kein info-Handshake innerhalb von {0:?}")]
    HandshakeTimeout(Duration),
    /// Lesefehler auf dem offenen Port: Das Gerät hat sich am USB abgemeldet.
    /// Taucht es unter demselben COM-Namen wieder auf, muss der Port neu
    /// geöffnet werden; der alte Handle bleibt tot.
    #[error("Verbindung zum Gerät verloren: {0}")]
    Lost(String),
    #[error(transparent)]
    Frame(#[from] protocol::FrameError),
}

/// Ergebnis eines Datenframes (main.swift: SerialFrameReceipt).
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum FrameReceipt {
    Ack { frame_id: i64, bytes: i64, rows: i64, provider: String },
    Error { frame_id: i64, message: String },
    /// Keine Antwort innerhalb des ACK-Timeouts.
    Timeout { frame_id: i64 },
}

impl FrameReceipt {
    pub fn is_ack(&self) -> bool {
        matches!(self, FrameReceipt::Ack { .. })
    }
}

pub struct Link {
    port: Box<dyn SerialPort>,
    name: String,
    pending: Vec<u8>,
    /// Alle empfangenen JSON-Zeilen, die nicht an einen Wartenden gingen, für die Diagnose.
    pub log: Vec<String>,
    /// Erster Lesefehler außer Timeout; danach gilt der Port als verloren.
    lost: Option<String>,
    /// Letztes gesendetes `get_info`, für die Wiederholung im Handshake.
    last_get_info: Option<Instant>,
}

/// Abstand, in dem `get_info` wiederholt wird, bis eine `info` kommt.
const GET_INFO_RETRY: Duration = Duration::from_secs(1);

impl Link {
    /// Port öffnen und die Modemleitungen in Ruhe lassen.
    pub fn open(name: &str) -> Result<Self, LinkError> {
        let port = serialport::new(name, protocol::BAUD_RATE)
            .data_bits(DataBits::Eight)
            .parity(Parity::None)
            .stop_bits(StopBits::One)
            .flow_control(FlowControl::None)
            .timeout(protocol::READ_SLICE)
            .open()
            .map_err(|e| LinkError::Open(e.to_string()))?;
        Ok(Self { port, name: name.to_string(), pending: Vec::new(), log: Vec::new(), lost: None, last_get_info: None })
    }

    /// Bereits geöffneten Port übernehmen (Tests mit Pseudo-Terminal).
    #[cfg(test)]
    fn from_port(port: Box<dyn SerialPort>, name: &str) -> Self {
        Self { port, name: name.to_string(), pending: Vec::new(), log: Vec::new(), lost: None, last_get_info: None }
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// `true`, sobald ein Lesefehler aufgetreten ist (siehe `LinkError::Lost`).
    pub fn is_lost(&self) -> bool {
        self.lost.is_some()
    }

    fn lost_error(&self) -> Option<LinkError> {
        self.lost.clone().map(LinkError::Lost)
    }

    pub fn write_all(&mut self, bytes: &[u8]) -> Result<(), LinkError> {
        self.port.write_all(bytes).map_err(|e| LinkError::Write(e.to_string()))?;
        self.port.flush().map_err(|e| LinkError::Write(e.to_string()))
    }

    /// Eine Zeile lesen, `\r` ignorieren, bei `\n` schneiden. `None` bei Ablauf von `deadline`.
    pub fn read_line(&mut self, deadline: Instant) -> Option<String> {
        let mut buf = [0u8; 256];
        loop {
            if let Some(pos) = self.pending.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.pending.drain(..=pos).collect();
                let text = String::from_utf8_lossy(&line[..line.len() - 1]).replace('\r', "");
                return Some(text);
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            let slice = (deadline - now).min(protocol::READ_SLICE);
            let _ = self.port.set_timeout(slice);
            match self.port.read(&mut buf) {
                Ok(0) => {}
                Ok(n) => self.pending.extend_from_slice(&buf[..n]),
                Err(e) if matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted) => {}
                Err(e) => {
                    // Bis 1.0.1 hieß das nur „keine Zeile“: Ein Gerät, das sich
                    // kurz am USB abmeldete, blieb als fremde Firmware stehen.
                    self.lost.get_or_insert_with(|| e.to_string());
                    return None;
                }
            }
        }
    }

    /// Eingang leeren: liest, solange innerhalb von 10-ms-Fenstern etwas kommt (Spec 2.3).
    pub fn drain(&mut self) {
        self.pending.clear();
        let mut buf = [0u8; 512];
        let _ = self.port.set_timeout(protocol::DRAIN_SLICE);
        loop {
            match self.port.read(&mut buf) {
                Ok(n) if n > 0 => continue,
                _ => break,
            }
        }
    }

    /// Kommando ohne Antwortauswertung (Spec 6.3).
    pub fn send_command(&mut self, line: &str) -> Result<(), LinkError> {
        self.write_all(line.as_bytes())
    }

    /// Handshake nach Spec 2.3: `\n`, Boot-Delay, drain, `get_info`, auf `info` warten.
    pub fn handshake(&mut self, timeout: Duration) -> Result<DeviceInfo, LinkError> {
        self.write_all(b"\n")?;
        std::thread::sleep(protocol::BOOT_DELAY);
        self.drain();
        self.send_get_info()?;
        self.wait_for_info(timeout)
    }

    fn send_get_info(&mut self) -> Result<(), LinkError> {
        self.last_get_info = Some(Instant::now());
        self.write_all(Command::get_info().as_bytes())
    }

    /// Auf eine `info`-Antwort warten (Spec 2.3, auch im Fenster nach
    /// `foreignFirmware`). `get_info` wird jede Sekunde wiederholt, weil eine
    /// zu früh gesendete Anfrage beim Booten verloren gehen kann.
    pub fn wait_for_info(&mut self, timeout: Duration) -> Result<DeviceInfo, LinkError> {
        let deadline = Instant::now() + timeout;
        loop {
            if self.last_get_info.map(|t| t.elapsed() >= GET_INFO_RETRY).unwrap_or(true) {
                self.send_get_info()?;
            }
            let slice_end = (Instant::now() + GET_INFO_RETRY).min(deadline);
            while let Some(line) = self.read_line(slice_end) {
                match DeviceMessage::parse_line(&line) {
                    Some(DeviceMessage::Info(info)) => return Ok(info),
                    Some(_) => self.remember(&line),
                    None => {}
                }
            }
            if let Some(err) = self.lost_error() {
                return Err(err);
            }
            if Instant::now() >= deadline {
                return Err(LinkError::HandshakeTimeout(timeout));
            }
        }
    }

    /// Datenframe senden und auf `ack`/`error` mit passender `frameId` warten (Spec 6.2).
    pub fn send_frame(&mut self, payload: &str, frame_id: i64, framed: bool, max_bytes: usize) -> Result<FrameReceipt, LinkError> {
        let bytes = protocol::encode_frame(payload, frame_id, framed, max_bytes)?;
        self.drain();
        self.write_all(&bytes)?;
        let deadline = Instant::now() + protocol::FRAME_ACK_TIMEOUT;
        while let Some(line) = self.read_line(deadline) {
            match DeviceMessage::parse_line(&line) {
                Some(DeviceMessage::Ack { frame_id: id, bytes, rows, provider, .. }) if id == frame_id => {
                    return Ok(FrameReceipt::Ack { frame_id, bytes, rows, provider });
                }
                Some(DeviceMessage::Error { frame_id: Some(id), message }) if id == frame_id => {
                    return Ok(FrameReceipt::Error { frame_id, message });
                }
                Some(_) => self.remember(&line),
                None => {}
            }
        }
        if let Some(err) = self.lost_error() {
            return Err(err);
        }
        Ok(FrameReceipt::Timeout { frame_id })
    }

    /// Kommando senden und auf die erste Nachricht des erwarteten Typs warten.
    pub fn command_with_response(&mut self, line: &str, expect_type: &str, timeout: Duration) -> Result<Option<DeviceMessage>, LinkError> {
        self.drain();
        self.write_all(line.as_bytes())?;
        let deadline = Instant::now() + timeout;
        while let Some(text) = self.read_line(deadline) {
            if let Some(msg) = DeviceMessage::parse_line(&text) {
                if msg.type_name() == expect_type {
                    return Ok(Some(msg));
                }
                self.remember(&text);
            }
        }
        if let Some(err) = self.lost_error() {
            return Err(err);
        }
        Ok(None)
    }

    fn remember(&mut self, line: &str) {
        if self.log.len() >= 200 {
            self.log.remove(0);
        }
        self.log.push(line.to_string());
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use serialport::TTYPort;
    use std::io::{Read, Write};

    fn pair() -> (TTYPort, Link) {
        let (master, slave) = TTYPort::pair().expect("Pseudo-Terminal");
        let name = slave.name().unwrap_or_default();
        (master, Link::from_port(Box::new(slave), &name))
    }

    #[test]
    fn get_info_is_repeated_until_info_arrives() {
        let (mut master, mut link) = pair();
        let reader = std::thread::spawn(move || {
            // Die ersten beiden Anfragen gehen „verloren", die dritte wird beantwortet.
            let mut seen = 0;
            let mut buf = [0u8; 256];
            let started = Instant::now();
            while seen < 3 && started.elapsed() < Duration::from_secs(5) {
                if let Ok(n) = master.read(&mut buf) {
                    seen += String::from_utf8_lossy(&buf[..n]).matches("get_info").count();
                }
            }
            master
                .write_all(b"{\"type\":\"info\",\"version\":\"2.18.1\",\"mac\":\"aa:bb:cc:dd:ee:ff\"}\n")
                .unwrap();
            (seen, master)
        });
        let info = link.wait_for_info(Duration::from_secs(5)).expect("info nach Wiederholung");
        assert_eq!(info.version, "2.18.1");
        let (seen, _master) = reader.join().unwrap();
        assert!(seen >= 3, "get_info wurde nur {seen}-mal gesendet");
    }

    #[test]
    fn vanished_device_is_reported_as_lost_not_as_foreign_firmware() {
        let (master, mut link) = pair();
        drop(master); // wie ein Gerät, das sich am USB abmeldet
        match link.wait_for_info(Duration::from_secs(3)) {
            Err(LinkError::Lost(_)) => {}
            Err(LinkError::Write(_)) => {} // je nach Plattform schlägt schon das Senden fehl
            other => panic!("erwartet Lost, bekommen {other:?}"),
        }
    }
}
