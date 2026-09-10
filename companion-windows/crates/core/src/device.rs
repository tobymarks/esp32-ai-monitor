//! Geräteprofile je MAC und die Registry dazu. Port von `DeviceProfile`,
//! `DeviceRegistry` und `resolveDeviceProfile` aus `main.swift` (Spec 6.1).
//!
//! Die App persistiert die Registry als JSON (siehe [`DeviceRegistry::to_json`]).
//! Das Format ist nicht mit den UserDefaults der Mac-App kompatibel, dort
//! liegen Datumswerte als Sekunden seit 2001; hier RFC 3339.

use crate::protocol::{DeviceInfo, DisplayVariant, Language, Orientation, ThemeSetting, LEGACY_DEVICE_MAC};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

pub const DEFAULT_BRIGHTNESS: i64 = 80;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceProfile {
    pub mac: String,
    pub friendly_name: String,
    #[serde(default)]
    pub theme: ThemeSetting,
    #[serde(default)]
    pub orientation: Orientation,
    #[serde(default)]
    pub language: Language,
    #[serde(default = "default_brightness")]
    pub brightness: i64,
    #[serde(default)]
    pub display_variant: Option<DisplayVariant>,
    #[serde(default)]
    pub last_seen_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub firmware_version: Option<String>,
}

fn default_brightness() -> i64 {
    DEFAULT_BRIGHTNESS
}

impl DeviceProfile {
    pub fn new(mac: &str, friendly_name: &str) -> Self {
        Self {
            mac: mac.to_string(),
            friendly_name: friendly_name.to_string(),
            theme: ThemeSetting::System,
            orientation: Orientation::Portrait,
            language: Language::De,
            brightness: DEFAULT_BRIGHTNESS,
            display_variant: None,
            last_seen_at: None,
            firmware_version: None,
        }
    }
}

/// Was `resolve` mit dem Profil gemacht hat, für Log und Diagnose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResolveOutcome {
    Matched,
    MigratedFromLegacy,
    Created,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceRegistry {
    /// BTreeMap, damit die JSON-Datei stabil sortiert bleibt.
    #[serde(default)]
    pub devices: BTreeMap<String, DeviceProfile>,
    /// MAC des gerade verbundenen Geräts; `None` ohne Verbindung.
    #[serde(default)]
    pub current_mac: Option<String>,
    /// Zuletzt verbundenes Gerät, bleibt über Trennungen erhalten (Vorlage für Defaults).
    #[serde(default)]
    pub last_known_mac: Option<String>,
}

