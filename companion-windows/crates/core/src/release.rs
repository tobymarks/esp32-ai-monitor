//! GitHub-Releases: Modelle, Auswahl je Kanal, Asset-Zuordnung, SHA-256-Sidecars.
//! Port von `GitHubRelease`, `AppUpdateManager.selectAppRelease`,
//! `FirmwareManager.selectFirmwareRelease` aus `main.swift`.
//!
//! Tag-Schema im Repo:
//! - Firmware: `v2.17.0` (stable), `fw-beta-v2.18.0-beta.1` (prerelease)
//! - Mac-App: `app-v1.28.0`, `app-beta-v…` (werden hier ignoriert)
//! - Windows-App: `win-v1.0.0`, `win-beta-v1.0.0-beta.1`

use crate::protocol::DisplayVariant;
use crate::semver;
use serde::{Deserialize, Serialize};

pub const GITHUB_REPO: &str = "tobymarks/esp32-ai-monitor";
pub const RELEASES_API: &str = "https://api.github.com/repos/tobymarks/esp32-ai-monitor/releases";
pub const RELEASES_PAGE: &str = "https://github.com/tobymarks/esp32-ai-monitor/releases";

/// Asset der Windows-App im Release (Plan, Entscheidung 4).
pub const WINDOWS_APP_ASSET: &str = "AIMonitor-Setup.exe";
pub const WINDOWS_APP_TAG_PREFIX: &str = "win-v";
pub const WINDOWS_APP_BETA_TAG_PREFIX: &str = "win-beta-v";
pub const FIRMWARE_BETA_TAG_PREFIX: &str = "fw-beta-v";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum UpdateChannel {
    #[default]
    Stable,
    Beta,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GitHubAsset {
    pub name: String,
    pub browser_download_url: String,
    #[serde(default)]
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GitHubRelease {
    pub tag_name: String,
    #[serde(default)]
    pub prerelease: bool,
    #[serde(default)]
    pub html_url: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub assets: Vec<GitHubAsset>,
}

impl GitHubRelease {
    pub fn asset(&self, name: &str) -> Option<&GitHubAsset> {
        self.assets.iter().find(|a| a.name == name)
    }

    /// Versionsnummer ohne Tag-Präfix, z. B. `2.17.0` aus `fw-beta-v2.17.0-beta.1` bleibt `2.17.0-beta.1`.
    pub fn version(&self) -> String {
        normalize_version(&self.tag_name)
    }
}

/// Entfernt alle bekannten Tag-Präfixe.
pub fn normalize_version(tag: &str) -> String {
    let t = tag.trim();
    for p in ["win-beta-v", "win-v", "fw-beta-v", "fw-beta-", "app-beta-v", "app-v", "v"] {
        if let Some(rest) = t.strip_prefix(p) {
            return rest.to_string();
        }
    }
    t.to_string()
}

pub fn parse_releases(json: &[u8]) -> Result<Vec<GitHubRelease>, serde_json::Error> {
    serde_json::from_slice(json)
}

fn newest<'a>(releases: impl Iterator<Item = &'a GitHubRelease>) -> Option<&'a GitHubRelease> {
    releases.max_by(|a, b| semver::compare(&a.version(), &b.version()))
}

/// Firmware-Release je Kanal: stable sind `v*`-Tags ohne `app-`/`win-`-Präfix
/// und ohne Prerelease-Flag; beta sind `fw-beta-v*` mit Prerelease-Flag,
/// mit Rückfall auf stable (main.swift:1280-1291).
pub fn select_firmware_release(releases: &[GitHubRelease], channel: UpdateChannel) -> Option<&GitHubRelease> {
    let stable = || {
        newest(releases.iter().filter(|r| {
            r.tag_name.starts_with('v') && !r.prerelease
        }))
    };
    match channel {
        UpdateChannel::Stable => stable(),
        UpdateChannel::Beta => newest(
            releases
                .iter()
                .filter(|r| r.tag_name.starts_with(FIRMWARE_BETA_TAG_PREFIX) && r.prerelease),
        )
        .or_else(stable),
    }
}

/// Windows-App-Release je Kanal, analog zu `selectAppRelease` mit `win-`-Präfixen.
pub fn select_windows_app_release(releases: &[GitHubRelease], channel: UpdateChannel) -> Option<&GitHubRelease> {
    let stable = || {
        newest(releases.iter().filter(|r| {
            r.tag_name.starts_with(WINDOWS_APP_TAG_PREFIX) && !r.prerelease
        }))
    };
    match channel {
        UpdateChannel::Stable => stable(),
        UpdateChannel::Beta => newest(
            releases
                .iter()
                .filter(|r| r.tag_name.starts_with(WINDOWS_APP_BETA_TAG_PREFIX) && r.prerelease),
        )
        .or_else(stable),
    }
}

/// `true`, wenn `latest` echt neuer ist als `current`; ein Downgrade nach
/// Kanalwechsel gilt nicht als Update (main.swift:908-915).
pub fn is_newer(current_version: &str, latest_version: &str) -> bool {
    semver::compare(current_version, latest_version) == std::cmp::Ordering::Less
}

/// Asset für die Board-Variante; alte Releases ohne ST7789-Asset fallen auf
/// das Standard-Asset zurück (main.swift:1326-1331).
pub fn firmware_asset<'a>(release: &'a GitHubRelease, variant: DisplayVariant) -> Option<(&'a GitHubAsset, bool)> {
    if let Some(a) = release.asset(variant.firmware_asset()) {
        return Some((a, false));
    }
    release
        .asset(DisplayVariant::Ili9341.firmware_asset())
        .map(|a| (a, true))
}

