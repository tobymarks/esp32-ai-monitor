//! Small bundled process for the native Mac app. No arbitrary plugin code is
//! executed: the package is a validated declarative manifest.

use aimonitor_core::claude_code;
use aimonitor_core::device::Location;
use aimonitor_core::plugin::{scene_for_protocol, Manifest, SceneLayout};
use aimonitor_core::protocol::Theme;
use aimonitor_core::plugin_package::{parse_package, MAX_PACKAGE_BYTES};
use serde_json::{json, Map, Value};
use std::env;
use std::fs;
use std::io::Read;
use std::path::Path;
use std::time::Duration;
use url::Url;

const MAX_SOURCE_BYTES: usize = 64 * 1024;

fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>, String> {
    let file = fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if file.metadata().map_err(|e| e.to_string())?.len() > limit as u64 {
        return Err("file too large".into());
    }
    let mut bytes = Vec::new();
    file.take((limit + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > limit {
        return Err("file too large".into());
    }
    Ok(bytes)
}

fn inspect(manifest: &Manifest, sha256: &str) -> Result<Value, String> {
    let url = manifest.source_url(&manifest.default_settings())?;
    let source_origin = Url::parse(&url)
        .map_err(|_| "invalid plugin source")?
        .origin()
        .ascii_serialization();
    Ok(json!({
        "id": manifest.id,
        "name": manifest.name,
        "version": manifest.version,
        "author": manifest.author,
        "description": manifest.description,
        "viewLabel": manifest.view_label,
        "attribution": manifest.attribution,
        "sourceOrigin": source_origin,
        "intervalSeconds": manifest.source.interval_seconds,
        "sha256": sha256,
        "signed": false,
        "requiresLocation": manifest.requires_location(),
        "settingsSpec": manifest.settings,
        "localizations": manifest.localizations,
        "settings": manifest.default_settings(),
    }))
}

fn fetch(
    manifest: &Manifest,
    settings: &Map<String, Value>,
    location: Option<&Location>,
) -> Result<Value, String> {
    let url = manifest.request_url(settings, location)?;
    let config = ureq::Agent::config_builder()
        .tls_config(ureq::tls::TlsConfig::builder()
            .root_certs(ureq::tls::RootCerts::PlatformVerifier).build())
        .timeout_global(Some(Duration::from_secs(12)))
        .max_redirects(0)
        .http_status_as_error(true)
        .user_agent("AI-Monitor-Plugin/1")
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

fn download_package(source: &str) -> Result<Vec<u8>, String> {
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
            .map_err(|e| format!("download: {e}"))?;
        match response.status().as_u16() {
            200 => {
                let bytes = response
                    .body_mut()
                    .with_config()
                    .limit((MAX_PACKAGE_BYTES + 1) as u64)
                    .read_to_vec()
                    .map_err(|e| format!("download: {e}"))?;
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
                current = current.join(location).map_err(|_| "invalid redirect")?;
            }
            status => return Err(format!("download HTTP {status}")),
        }
    }
    Err("too many plugin redirects".into())
}

struct Options {
    args: Vec<String>,
    theme: Theme,
    locale: String,
    /// `--location={"name":…,"latitude":…,"longitude":…}` of the connected display.
    location: Option<Location>,
    /// `--scene-protocol=N` as reported by the firmware. Defaults to 1, where
    /// umlauts are transliterated to ASCII.
    scene_protocol: u32,
}

fn parse_arguments(raw_args: Vec<String>) -> Result<Options, String> {
    let mut args = Vec::with_capacity(raw_args.len());
    let mut theme = None;
    let mut locale = None;
    let mut location = None;
    let mut scene_protocol = None;
    for (index, arg) in raw_args.into_iter().enumerate() {
        if index != 0 {
            if let Some(value) = arg.strip_prefix("--theme=") {
                if theme.is_some() {
                    return Err("duplicate plugin theme".into());
                }
                theme = Some(Theme::parse(value).ok_or("invalid plugin theme")?);
                continue;
            }
            if let Some(value) = arg.strip_prefix("--locale=") {
                if locale.is_some() {
                    return Err("duplicate plugin locale".into());
                }
                if value.is_empty() || value.len() > 16 || !value.bytes().all(|b| {
                    b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'-' | b'_')
                }) {
                    return Err("invalid plugin locale".into());
                }
                locale = Some(value.to_owned());
                continue;
            }
            if let Some(value) = arg.strip_prefix("--scene-protocol=") {
                if scene_protocol.is_some() {
                    return Err("duplicate scene protocol".into());
                }
                scene_protocol =
                    Some(value.parse::<u32>().map_err(|_| "invalid scene protocol")?);
                continue;
            }
            if let Some(value) = arg.strip_prefix("--location=") {
                if location.is_some() {
                    return Err("duplicate plugin location".into());
                }
                let place: Location =
                    serde_json::from_str(value).map_err(|_| "invalid plugin location")?;
                if !place.is_valid() {
                    return Err("invalid plugin location".into());
                }
                location = Some(place);
                continue;
            }
        }
        args.push(arg);
    }
    Ok(Options {
        args,
        theme: theme.unwrap_or(Theme::Dark),
        locale: locale.unwrap_or_else(|| "en".into()),
        location,
        scene_protocol: scene_protocol.unwrap_or(1),
    })
}

fn run() -> Result<Value, String> {
    let Options { args, theme, locale, location, scene_protocol } = parse_arguments(env::args().collect())?;
    let location = location.as_ref();
    if args.get(1).map(String::as_str) == Some("claude-hooks") {
        return claude_hooks(&args);
    }
    if args.len() < 3 {
        return Err("usage: aimonitor-plugin-host inspect|render PACKAGE [SETTINGS] [portrait|landscape|square|all] [FIXTURE]".into());
    }
    // `places QUERY`: Ortssuche für den Standort eines Displays.
    if args[1] == "places" && args.len() == 3 {
        let places = aimonitor_plugin_store::search_places(&args[2], &locale)?;
        return Ok(json!({"places": places}));
    }
    if args[1] == "download" && args.len() == 4 {
        let bytes = download_package(&args[2])?;
        let package = parse_package(&bytes)?;
        fs::write(&args[3], bytes).map_err(|e| format!("save package: {e}"))?;
        return inspect(&package.manifest, &package.sha256);
    }
    let bytes = read_bounded(Path::new(&args[2]), MAX_PACKAGE_BYTES)?;
    let package = parse_package(&bytes)?;
    match args[1].as_str() {
        "inspect" if args.len() == 3 => inspect(&package.manifest, &package.sha256),
        "validate-settings" if args.len() == 4 => {
            let bytes = read_bounded(Path::new(&args[3]), 16 * 1024)?;
            let settings: Map<String, Value> =
                serde_json::from_slice(&bytes).map_err(|_| "invalid settings JSON")?;
            package.manifest.source_url(&settings)?;
            if settings.len() != package.manifest.settings.len() {
                return Err("settings do not match manifest".into());
            }
            if package
                .manifest
                .settings
                .iter()
                .any(|spec| !settings.contains_key(&spec.key))
            {
                return Err("settings do not match manifest".into());
            }
            let url = package.manifest.source_url(&settings)?;
            let origin = Url::parse(&url).map_err(|_| "invalid source URL")?.origin().ascii_serialization();
            Ok(json!({"valid": true, "sourceOrigin": origin}))
        }
        "render" if args.len() == 5 || args.len() == 6 => {
            let settings = if args[3] == "-" {
                package.manifest.default_settings()
            } else {
                let bytes = read_bounded(Path::new(&args[3]), 16 * 1024)?;
                serde_json::from_slice::<Map<String, Value>>(&bytes)
                    .map_err(|_| "invalid settings JSON")?
            };
            let orientation = args[4].as_str();
            if !matches!(orientation, "portrait" | "landscape" | "square" | "all") {
                return Err("invalid orientation".into());
            }
            let data = if args.len() == 6 {
                let bytes = read_bounded(Path::new(&args[5]), MAX_SOURCE_BYTES)?;
                serde_json::from_slice(&bytes).map_err(|_| "invalid fixture JSON")?
            } else {
                fetch(&package.manifest, &settings, location)?
            };
            if orientation == "all" {
                let portrait = package.manifest.scene_at(
                    SceneLayout::Portrait, &data, &settings, theme, &locale, location,
                )?;
                let landscape = package.manifest.scene_at(
                    SceneLayout::Landscape, &data, &settings, theme, &locale, location,
                )?;
                let square = package.manifest.scene_at(
                    SceneLayout::Square, &data, &settings, theme, &locale, location,
                )?;
                let adapt = |scene| scene_for_protocol(scene, scene_protocol);
                Ok(json!({
                    "scenes": {"portrait": adapt(portrait), "landscape": adapt(landscape), "square": adapt(square)},
                    "attention": package.manifest.attention_states(&data),
                }))
            } else {
                let layout = match orientation {
                    "landscape" => SceneLayout::Landscape,
                    "square" => SceneLayout::Square,
                    _ => SceneLayout::Portrait,
                };
                let scene = package.manifest.scene_at(
                    layout, &data, &settings, theme, &locale, location,
                )?;
                Ok(json!({"scene": scene_for_protocol(scene, scene_protocol)}))
            }
        }
        _ => Err("invalid command or arguments".into()),
    }
}

/// `claude-hooks status|install|remove SETTINGS_PATH PORT` für die Mac-App.
/// Das Token kommt über `AIMONITOR_CLAUDE_TOKEN`, nicht über die Argumente.
fn claude_hooks(args: &[String]) -> Result<Value, String> {
    if args.len() != 5 {
        return Err("usage: aimonitor-plugin-host claude-hooks status|install|remove SETTINGS_PATH PORT".into());
    }
    let path = Path::new(&args[3]);
    let port: u16 = args[4].parse().map_err(|_| "invalid port")?;
    let token = env::var("AIMONITOR_CLAUDE_TOKEN").unwrap_or_default();
    if token.is_empty() && args[2] != "remove" {
        return Err("missing AIMONITOR_CLAUDE_TOKEN".into());
    }
    let status = match args[2].as_str() {
        "status" => claude_code::file_hook_status(path, port, &token)?,
        "install" => claude_code::write_hooks_file(path, true, port, &token)?,
        "remove" => claude_code::write_hooks_file(path, false, port, &token)?,
        _ => return Err("unknown claude-hooks action".into()),
    };
    Ok(json!({"status": status.wire()}))
}

fn main() {
    match run() {
        Ok(value) => println!("{value}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn theme_and_locale_options_work_in_either_order_and_any_position() {
        let expected = vec!["host", "render", "package", "-", "all", "fixture"];
        for first in 1..=expected.len() {
            for second in 1..=expected.len() + 1 {
                let mut input = expected.clone();
                input.insert(first, "--theme=light");
                input.insert(second, "--locale=de");
                let options =
                    parse_arguments(input.into_iter().map(str::to_owned).collect()).unwrap();
                assert_eq!(options.args, expected);
                assert_eq!(options.theme, Theme::Light);
                assert_eq!(options.locale, "de");
                assert!(options.location.is_none());
                assert_eq!(options.scene_protocol, 1);
            }
        }
        let default = parse_arguments(expected.iter().map(|s| s.to_string()).collect()).unwrap();
        assert_eq!(default.theme, Theme::Dark);
        assert_eq!(default.locale, "en");
        let place = parse_arguments(vec![
            "host".into(),
            "--location={\"name\":\"Köln\",\"latitude\":50.94,\"longitude\":6.96}".into(),
        ])
        .unwrap()
        .location
        .unwrap();
        assert_eq!((place.name.as_str(), place.latitude), ("Köln", 50.94));
        for locale in ["pt_br", "pt.br"] {
            let input = vec!["host".to_owned(), format!("--locale={locale}")];
            assert_eq!(parse_arguments(input).unwrap().locale, locale);
        }
        for options in [
            vec!["--theme=light", "--theme=dark"],
            vec!["--locale=de", "--locale=en"],
            vec!["--theme=unknown"],
            vec!["--locale=DE"],
            vec!["--location={\"latitude\":91,\"longitude\":0}"],
            vec!["--location=50,7"],
            vec!["--scene-protocol=two"],
        ] {
            let input = std::iter::once("host").chain(options).map(str::to_owned).collect();
            assert!(parse_arguments(input).is_err());
        }
    }
}
