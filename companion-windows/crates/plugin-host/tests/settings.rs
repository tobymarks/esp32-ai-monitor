//! Exercise the exact helper commands used by the native Mac settings flow.
use serde_json::{json, Value};
use std::fs;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};
use zip::write::SimpleFileOptions;

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let path = std::env::temp_dir().join(format!("aimonitor-host-{}-{nonce}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn package(&self, name: &str, manifest: &Value) -> PathBuf {
        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        zip.start_file("plugin.json", SimpleFileOptions::default()).unwrap();
        zip.write_all(&serde_json::to_vec(manifest).unwrap()).unwrap();
        let path = self.0.join(name);
        fs::write(&path, zip.finish().unwrap().into_inner()).unwrap();
        path
    }
}
impl Drop for Fixture {
    fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); }
}
fn host(command: &str, paths: &[&Path]) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_aimonitor-plugin-host"))
        .arg(command).args(paths).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn mac_helper_migrates_defaults_preserves_overrides_and_renders_sparse_settings() {
    let fixture = Fixture::new();
    let mut manifest: Value = serde_json::from_slice(include_bytes!(
        "../../../../tests/fixtures/display-plugin-url/plugin.json"
    )).unwrap();
    let old = fixture.package("old.aimplugin", &manifest);
    let saved_path = fixture.0.join("settings.json");
    let defaults = host("inspect", &[&old])["settings"].clone();
    // Missing settings on first installation.
    let initial = host("restore-settings", &[&old, &saved_path]);
    assert_eq!(initial["settings"], defaults);
    assert!(initial["savedSettings"].get("endpoint").is_none());

    manifest["version"] = json!("1.1.0");
    manifest["settings"][2]["default"] = json!("https://new.example/v2?scale={scale}");
    let new = fixture.package("new.aimplugin", &manifest);
    for custom in [false, true] {
        let mut saved = defaults.clone();
        saved["label"] = json!("Bonn");
        saved["scale"] = json!(7);
        if custom { saved["endpoint"] = json!("https://custom.example/data?scale={scale}"); }
        // A full legacy file, including the old default.
        fs::write(&saved_path, serde_json::to_vec(&saved).unwrap()).unwrap();
        let restored = host("restore-settings", &[&new, &saved_path, &old]);
        assert_eq!(restored["settings"]["label"], "Bonn");
        assert_eq!(restored["settings"]["scale"], 7);
        assert_eq!(restored["settings"]["endpoint"], if custom {
            saved["endpoint"].clone()
        } else { manifest["settings"][2]["default"].clone() });
        assert_eq!(restored["sourceOrigin"], if custom { "https://custom.example" } else { "https://new.example" });
        assert_eq!(restored["savedSettings"].get("endpoint").is_some(), custom);
        fs::write(&saved_path, serde_json::to_vec(&restored["savedSettings"]).unwrap()).unwrap();
        // Restart, using the sparse file just written.
        let restarted = host("restore-settings", &[&new, &saved_path]);
        assert_eq!(restored, restarted);
        let response = fixture.0.join("response.json");
        fs::write(&response, include_bytes!("../../../../tests/fixtures/display-plugin-url/response.json")).unwrap();
        let rendered = host("render", &[&new, &saved_path, Path::new("all"), &response]);
        for layout in ["portrait", "landscape", "square"] {
            let nodes = rendered["scenes"][layout]["nodes"].as_array().unwrap();
            assert!(nodes.iter().any(|node| node["text"] == "Bonn"));
            assert!(nodes.iter().any(|node| node["text"] == "18 pts"));
        }
        // Saving a default strips it again, while validation remains strict.
        fs::write(&saved_path, serde_json::to_vec(&restored["settings"]).unwrap()).unwrap();
        let validated = host("validate-settings", &[&new, &saved_path]);
        assert_eq!(validated, restored);
    }
    let mut invalid = defaults;
    invalid["endpoint"] = json!("http://invalid.example");
    invalid["label"] = json!("Bonn");
    invalid["scale"] = json!(7);
    fs::write(&saved_path, serde_json::to_vec(&invalid).unwrap()).unwrap();
    assert!(!Command::new(env!("CARGO_BIN_EXE_aimonitor-plugin-host"))
        .arg("validate-settings").args([&new, &saved_path]).output().unwrap().status.success());
    let restored = host("restore-settings", &[&new, &saved_path]);
    assert_eq!(restored["settings"]["label"], "Bonn");
    assert_eq!(restored["settings"]["scale"], 7);
    assert_eq!(restored["settings"]["endpoint"], manifest["settings"][2]["default"]);
}