/// Namen der erwarteten Firmware-Assets, die im Release fehlen.
pub fn missing_firmware_assets(release: &GitHubRelease) -> Vec<&'static str> {
    [DisplayVariant::Ili9341, DisplayVariant::St7789]
        .into_iter()
        .map(DisplayVariant::firmware_asset)
        .filter(|name| release.asset(name).is_none())
        .collect()
}

/// Dateiname im lokalen Firmware-Cache: `ai-monitor-st7789-v2.17.0.bin`.
pub fn cached_firmware_name(variant: DisplayVariant, tag: &str) -> String {
    let base = variant.firmware_asset().trim_end_matches(".bin");
    format!("{base}-{}.bin", tag.trim())
}

/// SHA-256 aus einer `.sha256`-Sidecar-Datei (`<hex>  <name>` oder nur `<hex>`).
pub fn parse_sha256_sidecar(text: &str) -> Option<String> {
    let first = text.split_whitespace().next()?;
    let hex = first.trim().to_ascii_lowercase();
    (hex.len() == 64 && hex.chars().all(|c| c.is_ascii_hexdigit())).then_some(hex)
}

/// SHA-256 als Hex, für den Vergleich mit der Sidecar-Datei.
pub fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(data);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rel(tag: &str, pre: bool, assets: &[&str]) -> GitHubRelease {
        GitHubRelease {
            tag_name: tag.into(),
            prerelease: pre,
            html_url: None,
            name: None,
            assets: assets
                .iter()
                .map(|a| GitHubAsset { name: (*a).into(), browser_download_url: format!("https://x/{a}"), size: 1 })
                .collect(),
        }
    }

    fn sample() -> Vec<GitHubRelease> {
        vec![
            rel("app-v1.28.0", false, &["AIMonitor.zip"]),
            rel("v2.16.0", false, &["ai-monitor.bin", "ai-monitor-st7789.bin"]),
            rel("v2.17.0", false, &["ai-monitor.bin", "ai-monitor-st7789.bin"]),
            rel("fw-beta-v2.18.0-beta.1", true, &["ai-monitor.bin"]),
            rel("win-v1.0.0", false, &["AIMonitor-Setup.exe", "AIMonitor-Setup.exe.sha256"]),
            rel("win-beta-v1.1.0-beta.2", true, &["AIMonitor-Setup.exe"]),
            rel("v2.9.0", false, &["ai-monitor.bin"]),
        ]
    }

    #[test]
    fn firmware_selection_by_channel() {
        let r = sample();
        assert_eq!(select_firmware_release(&r, UpdateChannel::Stable).unwrap().tag_name, "v2.17.0");
        assert_eq!(select_firmware_release(&r, UpdateChannel::Beta).unwrap().tag_name, "fw-beta-v2.18.0-beta.1");
        let only_stable: Vec<_> = r.iter().filter(|x| !x.prerelease).cloned().collect();
        assert_eq!(select_firmware_release(&only_stable, UpdateChannel::Beta).unwrap().tag_name, "v2.17.0");
    }

    #[test]
    fn windows_app_selection_ignores_mac_tags() {
        let r = sample();
        assert_eq!(select_windows_app_release(&r, UpdateChannel::Stable).unwrap().tag_name, "win-v1.0.0");
        assert_eq!(select_windows_app_release(&r, UpdateChannel::Beta).unwrap().tag_name, "win-beta-v1.1.0-beta.2");
        assert!(is_newer("1.0.0", "1.1.0-beta.2"));
        assert!(!is_newer("1.1.0-beta.2", "1.0.0"), "kein Downgrade als Update");
        assert!(!is_newer("1.0.0", "1.0.0"));
    }

    #[test]
    fn assets_and_cache_names() {
        let r = sample();
        let old = &r[6];
        let (a, fallback) = firmware_asset(old, DisplayVariant::St7789).unwrap();
        assert_eq!(a.name, "ai-monitor.bin");
        assert!(fallback);
        assert_eq!(missing_firmware_assets(old), ["ai-monitor-st7789.bin"]);
        assert!(missing_firmware_assets(&r[2]).is_empty());
        assert_eq!(cached_firmware_name(DisplayVariant::St7789, "v2.17.0"), "ai-monitor-st7789-v2.17.0.bin");
        assert_eq!(r[3].version(), "2.18.0-beta.1");
        assert_eq!(normalize_version("win-beta-v1.1.0-beta.2"), "1.1.0-beta.2");
    }

    #[test]
    fn sha256_sidecar_and_digest() {
        let hex = sha256_hex(b"abc");
        assert_eq!(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(parse_sha256_sidecar(&format!("{hex}  AIMonitor-Setup.exe\n")).unwrap(), hex);
        assert_eq!(parse_sha256_sidecar(&hex.to_uppercase()).unwrap(), hex);
        assert!(parse_sha256_sidecar("kaputt").is_none());
    }

    #[test]
    fn parses_github_json() {
        let json = br#"[{"tag_name":"v2.17.0","prerelease":false,"html_url":"https://g/x","assets":[{"name":"ai-monitor.bin","browser_download_url":"https://g/a.bin","size":1343520,"content_type":"application/octet-stream"}]}]"#;
        let r = parse_releases(json).unwrap();
        assert_eq!(r[0].assets[0].size, 1343520);
    }
}
