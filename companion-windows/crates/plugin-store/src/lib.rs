//! Portable store for declarative display plugins. Validation is in the core
//! crate; this module owns persistence, bounded HTTPS fetches, and state.

use aimonitor_core::plugin::{status_scene, Manifest, SceneLayout, Setting};
use aimonitor_core::plugin_package::{parse_package, MAX_PACKAGE_BYTES};
use chrono::{DateTime, Utc};
use serde::Serialize;
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
    pub settings_spec: Vec<Setting>,
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
    pub settings_spec: Vec<Setting>,
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
            settings_spec: self.manifest.settings.clone(),
            settings: self.settings.clone(),
            fetched_at: self.fetched_at,
            last_error: self.last_error.clone(),
        }
    }

    pub fn scene(&self, layout: SceneLayout) -> Value {
        if let Some(error) = &self.last_error {
            return status_scene(
                &self.manifest.view_label,
                &format!("Data unavailable: {error}"),
            );
        }
        let Some(data) = &self.data else {
            return status_scene(&self.manifest.view_label, "Loading data...");
        };
        let stale_after =
            chrono::Duration::seconds(self.manifest.source.interval_seconds as i64 * 3);
        if self
            .fetched_at
            .is_none_or(|time| Utc::now() - time > stale_after)
        {
            return status_scene(&self.manifest.view_label, "Data stale - waiting for update");
        }
        self.manifest
            .scene(layout, data, &self.settings)
            .unwrap_or_else(|_| {
                status_scene(&self.manifest.view_label, "Cannot render plugin data")
            })
    }
}

pub struct PluginStore {
    root: PathBuf,
    pub records: BTreeMap<String, PluginRecord>,
}

impl PluginStore {
    pub fn load(root: PathBuf) -> Self {
        let mut store = Self {
            root,
            records: BTreeMap::new(),
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

    pub fn due_fetches(
        &mut self,
        assigned: &HashSet<String>,
    ) -> Vec<(String, String, Manifest, Map<String, Value>)> {
        let mut due = Vec::new();
        for id in assigned {
            let Some(record) = self.records.get_mut(id) else {
                continue;
            };
            let interval = Duration::from_secs(if record.last_error.is_some() {
                record.manifest.source.interval_seconds.min(60)
            } else {
                record.manifest.source.interval_seconds
            } as u64);
            if record.last_attempt.is_some_and(|t| t.elapsed() < interval) {
                continue;
            }
            record.last_attempt = Some(Instant::now());
            due.push((
                id.clone(),
                record.sha256.clone(),
                record.manifest.clone(),
                record.settings.clone(),
            ));
        }
        due
    }

    pub fn apply_fetch(
        &mut self,
        id: &str,
        sha256: &str,
        settings: &Map<String, Value>,
        result: Result<Value, String>,
    ) {
        let Some(record) = self.records.get_mut(id) else {
            return;
        };
        if record.sha256 != sha256 || &record.settings != settings {
            return;
        }
        match result {
            Ok(value) => {
                record.data = Some(value);
                record.fetched_at = Some(Utc::now());
                record.last_error = None;
            }
            Err(error) => record.last_error = Some(error.chars().take(60).collect()),
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
        settings_spec: manifest.settings,
    })
}

pub fn fetch(manifest: &Manifest, settings: &Map<String, Value>) -> Result<Value, String> {
    let url = manifest.source_url(settings)?;
    let config = ureq::Agent::config_builder()
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

    fn fixture_package() -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        writer
            .start_file("plugin.json", SimpleFileOptions::default())
            .unwrap();
        writer
            .write_all(include_bytes!(
                "../../../../tests/fixtures/display-plugin/plugin.json"
            ))
            .unwrap();
        writer.finish().unwrap().into_inner()
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
        let (_, sha256, _, old_settings) = &due[0];
        let response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        ))
        .unwrap();

        let mut updated = old_settings.clone();
        updated.insert("label".into(), json!("Updated"));
        store.configure(id, updated.clone()).unwrap();
        store.apply_fetch(id, sha256, old_settings, Ok(response.clone()));
        assert!(store.records[id].data.is_none());
        let due = store.due_fetches(&assigned);
        assert_eq!(due.len(), 1);
        store.apply_fetch(id, &due[0].1, &updated, Ok(response));
        let scene = store.records[id].scene(SceneLayout::Portrait);
        assert!(scene["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|node| node["text"] == "Updated"));

        store.apply_fetch(id, &due[0].1, &updated, Err("offline".into()));
        let unavailable = store.records[id].scene(SceneLayout::Portrait);
        assert!(unavailable["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|node| node["text"] == "Data unavailable: offline"));

        store.remove(id).unwrap();
        assert!(store.due_fetches(&assigned).is_empty());
        fs::remove_dir_all(root).unwrap();
    }
}