impl DeviceRegistry {
    pub fn from_json(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "{}".into())
    }

    pub fn profile(&self, mac: &str) -> Option<&DeviceProfile> {
        self.devices.get(mac)
    }

    pub fn profile_mut(&mut self, mac: &str) -> Option<&mut DeviceProfile> {
        self.devices.get_mut(mac)
    }

    /// Profil des verbundenen Geräts, sonst des zuletzt bekannten.
    pub fn current_profile(&self) -> Option<&DeviceProfile> {
        self.current_mac
            .as_deref()
            .or(self.last_known_mac.as_deref())
            .and_then(|m| self.devices.get(m))
    }

    pub fn current_profile_mut(&mut self) -> Option<&mut DeviceProfile> {
        let mac = self.current_mac.clone().or_else(|| self.last_known_mac.clone())?;
        self.devices.get_mut(&mac)
    }

    pub fn save(&mut self, profile: DeviceProfile) {
        self.devices.insert(profile.mac.clone(), profile);
    }

    pub fn remove(&mut self, mac: &str) {
        self.devices.remove(mac);
        if self.current_mac.as_deref() == Some(mac) {
            self.current_mac = None;
        }
        if self.last_known_mac.as_deref() == Some(mac) {
            self.last_known_mac = None;
        }
    }

    pub fn is_name_taken(&self, name: &str, exclude_mac: Option<&str>) -> bool {
        self.devices
            .iter()
            .any(|(mac, p)| Some(mac.as_str()) != exclude_mac && p.friendly_name == name)
    }

    /// Verbindung getrennt: `current_mac` löschen, `last_known_mac` behalten.
    pub fn disconnected(&mut self) {
        self.current_mac = None;
    }

    /// Profil nach dem `info`-Handshake auflösen (main.swift:1967-2046).
    pub fn resolve(&mut self, info: &DeviceInfo, now: DateTime<Utc>) -> (DeviceProfile, ResolveOutcome) {
        let mac = info.mac.clone();

        if let Some(existing) = self.devices.get_mut(&mac) {
            if let Some(b) = info.brightness {
                existing.brightness = b;
            }
            if let Some(d) = info.display {
                existing.display_variant = Some(d);
            }
            existing.last_seen_at = Some(now);
            existing.firmware_version = Some(info.version.clone());
            let profile = existing.clone();
            self.current_mac = Some(mac.clone());
            self.last_known_mac = Some(mac);
            return (profile, ResolveOutcome::Matched);
        }

        // Echte MAC, aber nur ein Legacy-Profil: Einstellungen mitnehmen.
        if mac != LEGACY_DEVICE_MAC {
            if let Some(legacy) = self.devices.remove(LEGACY_DEVICE_MAC) {
                let mut moved = legacy;
                moved.mac = mac.clone();
                if let Some(b) = info.brightness {
                    moved.brightness = b;
                }
                if let Some(d) = info.display {
                    moved.display_variant = Some(d);
                }
                moved.last_seen_at = Some(now);
                moved.firmware_version = Some(info.version.clone());
                self.devices.insert(mac.clone(), moved.clone());
                self.current_mac = Some(mac.clone());
                self.last_known_mac = Some(mac);
                return (moved, ResolveOutcome::MigratedFromLegacy);
            }
        }

        // Neues Gerät: Auto-Name, Defaults aus dem zuletzt aktiven Profil.
        let existing_names: HashSet<String> = self.devices.values().map(|p| p.friendly_name.clone()).collect();
        let name = generate_auto_name(&existing_names, seed_from_time(now));
        let template = self.current_profile().cloned();
        let mut fresh = DeviceProfile::new(&mac, &name);
        if let Some(t) = &template {
            fresh.theme = t.theme;
            fresh.orientation = t.orientation;
            fresh.language = t.language;
            fresh.brightness = t.brightness;
        }
        if let Some(b) = info.brightness {
            fresh.brightness = b;
        }
        fresh.display_variant = info.display;
        fresh.last_seen_at = Some(now);
        fresh.firmware_version = Some(info.version.clone());
        self.devices.insert(mac.clone(), fresh.clone());
        self.current_mac = Some(mac.clone());
        self.last_known_mac = Some(mac);
        (fresh, ResolveOutcome::Created)
    }
}

// ---------------------------------------------------------------------------
// Auto-Namen (main.swift:108-185, 303-320)
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Genus {
    Masc,
    Fem,
    Neutr,
}

const ADJECTIVES: [(&str, &str, &str); 30] = [
    ("Flinker", "Flinke", "Flinkes"),
    ("Funkelnder", "Funkelnde", "Funkelndes"),
    ("Mürrischer", "Mürrische", "Mürrisches"),
    ("Stolzer", "Stolze", "Stolzes"),
    ("Neugieriger", "Neugierige", "Neugieriges"),
    ("Gelassener", "Gelassene", "Gelassenes"),
    ("Schelmischer", "Schelmische", "Schelmisches"),
    ("Mutiger", "Mutige", "Mutiges"),
    ("Verträumter", "Verträumte", "Verträumtes"),
    ("Pfiffiger", "Pfiffige", "Pfiffiges"),
    ("Wuseliger", "Wuselige", "Wuseliges"),
    ("Tapferer", "Tapfere", "Tapferes"),
    ("Stürmischer", "Stürmische", "Stürmisches"),
    ("Leiser", "Leise", "Leises"),
    ("Kniffliger", "Knifflige", "Kniffliges"),
    ("Flauschiger", "Flauschige", "Flauschiges"),
    ("Glücklicher", "Glückliche", "Glückliches"),
    ("Schlauer", "Schlaue", "Schlaues"),
    ("Ruhiger", "Ruhige", "Ruhiges"),
    ("Verrückter", "Verrückte", "Verrücktes"),
    ("Zackiger", "Zackige", "Zackiges"),
    ("Emsiger", "Emsige", "Emsiges"),
    ("Munterer", "Muntere", "Munteres"),
    ("Fröhlicher", "Fröhliche", "Fröhliches"),
    ("Weiser", "Weise", "Weises"),
    ("Frecher", "Freche", "Freches"),
    ("Kühner", "Kühne", "Kühnes"),
    ("Sanfter", "Sanfte", "Sanftes"),
    ("Granteliger", "Grantelige", "Granteliges"),
    ("Glitzernder", "Glitzernde", "Glitzerndes"),
];

