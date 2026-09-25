//! aimonitor-flash: gemergte Firmware-Images (Bootloader + Partitionen + App
//! ab Offset 0) auf den ESP32 schreiben. Nutzt espflash als Bibliothek,
//! Phase-0-Spike vom 10. September 2026: Release-Image bei 460800 Baud in
//! rund 26 s, danach Hard-Reset.
//!
//! Synchron und blockierend; die App ruft [`flash_image`] in einem
//! Worker-Thread auf und gibt vorher den Serial-Port frei (Spec 6.4).

use espflash::connection::{Connection, ResetAfterOperation, ResetBeforeOperation};
use espflash::flasher::Flasher;
use espflash::target::{Chip, ProgressCallbacks};
use serialport::{FlowControl, SerialPortType, UsbPortInfo};
use std::time::Duration;

/// Baudrate für den Flash-Vorgang wie die Mac-App (main.swift:64).
pub const FLASH_BAUD: u32 = 460_800;
/// Gemergte Images beginnen beim Bootloader.
pub const FLASH_ADDRESS: u32 = 0x0;

/// Layout aus scripts/build_firmware.sh für die unterstützten 4-MB-CYD-Boards.
pub const MAX_IMAGE_BYTES: u64 = 0x400000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageValidationError {
    Size,
    Layout,
}

pub fn validate_merged_image(image: &[u8]) -> Result<(), ImageValidationError> {
    if image.len() < 0x11000 || image.len() as u64 > MAX_IMAGE_BYTES {
        return Err(ImageValidationError::Size);
    }
    if image[0x1000] != 0xE9 || image[0x8000..0x8002] != [0xAA, 0x50] || image[0x10000] != 0xE9 {
        return Err(ImageValidationError::Layout);
    }
    Ok(())
}

#[derive(Debug, thiserror::Error)]
pub enum FlashError {
    #[error("Port konnte nicht geöffnet werden: {0}")]
    Open(String),
    #[error("Keine Verbindung zum ESP32-Bootloader: {0}")]
    Connect(String),
    #[error("Schreiben fehlgeschlagen: {0}")]
    Write(String),
    #[error("Leeres Firmware-Image")]
    EmptyImage,
}

/// Fortschritt, wie ihn die Oberfläche anzeigt (main.swift: FirmwareFlashPhase).
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
#[serde(tag = "phase", rename_all = "camelCase")]
pub enum FlashEvent {
    Connecting,
    Connected { chip: String },
    Erasing,
    Writing { written: usize, total: usize },
    Verifying,
    Rebooting,
    Done,
}

impl FlashEvent {
    /// Prozent innerhalb der Schreibphase, sonst `None`.
    pub fn percent(&self) -> Option<u32> {
        match self {
            FlashEvent::Writing { written, total } if *total > 0 => {
                Some(((*written as f64 / *total as f64) * 100.0).round().min(100.0) as u32)
            }
            _ => None,
        }
    }
}

struct Progress<'a> {
    total: usize,
    on_event: &'a mut dyn FnMut(FlashEvent),
}

impl ProgressCallbacks for Progress<'_> {
    fn init(&mut self, _addr: u32, len: usize) {
        self.total = len;
        (self.on_event)(FlashEvent::Erasing);
        (self.on_event)(FlashEvent::Writing { written: 0, total: len });
    }

    fn update(&mut self, current: usize) {
        (self.on_event)(FlashEvent::Writing { written: current.min(self.total), total: self.total });
    }

    fn verifying(&mut self) {
        (self.on_event)(FlashEvent::Verifying);
    }

    fn finish(&mut self, _skipped: bool) {
        (self.on_event)(FlashEvent::Writing { written: self.total, total: self.total });
    }
}

fn usb_info_for(port_name: &str) -> UsbPortInfo {
    serialport::available_ports()
        .unwrap_or_default()
        .into_iter()
        .find(|p| p.port_name == port_name)
        .and_then(|p| match p.port_type {
            SerialPortType::UsbPort(info) => Some(info),
            _ => None,
        })
        .unwrap_or(UsbPortInfo {
            vid: 0,
            pid: 0,
            serial_number: None,
            manufacturer: None,
            product: None,
        })
}

/// Image ab Offset 0 schreiben, verifizieren, Hard-Reset. Der Port muss
/// frei sein; der Aufrufer trennt vorher die normale Verbindung.
pub fn flash_image(port_name: &str, image: &[u8], baud: u32, on_event: &mut dyn FnMut(FlashEvent)) -> Result<(), FlashError> {
    if image.is_empty() {
        return Err(FlashError::EmptyImage);
    }
    on_event(FlashEvent::Connecting);

    let serial = serialport::new(port_name, 115_200)
        .flow_control(FlowControl::None)
        .timeout(Duration::from_secs(3))
        .open_native()
        .map_err(|e| FlashError::Open(e.to_string()))?;

    let connection = Connection::new(
        serial,
        usb_info_for(port_name),
        ResetAfterOperation::HardReset,
        ResetBeforeOperation::DefaultReset,
        115_200,
    );

    let mut flasher = Flasher::connect(connection, true, true, false, Some(Chip::Esp32), Some(baud))
        .map_err(|e| FlashError::Connect(e.to_string()))?;
    let chip = flasher.chip();
    on_event(FlashEvent::Connected { chip: format!("{chip:?}") });

    let mut progress = Progress { total: image.len(), on_event };
    flasher
        .write_bin_to_flash(FLASH_ADDRESS, image, &mut progress)
        .map_err(|e| FlashError::Write(e.to_string()))?;

    on_event(FlashEvent::Rebooting);
    flasher
        .connection()
        .reset_after(true, chip)
        .map_err(|e| FlashError::Write(e.to_string()))?;
    drop(flasher);
    on_event(FlashEvent::Done);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_only_while_writing() {
        assert_eq!(FlashEvent::Writing { written: 250, total: 1000 }.percent(), Some(25));
        assert_eq!(FlashEvent::Writing { written: 0, total: 0 }.percent(), None);
        assert_eq!(FlashEvent::Verifying.percent(), None);
    }

    #[test]
    fn empty_image_is_rejected_before_touching_the_port() {
        let mut events = Vec::new();
        let r = flash_image("/dev/does-not-exist", &[], FLASH_BAUD, &mut |e| events.push(e));
        assert!(matches!(r, Err(FlashError::EmptyImage)));
        assert!(events.is_empty());
    }

    #[test]
    fn merged_image_validation_distinguishes_app_image() {
        let mut image = vec![0xff; 0x11000];
        image[0x1000] = 0xe9;
        image[0x8000..0x8002].copy_from_slice(&[0xaa, 0x50]);
        image[0x10000] = 0xe9;
        assert!(validate_merged_image(&image).is_ok());
        image[0x1000] = 0xff;
        assert_eq!(validate_merged_image(&image), Err(ImageValidationError::Layout));
        assert_eq!(validate_merged_image(&vec![0xe9; 0x10000]), Err(ImageValidationError::Size));
        assert_eq!(validate_merged_image(&vec![0xe9; MAX_IMAGE_BYTES as usize + 1]), Err(ImageValidationError::Size));
    }
}
