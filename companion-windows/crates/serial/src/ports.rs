//! Port-Kandidaten. Der Mac filtert auf `cu.usbserial-*` (Spec 2.1); hier
//! filtern wir über die USB-Kennung des Adapters (Spec 9.2).

use serde::Serialize;
use serialport::{SerialPortType, UsbPortInfo};

/// Bekannte USB-Serial-Chips auf CYD-Boards.
pub const KNOWN_CHIPS: [(u16, u16, &str); 4] = [
    (0x1A86, 0x7523, "CH340"),
    (0x1A86, 0x55D4, "CH9102"),
    (0x10C4, 0xEA60, "CP2102"),
    (0x0403, 0x6001, "FT232"),
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PortCandidate {
    /// Gerätename, z. B. `COM5` oder `/dev/cu.usbserial-1440`.
    pub name: String,
    pub vid: Option<u16>,
    pub pid: Option<u16>,
    pub serial_number: Option<String>,
    pub product: Option<String>,
    /// Chip laut [`KNOWN_CHIPS`], sonst `None`.
    pub chip: Option<&'static str>,
}

impl PortCandidate {
    pub fn is_known_chip(&self) -> bool {
        self.chip.is_some()
    }
}

fn chip_for(usb: &UsbPortInfo) -> Option<&'static str> {
    KNOWN_CHIPS
        .iter()
        .find(|(v, p, _)| *v == usb.vid && *p == usb.pid)
        .map(|(_, _, name)| *name)
}

/// Alle USB-Serial-Ports, bekannte Chips zuerst, dann natürlich sortiert
/// (`COM9` vor `COM10`). Unter macOS nur die `cu.`-Einträge.
pub fn list_ports() -> Vec<PortCandidate> {
    let mut out: Vec<PortCandidate> = serialport::available_ports()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|p| match p.port_type {
            SerialPortType::UsbPort(usb) => Some(PortCandidate {
                chip: chip_for(&usb),
                name: p.port_name,
                vid: Some(usb.vid),
                pid: Some(usb.pid),
                serial_number: usb.serial_number,
                product: usb.product,
            }),
            _ => None,
        })
        .filter(|p| !cfg!(target_os = "macos") || p.name.starts_with("/dev/cu."))
        .collect();
    out.sort_by(|a, b| {
        b.is_known_chip()
            .cmp(&a.is_known_chip())
            .then_with(|| natural_key(&a.name).cmp(&natural_key(&b.name)))
    });
    out
}

/// Zerlegt `COM10` in ("COM", 10), damit Zahlen numerisch sortieren.
fn natural_key(name: &str) -> (String, u64) {
    let digits: String = name.chars().rev().take_while(|c| c.is_ascii_digit()).collect::<Vec<_>>().into_iter().rev().collect();
    let prefix = &name[..name.len() - digits.len()];
    (prefix.to_string(), digits.parse().unwrap_or(0))
}

/// Auswahlregel wie auf dem Mac (Spec 2.1): manueller Port, wenn vorhanden,
/// sonst der erste Kandidat mit bekanntem Chip, sonst der erste überhaupt.
pub fn choose_port<'a>(candidates: &'a [PortCandidate], manual: Option<&str>) -> Option<&'a PortCandidate> {
    if let Some(m) = manual {
        if let Some(c) = candidates.iter().find(|c| c.name == m) {
            return Some(c);
        }
    }
    candidates.iter().find(|c| c.is_known_chip()).or_else(|| candidates.first())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(name: &str, chip: Option<&'static str>) -> PortCandidate {
        PortCandidate { name: name.into(), vid: None, pid: None, serial_number: None, product: None, chip }
    }

    #[test]
    fn natural_sort_and_known_first() {
        let mut v = vec![cand("COM10", None), cand("COM9", Some("CH340")), cand("COM3", None)];
        v.sort_by(|a, b| b.is_known_chip().cmp(&a.is_known_chip()).then_with(|| natural_key(&a.name).cmp(&natural_key(&b.name))));
        assert_eq!(v.iter().map(|c| c.name.as_str()).collect::<Vec<_>>(), ["COM9", "COM3", "COM10"]);
    }

    #[test]
    fn manual_port_wins_when_present() {
        let v = vec![cand("COM3", None), cand("COM4", Some("CP2102"))];
        assert_eq!(choose_port(&v, Some("COM3")).unwrap().name, "COM3");
        assert_eq!(choose_port(&v, Some("COM7")).unwrap().name, "COM4");
        assert_eq!(choose_port(&v, None).unwrap().name, "COM4");
        assert!(choose_port(&[], None).is_none());
    }
}
