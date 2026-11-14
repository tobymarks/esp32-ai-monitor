//! Explicit per-device standalone snapshots; never exported during normal polling.
use crate::{
    serial_service::{self, Job},
    state::AppState,
};
use aimonitor_core::standalone::{export_profile, StandaloneExport};
use aimonitor_core::{
    plugin::SceneLayout,
    protocol::{DisplayVariant, Orientation},
};
use serde_json::Value;
use std::{sync::mpsc, time::Duration};
use tauri::{AppHandle, Manager};

pub fn preview(app: &AppHandle, mac: &str, id: &str) -> Result<StandaloneExport, String> {
    let state = app.state::<AppState>();
    let registry = state.registry.lock().unwrap();
    let profile = registry
        .devices
        .get(mac)
        .ok_or("standalone.deviceChanged")?;
    let layout = if profile.display_variant == Some(DisplayVariant::St7701) {
        SceneLayout::Square
    } else if profile.orientation == Orientation::Portrait {
        SceneLayout::Portrait
    } else {
        SceneLayout::Landscape
    };
    let store = state.plugins.lock().unwrap();
    let record = store.records.get(id).ok_or("standalone.select")?;
    export_profile(
        &record.manifest,
        &record.settings,
        layout,
        profile
            .theme
            .resolve(crate::serial_service::system_is_dark()),
        profile.language.wire(),
        profile.location.as_ref(),
    )
}

#[tauri::command]
pub fn standalone_preview(
    app: AppHandle,
    mac: String,
    id: String,
) -> Result<StandaloneExport, String> {
    preview(&app, &mac, &id)
}

#[tauri::command]
pub async fn standalone_action(
    app: AppHandle,
    mac: String,
    action: String,
    id: Option<String>,
    expected_sha256: Option<String>,
) -> Result<Value, String> {
    if !["status", "setup", "install", "remove", "disable", "enable"].contains(&action.as_str()) {
        return Err("standalone.invalid".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let (reply, receiver) = mpsc::channel();
        serial_service::send(
            &app,
            Job::Standalone {
                mac,
                action,
                id,
                expected_sha256,
                reply,
            },
        );
        receiver
            .recv_timeout(Duration::from_secs(120))
            .map_err(|_| "standalone.timeout".to_string())?
    })
    .await
    .map_err(|_| "standalone.failed".to_string())?
}

/// Pure transfer driver: native tests inject ACKs and failures without opening ports.
pub fn upload(
    export: &StandaloneExport,
    mut request: impl FnMut(Value) -> Result<Value, String>,
) -> Result<Value, String> {
    use serde_json::json;
    if export.profile.is_empty() || export.profile.len() > 8192 {
        return Err("standalone.invalid".into());
    }
    let transaction = uuid::Uuid::new_v4().simple().to_string();
    let result = (|| {
        request(json!({"cmd":"standalone_begin", "transaction":transaction,
            "bytes":export.profile.len(), "sha256":export.sha256}))?;
        let mut offset = 0;
        while offset < export.profile.len() {
            let mut end = (offset + 512).min(export.profile.len());
            while !export.profile.is_char_boundary(end) {
                end -= 1;
            }
            let ack = request(json!({"cmd":"standalone_chunk", "transaction":transaction,
                "offset":offset,"data":&export.profile[offset..end]}))?;
            if ack["offset"].as_u64() != Some(end as u64) {
                return Err("standalone.invalidAck".into());
            }
            offset = end;
        }
        request(json!({"cmd":"standalone_commit", "transaction":transaction}))?;
        let status = request(json!({"cmd":"standalone_status"}))?;
        if status["digest"].as_str() != Some(export.sha256.as_str()) || status["enabled"] != true {
            return Err("standalone.readback".into());
        }
        Ok(status)
    })();
    if result.is_err() {
        let _ = request(json!({"cmd":"standalone_abort", "transaction":transaction}));
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn export(profile: String) -> StandaloneExport {
        StandaloneExport {
            profile,
            sha256: "abc".repeat(21) + "a",
            plugin_id: "example".into(),
            name: "Example".into(),
            version: "1.0.0".into(),
            origin: "https://example.org".into(),
            sends_location: false,
            refresh_seconds: 60,
        }
    }
    #[test]
    fn unicode_and_escaped_chunks_roundtrip_inside_frame_budget() {
        let snapshot = export("ä\"\n".repeat(1000));
        let mut received = String::new();
        let mut transaction = None;
        upload(&snapshot, |frame| {
            assert!(serde_json::to_vec(&frame).unwrap().len() < 4095);
            match frame["cmd"].as_str().unwrap() {
                "standalone_begin" => {
                    assert_eq!(frame["bytes"], snapshot.profile.len());
                    transaction = frame["transaction"].as_str().map(str::to_owned);
                    Ok(json!({"ok":true}))
                }
                "standalone_chunk" => {
                    assert_eq!(frame["transaction"].as_str(), transaction.as_deref());
                    assert_eq!(frame["offset"], received.len());
                    received.push_str(frame["data"].as_str().unwrap());
                    Ok(json!({"offset":received.len()}))
                }
                "standalone_commit" => {
                    assert_eq!(received, snapshot.profile);
                    Ok(json!({"ok":true}))
                }
                "standalone_status" => Ok(json!({"digest":snapshot.sha256,"enabled":true})),
                _ => panic!("unexpected command"),
            }
        })
        .unwrap();
    }
    #[test]
    fn incorrect_offset_aborts_without_commit() {
        let mut commands = Vec::new();
        assert_eq!(
            upload(&export("profile".into()), |frame| {
                commands.push(frame["cmd"].as_str().unwrap().to_owned());
                Ok(json!({"offset":0}))
            })
            .unwrap_err(),
            "standalone.invalidAck"
        );
        assert_eq!(
            commands,
            ["standalone_begin", "standalone_chunk", "standalone_abort"]
        );
    }
    #[test]
    fn oversized_profile_never_contacts_device() {
        assert!(upload(&export("x".repeat(8193)), |_| panic!(
            "must not contact device"
        ))
        .is_err());
    }
    #[test]
    fn mismatching_readback_is_never_reported_as_installed() {
        let mut aborted = false;
        assert_eq!(
            upload(&export("x".into()), |frame| {
                if frame["cmd"] == "standalone_abort" {
                    aborted = true;
                }
                Ok(json!({"offset":1,"digest":"different","enabled":true}))
            })
            .unwrap_err(),
            "standalone.readback"
        );
        assert!(aborted);
    }
}
