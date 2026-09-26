//! Versioned, declarative display-plugin contract shared by the Windows host
//! and its tests. Plugins produce bounded firmware scenes, not ESP32 binaries.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashSet};
use url::Url;

pub const FORMAT_VERSION: u32 = 1;
pub const SCENE_PROTOCOL: u32 = 1;
pub const MAX_SCENE_NODES: usize = 24;
pub const MAX_SCENE_BYTES: usize = 1536;
pub const MAX_PACKAGE_MANIFEST_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SceneLayout {
    Portrait,
    Landscape,
    Square,
}

/// A scene frame addresses one already configured plugin window. It has its
/// own schema so legacy usage parsers cannot accidentally interpret it.
pub fn scene_envelope(
    plugin_id: &str,
    view_index: usize,
    scene: Value,
    frame_id: i64,
) -> Result<String, String> {
    if !valid_key(plugin_id, 40) || view_index >= 8 {
        return Err("invalid plugin target".into());
    }
    let payload = json!({
        "schemaVersion": 2,
        "frameId": frame_id,
        "data": [{"pluginId": plugin_id, "viewIndex": view_index, "scene": scene}],
    })
    .to_string();
    if payload.len() > 4095 {
        return Err("plugin frame too large".into());
    }
    Ok(payload)
}

