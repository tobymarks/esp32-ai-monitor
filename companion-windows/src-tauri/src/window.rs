//! Einstellungsfenster: wird bei Bedarf gebaut, Schließen versteckt nur.

use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder, WindowEvent};

pub const SETTINGS_LABEL: &str = "settings";

pub fn open_settings(app: &AppHandle) {
    if let Some(win) = app.get_webview_window(SETTINGS_LABEL) {
        let reopening = !win.is_visible().unwrap_or(false);
        let _ = win.show();
        let _ = win.unminimize();
        let _ = win.set_focus();
        if reopening {
            let _ = win.emit("settings-opened", ());
        }
        return;
    }

    let built = WebviewWindowBuilder::new(app, SETTINGS_LABEL, WebviewUrl::default())
        .title("AI Monitor")
        .inner_size(900.0, 600.0)
        .min_inner_size(720.0, 480.0)
        .center()
        .build();

    match built {
        Ok(win) => {
            let handle = win.clone();
            win.on_window_event(move |event| {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = handle.hide();
                }
            });
            let _ = win.set_focus();
        }
        Err(e) => eprintln!("[aimonitor] Einstellungsfenster nicht erstellt: {e}"),
    }
}