const ANIMALS: [(&str, Genus); 30] = [
    ("Dachs", Genus::Masc),
    ("Otter", Genus::Masc),
    ("Igel", Genus::Masc),
    ("Kolibri", Genus::Masc),
    ("Luchs", Genus::Masc),
    ("Biber", Genus::Masc),
    ("Eichhörnchen", Genus::Neutr),
    ("Fuchs", Genus::Masc),
    ("Waschbär", Genus::Masc),
    ("Hirsch", Genus::Masc),
    ("Wolf", Genus::Masc),
    ("Uhu", Genus::Masc),
    ("Seepferdchen", Genus::Neutr),
    ("Marienkäfer", Genus::Masc),
    ("Tintenfisch", Genus::Masc),
    ("Erdmännchen", Genus::Neutr),
    ("Murmeltier", Genus::Neutr),
    ("Pelikan", Genus::Masc),
    ("Elster", Genus::Fem),
    ("Salamander", Genus::Masc),
    ("Feuersalamander", Genus::Masc),
    ("Seeadler", Genus::Masc),
    ("Kakadu", Genus::Masc),
    ("Kranich", Genus::Masc),
    ("Panda", Genus::Masc),
    ("Koala", Genus::Masc),
    ("Quokka", Genus::Neutr),
    ("Ameisenbär", Genus::Masc),
    ("Schildkröte", Genus::Fem),
    ("Nashorn", Genus::Neutr),
];

fn seed_from_time(now: DateTime<Utc>) -> u64 {
    let nanos = now.timestamp_nanos_opt().unwrap_or(0) as u64;
    nanos ^ 0x9E37_79B9_7F4A_7C15
}

/// xorshift64, reicht für Namensvorschläge; kein `rand`-Crate nötig.
fn next_random(state: &mut u64) -> u64 {
    let mut x = *state;
    if x == 0 {
        x = 0x2545_F491_4F6C_DD1D;
    }
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    x
}

