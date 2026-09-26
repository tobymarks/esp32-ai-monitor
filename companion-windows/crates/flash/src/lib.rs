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

/// Zielchip eines gemergten Images (Layout aus scripts/build_firmware.sh).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetChip {
    /// CYD: ESP32 mit 4 MB, Bootloader an 0x1000.
    Esp32,
    /// Guition 4848S040: ESP32-S3 mit 16 MB, Bootloader an 0x0.
    Esp32S3,
}

impl TargetChip {
    pub fn max_image_bytes(self) -> u64 {
        match self {
            TargetChip::Esp32 => 0x400000,
            TargetChip::Esp32S3 => 0x1000000,
        }
    }

    fn bootloader_offset(self) -> usize {
        match self {
            TargetChip::Esp32 => 0x1000,
            TargetChip::Esp32S3 => 0x0,
        }
    }

    /// `chip_id` im Image-Header (Byte 12–13).
    fn image_chip_id(self) -> u16 {
        match self {
            TargetChip::Esp32 => 0,
            TargetChip::Esp32S3 => 9,
        }
    }

    fn espflash(self) -> Chip {
        match self {
            TargetChip::Esp32 => Chip::Esp32,
            TargetChip::Esp32S3 => Chip::Esp32s3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageValidationError {
    Size,
    Layout,
}

/// Prüft Größe, Bootloader, Partitionstabelle und App sowie die Chip-Kennung
/// im Bootloader-Header — so landet kein Image auf dem falschen Board.
pub fn validate_merged_image(image: &[u8], chip: TargetChip) -> Result<(), ImageValidationError> {
    if image.len() < 0x11000 || image.len() as u64 > chip.max_image_bytes() {
        return Err(ImageValidationError::Size);
    }
    let boot = chip.bootloader_offset();
    let chip_id = u16::from_le_bytes([image[boot + 12], image[boot + 13]]);
    if image[boot] != 0xE9 || chip_id != chip.image_chip_id()
        || image[0x8000..0x8002] != [0xAA, 0x50] || image[0x10000] != 0xE9 {
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
pub fn flash_image(port_name: &str, image: &[u8], baud: u32, chip: TargetChip, on_event: &mut dyn FnMut(FlashEvent)) -> Result<(), FlashError> {
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

    let mut flasher = Flasher::connect(connection, true, true, false, Some(chip.espflash()), Some(baud))
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
        let r = flash_image("/dev/does-not-exist", &[], FLASH_BAUD, TargetChip::Esp32, &mut |e| events.push(e));
        assert!(matches!(r, Err(FlashError::EmptyImage)));
        assert!(events.is_empty());
    }

    #[test]
    fn merged_image_validation_distinguishes_app_image() {
        let mut image = vec![0xff; 0x11000];
        image[0x1000] = 0xe9;
        image[0x100c..0x100e].copy_from_slice(&[0, 0]);
        image[0x8000..0x8002].copy_from_slice(&[0xaa, 0x50]);
        image[0x10000] = 0xe9;
        assert!(validate_merged_image(&image, TargetChip::Esp32).is_ok());
        // Dasselbe Image passt nicht zum S3: Bootloader liegt dort an 0x0.
        assert_eq!(validate_merged_image(&image, TargetChip::Esp32S3), Err(ImageValidationError::Layout));
        image[0x1000] = 0xff;
        assert_eq!(validate_merged_image(&image, TargetChip::Esp32), Err(ImageValidationError::Layout));
        assert_eq!(validate_merged_image(&vec![0xe9; 0x10000], TargetChip::Esp32), Err(ImageValidationError::Size));
        assert_eq!(validate_merged_image(&vec![0xe9; TargetChip::Esp32.max_image_bytes() as usize + 1], TargetChip::Esp32), Err(ImageValidationError::Size));
    }

    #[test]
    fn s3_image_needs_bootloader_at_zero_with_s3_chip_id() {
        let mut image = vec![0xff; 0x11000];
        image[0] = 0xe9;
        image[12..14].copy_from_slice(&9u16.to_le_bytes());
        image[0x8000..0x8002].copy_from_slice(&[0xaa, 0x50]);
        image[0x10000] = 0xe9;
        assert!(validate_merged_image(&image, TargetChip::Esp32S3).is_ok());
        // ESP32-Kennung im Header: falsches Board.
        image[12..14].copy_from_slice(&0u16.to_le_bytes());
        assert_eq!(validate_merged_image(&image, TargetChip::Esp32S3), Err(ImageValidationError::Layout));
        // 16 MB sind für den S3 erlaubt, für den ESP32 nicht.
        assert_eq!(validate_merged_image(&vec![0xe9; 0x400001], TargetChip::Esp32), Err(ImageValidationError::Size));
    }
}
