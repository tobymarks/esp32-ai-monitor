//! Portable store for declarative display plugins. Validation is in the core
//! crate; this module owns persistence, bounded HTTPS fetches, and state.

use aimonitor_core::device::Location;
use aimonitor_core::plugin::{
    scene_for_protocol, status_scene_with_theme, status_text, Manifest, SceneLayout, Setting,
};
use aimonitor_core::protocol::{Language, Theme};
use aimonitor_core::plugin_package::{parse_package, MAX_PACKAGE_BYTES};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use url::Url;

pub const PLUGINS_EVENT: &str = "plugins-changed";
const MAX_SOURCE_BYTES: usize = 64 * 1024;
const MAX_PLUGINS: usize = 20;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginPreview {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub attribution: Option<String>,
    pub source_origin: String,
    pub sha256: String,
    pub signed: bool,
    /// The plugin sends the display location to `source_origin`.
    pub requires_location: bool,
    pub settings_spec: Vec<Setting>,
    pub localizations: BTreeMap<String, BTreeMap<String, String>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginInfo {
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub view_label: String,
    pub attribution: Option<String>,
    pub source_origin: String,
    pub sha256: String,
    pub signed: bool,
    pub requires_location: bool,
    pub settings_spec: Vec<Setting>,
    pub localizations: BTreeMap<String, BTreeMap<String, String>>,
    pub settings: Map<String, Value>,
    pub fetched_at: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct PluginRecord {
    pub manifest: Manifest,
    pub sha256: String,
    pub settings: Map<String, Value>,
    pub data: Option<Value>,
    pub fetched_at: Option<DateTime<Utc>>,
    pub last_attempt: Option<Instant>,
    pub last_error: Option<String>,
}

impl PluginRecord {
    pub fn info(&self) -> PluginInfo {
        let origin = self
            .manifest
            .source_url(&self.settings)
            .ok()
            .and_then(|url| Url::parse(&url).ok())
            .map(|url| url.origin().ascii_serialization())
            .unwrap_or_else(|| "invalid source".into());
        PluginInfo {
            id: self.manifest.id.clone(),
            name: self.manifest.name.clone(),
            version: self.manifest.version.clone(),
            author: self.manifest.author.clone(),
            description: self.manifest.description.clone(),
            view_label: self.manifest.view_label.clone(),
            attribution: self.manifest.attribution.clone(),
            source_origin: origin,
            sha256: self.sha256.clone(),
            signed: false,
            requires_location: self.manifest.requires_location(),
            settings_spec: self.manifest.settings.clone(),
            localizations: self.manifest.localizations.clone(),
            settings: self.settings.clone(),
            fetched_at: self.fetched_at,
            last_error: self.last_error.clone(),
        }
    }

    /// `location` is the place stored for the connected display. Data fetched
    /// for another place is dropped by [`PluginStore::set_location`].
    /// `scene_protocol` is what the firmware reports; below 2 the text is
    /// transliterated to ASCII.
    pub fn scene(
        &self,
        layout: SceneLayout,
        language: Language,
        theme: Theme,
        location: Option<&Location>,
        scene_protocol: u32,
    ) -> Value {
        scene_for_protocol(self.scene_utf8(layout, language, theme, location), scene_protocol)
    }

    fn scene_utf8(
        &self,
        layout: SceneLayout,
        language: Language,
        theme: Theme,
        location: Option<&Location>,
    ) -> Value {
        let title = self.manifest.localized(language.wire(), &self.manifest.view_label);
        if self.manifest.requires_location() && location.is_none() {
            return status_scene_with_theme(title, status_text("location", language), theme);
        }
        if let Some(error) = &self.last_error {
            // Auf 60 Zeichen kürzen, sonst ersetzt status_scene die Meldung.
            let message: String = format!("{}: {error}", status_text("unavailable", language))
                .chars()
                .take(60)
                .collect();
            return status_scene_with_theme(title, &message, theme);
        }
        let Some(data) = &self.data else {
            return status_scene_with_theme(title, status_text("loading", language), theme);
        };
        let stale_after =
            chrono::Duration::seconds(self.manifest.source.interval_seconds as i64 * 3);
        if self
            .fetched_at
            .is_none_or(|time| Utc::now() - time > stale_after)
        {
            return status_scene_with_theme(title, status_text("stale", language), theme);
        }
        self.manifest
            .scene_at(layout, data, &self.settings, theme, language.wire(), location)
            .unwrap_or_else(|_| {
                status_scene_with_theme(title, status_text("render", language), theme)
            })
    }
}

pub struct PluginStore {
    root: PathBuf,
    pub records: BTreeMap<String, PluginRecord>,
    /// Standort des verbundenen Displays, siehe [`PluginStore::set_location`].
    location: Option<Location>,
}

/// One pending source request, see [`PluginStore::due_fetches`].
#[derive(Debug, Clone)]
pub struct DueFetch {
    pub id: String,
    pub sha256: String,
    pub manifest: Manifest,
    pub settings: Map<String, Value>,
    pub location: Option<Location>,
}

/// One place found by [`search_places`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Place {
    pub name: String,
    /// Region und Land zur Unterscheidung gleichnamiger Orte.
    pub detail: String,
    pub latitude: f64,
    pub longitude: f64,
}

impl PluginStore {
    pub fn load(root: PathBuf) -> Self {
        let mut store = Self {
            root,
            records: BTreeMap::new(),
            location: None,
        };
        let Ok(entries) = fs::read_dir(&store.root) else {
            return store;
        };
        // A power loss between the two Windows renames leaves a backup.
        // Check settings first: `.id.settings.previous` also ends in
        // `.previous` and must never become an `.aimplugin` file.
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            if let Some(id) = name
                .strip_prefix('.')
                .and_then(|s| s.strip_suffix(".settings.previous"))
            {
                let target = store.settings_path(id);
                if !target.exists() {
                    let _ = fs::rename(&path, &target);
                }
                continue;
            }
            if let Some(id) = name
                .strip_prefix('.')
                .and_then(|s| s.strip_suffix(".previous"))
            {
                let target = store.package_path(id);
                if !target.exists() {
                    let _ = fs::rename(&path, &target);
                }
            }
        }
        let Ok(entries) = fs::read_dir(&store.root) else {
            return store;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("aimplugin") {
                continue;
            }
            let Ok(bytes) = read_bounded(&path, MAX_PACKAGE_BYTES) else {
                continue;
            };
            let Ok(package) = parse_package(&bytes) else {
                eprintln!("[plugins] Ungueltiges Paket: {}", path.display());
                continue;
            };
            if path.file_stem().and_then(|s| s.to_str()) != Some(package.manifest.id.as_str()) {
                eprintln!(
                    "[plugins] Paket-ID und Dateiname passen nicht: {}",
                    path.display()
                );
                continue;
            }
            let settings = store.read_settings(&package.manifest);
            store.records.insert(
                package.manifest.id.clone(),
                PluginRecord {
                    manifest: package.manifest,
                    sha256: package.sha256,
                    settings,
                    data: None,
                    fetched_at: None,
                    last_attempt: None,
                    last_error: None,
                },
            );
        }
        store
    }

    pub fn location(&self) -> Option<&Location> {
        self.location.as_ref()
    }

    /// Der Standort gehört zum verbundenen Display. Wechselt er, gelten die
    /// Daten standortabhängiger Plugins nicht mehr und werden neu geholt.
    /// Liefert `true`, wenn sich etwas geändert hat.
    pub fn set_location(&mut self, location: Option<Location>) -> bool {
        let location = location.filter(Location::is_valid);
        if self.location == location {
            return false;
        }
        self.location = location;
        for record in self.records.values_mut() {
            if record.manifest.requires_location() {
                record.data = None;
                record.fetched_at = None;
                record.last_attempt = None;
                record.last_error = None;
            }
        }
        true
    }

    pub fn list(&self) -> Vec<PluginInfo> {
        self.records.values().map(PluginRecord::info).collect()
    }

    fn package_path(&self, id: &str) -> PathBuf {
        self.root.join(format!("{id}.aimplugin"))
    }
    fn settings_path(&self, id: &str) -> PathBuf {
        self.root.join(format!("{id}.settings.json"))
    }

    fn read_settings(&self, manifest: &Manifest) -> Map<String, Value> {
        let path = self.settings_path(&manifest.id);
        let saved: Map<String, Value> = read_bounded(&path, 16 * 1024)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        merge_valid_settings(manifest, &saved)
    }

    pub fn install(&mut self, bytes: &[u8]) -> Result<PluginInfo, String> {
        let package = parse_package(bytes)?;
        let id = package.manifest.id.clone();
        if !self.records.contains_key(&id) && self.records.len() >= MAX_PLUGINS {
            return Err("plugin limit reached".into());
        }
        fs::create_dir_all(&self.root).map_err(|e| format!("plugin directory: {e}"))?;
        let settings = self.read_settings(&package.manifest);
        let target = self.package_path(&id);
        let staged = self.root.join(format!(".{id}.installing"));
        let backup = self.root.join(format!(".{id}.previous"));
        fs::write(&staged, bytes).map_err(|e| format!("stage plugin: {e}"))?;
        // Windows cannot atomically rename over an existing file. Keep the
        // prior package until the replacement has been moved into place.
        if target.exists() {
            if backup.exists() {
                fs::remove_file(&backup).map_err(|e| format!("old backup: {e}"))?;
            }
            fs::rename(&target, &backup).map_err(|e| format!("backup plugin: {e}"))?;
        }
        if let Err(e) = fs::rename(&staged, &target) {
            if backup.exists() {
                let _ = fs::rename(&backup, &target);
            }
            let _ = fs::remove_file(&staged);
            return Err(format!("activate plugin: {e}"));
        }
        let _ = fs::remove_file(&backup);
        let record = PluginRecord {
            manifest: package.manifest,
            sha256: package.sha256,
            settings,
            data: None,
            fetched_at: None,
            last_attempt: None,
            last_error: None,
        };
        let info = record.info();
        self.records.insert(id, record);
        Ok(info)
    }

    pub fn configure(
        &mut self,
        id: &str,
        values: Map<String, Value>,
    ) -> Result<PluginInfo, String> {
        let record = self.records.get(id).ok_or("plugin not installed")?;
        record.manifest.source_url(&values)?;
        let merged = merge_valid_settings(&record.manifest, &values);
        if merged.len() != values.len() || merged.iter().any(|(k, v)| values.get(k) != Some(v)) {
            return Err("invalid plugin settings".into());
        }
        let bytes = serde_json::to_vec_pretty(&merged).map_err(|e| e.to_string())?;
        let target = self.settings_path(id);
        let staged = target.with_extension("part");
        let backup = self.root.join(format!(".{id}.settings.previous"));
        fs::write(&staged, bytes).map_err(|e| format!("save settings: {e}"))?;
        // Windows cannot rename over an existing target. A backup makes the
        // replacement recoverable if activation or the process fails.
        if target.exists() {
            if backup.exists() {
                fs::remove_file(&backup).map_err(|e| format!("old backup: {e}"))?;
            }
            fs::rename(&target, &backup).map_err(|e| format!("backup settings: {e}"))?;
        }
        if let Err(error) = fs::rename(&staged, &target) {
            if backup.exists() {
                let _ = fs::rename(&backup, &target);
            }
            return Err(format!("activate settings: {error}"));
        }
        let _ = fs::remove_file(&backup);
        let record = self.records.get_mut(id).unwrap();
        record.settings = merged;
        record.data = None;
        record.fetched_at = None;
        record.last_attempt = None;
        record.last_error = None;
        Ok(record.info())
    }

    pub fn remove(&mut self, id: &str) -> Result<(), String> {
        if !self.records.contains_key(id) {
            return Err("plugin not installed".into());
        }
        fs::remove_file(self.package_path(id)).map_err(|e| format!("remove plugin: {e}"))?;
        let _ = fs::remove_file(self.settings_path(id));
        self.records.remove(id);
        Ok(())
    }

    pub fn due_fetches(&mut self, assigned: &HashSet<String>) -> Vec<DueFetch> {
        let mut due = Vec::new();
        for id in assigned {
            let Some(record) = self.records.get_mut(id) else {
                continue;
            };
            // Ohne Standort gibt es nichts abzurufen; das Fenster zeigt den Hinweis.
            if record.manifest.requires_location() && self.location.is_none() {
                continue;
            }
            let interval = Duration::from_secs(if record.last_error.is_some() {
                record.manifest.source.interval_seconds.min(60)
            } else {
                record.manifest.source.interval_seconds
            } as u64);
            if record.last_attempt.is_some_and(|t| t.elapsed() < interval) {
                continue;
            }
            record.last_attempt = Some(Instant::now());
            due.push(DueFetch {
                id: id.clone(),
                sha256: record.sha256.clone(),
                manifest: record.manifest.clone(),
                settings: record.settings.clone(),
                location: self.location.clone(),
            });
        }
        due
    }

    pub fn apply_fetch(&mut self, fetch: &DueFetch, result: Result<Value, String>) -> bool {
        let Some(record) = self.records.get_mut(&fetch.id) else {
            return false;
        };
        if record.sha256 != fetch.sha256
            || record.settings != fetch.settings
            || (record.manifest.requires_location() && self.location != fetch.location)
        {
            return false;
        }
        match result {
            Ok(value) => {
                record.data = Some(value);
                record.fetched_at = Some(Utc::now());
                record.last_error = None;
                true
            }
            Err(error) => {
                record.last_error = Some(error.chars().take(60).collect());
                false
            }
        }
    }
}

