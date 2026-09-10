//! Tray-Icon mit Provider-Menü. Die wenigen Menütexte stehen direkt hier,
//! die Oberfläche selbst wird im Frontend lokalisiert.

use crate::commands::apply_provider;
use crate::poll;
use crate::serial_service::{self, ConnectionState};
use crate::settings::Settings;
use crate::state::{current_snapshot, AppState};
use crate::window;
use aimonitor_core::{Provider, Snapshot};
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Wry};

const TRAY_ID: &str = "main";

fn text(lang: &str, key: &str) -> &'static str {
    match (lang, key) {
        ("de", "refresh") => "Jetzt aktualisieren",
        ("de", "settings") => "Einstellungen…",
        ("de", "quit") => "Beenden",
        ("de", "disconnected") => "nicht verbunden",
        ("de", "probing") => "Gerät wird erkannt",
        ("de", "connected") => "verbunden",
        ("de", "foreignFirmware") => "fremde Firmware",
        (_, "refresh") => "Refresh now",
        (_, "settings") => "Settings…",
        (_, "quit") => "Quit",
        (_, "disconnected") => "not connected",
        (_, "probing") => "identifying device",
        (_, "connected") => "connected",
        _ => "unknown firmware",
    }
}

fn build_menu(app: &AppHandle, settings: &Settings, active: Provider) -> tauri::Result<Menu<Wry>> {
    let lang = settings.language.effective();
    let menu = Menu::new(app)?;
    for provider in Provider::ALL {
        let item = CheckMenuItem::with_id(
            app,
            format!("provider:{}", provider.key()),
            provider.display_label(),
            true,
            provider == active,
            None::<&str>,
        )?;
        menu.append(&item)?;
    }
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "refresh", text(lang, "refresh"), true, None::<&str>)?)?;
    menu.append(&MenuItem::with_id(app, "settings", text(lang, "settings"), true, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, "quit", text(lang, "quit"), true, None::<&str>)?)?;
    Ok(menu)
}

/// Tooltip mit Provider, erstem Wert und Verbindungszustand.
fn tooltip(app: &AppHandle, lang: &str, snap: &Snapshot) -> String {
    let value = match snap.rows.first() {
        Some(row) => format!("{} %", row.used_percent),
        None => snap.status.short_label(),
    };
    let conn = app.state::<AppState>().connection.lock().unwrap().clone();
    let link = match conn.state {
        ConnectionState::Connected => match conn.info.as_ref() {
            Some(info) => format!("{} ({})", text(lang, "connected"), info.version),
            None => text(lang, "connected").to_string(),
        },
        ConnectionState::Probing => text(lang, "probing").to_string(),
        ConnectionState::ForeignFirmware => text(lang, "foreignFirmware").to_string(),
        ConnectionState::Disconnected => text(lang, "disconnected").to_string(),
    };
    format!("AI Monitor · {} · {} · {}", snap.provider_label, value, link)
}

fn tray_image() -> tauri::Result<tauri::image::Image<'static>> {
    tauri::image::Image::from_bytes(include_bytes!("../icons/tray-32.png"))
}

/// Tray beim Start anlegen.
pub fn build(app: &AppHandle) -> tauri::Result<()> {
    let (settings, snap) = {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap().clone();
        (settings, current_snapshot(app))
    };
    let menu = build_menu(app, &settings, snap.provider)?;

    let builder = TrayIconBuilder::with_id(TRAY_ID)
        .icon(tray_image()?)
        .tooltip(tooltip(app, settings.language.effective(), &snap))
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "refresh" => poll::start_fetch(app),
            "settings" => window::open_settings(app),
            "quit" => serial_service::shutdown_and_exit(app),
            id => {
                if let Some(key) = id.strip_prefix("provider:") {
                    if let Ok(provider) = key.parse::<Provider>() {
                        apply_provider(app, provider);
                    }
                }
            }
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                window::open_settings(tray.app_handle());
            }
        });

    // Monochromes Template-Icon in der macOS-Menüleiste, sonst wie geliefert.
    #[cfg(target_os = "macos")]
    let builder = builder.icon_as_template(true);

    let tray = builder.build(app)?;
    *app.state::<AppState>().tray.lock().unwrap() = Some(tray);
    Ok(())
}

/// Tooltip und Menü (Haken, Sprache) nach jeder Änderung neu setzen.
pub fn refresh(app: &AppHandle) {
    let state = app.state::<AppState>();
    let settings = state.settings.lock().unwrap().clone();
    let snap = current_snapshot(app);
    let tray = state.tray.lock().unwrap();
    let Some(tray) = tray.as_ref() else { return };
    let _ = tray.set_tooltip(Some(tooltip(app, settings.language.effective(), &snap)));
    match build_menu(app, &settings, snap.provider) {
        Ok(menu) => {
            let _ = tray.set_menu(Some(menu));
        }
        Err(e) => eprintln!("[aimonitor] Tray-Menü nicht gebaut: {e}"),
    }
}
