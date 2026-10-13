//! Versioned, declarative display-plugin contract shared by the Windows host
//! and its tests. Plugins produce bounded firmware scenes, not ESP32 binaries.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Number, Value};
use crate::device::Location;
use crate::protocol::Theme;
use std::collections::{BTreeMap, HashSet};
use url::Url;

pub const FORMAT_VERSION: u32 = 3;
/// 2 adds the German umlauts and the degree sign to scene text. Firmware
/// reporting 1 gets the same scenes transliterated, see [`scene_for_protocol`].
pub const SCENE_PROTOCOL: u32 = 2;
pub const MAX_SCENE_NODES: usize = 24;
pub const MAX_SCENE_BYTES: usize = 1536;
pub const MAX_PACKAGE_MANIFEST_BYTES: usize = 64 * 1024;
/// Shortest refresh interval: 60 s up to format 2, 20 s from format 3.
pub const MIN_INTERVAL_SECONDS: u32 = 60;
pub const MIN_INTERVAL_SECONDS_V3: u32 = 20;
const MAX_LISTS: usize = 4;
const MAX_LIST_ITEMS: usize = 8;
/// Entries of a source array considered for a list; later ones are ignored.
const MAX_LIST_SOURCE_ITEMS: usize = 500;

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

/// Statustexte für Plugin-Fenster in der Sprache des Geräteprofils. Die
/// Firmware nimmt in Szenen nur druckbares ASCII an, deshalb stehen die
/// deutschen Texte ohne Umlaute.
pub fn status_text(key: &str, language: crate::protocol::Language) -> &'static str {
    use crate::protocol::Language;
    match (language, key) {
        (Language::De, "missing") => "Plugin fehlt",
        (Language::De, "missing.hint") => "Plugin in den Einstellungen installieren",
        (Language::De, "unavailable") => "Daten nicht abrufbar",
        (Language::De, "loading") => "Lade Daten ...",
        (Language::De, "stale") => "Daten veraltet - warte auf Update",
        (Language::De, "render") => "Plugin-Daten nicht darstellbar",
        (Language::De, "location") => "Standort fehlt - in der App am Display festlegen",
        (Language::En, "missing") => "Plugin missing",
        (Language::En, "missing.hint") => "Install this plugin in Settings",
        (Language::En, "unavailable") => "Data unavailable",
        (Language::En, "loading") => "Loading data...",
        (Language::En, "stale") => "Data stale - waiting for update",
        (Language::En, "render") => "Cannot render plugin data",
        (Language::En, "location") => "No location - set one for this display in the app",
        _ => "",
    }
}

pub fn status_scene(title: &str, message: &str) -> Value {
    status_scene_with_theme(title, message, Theme::Dark)
}