fn merge_valid_settings(manifest: &Manifest, saved: &Map<String, Value>) -> Map<String, Value> {
    let mut result = manifest.default_settings();
    for setting in &manifest.settings {
        if let Some(value) = saved.get(&setting.key) {
            let mut candidate = result.clone();
            candidate.insert(setting.key.clone(), value.clone());
            if manifest.source_url(&candidate).is_ok() {
                result = candidate;
            }
        }
    }
    result
}

pub fn read_bounded(path: &Path, max: usize) -> Result<Vec<u8>, String> {
    let metadata = fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if metadata.len() > max as u64 {
        return Err("file exceeds size limit".into());
    }
    let mut bytes = Vec::new();
    fs::File::open(path)
        .map_err(|e| e.to_string())?
        .take((max + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > max {
        return Err("file exceeds size limit".into());
    }
    Ok(bytes)
}

pub fn read_source(source: &str) -> Result<Vec<u8>, String> {
    if !source.contains("://") {
        return read_bounded(Path::new(source), MAX_PACKAGE_BYTES);
    }
    let mut current = Url::parse(source).map_err(|_| "invalid plugin URL")?;
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(20)))
        .max_redirects(0)
        .http_status_as_error(false)
        .user_agent("AI-Monitor-Plugin-Installer/1")
        .build();
    let agent = ureq::Agent::new_with_config(config);
    for _ in 0..=5 {
        if current.scheme() != "https" || current.username() != "" || current.password().is_some() {
            return Err("plugin URL and redirects must use HTTPS".into());
        }
        let mut response = agent
            .get(current.as_str())
            .call()
            .map_err(|e| format!("plugin download: {e}"))?;
        match response.status().as_u16() {
            200 => {
                let bytes = response
                    .body_mut()
                    .with_config()
                    .limit((MAX_PACKAGE_BYTES + 1) as u64)
                    .read_to_vec()
                    .map_err(|e| format!("plugin download: {e}"))?;
                if bytes.len() > MAX_PACKAGE_BYTES {
                    return Err("plugin package too large".into());
                }
                return Ok(bytes);
            }
            301 | 302 | 303 | 307 | 308 => {
                let location = response
                    .headers()
                    .get("location")
                    .and_then(|v| v.to_str().ok())
                    .ok_or("redirect without location")?;
                current = current
                    .join(location)
                    .map_err(|_| "invalid plugin redirect")?;
            }
            status => return Err(format!("plugin download HTTP {status}")),
        }
    }
    Err("too many plugin redirects".into())
}