/// „Flinker Dachs" mit Genus-Abgleich, 50 Versuche gegen Kollisionen,
/// dann „Gerät N" mit kleinster freier Nummer.
pub fn generate_auto_name(existing: &HashSet<String>, seed: u64) -> String {
    let mut state = seed;
    for _ in 0..50 {
        let adj = ADJECTIVES[(next_random(&mut state) % ADJECTIVES.len() as u64) as usize];
        let (animal, genus) = ANIMALS[(next_random(&mut state) % ANIMALS.len() as u64) as usize];
        let form = match genus {
            Genus::Masc => adj.0,
            Genus::Fem => adj.1,
            Genus::Neutr => adj.2,
        };
        let candidate = format!("{form} {animal}");
        if !existing.contains(&candidate) {
            return candidate;
        }
    }
    let mut n = 1;
    while existing.contains(&format!("Gerät {n}")) {
        n += 1;
    }
    format!("Gerät {n}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn info(mac: &str, version: &str, brightness: Option<i64>, display: Option<DisplayVariant>) -> DeviceInfo {
        DeviceInfo {
            version: version.into(),
            mac: mac.into(),
            display,
            orientation: None,
            theme: None,
            language: None,
            brightness,
            serial_transport: None,
            max_frame_bytes: None,
            wifi_configured: None,
            wifi_connected: None,
            time_synced: None,
            uptime: None,
            heap: None,
        }
    }

    fn now() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 9, 0, 0).unwrap()
    }

    #[test]
    fn creates_matches_and_updates() {
        let mut reg = DeviceRegistry::default();
        let (p, o) = reg.resolve(&info("aa:bb", "2.17.0", Some(60), Some(DisplayVariant::Ili9341)), now());
        assert_eq!(o, ResolveOutcome::Created);
        assert_eq!(p.brightness, 60);
        assert_eq!(p.display_variant, Some(DisplayVariant::Ili9341));
        assert!(!p.friendly_name.is_empty());
        assert_eq!(reg.current_mac.as_deref(), Some("aa:bb"));

        reg.profile_mut("aa:bb").unwrap().orientation = Orientation::LandscapeLeft;
        let (p2, o2) = reg.resolve(&info("aa:bb", "2.18.0", Some(70), None), now());
        assert_eq!(o2, ResolveOutcome::Matched);
        assert_eq!(p2.orientation, Orientation::LandscapeLeft, "Nutzereinstellung bleibt");
        assert_eq!(p2.brightness, 70);
        assert_eq!(p2.display_variant, Some(DisplayVariant::Ili9341), "unknown überschreibt nicht");
        assert_eq!(p2.firmware_version.as_deref(), Some("2.18.0"));
    }

    #[test]
    fn migrates_legacy_profile_and_uses_template_for_new_devices() {
        let mut reg = DeviceRegistry::default();
        let (legacy, _) = reg.resolve(&info(LEGACY_DEVICE_MAC, "2.9.0", None, None), now());
        reg.profile_mut(LEGACY_DEVICE_MAC).unwrap().language = Language::En;
        assert_eq!(legacy.mac, LEGACY_DEVICE_MAC);

        let (moved, o) = reg.resolve(&info("cc:dd", "2.10.0", Some(50), None), now());
        assert_eq!(o, ResolveOutcome::MigratedFromLegacy);
        assert_eq!(moved.language, Language::En);
        assert!(reg.profile(LEGACY_DEVICE_MAC).is_none());

        // Zweites, neues Gerät bekommt die Einstellungen des aktiven als Vorlage.
        let (fresh, o) = reg.resolve(&info("ee:ff", "2.17.0", None, None), now());
        assert_eq!(o, ResolveOutcome::Created);
        assert_eq!(fresh.language, Language::En);
        assert_eq!(fresh.brightness, 50);
        assert_ne!(fresh.friendly_name, moved.friendly_name);
    }

    #[test]
    fn auto_names_avoid_collisions_and_fall_back() {
        let mut existing = HashSet::new();
        let a = generate_auto_name(&existing, 1);
        existing.insert(a.clone());
        let b = generate_auto_name(&existing, 1);
        assert_ne!(a, b);
        for adj in ADJECTIVES {
            for (animal, genus) in ANIMALS {
                let form = match genus {
                    Genus::Masc => adj.0,
                    Genus::Fem => adj.1,
                    Genus::Neutr => adj.2,
                };
                existing.insert(format!("{form} {animal}"));
            }
        }
        assert_eq!(generate_auto_name(&existing, 7), "Gerät 1");
        existing.insert("Gerät 1".into());
        assert_eq!(generate_auto_name(&existing, 7), "Gerät 2");
    }

    #[test]
    fn json_round_trip_keeps_fields() {
        let mut reg = DeviceRegistry::default();
        reg.resolve(&info("aa:bb", "2.17.0", Some(80), Some(DisplayVariant::St7789)), now());
        let json = reg.to_json();
        assert!(json.contains("\"friendlyName\""));
        assert!(json.contains("\"displayVariant\": \"st7789\""));
        let back = DeviceRegistry::from_json(&json).unwrap();
        assert_eq!(back.devices, reg.devices);
        assert_eq!(back.current_mac, reg.current_mac);
    }
}
