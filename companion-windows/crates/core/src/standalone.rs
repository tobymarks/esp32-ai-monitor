//! Bounded, credential-free device profiles. Export is explicit and contains
//! only one resolved layout and the settings actually read by its bindings.
use crate::device::Location;
use crate::plugin::{self, Binding, BindingFormat, Manifest, SceneLayout, SceneTemplate};
use crate::protocol::Theme;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};

pub const PROTOCOL: u32 = 1;
pub const MAX_PROFILE_BYTES: usize = 8192;
pub const MAX_RESPONSE_BYTES: usize = 8192;
pub const MAX_BINDINGS: usize = 16;
pub const MAX_JSON_DEPTH: usize = 8;

// A Value preserves the difference between absent and explicit null constants.
// Only bindings reading a host setting/location carry this member.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceBinding {
    pub name: String,
    pub path: String,
    pub format: BindingFormat,
    pub suffix: String,
    pub map: BTreeMap<String, String>,
    pub fallback: String,
    pub scale: Option<f64>,
    pub trim: bool,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "constant_value"
    )]
    pub constant: Option<Value>,
    pub display_map: BTreeMap<String, String>,
    pub display_fallback: String,
}

fn constant_value<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Value>, D::Error> {
    Value::deserialize(d).map(Some)
}