pub fn inspect(bytes: &[u8]) -> Result<PluginPreview, String> {
    let package = parse_package(bytes)?;
    let manifest = package.manifest;
    let url = manifest.source_url(&manifest.default_settings())?;
    let source_origin = Url::parse(&url)
        .map_err(|_| "invalid plugin source")?
        .origin()
        .ascii_serialization();
    let requires_location = manifest.requires_location();
    Ok(PluginPreview {
        id: manifest.id,
        name: manifest.name,
        version: manifest.version,
        author: manifest.author,
        description: manifest.description,
        attribution: manifest.attribution,
        source_origin,
        sha256: package.sha256,
        signed: false,
        requires_location,
        settings_spec: manifest.settings,
        localizations: manifest.localizations,
    })
}

/// Ortssuche für den Standort eines Displays, frei und ohne Schlüssel. Orte
/// und Postleitzahlen findet das Geocoding von Open-Meteo. Kennt es die
/// Eingabe nicht, etwa eine Adresse mit Straße, folgt eine Anfrage an
/// Nominatim (OpenStreetMap). Liefert höchstens acht Treffer.
pub fn search_places(query: &str, language: &str) -> Result<Vec<Place>, String> {
    let query = query.trim();
    if query.chars().count() < 2 || query.chars().count() > 80 {
        return Ok(Vec::new());
    }
    let language = if language == "de" { "de" } else { "en" };
    let mut url = Url::parse("https://geocoding-api.open-meteo.com/v1/search").unwrap();
    url.query_pairs_mut()
        .append_pair("name", query)
        .append_pair("count", "8")
        .append_pair("format", "json")
        .append_pair("language", language);
    let places = parse_places(&search_request(&url)?);
    if !places.is_empty() {
        return Ok(places);
    }
    // Nominatim verlangt eine erkennbare Kennung und höchstens eine Anfrage
    // pro Sekunde; die Suche läuft nur auf ausdrückliche Eingabe.
    let mut url = Url::parse("https://nominatim.openstreetmap.org/search").unwrap();
    url.query_pairs_mut()
        .append_pair("q", query)
        .append_pair("format", "jsonv2")
        .append_pair("limit", "8")
        .append_pair("addressdetails", "1")
        .append_pair("accept-language", language);
    Ok(parse_addresses(&search_request(&url)?))
}

