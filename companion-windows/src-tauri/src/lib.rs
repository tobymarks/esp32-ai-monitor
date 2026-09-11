//! Tauri-Hülle der AI-Monitor-App: Tray, Einstellungsfenster, Abrufzyklus.
//! Die Fachlogik liegt in `aimonitor-core`.

mod commands;
mod flash;
mod poll;
mod registry;
mod serial_service;
mod settings;
mod state;
mod timezone;
mod tray;
mod updates;
mod window;

use aimonitor_core::Source;
use settings::Settings;
use state::AppState;
use tauri::Manager;

/// Entwicklungsschalter AIMONITOR_DEV_ACTION (siehe README). `flash` wartet
/// zuerst bis zu 60 s auf eine Verbindung; Variante über
/// AIMONITOR_DEV_VARIANT (Default ili9341).
fn dev_action(app: tauri::AppHandle, action: String) {
    use aimonitor_core::protocol::DisplayVariant;
    std::thread::Builder::new()
        .name("aimonitor-dev-action".into())
        .spawn(move || {
            let variant = std::env::var("AIMONITOR_DEV_VARIANT")
                .ok()
                .and_then(|v| DisplayVariant::parse(&v))
                .unwrap_or(DisplayVariant::Ili9341);
            match action.as_str() {
                "check" => {
                    let status = updates::check(&app, true);
                    println!("[dev] check_updates: {}", serde_json::to_string_pretty(&status).unwrap_or_default());
                }
                "download" => match updates::download_firmware(&app, variant) {
                    Ok(f) => println!("[dev] download_firmware: {}", serde_json::to_string_pretty(&f).unwrap_or_default()),
                    Err(e) => eprintln!("[dev] download_firmware fehlgeschlagen: {e}"),
                },
                "flash" => {
                    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
                    while std::time::Instant::now() < deadline {
                        if app.state::<AppState>().connection.lock().unwrap().port.is_some() {
                            break;
                        }
                        std::thread::sleep(std::time::Duration::from_millis(500));
                    }
                    match flash::run(&app, variant) {
                        Ok(o) => println!("[dev] flash_firmware: {}", serde_json::to_string_pretty(&o).unwrap_or_default()),
                        Err(e) => eprintln!("[dev] flash_firmware fehlgeschlagen: {e}"),
                    }
                }
                other => eprintln!("[dev] Unbekannte AIMONITOR_DEV_ACTION: {other}"),
            }
        })
        .expect("Dev-Thread");
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::Builder::new().build())
        .setup(|app| {
            // Kein Dock-Icon unter macOS, die App lebt in der Menüleiste.
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let handle = app.handle().clone();
            let settings = Settings::load(&handle);
            let source = Source::new(settings.provider);
            println!(
                "[aimonitor] Start: Provider {}, CLI {:?}, Sprache {}",
                settings.provider,
                source.cli_path(),
                settings.language.effective()
            );
            let devices = registry::load(&handle);
            let manual_port = settings.manual_port.clone();
            let (serial_tx, serial_rx) = std::sync::mpsc::channel();
            app.manage(AppState::new(source, settings, devices, serial_tx));

            tray::build(&handle)?;
            serial_service::start(handle.clone(), serial_rx, manual_port);
            // Strg+C oder SIGTERM (z. B. aus `cargo tauri dev`) beenden wie
            // „Beenden" im Tray: standby ans Gerät, Port schließen, dann Exit.
            let signal_handle = handle.clone();
            if let Err(e) = ctrlc::set_handler(move || serial_service::shutdown_and_exit(&signal_handle)) {
                eprintln!("[aimonitor] Signal-Handler nicht gesetzt: {e}");
            }
            // Entwicklung: AIMONITOR_OPEN_SETTINGS=1 öffnet das Fenster sofort,
            // ohne den Umweg über das Tray-Menü.
            if std::env::var("AIMONITOR_OPEN_SETTINGS").map(|v| v == "1").unwrap_or(false) {
                window::open_settings(&handle);
            }
            updates::start_timer(handle.clone());
            // Entwicklung: AIMONITOR_DEV_ACTION=check|download|flash führt den
            // jeweiligen Command einmal beim Start aus und protokolliert das
            // Ergebnis; für Gerätetests ohne Klicks im Fenster.
            if let Ok(action) = std::env::var("AIMONITOR_DEV_ACTION") {
                dev_action(handle.clone(), action);
            }
            poll::start_timer(handle);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_snapshot,
            commands::set_provider,
            commands::refresh,
            commands::get_settings,
            commands::set_settings,
            commands::list_providers,
            commands::rescan_cli,
            commands::open_settings,
            commands::get_initial_page,
            commands::get_connection,
            commands::list_ports,
            commands::set_manual_port,
            commands::get_devices,
            commands::rename_device,
            commands::update_profile,
            commands::set_brightness,
            commands::get_timezones,
            commands::set_timezone,
            commands::send_diagnostic_frame,
            commands::check_updates,
            commands::get_update_status,
            commands::download_firmware,
            commands::flash_firmware,
            commands::install_app_update,
            commands::open_release_page,
        ])
        .build(tauri::generate_context!())
        .expect("Tauri-App konnte nicht gebaut werden")
        .run(|_app, event| {
            // Ohne Fenster weiterlaufen; nur "Beenden" (Exit-Code gesetzt) beendet.
            if let tauri::RunEvent::ExitRequested { code: None, api, .. } = event {
                api.prevent_exit();
            }
        });
}