pub fn status_scene(title: &str, message: &str) -> Value {
    let title = if printable(title, 40) {
        title
    } else {
        "Plugin"
    };
    let message = if printable(message, 60) {
        message
    } else {
        "Unavailable"
    };
    json!({
        "background": 1580575,
        "nodes": [
            {"type":"text","x":50,"y":75,"w":900,"h":120,"color":16777215,"font":24,"text":title},
            {"type":"rect","x":50,"y":210,"w":900,"h":3,"color":3717119},
            {"type":"text","x":50,"y":300,"w":900,"h":180,"color":11250603,"font":16,"text":message}
        ]
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    pub format_version: u32,
    pub id: String,
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub view_label: String,
    pub attribution: Option<String>,
    pub min_scene_protocol: u32,
    pub source: HttpSource,
    pub settings: Vec<Setting>,
    pub bindings: Vec<Binding>,
    pub scenes: SceneVariants,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HttpSource {
    pub url: String,
    pub interval_seconds: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Setting {
    pub key: String,
    pub label: String,
    pub kind: SettingKind,
    pub default: Value,
    pub min: Option<f64>,
    pub max: Option<f64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SettingKind {
    Number,
    Text,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
    pub name: String,
    /// Dotted response path (`daily.temperature_2m_max.0`) or `settings.key`.
    pub path: String,
    pub format: BindingFormat,
    #[serde(default)]
    pub suffix: String,
    #[serde(default)]
    pub map: BTreeMap<String, String>,
    pub fallback: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BindingFormat {
    Text,
    Integer,
    Decimal1,
    Map,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SceneVariants {
    pub portrait: SceneTemplate,
    pub landscape: SceneTemplate,
    #[serde(default)]
    pub square: Option<SceneTemplate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SceneTemplate {
    pub background: u32,
    pub nodes: Vec<Value>,
}

pub fn parse_manifest(bytes: &[u8]) -> Result<Manifest, String> {
    if bytes.len() > MAX_PACKAGE_MANIFEST_BYTES {
        return Err("manifest too large".into());
    }
    let manifest: Manifest =
        serde_json::from_slice(bytes).map_err(|e| format!("invalid manifest: {e}"))?;
    manifest.validate()?;
    Ok(manifest)
}

fn valid_key(s: &str, max: usize) -> bool {
    !s.is_empty()
        && s.len() <= max
        && s.bytes().all(|c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'.' | b'-' | b'_')
        })
}

fn printable(s: &str, max: usize) -> bool {
    s.len() <= max && s.bytes().all(|c| (0x20..=0x7e).contains(&c))
}

impl Manifest {
    pub fn validate(&self) -> Result<(), String> {
        if self.format_version != FORMAT_VERSION {
            return Err("unsupported plugin format".into());
        }
        if self.min_scene_protocol == 0 || self.min_scene_protocol > SCENE_PROTOCOL {
            return Err("unsupported scene protocol".into());
        }
        if !valid_key(&self.id, 40) || !self.id.as_bytes()[0].is_ascii_lowercase() {
            return Err("invalid plugin ID".into());
        }
        if !printable(&self.name, 60)
            || self.name.is_empty()
            || !printable(&self.author, 80)
            || self.author.is_empty()
            || !printable(&self.description, 300)
            || !printable(&self.view_label, 24)
            || self.view_label.is_empty()
            || self
                .attribution
                .as_ref()
                .is_some_and(|s| !printable(s, 100))
        {
            return Err("invalid plugin metadata".into());
        }
        if self.version.len() > 32 || semver_parts(&self.version).is_none() {
            return Err("invalid plugin version".into());
        }
        if !(60..=86_400).contains(&self.source.interval_seconds) {
            return Err("invalid refresh interval".into());
        }
        // URL templates may contain only numeric settings. Replace them with
        // zero here, then parse the URL before a network request is possible.
        let mut sample_url = self.source.url.clone();
        let mut setting_names = HashSet::new();
        if self.settings.len() > 16 || self.bindings.len() > 32 {
            return Err("too many settings or bindings".into());
        }
        for setting in &self.settings {
            if !valid_key(&setting.key, 30)
                || !setting_names.insert(setting.key.as_str())
                || !printable(&setting.label, 40)
                || setting.label.is_empty()
            {
                return Err("invalid setting".into());
            }
            validate_setting(setting, &setting.default)?;
            let token = format!("{{{}}}", setting.key);
            if sample_url.contains(&token) {
                if !matches!(setting.kind, SettingKind::Number) {
                    return Err("URL placeholders must be numeric".into());
                }
                sample_url = sample_url.replace(&token, "0");
            }
        }
        if sample_url.contains('{') || sample_url.contains('}') {
            return Err("unknown URL placeholder".into());
        }
        let url = Url::parse(&sample_url).map_err(|_| "invalid source URL")?;
        if url.scheme() != "https"
            || url.host_str().is_none()
            || url.username() != ""
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err("source must be an HTTPS URL without credentials".into());
        }
        let mut names = HashSet::new();
        for binding in &self.bindings {
            if !valid_key(&binding.name, 30)
                || !names.insert(binding.name.as_str())
                || binding.path.len() > 100
                || binding.path.is_empty()
                || binding.path.split('.').any(|part| part.is_empty())
                || !printable(&binding.suffix, 20)
                || !printable(&binding.fallback, 64)
                || binding.map.len() > 100
                || binding
                    .map
                    .iter()
                    .any(|(k, v)| !printable(k, 30) || !printable(v, 64))
            {
                return Err("invalid binding".into());
            }
            if let Some(key) = binding.path.strip_prefix("settings.") {
                if !setting_names.contains(key) {
                    return Err("binding references unknown setting".into());
                }
            }
        }
        for scene in [&self.scenes.portrait, &self.scenes.landscape]
            .into_iter()
            .chain(self.scenes.square.as_ref())
        {
            if scene.background > 0xFFFFFF || scene.nodes.len() > MAX_SCENE_NODES {
                return Err("invalid scene bounds".into());
            }
            for node in &scene.nodes {
                validate_template_node(node, &names, &self.bindings)?;
            }
        }
        Ok(())
    }

    pub fn default_settings(&self) -> Map<String, Value> {
        self.settings
            .iter()
            .map(|s| (s.key.clone(), s.default.clone()))
            .collect()
    }

    pub fn source_url(&self, settings: &Map<String, Value>) -> Result<String, String> {
        let mut url = self.source.url.clone();
        for setting in &self.settings {
            let value = settings.get(&setting.key).unwrap_or(&setting.default);
            validate_setting(setting, value)?;
            let token = format!("{{{}}}", setting.key);
            if url.contains(&token) {
                url = url.replace(&token, &value.to_string());
            }
        }
        if url.contains('{') || url.contains('}') {
            return Err("unresolved URL placeholder".into());
        }
        // The resulting URL must retain the validated origin.
        let parsed = Url::parse(&url).map_err(|_| "invalid source URL")?;
        let template = self.source.url.clone();
        let mut baseline = template;
        for s in &self.settings {
            baseline = baseline.replace(&format!("{{{}}}", s.key), "0");
        }
        let base = Url::parse(&baseline).map_err(|_| "invalid source URL")?;
        if parsed.origin() != base.origin() {
            return Err("source origin changed".into());
        }
        Ok(url)
    }

    pub fn scene(
        &self,
        layout: SceneLayout,
        data: &Value,
        settings: &Map<String, Value>,
    ) -> Result<Value, String> {
        for setting in &self.settings {
            validate_setting(
                setting,
                settings.get(&setting.key).unwrap_or(&setting.default),
            )?;
        }
        let mut values = BTreeMap::new();
        for binding in &self.bindings {
            let source = if binding.path.starts_with("settings.") {
                settings.get(&binding.path[9..])
            } else {
                lookup(data, &binding.path)
            };
            let formatted = format_binding(binding, source);
            if !printable(&formatted, 64) {
                return Err("binding text too long".into());
            }
            values.insert(binding.name.as_str(), formatted);
        }
        let template = match layout {
            SceneLayout::Portrait => &self.scenes.portrait,
            SceneLayout::Landscape => &self.scenes.landscape,
            SceneLayout::Square => self.scenes.square.as_ref().unwrap_or(&self.scenes.portrait),
        };
        let mut nodes = Vec::new();
        for node in &template.nodes {
            let mut node = node.clone();
            let object = node.as_object_mut().ok_or("invalid scene node")?;
            if let Some(when) = object.remove("visibleWhen") {
                let binding = when
                    .get("binding")
                    .and_then(Value::as_str)
                    .ok_or("invalid condition")?;
                let expected = when
                    .get("equals")
                    .and_then(Value::as_str)
                    .ok_or("invalid condition")?;
                if values.get(binding).is_none_or(|value| value != expected) {
                    continue;
                }
            }
            if let Some(text) = object.get_mut("text") {
                let original = text.as_str().ok_or("invalid text")?;
                let mut rendered = original.to_owned();
                for (key, value) in &values {
                    rendered = rendered.replace(&format!("{{{{{key}}}}}"), value);
                }
                if rendered.contains("{{") || !printable(&rendered, 64) {
                    return Err("invalid rendered text".into());
                }
                *text = Value::String(rendered);
            }
            if let Some(binding) = object.remove("valueBinding") {
                let name = binding.as_str().ok_or("invalid bar binding")?;
                let value: u8 = values
                    .get(name)
                    .ok_or("unknown bar binding")?
                    .parse()
                    .map_err(|_| "bar binding must be a whole percent")?;
                if value > 100 {
                    return Err("bar binding outside 0..100".into());
                }
                object.insert("value".into(), json!(value));
            }
            validate_wire_node(&node)?;
            nodes.push(node);
        }
        let scene = json!({"background": template.background, "nodes": nodes});
        if serde_json::to_vec(&scene).map_err(|e| e.to_string())?.len() > MAX_SCENE_BYTES {
            return Err("rendered scene too large".into());
        }
        Ok(scene)
    }
}

fn semver_parts(value: &str) -> Option<[u32; 3]> {
    let parts: Vec<_> = value.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    Some([
        parts[0].parse().ok()?,
        parts[1].parse().ok()?,
        parts[2].parse().ok()?,
    ])
}

fn validate_setting(spec: &Setting, value: &Value) -> Result<(), String> {
    match spec.kind {
        SettingKind::Number => {
            let number = value
                .as_f64()
                .filter(|v| v.is_finite())
                .ok_or("setting must be a number")?;
            if spec.min.is_some_and(|min| number < min) || spec.max.is_some_and(|max| number > max)
            {
                return Err("setting out of range".into());
            }
        }
        SettingKind::Text => {
            let text = value.as_str().ok_or("setting must be text")?;
            if !printable(text, 64) {
                return Err("setting text too long or unsupported".into());
            }
        }
    }
    Ok(())
}

fn lookup<'a>(value: &'a Value, path: &str) -> Option<&'a Value> {
    path.split('.').try_fold(value, |current, part| {
        if let Ok(index) = part.parse::<usize>() {
            current.get(index)
        } else {
            current.get(part)
        }
    })
}

fn format_binding(binding: &Binding, value: Option<&Value>) -> String {
    let Some(value) = value else {
        return binding.fallback.clone();
    };
    let rendered = match binding.format {
        BindingFormat::Text => value
            .as_str()
            .map(str::to_owned)
            .or_else(|| value.as_i64().map(|v| v.to_string())),
        BindingFormat::Integer => value.as_f64().map(|v| format!("{:.0}", v)),
        BindingFormat::Decimal1 => value.as_f64().map(|v| format!("{:.1}", v)),
        BindingFormat::Map => {
            let key = value
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| value.to_string());
            binding.map.get(&key).cloned()
        }
    };
    rendered
        .map(|v| format!("{}{}", v, binding.suffix))
        .unwrap_or_else(|| binding.fallback.clone())
}

fn number(node: &Value, key: &str) -> Result<i64, String> {
    node.get(key)
        .and_then(Value::as_i64)
        .ok_or_else(|| format!("invalid node {key}"))
}

fn validate_template_node(
    node: &Value,
    bindings: &HashSet<&str>,
    binding_specs: &[Binding],
) -> Result<(), String> {
    if let Some(when) = node.get("visibleWhen") {
        let binding = when
            .get("binding")
            .and_then(Value::as_str)
            .ok_or("invalid condition")?;
        let equals = when
            .get("equals")
            .and_then(Value::as_str)
            .ok_or("invalid condition")?;
        if !bindings.contains(binding) || !printable(equals, 64) {
            return Err("invalid condition".into());
        }
    }
    let mut sample = node.clone();
    sample
        .as_object_mut()
        .ok_or("invalid node")?
        .remove("visibleWhen");
    if let Some(name) = sample.get("valueBinding") {
        let name = name.as_str().ok_or("invalid bar binding")?;
        let spec = binding_specs
            .iter()
            .find(|binding| binding.name == name)
            .ok_or("unknown bar binding")?;
        if sample.get("type").and_then(Value::as_str) != Some("bar")
            || sample.get("value").is_some()
            || spec.format != BindingFormat::Integer
            || !spec.suffix.is_empty()
            || !spec.fallback.parse::<u8>().is_ok_and(|n| n <= 100)
        {
            return Err("invalid bar binding".into());
        }
        let object = sample.as_object_mut().ok_or("invalid node")?;
        object.remove("valueBinding");
        object.insert("value".into(), json!(0));
    }
    if let Some(text) = sample.get_mut("text") {
        let mut value = text.as_str().ok_or("invalid text")?.to_string();
        for name in bindings {
            value = value.replace(&format!("{{{{{name}}}}}"), "X");
        }
        *text = Value::String(value);
    }
    validate_wire_node(&sample)
}

fn validate_wire_node(node: &Value) -> Result<(), String> {
    let kind = node
        .get("type")
        .and_then(Value::as_str)
        .ok_or("invalid node type")?;
    let x = number(node, "x")?;
    let y = number(node, "y")?;
    let w = number(node, "w")?;
    let h = number(node, "h")?;
    // Check each component before adding. Coordinates come from untrusted
    // manifests and may contain i64::MAX, which would overflow x + w.
    if !(0..=1000).contains(&x)
        || !(0..=1000).contains(&y)
        || !(1..=1000).contains(&w)
        || !(1..=1000).contains(&h)
        || x > 1000 - w
        || y > 1000 - h
    {
        return Err("node outside display".into());
    }
    let color = number(node, "color")?;
    if !(0..=0xFFFFFF).contains(&color) {
        return Err("invalid node color".into());
    }
    match kind {
        "text" => {
            let text = node
                .get("text")
                .and_then(Value::as_str)
                .ok_or("missing node text")?;
            if !printable(text, 64) {
                return Err("invalid node text".into());
            }
            let font = node.get("font").and_then(Value::as_i64).unwrap_or(14);
            if ![12, 14, 16, 20, 24, 36, 48].contains(&font) {
                return Err("invalid font".into());
            }
            let align = node.get("align").and_then(Value::as_str).unwrap_or("left");
            if !["left", "center", "right"].contains(&align) {
                return Err("invalid alignment".into());
            }
        }
        "bar" => {
            let value = number(node, "value")?;
            let track = number(node, "trackColor")?;
            if !(0..=100).contains(&value) || !(0..=0xFFFFFF).contains(&track) {
                return Err("invalid bar".into());
            }
        }
        "rect" | "circle" => {}
        _ => return Err("invalid node type".into()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> Manifest {
        parse_manifest(include_bytes!("../../../../tests/fixtures/display-plugin/plugin.json"))
            .unwrap()
    }

    #[test]
    fn fixture_renders_all_panel_shapes() {
        let plugin = fixture();
        let settings = plugin.default_settings();
        assert!(plugin
            .source_url(&settings)
            .unwrap()
            .starts_with("https://example.org/api?"));
        let response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        ))
        .unwrap();
        for layout in [
            SceneLayout::Portrait,
            SceneLayout::Landscape,
            SceneLayout::Square,
        ] {
            let scene = plugin.scene(layout, &response, &settings).unwrap();
            let nodes = scene["nodes"].as_array().unwrap();
            assert!(nodes.len() >= 7);
            assert!(nodes
                .iter()
                .any(|n| n["text"].as_str().is_some_and(|s| s.contains("18 pts"))));
            assert!(nodes.iter().any(|n| n["type"] == "bar" && n["value"] == 62));
        }
    }

    #[test]
    fn condition_changes_scene_without_reflashing() {
        let plugin = fixture();
        let settings = plugin.default_settings();
        let mut response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        ))
        .unwrap();
        let active = plugin
            .scene(SceneLayout::Portrait, &response, &settings)
            .unwrap();
        assert!(active["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["type"] == "circle"));
        response["metric"]["state"] = json!(0);
        let idle = plugin
            .scene(SceneLayout::Portrait, &response, &settings)
            .unwrap();
        assert!(!idle["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["type"] == "circle"));
        assert!(idle["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["text"] == "Idle"));
    }

    #[test]
    fn bar_binding_follows_live_data_and_rejects_invalid_templates() {
        let plugin = fixture();
        let settings = plugin.default_settings();
        let mut response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        ))
        .unwrap();
        response["metric"]["level"] = json!(77);
        let scene = plugin
            .scene(SceneLayout::Portrait, &response, &settings)
            .unwrap();
        assert!(scene["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["type"] == "bar" && n["value"] == 77));

        response["metric"]["level"] = json!(150);
        assert!(plugin
            .scene(SceneLayout::Portrait, &response, &settings)
            .is_err());

        let mut invalid = fixture();
        let bar = invalid
            .scenes
            .portrait
            .nodes
            .iter_mut()
            .find(|node| node["type"] == "bar")
            .unwrap();
        bar["valueBinding"] = json!("unknown");
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn square_panel_uses_portrait_for_older_packages() {
        let mut plugin = fixture();
        plugin.scenes.square = None;
        plugin.validate().unwrap();
        let settings = plugin.default_settings();
        let response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        ))
        .unwrap();
        assert_eq!(
            plugin
                .scene(SceneLayout::Square, &response, &settings)
                .unwrap(),
            plugin
                .scene(SceneLayout::Portrait, &response, &settings)
                .unwrap()
        );
    }

    #[test]
    fn malformed_origin_and_scene_are_rejected() {
        let mut plugin = fixture();
        plugin.source.url = "http://localhost/metric".into();
        assert!(plugin.validate().is_err());
        let mut plugin = fixture();
        plugin.min_scene_protocol = 0;
        assert!(plugin.validate().is_err());
        let mut plugin = fixture();
        plugin.scenes.portrait.nodes[0]["w"] = json!(2000);
        assert!(plugin.validate().is_err());
        let mut plugin = fixture();
        plugin.scenes.portrait.nodes[0]["x"] = json!(i64::MAX);
        assert!(plugin.validate().is_err());
        let mut plugin = fixture();
        plugin.scenes.portrait.nodes[0]["w"] = json!(i64::MAX);
        assert!(plugin.validate().is_err());
    }

    #[test]
    fn scene_frame_targets_configured_window() {
        let payload = scene_envelope(
            "org.aimonitor.fixture",
            2,
            status_scene("Fixture", "Loading"),
            17,
        )
        .unwrap();
        let value: Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(value["schemaVersion"], 2);
        assert_eq!(value["data"][0]["viewIndex"], 2);
        assert_eq!(value["data"][0]["pluginId"], "org.aimonitor.fixture");
    }
}