fn search_request(url: &Url) -> Result<Value, String> {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(12)))
        .max_redirects(0)
        .user_agent("AI-Monitor/1 (https://github.com/tobymarks/esp32-ai-monitor)")
        .http_status_as_error(true)
        .build();
    let agent = ureq::Agent::new_with_config(config);
    let mut response = agent.get(url.as_str()).call().map_err(|e| format!("search: {e}"))?;
    let bytes = response
        .body_mut()
        .with_config()
        .limit(MAX_SOURCE_BYTES as u64)
        .read_to_vec()
        .map_err(|e| format!("search: {e}"))?;
    serde_json::from_slice(&bytes).map_err(|_| "invalid search response".into())
}

/// Treffer von Nominatim. Als Name dient die Gemeinde, damit auf dem Display
/// „Pforzheim“ steht und nicht die Straße; die Adresse steht im Detail.
fn parse_addresses(value: &Value) -> Vec<Place> {
    let Some(results) = value.as_array() else {
        return Vec::new();
    };
    results
        .iter()
        .filter_map(|item| {
            let address = item.get("address");
            let part = |key: &str| {
                address.and_then(|a| a.get(key)).and_then(Value::as_str).unwrap_or("").trim()
            };
            let coordinate = |key: &str| item.get(key)?.as_str()?.parse::<f64>().ok();
            let town = ["city", "town", "village", "municipality", "hamlet", "county"]
                .into_iter()
                .map(part)
                .find(|value| !value.is_empty())
                .or_else(|| item.get("name").and_then(Value::as_str))
                .unwrap_or("");
            let name: String = town.trim().chars().take(80).collect();
            let place = Location {
                name: name.clone(),
                latitude: coordinate("lat")?,
                longitude: coordinate("lon")?,
            };
            if name.is_empty() || !place.is_valid() {
                return None;
            }
            let street = [part("road"), part("house_number")]
                .into_iter()
                .filter(|value| !value.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            let detail = [street.as_str(), part("state"), part("country")]
                .into_iter()
                .filter(|value| !value.is_empty() && *value != name)
                .collect::<Vec<_>>()
                .join(", ");
            Some(Place { name, detail, latitude: place.latitude, longitude: place.longitude })
        })
        .take(8)
        .collect()
}

fn parse_places(value: &Value) -> Vec<Place> {
    let Some(results) = value.get("results").and_then(Value::as_array) else {
        return Vec::new();
    };
    results
        .iter()
        .filter_map(|item| {
            let text = |key: &str| item.get(key).and_then(Value::as_str).unwrap_or("").trim();
            let name: String = text("name").chars().take(80).collect();
            let place = Location {
                name: name.clone(),
                latitude: item.get("latitude")?.as_f64()?,
                longitude: item.get("longitude")?.as_f64()?,
            };
            if name.is_empty() || !place.is_valid() {
                return None;
            }
            let detail = [text("admin1"), text("country")]
                .into_iter()
                .filter(|part| !part.is_empty() && *part != name)
                .collect::<Vec<_>>()
                .join(", ");
            Some(Place { name, detail, latitude: place.latitude, longitude: place.longitude })
        })
        .take(8)
        .collect()
}

pub fn fetch(
    manifest: &Manifest,
    settings: &Map<String, Value>,
    location: Option<&Location>,
) -> Result<Value, String> {
    // Development fixture: a file named <plugin-id>.json replaces the HTTPS
    // response for that plugin only. It keeps hardware switching tests
    // deterministic without changing the installed package or source URL.
    #[cfg(debug_assertions)]
    if let Some(dir) = std::env::var_os("AIMONITOR_PLUGIN_FIXTURE_DIR") {
        let fixture = Path::new(&dir).join(format!("{}.json", manifest.id));
        if fixture.is_file() {
            eprintln!("[plugins] Testdaten aus lokaler Fixture fuer {}", manifest.id);
            let bytes = read_bounded(&fixture, MAX_SOURCE_BYTES)?;
            return serde_json::from_slice(&bytes).map_err(|_| "invalid source JSON".into());
        }
    }
    let url = manifest.request_url(settings, location)?;
    let config = ureq::Agent::config_builder()
        .tls_config(ureq::tls::TlsConfig::builder()
            .root_certs(ureq::tls::RootCerts::PlatformVerifier).build())
        .timeout_global(Some(Duration::from_secs(12)))
        .max_redirects(0)
        .user_agent("AI-Monitor-Plugin/1")
        .http_status_as_error(true)
        .build();
    let agent = ureq::Agent::new_with_config(config);
    let mut response = agent.get(&url).call().map_err(|e| format!("fetch: {e}"))?;
    let bytes = response
        .body_mut()
        .with_config()
        .limit(MAX_SOURCE_BYTES as u64)
        .read_to_vec()
        .map_err(|e| format!("read: {e}"))?;
    serde_json::from_slice(&bytes).map_err(|_| "invalid source JSON".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{Cursor, Write};
    use std::time::{SystemTime, UNIX_EPOCH};
    use zip::write::SimpleFileOptions;

    const FIXTURE: &[u8] = include_bytes!("../../../../tests/fixtures/display-plugin/plugin.json");

    fn package(manifest: &[u8]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        writer
            .start_file("plugin.json", SimpleFileOptions::default())
            .unwrap();
        writer.write_all(manifest).unwrap();
        writer.finish().unwrap().into_inner()
    }

    fn fixture_package() -> Vec<u8> {
        package(FIXTURE)
    }

    #[test]
    fn location_plugin_waits_for_a_place_and_refetches_when_it_changes() {
        let mut manifest: Value = serde_json::from_slice(FIXTURE).unwrap();
        manifest["formatVersion"] = json!(3);
        manifest["requires"] = json!(["location"]);
        manifest["source"]["url"] =
            json!("https://example.org/api?lat={location.latitude}&lon={location.longitude}");
        manifest["bindings"][0]["path"] = json!("location.name");
        let root = test_root();
        let id = "org.aimonitor.fixture";
        let mut store = PluginStore::load(root.clone());
        let info = store.install(&package(manifest.to_string().as_bytes())).unwrap();
        assert!(info.requires_location);
        let assigned = HashSet::from([id.to_string()]);
        let texts = |store: &PluginStore| -> Vec<Value> {
            store.records[id]
                .scene(SceneLayout::Portrait, Language::De, Theme::Dark, store.location(), 1)
                ["nodes"].as_array().unwrap().iter().map(|node| node["text"].clone()).collect()
        };

        assert!(store.due_fetches(&assigned).is_empty());
        assert!(texts(&store).contains(&json!("Standort fehlt - in der App am Display festlegen")));

        let home = Location { name: "Köln".into(), latitude: 50.94, longitude: 6.96 };
        assert!(store.set_location(Some(home.clone())));
        assert!(!store.set_location(Some(home.clone())));
        let due = store.due_fetches(&assigned);
        assert_eq!(due[0].location, Some(home));
        let response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        ))
        .unwrap();

        // Das Display wechselt, bevor die Antwort da ist: Sie gilt nicht mehr.
        let office = Location { name: "Bonn".into(), latitude: 50.73, longitude: 7.1 };
        assert!(store.set_location(Some(office)));
        assert!(!store.apply_fetch(&due[0], Ok(response.clone())));
        let due = store.due_fetches(&assigned);
        assert_eq!(due.len(), 1);
        assert!(store.apply_fetch(&due[0], Ok(response)));
        assert!(texts(&store).contains(&json!("Bonn")));
        // Neue Firmware zeigt Umlaute, alte bekommt die Umschrift.
        assert!(store.set_location(Some(Location { name: "Köln".into(), latitude: 50.94, longitude: 6.96 })));
        let due = store.due_fetches(&assigned);
        assert!(store.apply_fetch(&due[0], Ok(json!({"metric": {"value": 1}}))));
        assert!(texts(&store).contains(&json!("Koeln")));
        let modern = store.records[id].scene(
            SceneLayout::Portrait, Language::De, Theme::Dark, store.location(), 2);
        assert_eq!(modern["nodes"][0]["text"], "Köln");

        assert!(store.set_location(None));
        assert!(store.records[id].data.is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn place_search_results_are_bounded_and_validated() {
        let places = parse_places(&json!({"results": [
            {"name": "Köln", "admin1": "Nordrhein-Westfalen", "country": "Deutschland",
             "latitude": 50.93333, "longitude": 6.95},
            {"name": "Luxemburg", "admin1": "Luxemburg", "country": "Luxemburg",
             "latitude": 49.61, "longitude": 6.13},
            {"name": "Kaputt", "latitude": 200.0, "longitude": 0.0},
            {"name": "", "latitude": 1.0, "longitude": 1.0}
        ]}));
        assert_eq!(places.len(), 2);
        assert_eq!(places[0].detail, "Nordrhein-Westfalen, Deutschland");
        assert_eq!(places[1].detail, "");
        assert!(parse_places(&json!({"generationtime_ms": 0.4})).is_empty());

        let addresses = parse_addresses(&json!([
            {"lat": "48.8926754", "lon": "8.6796884", "name": "Firma",
             "address": {"house_number": "104", "road": "Maximilianstraße", "city": "Pforzheim",
                         "state": "Baden-Württemberg", "country": "Deutschland"}},
            {"lat": "nicht", "lon": "8.0", "address": {"city": "Kaputt"}},
            {"lat": "47.0", "lon": "8.0", "address": {}}
        ]));
        assert_eq!(addresses.len(), 1);
        assert_eq!(addresses[0].name, "Pforzheim");
        assert_eq!(addresses[0].detail, "Maximilianstraße 104, Baden-Württemberg, Deutschland");
        assert_eq!(addresses[0].latitude, 48.8926754);
        assert!(parse_addresses(&json!({"error": "x"})).is_empty());
    }

    fn test_root() -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!(
            "aimonitor-plugin-test-{}-{nonce}",
            std::process::id()
        ))
    }

    #[test]
    fn configured_endpoint_survives_restart_update_and_rejects_old_fetches() {
        let mut manifest: Value = serde_json::from_slice(include_bytes!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        )).unwrap();
        manifest["formatVersion"] = json!(4);
        let template = manifest["source"].as_object_mut().unwrap().remove("url").unwrap();
        manifest["source"]["urlSetting"] = json!("endpoint");
        manifest["settings"].as_array_mut().unwrap().push(json!({
            "key":"endpoint", "label":"Data URL", "kind":"url", "default":template
        }));
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        writer.start_file("plugin.json", zip::write::SimpleFileOptions::default()).unwrap();
        writer.write_all(&serde_json::to_vec(&manifest).unwrap()).unwrap();
        let package = writer.finish().unwrap().into_inner();
        let root = test_root();
        let id = "org.aimonitor.fixture";
        let mut store = PluginStore::load(root.clone());
        store.install(&package).unwrap();
        let assigned = HashSet::from([id.to_owned()]);
        let old = store.due_fetches(&assigned).remove(0);
        let mut settings = store.records[id].settings.clone();
        settings.insert("endpoint".into(), json!("https://new.example:8443/metrics?scale={scale}"));
        assert_eq!(store.configure(id, settings.clone()).unwrap().source_origin, "https://new.example:8443");
        assert!(!store.apply_fetch(&old, Ok(json!({}))));
        assert!(store.records[id].data.is_none());
        let mut invalid = settings.clone();
        invalid.insert("endpoint".into(), json!("http://new.example/"));
        assert!(store.configure(id, invalid).is_err());
        assert_eq!(store.records[id].settings, settings);
        let due = store.due_fetches(&assigned).remove(0);
        assert_eq!(due.manifest.source_url(&due.settings).unwrap(), "https://new.example:8443/metrics?scale=1");
        let mut restored = PluginStore::load(root.clone());
        assert_eq!(restored.records[id].settings, settings);
        restored.install(&package).unwrap();
        assert_eq!(restored.records[id].settings, settings);
        assert_eq!(restored.records[id].info().source_origin, "https://new.example:8443");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn settings_survive_update_and_interrupted_package_replace() {
        let root = test_root();
        let package = fixture_package();
        let id = "org.aimonitor.fixture";
        let mut store = PluginStore::load(root.clone());
        store.install(&package).unwrap();
        let mut settings = store.records[id].settings.clone();
        settings.insert("label".into(), json!("Updated"));
        assert!(store.configure(id, settings).is_ok());
        let mut invalid = store.records[id].settings.clone();
        invalid.insert("scale".into(), json!(999));
        assert!(store.configure(id, invalid).is_err());
        store.install(&package).unwrap();
        assert_eq!(store.records[id].settings["label"], json!("Updated"));

        let target = root.join(format!("{id}.aimplugin"));
        let backup = root.join(format!(".{id}.previous"));
        fs::rename(&target, &backup).unwrap();
        let recovered = PluginStore::load(root.clone());
        assert!(target.exists());
        assert_eq!(recovered.records[id].settings["label"], json!("Updated"));

        let settings_target = root.join(format!("{id}.settings.json"));
        let settings_backup = root.join(format!(".{id}.settings.previous"));
        fs::rename(&settings_target, &settings_backup).unwrap();
        let recovered = PluginStore::load(root.clone());
        assert!(settings_target.exists());
        assert!(!root.join(format!("{id}.settings.aimplugin")).exists());
        assert_eq!(recovered.records[id].settings["label"], json!("Updated"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn assigned_plugin_ignores_old_fetches_and_reports_errors() {
        let root = test_root();
        let package = fixture_package();
        let id = "org.aimonitor.fixture";
        let mut store = PluginStore::load(root.clone());
        store.install(&package).unwrap();
        assert!(store.due_fetches(&HashSet::new()).is_empty());

        let assigned = HashSet::from([id.to_string()]);
        let due = store.due_fetches(&assigned);
        assert_eq!(due.len(), 1);
        assert!(store.due_fetches(&assigned).is_empty());
        let stale = due[0].clone();
        let old_settings = &stale.settings;
        let response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        ))
        .unwrap();

        let mut updated = old_settings.clone();
        updated.insert("label".into(), json!("Updated"));
        store.configure(id, updated.clone()).unwrap();
        assert!(!store.apply_fetch(&stale, Ok(response.clone())));
        assert!(store.records[id].data.is_none());
        let due = store.due_fetches(&assigned);
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].settings, updated);
        assert!(store.apply_fetch(&due[0], Ok(response)));
        let scene = store.records[id].scene(SceneLayout::Portrait, Language::En, Theme::Dark, None, 2);
        assert!(scene["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|node| node["text"] == "Updated"));

        assert!(!store.apply_fetch(&due[0], Err("offline".into())));
        let unavailable = store.records[id].scene(SceneLayout::Portrait, Language::En, Theme::Dark, None, 2);
        assert!(unavailable["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|node| node["text"] == "Data unavailable: offline"));
        let unavailable_de = store.records[id].scene(SceneLayout::Portrait, Language::De, Theme::Dark, None, 2);
        assert!(unavailable_de["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|node| node["text"] == "Daten nicht abrufbar: offline"));

        store.remove(id).unwrap();
        assert!(store.due_fetches(&assigned).is_empty());
        fs::remove_dir_all(root).unwrap();
    }
}