pub fn status_scene_with_theme(title: &str, message: &str, theme: Theme) -> Value {
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
    let (background, primary, secondary, divider) = match theme {
        Theme::Dark => (1580575, 16777215, 11250603, 3717119),
        Theme::Light => (0xF5F7FA, 0x17212F, 0x45566A, 0xD4DDE7),
    };
    json!({
        "background": background,
        "nodes": [
            {"type":"text","x":50,"y":75,"w":900,"h":120,"color":primary,"font":24,"text":title},
            {"type":"rect","x":50,"y":210,"w":900,"h":3,"color":divider},
            {"type":"text","x":50,"y":300,"w":900,"h":180,"color":secondary,"font":16,"text":message}
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
    #[serde(default)]
    pub attention_rules: Vec<AttentionRule>,
    /// Host data the plugin needs beyond its own settings (format version 3).
    #[serde(default)]
    pub requires: Vec<Requirement>,
    /// Filtered, sorted selections from arrays in the source (format version 3).
    #[serde(default)]
    pub lists: Vec<ListSpec>,
    pub scenes: SceneVariants,
    /// Optional exact-text translations of author-supplied display strings.
    /// Missing locales and entries use the manifest's original text.
    #[serde(default)]
    pub localizations: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    pub light_scenes: Option<SceneVariants>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Requirement {
    /// The location stored for the connected display. Enables the URL
    /// placeholders `{location.latitude}` and `{location.longitude}` and the
    /// binding paths `location.name`, `location.latitude`, `location.longitude`.
    Location,
}

/// Picks entries from an array in the source JSON. Bindings and attention
/// rules read the result as `lists.<name>.count` (all matches) and
/// `lists.<name>.items.<index>.<field>` (the first `limit` matches).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListSpec {
    pub name: String,
    /// Dotted path to the source array, such as `ac`.
    pub path: String,
    /// Conditions an entry must all meet; paths are relative to the entry.
    #[serde(default, rename = "where")]
    pub filters: Vec<ListFilter>,
    /// Numeric field to order by. Entries without it come last.
    #[serde(default)]
    pub sort_by: Option<String>,
    #[serde(default)]
    pub descending: bool,
    pub limit: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ListFilter {
    pub path: String,
    pub operator: FilterOperator,
    #[serde(default)]
    pub value: Option<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FilterOperator {
    Equals,
    NotEquals,
    AtLeast,
    AtMost,
    Exists,
}

impl ListFilter {
    fn matches(&self, item: &Value) -> bool {
        let actual = lookup(item, &self.path).filter(|value| !value.is_null());
        let expected = self.value.as_ref();
        let compare = |at_least: bool| {
            actual
                .and_then(Value::as_f64)
                .zip(expected.and_then(Value::as_f64))
                .is_some_and(|(a, b)| if at_least { a >= b } else { a <= b })
        };
        match self.operator {
            FilterOperator::Exists => actual.is_some(),
            FilterOperator::Equals => expected.is_some_and(|value| equal_value(actual, value)),
            FilterOperator::NotEquals => expected.is_some_and(|value| !equal_value(actual, value)),
            FilterOperator::AtLeast => compare(true),
            FilterOperator::AtMost => compare(false),
        }
    }
}

const LOCATION_TOKENS: [&str; 2] = ["{location.latitude}", "{location.longitude}"];

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
    /// Factor applied to a number before formatting, such as 0.3048 for
    /// feet to metres (format version 3, `integer` and `decimal1` only).
    #[serde(default)]
    pub scale: Option<f64>,
    /// Strip surrounding whitespace from text; an empty result uses the
    /// fallback (format version 3, `text` and `map` only).
    #[serde(default)]
    pub trim: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AttentionRule {
    pub id: String,
    pub path: String,
    pub operator: AttentionOperator,
    pub value: Value,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AttentionOperator {
    Equals,
    AtLeast,
    AtMost,
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
    // Read the version before strict field validation. Otherwise a future
    // field masks the actionable compatibility error as "unknown field".
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Header {
        format_version: u64,
        #[serde(flatten)]
        fields: Map<String, Value>,
    }
    let header: Header =
        serde_json::from_slice(bytes).map_err(|e| format!("invalid manifest: {e}"))?;
    if header.format_version > u64::from(FORMAT_VERSION) {
        return Err(format!(
            "This plugin requires a newer version of AI Monitor (formatVersion {})",
            header.format_version
        ));
    }
    if header.format_version == 1 && header.fields.contains_key("attentionRules") {
        return Err("attentionRules require formatVersion 2".into());
    }
    if header.format_version < 3 && header.fields.contains_key("requires") {
        return Err("requires needs formatVersion 3".into());
    }
    if header.format_version < 3 && header.fields.contains_key("lists") {
        return Err("lists need formatVersion 3".into());
    }
    // Companions before format 3 accept only ASCII text in a manifest.
    if header.format_version < 3 && !bytes.is_ascii() {
        return Err("umlauts need formatVersion 3".into());
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

/// Characters the device fonts carry beyond printable ASCII.
const DISPLAY_EXTRA: [char; 8] = ['°', 'Ä', 'Ö', 'Ü', 'ß', 'ä', 'ö', 'ü'];

/// Text the display can show. `max` counts UTF-8 bytes like the firmware
/// does, so an umlaut uses two.
fn printable(s: &str, max: usize) -> bool {
    s.len() <= max && s.chars().all(|c| (' '..='~').contains(&c) || DISPLAY_EXTRA.contains(&c))
}

/// ASCII spelling for firmware with scene protocol 1. Never longer in bytes
/// than the UTF-8 original, so validated scenes stay within their limits.
pub fn ascii_text(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let upper = |c: Option<&char>| c.is_some_and(|c| c.is_uppercase());
    let lower = |c: Option<&char>| c.is_some_and(|c| c.is_lowercase());
    let mut out = String::with_capacity(text.len());
    for (i, &c) in chars.iter().enumerate() {
        // In capitals the second letter is a capital too: `FLÜGE` becomes
        // `FLUEGE`, while `Über` becomes `Ueber`.
        let previous = i.checked_sub(1).and_then(|p| chars.get(p));
        let next = chars.get(i + 1);
        let capitals = upper(next) || (upper(previous) && !lower(next));
        match c {
            'Ä' => out.push_str(if capitals { "AE" } else { "Ae" }),
            'Ö' => out.push_str(if capitals { "OE" } else { "Oe" }),
            'Ü' => out.push_str(if capitals { "UE" } else { "Ue" }),
            'ä' => out.push_str("ae"),
            'ö' => out.push_str("oe"),
            'ü' => out.push_str("ue"),
            'ß' => out.push_str(if capitals { "SS" } else { "ss" }),
            '°' => {}
            c if (' '..='~').contains(&c) => out.push(c),
            _ => {}
        }
    }
    out
}

/// Adapt a finished scene to the connected firmware: scene protocol 2 shows
/// umlauts, older firmware accepts only ASCII text.
pub fn scene_for_protocol(mut scene: Value, scene_protocol: u32) -> Value {
    if scene_protocol >= 2 {
        return scene;
    }
    if let Some(nodes) = scene.get_mut("nodes").and_then(Value::as_array_mut) {
        for node in nodes {
            if let Some(text) = node.get_mut("text") {
                if let Some(ascii) = text.as_str().filter(|t| !t.is_ascii()).map(ascii_text) {
                    *text = Value::String(ascii);
                }
            }
        }
    }
    scene
}

fn valid_dotted_path(path: &str) -> bool {
    !path.is_empty() && path.len() <= 100 && path.split('.').all(|part| !part.is_empty())
}

fn equal_value(actual: Option<&Value>, expected: &Value) -> bool {
    let Some(actual) = actual else { return false };
    match (actual, expected) {
        (Value::Number(a), Value::Number(b)) if a.is_f64() || b.is_f64() => {
            // An integer larger than 2^53 can round to a different value as f64.
            let exactly_representable = |number: &Number| {
                number.is_f64() || number.as_f64().is_some_and(|n| n.abs() <= 9_007_199_254_740_992.0)
            };
            exactly_representable(a) && exactly_representable(b) && a.as_f64() == b.as_f64()
        }
        _ => actual == expected,
    }
}

impl Manifest {
    pub fn validate(&self) -> Result<(), String> {
        if self.format_version == 1 && !self.attention_rules.is_empty() {
            return Err("attentionRules require formatVersion 2".into());
        }
        if self.format_version < 3 && !self.requires.is_empty() {
            return Err("requires needs formatVersion 3".into());
        }
        if !(1..=FORMAT_VERSION).contains(&self.format_version) {
            return Err("unsupported plugin format".into());
        }
        if self.requires.len() > 1 {
            return Err("duplicate requirement".into());
        }
        if self.min_scene_protocol == 0 || self.min_scene_protocol > SCENE_PROTOCOL {
            return Err("unsupported scene protocol".into());
        }
        if !valid_key(&self.id, 40) || !self.id.as_bytes()[0].is_ascii_lowercase() {
            return Err("invalid plugin ID".into());
        }
        // Eingebaute Fenster wie `builtin.claude-code` belegen dieses Präfix.
        if self.id.starts_with(crate::claude_code::RESERVED_PREFIX) {
            return Err("reserved plugin ID".into());
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
        let shortest = if self.format_version >= 3 {
            MIN_INTERVAL_SECONDS_V3
        } else {
            MIN_INTERVAL_SECONDS
        };
        if !(shortest..=86_400).contains(&self.source.interval_seconds) {
            return Err("invalid refresh interval".into());
        }
        if self.format_version < 3 && !self.lists.is_empty() {
            return Err("lists need formatVersion 3".into());
        }
        if self.lists.len() > MAX_LISTS {
            return Err("too many lists".into());
        }
        let mut list_names = HashSet::new();
        for list in &self.lists {
            if !valid_key(&list.name, 30)
                || !list_names.insert(list.name.as_str())
                || !valid_dotted_path(&list.path)
                || !(1..=MAX_LIST_ITEMS).contains(&list.limit)
                || list.filters.len() > 8
                || list.sort_by.as_ref().is_some_and(|path| !valid_dotted_path(path))
            {
                return Err("invalid list".into());
            }
            for filter in &list.filters {
                let value_ok = match (filter.operator, &filter.value) {
                    (FilterOperator::Exists, None) => true,
                    (FilterOperator::Exists, Some(_)) | (_, None) => false,
                    (FilterOperator::AtLeast | FilterOperator::AtMost, Some(value)) => {
                        value.as_f64().is_some()
                    }
                    (_, Some(value)) => {
                        value.is_boolean()
                            || value.is_number()
                            || value.as_str().is_some_and(|text| printable(text, 64))
                    }
                };
                if !valid_dotted_path(&filter.path) || !value_ok {
                    return Err("invalid list filter".into());
                }
            }
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
        if self.requires_location() {
            for token in LOCATION_TOKENS {
                sample_url = sample_url.replace(token, "0");
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
        if self.attention_rules.len() > 16 {
            return Err("too many attention rules".into());
        }
        let mut rule_ids = HashSet::new();
        for rule in &self.attention_rules {
            if !valid_key(&rule.id, 30) || !rule_ids.insert(rule.id.as_str())
                || !valid_dotted_path(&rule.path)
                || !self.valid_list_path(&rule.path)
                || !(rule.value.is_boolean() || rule.value.is_string() || rule.value.is_number())
                || matches!(rule.operator, AttentionOperator::AtLeast | AttentionOperator::AtMost)
                    && rule.value.as_f64().is_none()
            {
                return Err("invalid attention rule".into());
            }
        }
        let mut names = HashSet::new();
        for binding in &self.bindings {
            if !valid_key(&binding.name, 30)
                || !names.insert(binding.name.as_str())
                || !valid_dotted_path(&binding.path)
                || !printable(&binding.suffix, 20)
                || !printable(&binding.fallback, 64)
                || binding.map.len() > 100
                || binding
                    .map
                    .iter()
                    .any(|(k, v)| {
                        !printable(k, 30)
                            || !printable(v, 64)
                            || (binding.format == BindingFormat::Map
                                && v.len() + binding.suffix.len() > 64)
                    })
            {
                return Err("invalid binding".into());
            }
            if let Some(key) = binding.path.strip_prefix("settings.") {
                if !setting_names.contains(key) {
                    return Err("binding references unknown setting".into());
                }
            }
            if self.requires_location() {
                if let Some(key) = binding.path.strip_prefix("location.") {
                    if !["name", "latitude", "longitude"].contains(&key) {
                        return Err("binding references unknown location field".into());
                    }
                }
            }
            if !self.valid_list_path(&binding.path) {
                return Err("binding references unknown list entry".into());
            }
            let numeric = matches!(binding.format, BindingFormat::Integer | BindingFormat::Decimal1);
            if self.format_version < 3 && (binding.scale.is_some() || binding.trim) {
                return Err("scale and trim need formatVersion 3".into());
            }
            if binding.scale.is_some_and(|scale| !numeric || !scale.is_finite() || scale == 0.0)
                || (binding.trim && numeric)
            {
                return Err("invalid binding".into());
            }
        }
        for variants in std::iter::once(&self.scenes).chain(self.light_scenes.as_ref()) {
            for scene in [&variants.portrait, &variants.landscape]
                .into_iter()
                .chain(variants.square.as_ref())
            {
                if scene.background > 0xFFFFFF || scene.nodes.len() > MAX_SCENE_NODES {
                    return Err("invalid scene bounds".into());
                }
                for node in &scene.nodes {
                    if self.format_version < 3
                        && node.get("visibleWhen").is_some_and(|when| when.get("notEquals").is_some())
                    {
                        return Err("notEquals needs formatVersion 3".into());
                    }
                    validate_template_node(node, &names, &self.bindings)?;
                }
            }
        }
        if self.localizations.len() > 16
            || self.localizations.iter().any(|(locale, entries)| {
                !valid_key(locale, 16)
                    || entries.len() > 100
                    || entries.iter().any(|(source, translated)| {
                        !printable(source, 300)
                            || source.is_empty()
                            || !printable(translated, 300)
                            || translated.is_empty()
                    })
            })
        {
            return Err("invalid plugin localizations".into());
        }
        for (locale, _) in &self.localizations {
            if !printable(self.localized(locale, &self.name), 60)
                || !printable(self.localized(locale, &self.author), 80)
                || !printable(self.localized(locale, &self.description), 300)
                || !printable(self.localized(locale, &self.view_label), 24)
                || self
                    .attribution
                    .as_ref()
                    .is_some_and(|value| !printable(self.localized(locale, value), 100))
                || self
                    .settings
                    .iter()
                    .any(|setting| !printable(self.localized(locale, &setting.label), 40))
            {
                return Err("localized metadata too long".into());
            }
            for binding in &self.bindings {
                for value in binding.map.values() {
                    let translated = self.localized(locale, value);
                    if !printable(translated, 64)
                        || (binding.format == BindingFormat::Map
                            && translated.len() + binding.suffix.len() > 64)
                    {
                        return Err("localized binding too long".into());
                    }
                }
                if !printable(self.localized(locale, &binding.fallback), 64) {
                    return Err("localized binding too long".into());
                }
            }
            for variants in std::iter::once(&self.scenes).chain(self.light_scenes.as_ref()) {
                for scene in [&variants.portrait, &variants.landscape]
                    .into_iter()
                    .chain(variants.square.as_ref())
                {
                    for node in &scene.nodes {
                        if let Some(source) = node.get("text").and_then(Value::as_str) {
                            let mut translated = node.clone();
                            translated["text"] = json!(self.localized(locale, source));
                            validate_template_node(&translated, &names, &self.bindings)?;
                        }
                    }
                }
            }
        }
        Ok(())
    }

    pub fn localized<'a>(&'a self, locale: &str, source: &'a str) -> &'a str {
        self.localizations
            .get(locale)
            .and_then(|entries| entries.get(source))
            .map(String::as_str)
            .unwrap_or(source)
    }

    pub fn default_settings(&self) -> Map<String, Value> {
        self.settings
            .iter()
            .map(|s| (s.key.clone(), s.default.clone()))
            .collect()
    }

    /// `lists.*` is reserved in plugins that declare lists: a path there must
    /// name a declared list and stay within its limit.
    fn valid_list_path(&self, path: &str) -> bool {
        if self.lists.is_empty() {
            return true;
        }
        let Some(rest) = path.strip_prefix("lists.") else {
            return path != "lists";
        };
        let mut parts = rest.split('.');
        let Some(list) = parts.next().and_then(|name| self.lists.iter().find(|l| l.name == name))
        else {
            return false;
        };
        match (parts.next(), parts.next()) {
            (Some("count"), None) => true,
            (Some("items"), Some(index)) => {
                index.parse::<usize>().is_ok_and(|i| i < list.limit) && parts.next().is_some()
            }
            _ => false,
        }
    }

    /// The declared lists applied to one source response, shaped so that
    /// `lists.<name>.count` and `lists.<name>.items.<index>` resolve.
    fn selected_lists(&self, data: &Value) -> Option<Value> {
        if self.lists.is_empty() {
            return None;
        }
        let mut lists = Map::new();
        for spec in &self.lists {
            let mut items: Vec<&Value> = lookup(data, &spec.path)
                .and_then(Value::as_array)
                .map(|entries| {
                    entries
                        .iter()
                        .take(MAX_LIST_SOURCE_ITEMS)
                        .filter(|item| spec.filters.iter().all(|filter| filter.matches(item)))
                        .collect()
                })
                .unwrap_or_default();
            if let Some(key) = &spec.sort_by {
                let rank = |item: &Value| lookup(item, key).and_then(Value::as_f64);
                // A stable sort keeps the source order among equal entries.
                items.sort_by(|a, b| match (rank(a), rank(b)) {
                    (Some(x), Some(y)) if spec.descending => y.total_cmp(&x),
                    (Some(x), Some(y)) => x.total_cmp(&y),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => std::cmp::Ordering::Equal,
                });
            }
            let count = items.len();
            items.truncate(spec.limit);
            lists.insert(spec.name.clone(), json!({"count": count, "items": items}));
        }
        Some(json!({ "lists": lists }))
    }

    pub fn requires_location(&self) -> bool {
        self.requires.contains(&Requirement::Location)
    }

    /// URL for checking settings and showing the origin. Location placeholders
    /// are replaced with zero; use [`Manifest::request_url`] for a real fetch.
    pub fn source_url(&self, settings: &Map<String, Value>) -> Result<String, String> {
        self.resolved_url(settings, Some((0.0, 0.0)))
    }

    /// URL for the actual request. A plugin that requires a location cannot
    /// be fetched without one; coordinates are sent with three decimals.
    pub fn request_url(
        &self,
        settings: &Map<String, Value>,
        location: Option<&Location>,
    ) -> Result<String, String> {
        let place = if self.requires_location() {
            let place = location.filter(|l| l.is_valid()).ok_or("location required")?;
            Some((place.latitude, place.longitude))
        } else {
            None
        };
        self.resolved_url(settings, place)
    }

    fn resolved_url(
        &self,
        settings: &Map<String, Value>,
        place: Option<(f64, f64)>,
    ) -> Result<String, String> {
        let mut url = self.source.url.clone();
        if self.requires_location() {
            let (latitude, longitude) = place.ok_or("location required")?;
            url = url
                .replace(LOCATION_TOKENS[0], &format!("{latitude:.3}"))
                .replace(LOCATION_TOKENS[1], &format!("{longitude:.3}"));
        }
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
        if self.requires_location() {
            for token in LOCATION_TOKENS {
                baseline = baseline.replace(token, "0");
            }
        }
        let base = Url::parse(&baseline).map_err(|_| "invalid source URL")?;
        if parsed.origin() != base.origin() {
            return Err("source origin changed".into());
        }
        Ok(url)
    }

    /// Declarative conditions evaluated against the source JSON, never the rendered scene.
    /// The host triggers only on false-to-true transitions after a baseline fetch.
    pub fn attention_states(&self, data: &Value) -> BTreeMap<String, bool> {
        let lists = self.selected_lists(data);
        self.attention_rules.iter().map(|rule| {
            let actual = match &lists {
                Some(lists) if rule.path.starts_with("lists.") => lookup(lists, &rule.path),
                _ => lookup(data, &rule.path),
            };
            let active = match rule.operator {
                AttentionOperator::Equals => equal_value(actual, &rule.value),
                AttentionOperator::AtLeast => actual.and_then(Value::as_f64)
                    .zip(rule.value.as_f64()).is_some_and(|(a, b)| a >= b),
                AttentionOperator::AtMost => actual.and_then(Value::as_f64)
                    .zip(rule.value.as_f64()).is_some_and(|(a, b)| a <= b),
            };
            (rule.id.clone(), active)
        }).collect()
    }

    pub fn scene(
        &self,
        layout: SceneLayout,
        data: &Value,
        settings: &Map<String, Value>,
    ) -> Result<Value, String> {
        self.scene_with_theme_and_locale(layout, data, settings, Theme::Dark, "en")
    }

    pub fn scene_localized(
        &self,
        layout: SceneLayout,
        data: &Value,
        settings: &Map<String, Value>,
        locale: &str,
    ) -> Result<Value, String> {
        self.scene_with_theme_and_locale(layout, data, settings, Theme::Dark, locale)
    }

    pub fn scene_with_theme(
        &self,
        layout: SceneLayout,
        data: &Value,
        settings: &Map<String, Value>,
        theme: Theme,
    ) -> Result<Value, String> {
        self.scene_with_theme_and_locale(layout, data, settings, theme, "en")
    }

    pub fn scene_with_theme_and_locale(
        &self,
        layout: SceneLayout,
        data: &Value,
        settings: &Map<String, Value>,
        theme: Theme,
        locale: &str,
    ) -> Result<Value, String> {
        self.scene_at(layout, data, settings, theme, locale, None)
    }

    /// Like [`Manifest::scene_with_theme_and_locale`], with the display's
    /// location for plugins that require it. Without a location those
    /// bindings use their fallback.
    pub fn scene_at(
        &self,
        layout: SceneLayout,
        data: &Value,
        settings: &Map<String, Value>,
        theme: Theme,
        locale: &str,
        location: Option<&Location>,
    ) -> Result<Value, String> {
        let place = location
            .filter(|l| self.requires_location() && l.is_valid())
            .map(|l| {
                let name = l.display_name();
                json!({
                    "name": if name.is_empty() { Value::Null } else { json!(name) },
                    "latitude": l.latitude,
                    "longitude": l.longitude,
                })
            });
        for setting in &self.settings {
            validate_setting(
                setting,
                settings.get(&setting.key).unwrap_or(&setting.default),
            )?;
        }
        let lists = self.selected_lists(data);
        let mut values = BTreeMap::new();
        let mut condition_values = BTreeMap::new();
        for binding in &self.bindings {
            let source = if binding.path.starts_with("settings.") {
                settings.get(&binding.path[9..])
            } else if self.requires_location() && binding.path.starts_with("location.") {
                // Reserved for the host; a source field named `location` is
                // only shadowed in plugins that ask for the display location.
                place.as_ref().and_then(|p| p.get(&binding.path[9..]))
            } else if let (Some(lists), true) = (&lists, binding.path.starts_with("lists.")) {
                lookup(lists, &binding.path)
            } else {
                lookup(data, &binding.path)
            };
            let resolved = binding_value(binding, source);
            let unlocalized = resolved
                .as_ref()
                .map(|value| format!("{}{}", value, binding.suffix))
                .unwrap_or_else(|| binding.fallback.clone());
            let formatted = match (&resolved, binding.format) {
                (Some(value), BindingFormat::Map) => {
                    format!("{}{}", self.localized(locale, value), binding.suffix)
                }
                (None, BindingFormat::Map | BindingFormat::Text) => {
                    self.localized(locale, &binding.fallback).to_owned()
                }
                (None, BindingFormat::Integer | BindingFormat::Decimal1)
                    if !binding.fallback.parse::<f64>().is_ok_and(f64::is_finite) =>
                {
                    self.localized(locale, &binding.fallback).to_owned()
                }
                _ => unlocalized.clone(),
            };
            if !printable(&formatted, 64) {
                return Err("binding text too long".into());
            }
            condition_values.insert(binding.name.as_str(), unlocalized);
            values.insert(binding.name.as_str(), formatted);
        }
        let scenes = if theme == Theme::Light {
            self.light_scenes.as_ref().unwrap_or(&self.scenes)
        } else {
            &self.scenes
        };
        let template = match layout {
            SceneLayout::Portrait => &scenes.portrait,
            SceneLayout::Landscape => &scenes.landscape,
            SceneLayout::Square => scenes.square.as_ref().unwrap_or(&scenes.portrait),
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
                let actual = condition_values.get(binding);
                let text = |key: &str| when.get(key).and_then(Value::as_str);
                let visible = match (text("equals"), text("notEquals")) {
                    (Some(expected), None) => actual.is_some_and(|value| value == expected),
                    (None, Some(unwanted)) => actual.is_some_and(|value| value != unwanted),
                    _ => return Err("invalid condition".into()),
                };
                if !visible {
                    continue;
                }
            }
            if let Some(text) = object.get_mut("text") {
                let original = text.as_str().ok_or("invalid text")?;
                let mut rendered = self.localized(locale, original).to_owned();
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

fn binding_value(binding: &Binding, value: Option<&Value>) -> Option<String> {
    let value = value?;
    let scale = binding.scale.unwrap_or(1.0);
    match binding.format {
        BindingFormat::Text => value
            .as_str()
            .map(|text| if binding.trim { text.trim() } else { text })
            .filter(|text| !(binding.trim && text.is_empty()))
            .map(str::to_owned)
            .or_else(|| value.as_i64().map(|v| v.to_string())),
        BindingFormat::Integer => value.as_f64().map(|v| format!("{:.0}", v * scale)),
        BindingFormat::Decimal1 => value.as_f64().map(|v| format!("{:.1}", v * scale)),
        BindingFormat::Map => {
            let key = value
                .as_str()
                .map(|text| if binding.trim { text.trim() } else { text })
                .map(str::to_owned)
                .unwrap_or_else(|| value.to_string());
            binding.map.get(&key).cloned()
        }
    }
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
        let text = |key: &str| when.get(key).and_then(Value::as_str);
        let expected = match (text("equals"), text("notEquals")) {
            (Some(value), None) | (None, Some(value)) => value,
            _ => return Err("invalid condition".into()),
        };
        if !bindings.contains(binding) || !printable(expected, 64) {
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
        if value.contains("{{") {
            return Err("unknown text binding".into());
        }
        *text = Value::String(value);
    }
    validate_wire_node(&sample)
}

/// Eine fertige Szene so prüfen, wie es die Firmware tut (ohne Byte-Grenze).
#[cfg(test)]
pub(crate) fn validate_scene_for_tests(scene: &Value) -> Result<(), String> {
    let background = scene.get("background").and_then(Value::as_i64).ok_or("missing background")?;
    if !(0..=0xFFFFFF).contains(&background) {
        return Err("invalid background".into());
    }
    let nodes = scene.get("nodes").and_then(Value::as_array).ok_or("missing nodes")?;
    if nodes.len() > MAX_SCENE_NODES {
        return Err("too many nodes".into());
    }
    nodes.iter().try_for_each(validate_wire_node)
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

    #[test]
    fn status_texts_fit_firmware_limits() {
        use crate::protocol::Language;
        for language in [Language::De, Language::En] {
            for key in ["missing", "missing.hint", "unavailable", "loading", "stale", "render"] {
                let text = status_text(key, language);
                assert!(!text.is_empty(), "{key} fehlt");
                // Titel dürfen 40, Meldungen 60 druckbare ASCII-Zeichen haben.
                assert!(printable(text, if key == "missing" { 40 } else { 60 }), "{key}: {text}");
            }
        }
    }

    fn fixture() -> Manifest {
        parse_manifest(include_bytes!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        ))
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
    fn localizations_translate_static_and_mapped_text_with_fallback() {
        let mut plugin = fixture();
        plugin.localizations.insert(
            "de".into(),
            BTreeMap::from([
                ("English label".into(), "Deutscher Text".into()),
                ("Active".into(), "Aktiv".into()),
                ("Level {{level}}%".into(), "Stand {{level}}%".into()),
            ]),
        );
        let response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        ))
        .unwrap();
        let settings = plugin.default_settings();
        // Use a simple scene text to exercise translation before interpolation.
        plugin.scenes.portrait.nodes.push(json!({
            "type":"text", "x":0, "y":0, "w":200, "h":30,
            "color":16777215, "text":"English label"
        }));
        plugin.validate().unwrap();
        let de = plugin
            .scene_localized(SceneLayout::Portrait, &response, &settings, "de")
            .unwrap();
        assert!(de["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["text"] == "Deutscher Text"));
        assert!(de["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["text"] == "Aktiv"));
        assert!(de["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["text"] == "Stand 62%"));
        assert!(de["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["type"] == "circle"));
        let fr = plugin
            .scene_localized(SceneLayout::Portrait, &response, &settings, "fr")
            .unwrap();
        assert!(fr["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["text"] == "English label"));
        plugin.localizations.get_mut("de").unwrap().insert(
            "Level {{level}}%".into(),
            "Stand {{unknown}}%".into(),
        );
        assert!(plugin.validate().is_err());
    }

    #[test]
    fn localized_fallbacks_keep_conditions_independent_of_display_text() {
        let mut plugin = fixture();
        plugin.bindings.push(Binding {
            name: "condition".into(),
            path: "metric.condition".into(),
            format: BindingFormat::Text,
            suffix: String::new(),
            map: BTreeMap::new(),
            fallback: "Unknown".into(),
            scale: None,
            trim: false,
        });
        for expected in ["Unknown", "Clear"] {
            plugin.scenes.portrait.nodes.push(json!({
                "type":"text", "x":0, "y":0, "w":200, "h":30,
                "color":16777215, "text":"{{condition}}",
                "visibleWhen":{"binding":"condition", "equals":expected}
            }));
        }
        plugin.localizations.insert("de".into(), BTreeMap::from([
            ("Unknown".into(), "Unbekannt".into()),
            ("Clear".into(), "Klar".into()),
            ("-- pts".into(), "-- Punkte".into()),
            ("0".into(), "Null".into()),
        ]));
        plugin.validate().unwrap();
        let mut response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        )).unwrap();
        response["metric"].as_object_mut().unwrap().remove("value");
        response["metric"].as_object_mut().unwrap().remove("level");
        let settings = plugin.default_settings();
        let fallback_scene = plugin.scene_localized(
            SceneLayout::Portrait, &response, &settings, "de",
        ).unwrap();
        let fallback_nodes = fallback_scene["nodes"].as_array().unwrap();
        assert!(fallback_nodes.iter().any(|node| node["text"] == "Unbekannt"));
        assert!(fallback_nodes.iter().any(|node| node["text"] == "-- Punkte"));
        assert!(fallback_nodes.iter().any(|node| node["type"] == "bar" && node["value"] == 0));
        assert!(!fallback_nodes.iter().any(|node| node["text"] == "Clear"));

        response["metric"]["condition"] = json!("Clear");
        let source_scene = plugin.scene_localized(
            SceneLayout::Portrait, &response, &settings, "de",
        ).unwrap();
        let source_nodes = source_scene["nodes"].as_array().unwrap();
        assert!(source_nodes.iter().any(|node| node["text"] == "Clear"));
        assert!(!source_nodes.iter().any(|node| node["text"] == "Unbekannt"));

        plugin.bindings.iter_mut().find(|binding| binding.name == "value").unwrap().fallback =
            "NaN".into();
        plugin.localizations.get_mut("de").unwrap().insert(
            "NaN".into(), "Kein Wert".into(),
        );
        let nan_scene = plugin.scene_localized(
            SceneLayout::Portrait, &response, &settings, "de",
        ).unwrap();
        assert!(nan_scene["nodes"].as_array().unwrap().iter().any(
            |node| node["text"] == "Kein Wert"
        ));
    }

    #[test]
    fn translated_map_values_include_suffix_in_length_validation() {
        let mut plugin = fixture();
        plugin.bindings.iter_mut().find(|binding| binding.name == "state").unwrap().suffix =
            " load".into();
        plugin.localizations.insert("de".into(), BTreeMap::from([
            ("Active".into(), "X".repeat(60)),
        ]));
        assert_eq!(plugin.validate(), Err("localized binding too long".into()));
        plugin.localizations.clear();
        plugin.bindings.iter_mut().find(|binding| binding.name == "state").unwrap()
            .map.insert("1".into(), "X".repeat(60));
        assert_eq!(plugin.validate(), Err("invalid binding".into()));
    }

    #[test]
    fn translated_metadata_uses_the_original_field_limits() {
        let mut plugin = fixture();
        plugin.localizations.insert("de".into(), BTreeMap::from([
            (plugin.view_label.clone(), "X".repeat(25)),
        ]));
        assert_eq!(plugin.validate(), Err("localized metadata too long".into()));
        plugin.localizations.get_mut("de").unwrap().insert(
            plugin.view_label.clone(), "Ansicht".into(),
        );
        plugin.localizations.get_mut("de").unwrap().insert(
            plugin.settings[0].label.clone(), "X".repeat(41),
        );
        assert_eq!(plugin.validate(), Err("localized metadata too long".into()));
    }

    #[test]
    fn unknown_placeholder_is_rejected_without_localizations() {
        let mut plugin = fixture();
        assert!(plugin.localizations.is_empty());
        plugin.scenes.portrait.nodes[6]["text"] = json!("Level {{unknown}}%");
        assert!(plugin.validate().is_err());
    }

    #[test]
    fn localized_light_scene_text_is_rendered_and_validated() {
        let mut plugin = fixture();
        let mut light = plugin.scenes.clone();
        light.portrait.nodes[6]["text"] = json!("Light {{level}}%");
        plugin.light_scenes = Some(light);
        plugin.localizations.insert("de".into(), BTreeMap::from([
            ("Light {{level}}%".into(), "Hell {{level}}%".into()),
        ]));
        plugin.validate().unwrap();
        let response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        )).unwrap();
        let scene = plugin.scene_with_theme_and_locale(
            SceneLayout::Portrait, &response, &plugin.default_settings(), Theme::Light, "de",
        ).unwrap();
        assert!(scene["nodes"].as_array().unwrap().iter().any(|n| n["text"] == "Hell 62%"));

        plugin.localizations.get_mut("de").unwrap().insert(
            "Light {{level}}%".into(), "Hell {{unknown}}%".into(),
        );
        assert!(plugin.validate().is_err());
    }

    #[test]
    fn light_scenes_select_each_layout_and_legacy_plugins_fall_back() {
        let mut plugin = fixture();
        let settings = plugin.default_settings();
        let response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        )).unwrap();
        let legacy_light = plugin.scene_with_theme(SceneLayout::Portrait, &response, &settings, Theme::Light).unwrap();
        let legacy_dark = plugin.scene(SceneLayout::Portrait, &response, &settings).unwrap();
        assert_eq!(legacy_light, legacy_dark);

        let mut light = plugin.scenes.clone();
        light.portrait.background = 0xF5F7FA;
        light.landscape.background = 0xF0F4F8;
        light.square.as_mut().unwrap().background = 0xFFFFFF;
        plugin.light_scenes = Some(light);
        plugin.validate().unwrap();
        for (layout, expected) in [
            (SceneLayout::Portrait, 0xF5F7FA),
            (SceneLayout::Landscape, 0xF0F4F8),
            (SceneLayout::Square, 0xFFFFFF),
        ] {
            let scene = plugin.scene_with_theme(layout, &response, &settings, Theme::Light).unwrap();
            assert_eq!(scene["background"], expected);
        }
        assert_eq!(plugin.scene(SceneLayout::Portrait, &response, &settings).unwrap()["background"], legacy_dark["background"]);
        plugin.light_scenes.as_mut().unwrap().portrait.nodes[0]["color"] = json!(0x1_000000);
        assert!(plugin.validate().is_err());
    }

    #[test]
    fn localized_map_fallback_keeps_existing_suffix_behavior() {
        let mut plugin = fixture();
        let state = plugin.bindings.iter_mut().find(|b| b.name == "state").unwrap();
        state.suffix = "!".into();
        plugin.localizations.insert("de".into(), BTreeMap::from([
            ("Unknown".into(), "Unbekannt".into()),
        ]));
        let mut response: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/response.json"
        )).unwrap();
        response["metric"]["state"] = json!(99);
        let scene = plugin.scene_localized(SceneLayout::Portrait, &response, &plugin.default_settings(), "de").unwrap();
        assert!(scene["nodes"].as_array().unwrap().iter().any(|n| n["text"] == "Unbekannt"));
    }

    #[test]
    fn builtin_prefix_is_reserved() {
        let mut plugin = fixture();
        plugin.id = crate::claude_code::VIEW_ID.into();
        assert_eq!(plugin.validate().unwrap_err(), "reserved plugin ID");
    }

    #[test]
    fn status_scene_follows_theme() {
        let dark = status_scene("Plugin", "Loading");
        let light = status_scene_with_theme("Plugin", "Loading", Theme::Light);
        assert_ne!(dark["background"], light["background"]);
        assert_ne!(dark["nodes"][0]["color"], light["nodes"][0]["color"]);
    }

    #[test]
    fn future_format_reports_upgrade_before_unknown_fields() {
        let mut package: Value = serde_json::from_slice(include_bytes!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        )).unwrap();
        package["formatVersion"] = json!(FORMAT_VERSION + 1);
        package["futureFeature"] = json!({"enabled": true});
        let err = parse_manifest(&serde_json::to_vec(&package).unwrap()).unwrap_err();
        assert!(err.contains("newer version of AI Monitor"), "{err}");
        package["formatVersion"] = json!(2);
        let err = parse_manifest(&serde_json::to_vec(&package).unwrap()).unwrap_err();
        assert!(err.contains("unknown field"), "{err}");
    }

    fn location_fixture() -> Value {
        let mut manifest: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        ))
        .unwrap();
        manifest["formatVersion"] = json!(3);
        manifest["requires"] = json!(["location"]);
        manifest["source"]["url"] = json!(
            "https://example.org/api?lat={location.latitude}&lon={location.longitude}&scale={scale}"
        );
        manifest["bindings"][0] = json!({
            "name": "label", "path": "location.name", "format": "text",
            "suffix": "", "map": {}, "fallback": "Here"
        });
        manifest
    }

    #[test]
    fn location_requirement_fills_url_and_bindings() {
        let manifest = parse_manifest(location_fixture().to_string().as_bytes()).unwrap();
        assert!(manifest.requires_location());
        let settings = manifest.default_settings();
        let place = Location { name: "Köln".into(), latitude: 50.93751, longitude: 6.96028 };
        assert_eq!(
            manifest.request_url(&settings, Some(&place)).unwrap(),
            "https://example.org/api?lat=50.938&lon=6.960&scale=1"
        );
        assert_eq!(manifest.request_url(&settings, None).unwrap_err(), "location required");
        let outside = Location { latitude: 120.0, ..place.clone() };
        assert!(manifest.request_url(&settings, Some(&outside)).is_err());
        // The origin shown before installation needs no location.
        assert!(manifest.source_url(&settings).unwrap().starts_with("https://example.org/api?lat=0.000"));

        let data = json!({"location": {"name": "From source"}, "metric": {"value": 1}});
        let text = |location: Option<&Location>| {
            manifest
                .scene_at(SceneLayout::Portrait, &data, &settings, Theme::Dark, "en", location)
                .unwrap()["nodes"][0]["text"]
                .clone()
        };
        assert_eq!(text(Some(&place)), "Köln");
        assert_eq!(text(None), "Here");
        let unnamed = Location { name: String::new(), ..place };
        assert_eq!(text(Some(&unnamed)), "Here");
    }

    #[test]
    fn location_is_gated_by_format_and_requirement() {
        let mut old = location_fixture();
        old["formatVersion"] = json!(2);
        assert_eq!(
            parse_manifest(old.to_string().as_bytes()).unwrap_err(),
            "requires needs formatVersion 3"
        );
        let mut undeclared = location_fixture();
        undeclared.as_object_mut().unwrap().remove("requires");
        assert_eq!(
            parse_manifest(undeclared.to_string().as_bytes()).unwrap_err(),
            "unknown URL placeholder"
        );
        let mut unknown_field = location_fixture();
        unknown_field["bindings"][0]["path"] = json!("location.street");
        assert!(parse_manifest(unknown_field.to_string().as_bytes()).is_err());
        let mut unknown = location_fixture();
        unknown["requires"] = json!(["camera"]);
        assert!(parse_manifest(unknown.to_string().as_bytes()).is_err());

        // Without the requirement a source field named `location` stays readable.
        let mut plain: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        ))
        .unwrap();
        plain["bindings"][0]["path"] = json!("location.name");
        let manifest = parse_manifest(plain.to_string().as_bytes()).unwrap();
        let scene = manifest
            .scene(SceneLayout::Portrait, &json!({"location": {"name": "From source"}}),
                   &manifest.default_settings())
            .unwrap();
        assert_eq!(scene["nodes"][0]["text"], "From source");
    }

    fn list_fixture() -> Value {
        let mut manifest: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        ))
        .unwrap();
        manifest["formatVersion"] = json!(3);
        manifest["source"]["intervalSeconds"] = json!(20);
        manifest["lists"] = json!([{
            "name": "flights", "path": "ac", "limit": 2, "sortBy": "dst",
            "where": [
                {"path": "alt_baro", "operator": "notEquals", "value": "ground"},
                {"path": "flight", "operator": "exists"}
            ]
        }]);
        manifest["bindings"] = json!([
            {"name": "label", "path": "lists.flights.items.0.flight", "format": "text",
             "trim": true, "fallback": "No flight"},
            {"name": "value", "path": "lists.flights.items.0.alt_baro", "format": "integer",
             "scale": 0.3048, "suffix": " m", "fallback": "-"},
            {"name": "level", "path": "lists.flights.count", "format": "integer", "fallback": "0"},
            {"name": "state", "path": "lists.flights.items.1.flight", "format": "text",
             "trim": true, "fallback": ""}
        ]);
        manifest["attentionRules"] = json!([
            {"id": "overhead", "path": "lists.flights.count", "operator": "atLeast", "value": 1}
        ]);
        for layout in ["portrait", "landscape", "square"] {
            manifest["scenes"][layout]["nodes"][2]["visibleWhen"] =
                json!({"binding": "state", "notEquals": ""});
        }
        manifest
    }

    fn texts(scene: &Value) -> Vec<String> {
        scene["nodes"].as_array().unwrap().iter()
            .filter_map(|node| node["text"].as_str().map(str::to_owned))
            .collect()
    }

    #[test]
    fn lists_filter_sort_and_limit_source_arrays() {
        let manifest = parse_manifest(list_fixture().to_string().as_bytes()).unwrap();
        let settings = manifest.default_settings();
        // Unsortiert, mit Bodenverkehr, aufgefüllten Callsigns und Lücken, wie von adsb.lol.
        let data = json!({"ac": [
            {"flight": "DLH4WF  ", "alt_baro": 11425, "dst": 13.3},
            {"flight": "DLH695  ", "alt_baro": "ground", "dst": 2.3},
            {"alt_baro": 26275, "dst": 0.8},
            {"flight": "SWR2CY  ", "alt_baro": 475, "dst": 1.9},
            {"flight": "NODIST  ", "alt_baro": 3000},
            {"flight": "UAL932  ", "alt_baro": 975, "dst": 2.2}
        ]});
        let scene = manifest.scene(SceneLayout::Portrait, &data, &settings).unwrap();
        let shown = texts(&scene);
        assert_eq!(shown[0], "SWR2CY");
        assert!(shown.contains(&"145 m".to_string()), "{shown:?}");
        // Vier Treffer insgesamt, auch wenn nur zwei Einträge bindbar sind.
        assert!(shown.contains(&"Level 4%".to_string()), "{shown:?}");
        assert_eq!(scene["nodes"].as_array().unwrap().len(), 8);
        assert_eq!(manifest.attention_states(&data)["overhead"], true);

        // Ein Treffer: der zweite Eintrag fehlt, sein Knoten verschwindet.
        let one = json!({"ac": [{"flight": "SWR2CY  ", "alt_baro": 475, "dst": 1.9}]});
        let scene = manifest.scene(SceneLayout::Portrait, &one, &settings).unwrap();
        assert_eq!(scene["nodes"].as_array().unwrap().len(), 7);

        // Leerer Himmel, fehlendes Feld oder kein Array: Ersatztexte, keine Regel.
        for empty in [json!({"ac": []}), json!({}), json!({"ac": "none"})] {
            let scene = manifest.scene(SceneLayout::Portrait, &empty, &settings).unwrap();
            assert_eq!(texts(&scene)[0], "No flight");
            assert_eq!(manifest.attention_states(&empty)["overhead"], false);
        }

        let mut descending = list_fixture();
        descending["lists"][0]["descending"] = json!(true);
        let manifest = parse_manifest(descending.to_string().as_bytes()).unwrap();
        let scene = manifest.scene(SceneLayout::Portrait, &data, &settings).unwrap();
        assert_eq!(texts(&scene)[0], "DLH4WF");
    }

    #[test]
    fn list_features_are_gated_and_validated() {
        let rejected = |edit: &dyn Fn(&mut Value)| {
            let mut manifest = list_fixture();
            edit(&mut manifest);
            parse_manifest(manifest.to_string().as_bytes()).unwrap_err()
        };
        assert_eq!(rejected(&|m| m["formatVersion"] = json!(2)), "lists need formatVersion 3");
        assert_eq!(rejected(&|m| m["source"]["intervalSeconds"] = json!(19)), "invalid refresh interval");
        assert_eq!(rejected(&|m| m["lists"][0]["limit"] = json!(9)), "invalid list");
        assert_eq!(rejected(&|m| m["lists"][0]["where"][1]["value"] = json!(1)), "invalid list filter");
        assert_eq!(rejected(&|m| m["lists"][0]["where"][0]["value"] = Value::Null), "invalid list filter");
        // Index außerhalb des Limits, unbekannte Liste, Liste ohne Feld.
        for path in ["lists.flights.items.2.flight", "lists.other.count", "lists.flights.items.0", "lists.flights"] {
            assert_eq!(
                rejected(&|m| m["bindings"][0]["path"] = json!(path)),
                "binding references unknown list entry"
            );
        }
        assert_eq!(rejected(&|m| m["attentionRules"][0]["path"] = json!("lists.nope.count")), "invalid attention rule");
        assert_eq!(rejected(&|m| m["bindings"][0]["scale"] = json!(2)), "invalid binding");
        assert_eq!(rejected(&|m| m["bindings"][1]["trim"] = json!(true)), "invalid binding");
        assert_eq!(rejected(&|m| m["bindings"][1]["scale"] = json!(0)), "invalid binding");

        // Format 2 kennt weder das kurze Intervall noch die neuen Felder.
        let old = |edit: &dyn Fn(&mut Value)| {
            let mut manifest: Value = serde_json::from_str(include_str!(
                "../../../../tests/fixtures/display-plugin/plugin.json"
            ))
            .unwrap();
            manifest["formatVersion"] = json!(2);
            edit(&mut manifest);
            parse_manifest(manifest.to_string().as_bytes()).unwrap_err()
        };
        assert_eq!(old(&|m| m["source"]["intervalSeconds"] = json!(20)), "invalid refresh interval");
        assert_eq!(old(&|m| m["bindings"][0]["trim"] = json!(true)), "scale and trim need formatVersion 3");
        assert_eq!(
            old(&|m| m["scenes"]["portrait"]["nodes"][2]["visibleWhen"] = json!({"binding": "state", "notEquals": "x"})),
            "notEquals needs formatVersion 3"
        );
        assert_eq!(
            rejected(&|m| m["scenes"]["portrait"]["nodes"][2]["visibleWhen"] =
                json!({"binding": "state", "equals": "a", "notEquals": "b"})),
            "invalid condition"
        );
    }

    #[test]
    fn umlauts_reach_new_firmware_and_are_transliterated_for_old() {
        let mut manifest = location_fixture();
        manifest["viewLabel"] = json!("Flüge");
        manifest["scenes"]["portrait"]["nodes"][6]["text"] = json!("Höhe {{level}} m, 12 °C, groß");
        manifest["localizations"] = json!({"de": {"Flüge": "Flüge"}});
        let parsed = parse_manifest(manifest.to_string().as_bytes()).unwrap();
        let place = Location { name: "Zürich".into(), latitude: 47.37, longitude: 8.54 };
        let scene = parsed
            .scene_at(SceneLayout::Portrait, &json!({}), &parsed.default_settings(),
                      Theme::Dark, "de", Some(&place))
            .unwrap();
        assert_eq!(texts(&scene)[0], "Zürich");
        assert!(texts(&scene).contains(&"Höhe 0 m, 12 °C, groß".to_string()));
        let old = scene_for_protocol(scene.clone(), 1);
        assert_eq!(texts(&old)[0], "Zuerich");
        assert!(texts(&old).contains(&"Hoehe 0 m, 12 C, gross".to_string()));
        validate_scene_for_tests(&old).unwrap();
        assert_eq!(scene_for_protocol(scene.clone(), 2), scene);
        // Die Umschrift ist in Bytes nie länger als das Original.
        assert_eq!(ascii_text("FLÜGE Über STRAßE Öl Ä"), "FLUEGE Ueber STRASSE Oel Ae");
        for text in ["ÄÖÜäöüß°", "Größe", "Fuß"] {
            assert!(ascii_text(text).len() <= text.len());
            assert!(ascii_text(text).is_ascii());
        }

        // 64 zählt Bytes wie in der Firmware: 32 Umlaute passen, 33 nicht.
        let mut long = location_fixture();
        long["scenes"]["portrait"]["nodes"][6]["text"] = json!("ü".repeat(32));
        assert!(parse_manifest(long.to_string().as_bytes()).is_ok());
        long["scenes"]["portrait"]["nodes"][6]["text"] = json!("ü".repeat(33));
        assert!(parse_manifest(long.to_string().as_bytes()).is_err());

        // Andere Zeichen kennt die Schrift nicht, und ältere Formate bleiben ASCII.
        let mut accent = location_fixture();
        accent["viewLabel"] = json!("Café");
        assert!(parse_manifest(accent.to_string().as_bytes()).is_err());
        let mut old_format: Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        ))
        .unwrap();
        old_format["viewLabel"] = json!("Flüge");
        assert_eq!(
            parse_manifest(serde_json::to_string(&old_format).unwrap().as_bytes()).unwrap_err(),
            "umlauts need formatVersion 3"
        );
    }

    #[test]
    fn attention_rules_parse_only_in_v2() {
        let mut package: Value = serde_json::from_slice(include_bytes!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        )).unwrap();
        package["attentionRules"] = json!([{
            "id": "rain", "path": "forecast.rain", "operator": "equals", "value": true
        }]);
        assert!(parse_manifest(&serde_json::to_vec(&package).unwrap()).is_err());
        package["formatVersion"] = json!(2);
        assert!(parse_manifest(&serde_json::to_vec(&package).unwrap()).is_ok());
    }

    #[test]
    fn format_one_rejects_attention_field_even_when_empty_or_null() {
        let mut package: Value = serde_json::from_slice(include_bytes!(
            "../../../../tests/fixtures/display-plugin/plugin.json"
        )).unwrap();
        for value in [json!([]), Value::Null] {
            package["attentionRules"] = value;
            let error = parse_manifest(&serde_json::to_vec(&package).unwrap()).unwrap_err();
            assert_eq!(error, "attentionRules require formatVersion 2");
        }
        package["formatVersion"] = json!(2);
        package["attentionRules"] = json!([]);
        assert!(parse_manifest(&serde_json::to_vec(&package).unwrap()).is_ok());
    }

    #[test]
    fn attention_rules_use_source_values() {
        let mut plugin = fixture();
        plugin.format_version = 2;
        plugin.attention_rules = vec![
            AttentionRule { id: "rain".into(), path: "weather.condition".into(),
                operator: AttentionOperator::Equals, value: json!("rain") },
            AttentionRule { id: "warning".into(), path: "weather.severity".into(),
                operator: AttentionOperator::AtLeast, value: json!(2) },
        ];
        plugin.validate().unwrap();
        let clear = json!({"weather": {"condition": "clear", "severity": 0}});
        let storm = json!({"weather": {"condition": "rain", "severity": 3}});
        assert!(!plugin.attention_states(&clear)["rain"]);
        assert!(!plugin.attention_states(&clear)["warning"]);
        assert!(plugin.attention_states(&storm)["rain"]);
        assert!(plugin.attention_states(&storm)["warning"]);
    }

    #[test]
    fn attention_equals_accepts_decimal_values_and_binding_paths() {
        let mut plugin = fixture();
        plugin.format_version = 2;
        plugin.attention_rules = vec![AttentionRule {
            id: "dry".into(), path: "weather.rain-rate".into(),
            operator: AttentionOperator::Equals, value: json!(0),
        }];
        plugin.validate().unwrap();
        assert!(plugin.attention_states(&json!({"weather": {"rain-rate": 0.0}}))["dry"]);
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
