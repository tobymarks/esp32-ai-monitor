//! Schema- und Regeltests gegen die Fixture-Dateien.
//!
//! - `fixtures/codexbar/synthetic/*.json`: snake_case wie Win-CodexBar, immer vorhanden
//! - `fixtures/codexbar/<provider>.json`: echte Aufnahmen von Windows, sobald vorhanden
//! - `companion/Fixtures/codexbar/*.json`: camelCase der Upstream-CLI (Mac-App)
//!
//! Bricht eine Datei den Parser, ändert sich also das CLI-Format, fällt der
//! Test hier auf, bevor die App auf dem Display etwas Falsches zeigt.

use aimonitor_core::codexbar::{evaluate, parse_output};
use aimonitor_core::{build_rows, PercentMode, Provider, Status};
use chrono::{DateTime, TimeZone, Utc};
use std::path::{Path, PathBuf};
use std::time::Duration;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..").canonicalize().unwrap()
}

fn synthetic_dir() -> PathBuf {
    repo_root().join("companion-windows/fixtures/codexbar/synthetic")
}

/// Fest verdrahtetes "jetzt" passend zu den festen Stempeln in make_synthetic.py.
fn synthetic_now() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 9, 11, 8, 5, 0).unwrap()
}

fn provider_of(file: &Path) -> Provider {
    let stem = file.file_stem().unwrap().to_string_lossy();
    Provider::normalized(stem.split('-').next().unwrap())
}

fn json_files(dir: &Path) -> Vec<PathBuf> {
    let Ok(rd) = std::fs::read_dir(dir) else { return vec![] };
    let mut files: Vec<PathBuf> = rd
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().map(|e| e == "json").unwrap_or(false))
        .collect();
    files.sort();
    files
}

#[test]
fn every_synthetic_fixture_parses() {
    let files = json_files(&synthetic_dir());
    assert!(files.len() >= 10, "synthetische Fixtures fehlen, make_synthetic.py ausführen");
    for file in files {
        let data = std::fs::read(&file).unwrap();
        let result = parse_output(&data).unwrap_or_else(|e| panic!("{}: {:?}", file.display(), e));
        let provider = provider_of(&file);
        let eval = evaluate(result, provider, synthetic_now(), Duration::from_secs(900));
        let name = file.file_stem().unwrap().to_string_lossy().into_owned();
        match name.as_str() {
            "cursor-error" => assert!(matches!(eval.status, Status::ProviderUnavailable { .. }), "{name}"),
            "claude-stale" => assert!(matches!(eval.status, Status::Stale { .. }), "{name}"),
            _ => assert_eq!(eval.status, Status::Ok, "{name}"),
        }
    }
}

#[test]
fn synthetic_rows_match_mac_app_rules() {
    let load = |name: &str| {
        let data = std::fs::read(synthetic_dir().join(format!("{name}.json"))).unwrap();
        let eval = evaluate(parse_output(&data).unwrap(), provider_of(Path::new(name)), synthetic_now(), Duration::from_secs(900));
        build_rows(&eval.entry.expect(name), PercentMode::Used)
    };

    let claude = load("claude");
    assert_eq!(claude.iter().map(|r| r.title.as_str()).collect::<Vec<_>>(), ["Session", "Weekly", "Fable weekly"]);
    assert_eq!(claude[0].used_percent, 37);
    assert!(claude[0].resets_at.is_some());

    let antigravity = load("antigravity");
    assert_eq!(antigravity.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), ["claude", "gemini-pro", "gemini-flash"]);

    let copilot = load("copilot-chat-only");
    assert_eq!(copilot.len(), 1);
    assert_eq!(copilot[0].title, "Chat");
    assert_eq!(copilot[0].window_minutes, 43200);

    let cursor = load("cursor");
    assert_eq!(cursor.len(), 3, "Grok-Bot-Zusatzfenster passt nicht mehr in drei Zeilen");
    assert_eq!(cursor[2].title, "API");

    let legacy = load("cursor-legacy");
    assert_eq!(legacy.len(), 1);
    assert_eq!(legacy[0].title, "Plan");
}

#[test]
fn upstream_camel_case_fixtures_parse_too() {
    let dir = repo_root().join("companion/Fixtures/codexbar");
    let files = json_files(&dir);
    if files.is_empty() {
        eprintln!("Mac-Fixtures nicht gefunden, übersprungen");
        return;
    }
    for file in files {
        let data = std::fs::read(&file).unwrap();
        let result = parse_output(&data).unwrap_or_else(|e| panic!("{}: {:?}", file.display(), e));
        let provider = provider_of(&file);
        let updated = result.usage.as_ref().and_then(|u| u.updated_at.clone()).expect("updatedAt");
        let now = aimonitor_core::codexbar::parse_timestamp(&updated).unwrap();
        let eval = evaluate(result, provider, now, Duration::from_secs(900));
        assert_eq!(eval.status, Status::Ok, "{}", file.display());
        assert!(!build_rows(&eval.entry.unwrap(), PercentMode::Used).is_empty(), "{}", file.display());
    }
}

/// Echte Windows-Aufnahmen, sobald `collect_fixtures.ps1` gelaufen ist.
/// Ohne Dateien läuft der Test leer durch, damit CI auf dem Mac nicht bricht.
#[test]
fn real_windows_fixtures_parse_when_present() {
    let dir = repo_root().join("companion-windows/fixtures/codexbar");
    let files = json_files(&dir);
    if files.is_empty() {
        eprintln!("keine echten Windows-Fixtures vorhanden, übersprungen");
        return;
    }
    for file in files {
        let data = std::fs::read(&file).unwrap();
        let result = parse_output(&data).unwrap_or_else(|e| panic!("{}: {:?}", file.display(), e));
        let name = file.file_stem().unwrap().to_string_lossy().into_owned();
        let eval = evaluate(result, provider_of(&file), Utc::now(), Duration::from_secs(900));
        if name.ends_with("-error") {
            assert!(matches!(eval.status, Status::ProviderUnavailable { .. }), "{name}");
        } else {
            // Aufnahmen sind alt, also Stale, aber der Eintrag muss da sein und Zeilen ergeben.
            let entry = eval.entry.unwrap_or_else(|| panic!("{name}: kein Eintrag, Status {:?}", eval.status));
            assert!(!build_rows(&entry, PercentMode::Used).is_empty(), "{name}: keine Zeilen");
        }
    }
}