impl DeviceBinding {
    fn spec(&self) -> Binding {
        Binding {
            name: self.name.clone(),
            path: self.path.clone(),
            format: self.format,
            suffix: self.suffix.clone(),
            map: self.map.clone(),
            fallback: self.fallback.clone(),
            scale: self.scale,
            trim: self.trim,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DevicePluginProfile {
    pub protocol: u32,
    pub plugin_id: String,
    pub name: String,
    pub plugin_version: String,
    pub url: String,
    pub interval_seconds: u32,
    pub uses_location: bool,
    pub theme: Theme,
    pub locale: String,
    pub layout: String,
    pub bindings: Vec<DeviceBinding>,
    pub scene: SceneTemplate,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StandaloneExport {
    /// Exact UTF-8 bytes to hash and transfer; do not reserialize the string.
    pub profile: String,
    pub sha256: String,
    pub plugin_id: String,
    pub name: String,
    pub version: String,
    pub origin: String,
    pub sends_location: bool,
    pub refresh_seconds: u32,
}

/// Reject common credential-bearing queries in addition to the host's HTTPS
/// policy. Opaque secrets in paths cannot be inferred: the UI also explains
/// that only public, credential-free endpoints qualify.
fn validate_public_url(text: &str) -> Result<url::Url, String> {
    let url = plugin::validate_source_url(text)?;
    if !matches!(url.host(), Some(url::Host::Domain(host))
        if host.bytes().any(|c| c.is_ascii_alphabetic())
            && host.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-')))
        || url.port_or_known_default() != Some(443)
        || text.contains('{')
        || text.contains('}')
        || url.query_pairs().any(|(key, _)| {
            matches!(
                key.to_ascii_lowercase().as_str(),
                "token"
                    | "access_token"
                    | "api_key"
                    | "apikey"
                    | "key"
                    | "auth"
                    | "authorization"
                    | "password"
                    | "secret"
                    | "signature"
                    | "sig"
            )
        })
    {
        return Err("standalone sources must be resolved, public URLs without credentials".into());
    }
    Ok(url)
}

pub fn export_profile(
    manifest: &Manifest,
    settings: &Map<String, Value>,
    layout: SceneLayout,
    theme: Theme,
    locale: &str,
    location: Option<&Location>,
) -> Result<StandaloneExport, String> {
    manifest.validate()?;
    if !manifest.lists.is_empty() {
        return Err(
            "Standalone does not support lists; this plugin remains available over USB".into(),
        );
    }
    if !manifest.attention_rules.is_empty() {
        return Err(
            "Standalone does not support attention rules; this plugin remains available over USB"
                .into(),
        );
    }
    if manifest.bindings.len() > MAX_BINDINGS {
        return Err("Standalone supports at most 16 bindings".into());
    }
    // The device uses a small, strict URL parser. Store the same canonical
    // scheme/host/port spelling accepted by the desktop URL parser, rather
    // than forwarding equivalent spellings such as HTTPS or an escaped host.
    let url = validate_public_url(&manifest.request_url(settings, location)?)?;
    let origin = url.origin().ascii_serialization();
    let url = url.to_string();
    let place = location
        .filter(|p| manifest.requires_location() && p.is_valid())
        .map(|p| {
            let name = p.display_name();
            json!({"name": if name.is_empty() { Value::Null } else { json!(name) },
            "latitude": p.latitude, "longitude": p.longitude})
        });
    let bindings = manifest
        .bindings
        .iter()
        .map(|b| {
            let constant = if let Some(key) = b.path.strip_prefix("settings.") {
                Some(settings.get(key).cloned().unwrap_or(Value::Null))
            } else if manifest.requires_location() && b.path.starts_with("location.") {
                Some(
                    place
                        .as_ref()
                        .and_then(|p| p.get(&b.path[9..]))
                        .cloned()
                        .unwrap_or(Value::Null),
                )
            } else {
                None
            };
            let display_fallback =
                if matches!(b.format, BindingFormat::Integer | BindingFormat::Decimal1)
                    && b.fallback.parse::<f64>().is_ok_and(f64::is_finite)
                {
                    b.fallback.clone()
                } else {
                    manifest.localized(locale, &b.fallback).to_owned()
                };
            DeviceBinding {
                name: b.name.clone(),
                path: b.path.clone(),
                format: b.format,
                suffix: b.suffix.clone(),
                map: b.map.clone(),
                fallback: b.fallback.clone(),
                scale: b.scale,
                trim: b.trim,
                constant,
                display_fallback,
                display_map: b
                    .map
                    .values()
                    .map(|v| (v.clone(), manifest.localized(locale, v).to_owned()))
                    .collect(),
            }
        })
        .collect();
    let variants = if theme == Theme::Light {
        manifest.light_scenes.as_ref().unwrap_or(&manifest.scenes)
    } else {
        &manifest.scenes
    };
    let mut scene = match layout {
        SceneLayout::Portrait => &variants.portrait,
        SceneLayout::Landscape => &variants.landscape,
        SceneLayout::Square => variants.square.as_ref().unwrap_or(&variants.portrait),
    }
    .clone();
    for node in &mut scene.nodes {
        if let Some(text) = node.get("text").and_then(Value::as_str) {
            node["text"] = json!(manifest.localized(locale, text));
        }
    }
    let profile = DevicePluginProfile {
        protocol: PROTOCOL,
        plugin_id: manifest.id.clone(),
        name: manifest.localized(locale, &manifest.name).to_owned(),
        plugin_version: manifest.version.clone(),
        url,
        interval_seconds: manifest.source.interval_seconds.max(60),
        uses_location: manifest.requires_location(),
        theme,
        locale: locale.to_owned(),
        layout: match layout {
            SceneLayout::Portrait => "portrait",
            SceneLayout::Landscape => "landscape",
            SceneLayout::Square => "square",
        }
        .into(),
        bindings,
        scene,
    };
    profile.validate()?;
    let serialized = serde_json::to_string(&profile).map_err(|e| e.to_string())?;
    Ok(StandaloneExport {
        sha256: format!("{:x}", Sha256::digest(serialized.as_bytes())),
        profile: serialized,
        plugin_id: profile.plugin_id,
        name: profile.name,
        version: profile.plugin_version,
        origin,
        sends_location: profile.uses_location,
        refresh_seconds: profile.interval_seconds,
    })
}

pub fn parse_profile(bytes: &[u8]) -> Result<DevicePluginProfile, String> {
    if bytes.len() > MAX_PROFILE_BYTES {
        return Err("standalone profile exceeds 8192 bytes".into());
    }
    let profile: DevicePluginProfile =
        serde_json::from_slice(bytes).map_err(|e| format!("invalid standalone profile: {e}"))?;
    profile.validate()?;
    Ok(profile)
}

impl DevicePluginProfile {
    pub fn validate(&self) -> Result<(), String> {
        if self.protocol != PROTOCOL
            || !plugin::valid_key(&self.plugin_id, 40)
            || !self.plugin_id.as_bytes()[0].is_ascii_lowercase()
            || self.plugin_id.starts_with("builtin.")
            || self.name.is_empty()
            || !plugin::printable(&self.name, 60)
            || self.plugin_version.len() > 32
            || self.plugin_version.split('.').count() != 3
            || self
                .plugin_version
                .split('.')
                .any(|p| p.parse::<u32>().is_err())
            || !matches!(self.locale.as_str(), "en" | "de")
            || !matches!(self.layout.as_str(), "portrait" | "landscape" | "square")
            || !(60..=86400).contains(&self.interval_seconds)
        {
            return Err("invalid standalone metadata or interval".into());
        }
        validate_public_url(&self.url)?;
        if self.bindings.len() > MAX_BINDINGS {
            return Err("too many standalone bindings".into());
        }
        let mut names = HashSet::new();
        for b in &self.bindings {
            let numeric = matches!(b.format, BindingFormat::Integer | BindingFormat::Decimal1);
            if !plugin::valid_key(&b.name, 30)
                || !names.insert(b.name.as_str())
                || b.path.is_empty()
                || b.path.len() > 100
                || !b.path.is_ascii()
                || b.path.split('.').count() > 8
                || b.path.split('.').any(str::is_empty)
                || !b
                    .path
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
                || !plugin::printable(&b.suffix, 20)
                || !plugin::printable(&b.fallback, 64)
                || !plugin::printable(&b.display_fallback, 64)
                || b.map.len() > 32
                || b.display_map.len() > 32
                || b.map.iter().any(|(k, v)| {
                    !plugin::printable(k, 30)
                        || !plugin::printable(v, 64)
                        || (b.format == BindingFormat::Map && v.len() + b.suffix.len() > 64)
                })
                || b.display_map.iter().any(|(k, v)| {
                    !plugin::printable(k, 64)
                        || !plugin::printable(v, 64)
                        || v.len() + b.suffix.len() > 64
                        || !b.map.values().any(|raw| raw == k)
                })
                || b.scale
                    .is_some_and(|s| !numeric || !s.is_finite() || s == 0.0)
                || (b.trim && numeric)
                || b.constant.as_ref().is_some_and(|v| {
                    !(v.is_null()
                        || v.is_number()
                        || v.is_boolean()
                        || v.as_str().is_some_and(|s| plugin::printable(s, 64)))
                })
            {
                return Err("invalid standalone binding".into());
            }
        }
        if self.scene.background > 0xffffff || self.scene.nodes.len() > plugin::MAX_SCENE_NODES {
            return Err("invalid standalone scene bounds".into());
        }
        let specs: Vec<_> = self.bindings.iter().map(DeviceBinding::spec).collect();
        for node in &self.scene.nodes {
            let object = node.as_object().ok_or("invalid standalone node")?;
            if object.keys().any(|k| {
                ![
                    "type",
                    "x",
                    "y",
                    "w",
                    "h",
                    "color",
                    "font",
                    "text",
                    "align",
                    "trackColor",
                    "value",
                    "valueBinding",
                    "visibleWhen",
                ]
                .contains(&k.as_str())
            }) {
                return Err("unsupported standalone node property".into());
            }
            if let Some(when) = node.get("visibleWhen") {
                if when.as_object().is_none_or(|w| {
                    w.len() != 2
                        || w.keys()
                            .any(|k| !["binding", "equals", "notEquals"].contains(&k.as_str()))
                }) {
                    return Err("invalid standalone visibility condition".into());
                }
            }
            plugin::validate_template_node(node, &names, &specs)?;
        }
        if serde_json::to_vec(self).map_err(|e| e.to_string())?.len() > MAX_PROFILE_BYTES {
            return Err("standalone profile exceeds 8192 bytes".into());
        }
        Ok(())
    }

    /// Host oracle for the device evaluator. The normal desktop renderer is
    /// deliberately kept separate and compared by golden tests.
    pub fn render(&self, response: &[u8]) -> Result<Value, String> {
        self.validate()?;
        if response.len() > MAX_RESPONSE_BYTES {
            return Err("standalone response exceeds 8192 bytes".into());
        }
        let data: Value =
            serde_json::from_slice(response).map_err(|_| "invalid standalone response JSON")?;
        fn depth(v: &Value, level: usize) -> bool {
            match v {
                Value::Array(a) => level < MAX_JSON_DEPTH && a.iter().all(|v| depth(v, level + 1)),
                Value::Object(m) => {
                    level < MAX_JSON_DEPTH && m.values().all(|v| depth(v, level + 1))
                }
                _ => true,
            }
        }
        if !depth(&data, 0) {
            return Err("standalone response nesting exceeds 8".into());
        }
        let mut values = BTreeMap::new();
        let mut conditions = BTreeMap::new();
        for b in &self.bindings {
            let source = b
                .constant
                .as_ref()
                .or_else(|| plugin::lookup(&data, &b.path));
            let resolved = plugin::binding_value(&b.spec(), source);
            let raw = resolved
                .as_ref()
                .map(|v| format!("{v}{}", b.suffix))
                .unwrap_or_else(|| b.fallback.clone());
            let displayed = match (&resolved, b.format) {
                (Some(v), BindingFormat::Map) => {
                    format!("{}{}", b.display_map.get(v).unwrap_or(v), b.suffix)
                }
                (None, _) => b.display_fallback.clone(),
                _ => raw.clone(),
            };
            if !plugin::printable(&displayed, 64) {
                return Err("binding text too long".into());
            }
            values.insert(b.name.as_str(), displayed);
            conditions.insert(b.name.as_str(), raw);
        }
        let mut nodes = Vec::new();
        for node in &self.scene.nodes {
            let mut node = node.clone();
            let object = node.as_object_mut().ok_or("invalid node")?;
            if let Some(when) = object.remove("visibleWhen") {
                let actual = conditions.get(when["binding"].as_str().ok_or("invalid condition")?);
                let visible = if let Some(expected) = when.get("equals").and_then(Value::as_str) {
                    actual.is_some_and(|v| v == expected)
                } else {
                    actual.is_some_and(|v| {
                        Some(v.as_str()) != when.get("notEquals").and_then(Value::as_str)
                    })
                };
                if !visible {
                    continue;
                }
            }
            if let Some(text) = object.get_mut("text") {
                let mut rendered = text.as_str().ok_or("invalid text")?.to_owned();
                for (name, value) in &values {
                    rendered = rendered.replace(&format!("{{{{{name}}}}}"), value);
                }
                if rendered.contains("{{") || !plugin::printable(&rendered, 64) {
                    return Err("invalid rendered text".into());
                }
                *text = json!(rendered);
            }
            if let Some(binding) = object.remove("valueBinding") {
                let value: u8 = values
                    .get(binding.as_str().ok_or("invalid bar binding")?)
                    .ok_or("unknown bar binding")?
                    .parse()
                    .map_err(|_| "bar binding must be a whole percent")?;
                if value > 100 {
                    return Err("bar binding outside 0..100".into());
                }
                object.insert("value".into(), json!(value));
            }
            plugin::validate_wire_node(&node)?;
            nodes.push(node);
        }
        let scene = json!({"background":self.scene.background,"nodes":nodes});
        if serde_json::to_vec(&scene).map_err(|e| e.to_string())?.len() > plugin::MAX_SCENE_BYTES {
            return Err("rendered scene too large".into());
        }
        Ok(scene)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Manifest {
        plugin::parse_manifest(include_bytes!(
            "../../../../tests/fixtures/standalone-status/plugin.json"
        ))
        .unwrap()
    }
    fn exported(m: &Manifest) -> StandaloneExport {
        export_profile(
            m,
            &m.default_settings(),
            SceneLayout::Portrait,
            Theme::Dark,
            "en",
            None,
        )
        .unwrap()
    }
    fn profile() -> DevicePluginProfile {
        parse_profile(exported(&fixture()).profile.as_bytes()).unwrap()
    }

    #[test]
    fn every_format_can_export_by_supported_operations() {
        let original = plugin::parse_manifest(include_bytes!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        ))
        .unwrap();
        for version in 1..=4 {
            let mut m = original.clone();
            m.format_version = version;
            let export = exported(&m);
            assert_eq!(
                export.sha256,
                format!("{:x}", Sha256::digest(export.profile.as_bytes()))
            );
            assert_eq!(export.origin, "https://example.org");
            assert_eq!(
                parse_profile(export.profile.as_bytes()).unwrap().bindings[0].constant,
                Some(json!("Demo"))
            );
        }
    }
    #[test]
    fn unsupported_operations_rejected_explicitly() {
        let mut m = fixture();
        m.attention_rules.push(plugin::AttentionRule {
            id: "alert".into(),
            path: "status.indicator".into(),
            operator: plugin::AttentionOperator::Equals,
            value: json!("none"),
        });
        assert!(export_profile(
            &m,
            &m.default_settings(),
            SceneLayout::Portrait,
            Theme::Dark,
            "en",
            None
        )
        .unwrap_err()
        .contains("attention"));
        m.attention_rules.clear();
        m.lists.push(plugin::ListSpec {
            name: "items".into(),
            path: "items".into(),
            filters: vec![],
            sort_by: None,
            descending: false,
            limit: 1,
        });
        assert!(export_profile(
            &m,
            &m.default_settings(),
            SceneLayout::Portrait,
            Theme::Dark,
            "en",
            None
        )
        .unwrap_err()
        .contains("lists"));
    }
    #[test]
    fn malformed_and_resource_limits_rejected() {
        let p = profile();
        let bytes = serde_json::to_vec(&p).unwrap();
        assert!(parse_profile(&[b' '; 8193]).is_err());
        for mut value in [json!({}), serde_json::from_slice::<Value>(&bytes).unwrap()] {
            value["extra"] = json!(true);
            assert!(parse_profile(&serde_json::to_vec(&value).unwrap()).is_err());
        }
        let mut q = p.clone();
        q.protocol = 2;
        assert!(q.validate().is_err());
        let mut q = p.clone();
        q.interval_seconds = 59;
        assert!(q.validate().is_err());
        let mut q = p.clone();
        q.bindings[0].path = "a.b.c.d.e.f.g.h.i".into();
        assert!(q.validate().is_err());
        let mut q = p.clone();
        q.bindings = vec![q.bindings[0].clone(); 17];
        assert!(q.validate().is_err());
        let mut q = p.clone();
        q.bindings[0].constant = Some(json!({"token":"private"}));
        assert!(q.validate().is_err());
        let mut q = p.clone();
        q.scene.nodes[0]["script"] = json!("alert()");
        assert!(q.validate().is_err());
        let mut q = p.clone();
        q.scene.nodes[0]["w"] = json!(i64::MAX);
        assert!(q.validate().is_err());
        let mut q = p.clone();
        q.scene.nodes[0]["visibleWhen"] = json!({"binding":"state","equals":"x","notEquals":"y"});
        assert!(q.validate().is_err());
        assert!(p.render(&[b' '; 8193]).is_err());
        assert!(p.render(b"{} trailing").is_err());
        assert!(p.render(b"{\"a\":").is_err());
        assert!(p.render(b"[[[[[[[[[0]]]]]]]]]").is_err());
        assert!(p.render(b"[[[[[[[[0]]]]]]]]").is_ok());
        assert!(p
            .render(&serde_json::to_vec(&json!({"page":{"name":"ü".repeat(33)}})).unwrap())
            .is_err());
    }
    #[test]
    fn resolved_location_and_minimum_interval_snapshot() {
        let m = plugin::parse_manifest(include_bytes!(
            "../../../../tests/fixtures/standalone-weather/plugin.json"
        ))
        .unwrap();
        assert!(export_profile(
            &m,
            &m.default_settings(),
            SceneLayout::Square,
            Theme::Light,
            "de",
            None
        )
        .is_err());
        let place = Location {
            name: "Köln".into(),
            latitude: 50.94131,
            longitude: 6.95828,
        };
        let result = export_profile(
            &m,
            &m.default_settings(),
            SceneLayout::Square,
            Theme::Light,
            "de",
            Some(&place),
        )
        .unwrap();
        assert!(result.sends_location);
        assert_eq!(result.refresh_seconds, 60);
        assert!(result.profile.contains("latitude=50.941&longitude=6.958"));
        let p = parse_profile(result.profile.as_bytes()).unwrap();
        assert_eq!(p.bindings[0].constant, Some(json!("Köln")));
        assert_eq!(p.theme, Theme::Light);
        assert_eq!(p.layout, "square");
    }
    #[test]
    fn credentials_redirect_policy_and_unknown_fields_cannot_enter_profile() {
        for url in [
            "http://example.org",
            "https://user:pass@example.org",
            "https://example.org/#secret",
            "https://example.org/?token=x",
            "https://example.org/?API_KEY=x",
            "https://example.org/?%61uth=x",
            "https://example.org/{value}",
            "https://example.org/\\x",
            "https://status_example.org/status.json",
        ] {
            let mut p = profile();
            p.url = url.into();
            assert!(p.validate().is_err(), "{url}");
        }
    }
    #[test]
    fn exported_urls_use_device_compatible_canonical_spelling() {
        for url in [
            "HTTPS://status.example.org/api/v2/status.json",
            "https://%73tatus.example.org/api/v2/status.json",
            "https:////status.example.org:443/api/v2/status.json",
            "https://status.example.org:0443/api/v2/status.json",
        ] {
            let mut m = fixture();
            m.source.url = Some(url.into());
            let result = exported(&m);
            let p = parse_profile(result.profile.as_bytes()).unwrap();
            assert_eq!(p.url, "https://status.example.org/api/v2/status.json");
            assert_eq!(result.origin, "https://status.example.org");
        }
    }
    #[test]
    fn explicit_null_constant_never_falls_back_to_response_field() {
        let mut p = profile();
        p.bindings[0].constant = Some(Value::Null);
        let p = parse_profile(&serde_json::to_vec(&p).unwrap()).unwrap();
        let rendered = p
            .render(br#"{"page":{"name":"source injection"}}"#)
            .unwrap();
        assert_eq!(rendered["nodes"][0]["text"], "Service");
    }
    #[test]
    fn localization_keeps_raw_visibility_and_missing_numeric_fallback() {
        let mut m = fixture();
        m.localizations
            .get_mut("de")
            .unwrap()
            .insert("0".into(), "Null".into());
        let result = export_profile(
            &m,
            &m.default_settings(),
            SceneLayout::Portrait,
            Theme::Dark,
            "de",
            None,
        )
        .unwrap();
        let p = parse_profile(result.profile.as_bytes()).unwrap();
        for response in [
            br#"{}"#.as_slice(),
            include_bytes!("../../../../tests/fixtures/standalone-status/response.json"),
        ] {
            let data = serde_json::from_slice(response).unwrap();
            assert_eq!(
                p.render(response).unwrap(),
                m.scene_at(
                    SceneLayout::Portrait,
                    &data,
                    &m.default_settings(),
                    Theme::Dark,
                    "de",
                    None
                )
                .unwrap()
            );
        }
    }
}
