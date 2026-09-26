//! Tauri adapter for the portable display-plugin store.

pub use aimonitor_plugin_store::*;
use tauri::{AppHandle, Manager};

pub fn app_store(app: &AppHandle) -> Result<PluginStore, tauri::Error> {
    let root = app.path().app_config_dir()?.join("plugins");
    Ok(PluginStore::load(root))
}
