//! Tauri-Hülle der AI-Monitor-App: Tray, Einstellungsfenster, Abrufzyklus.
//! Die Fachlogik liegt in `aimonitor-core`.

mod commands;
mod poll;
mod registry;
mod serial_service;
mod settings;
mod state;
mod timezone;
mod tray;
mod window;

use aimonitor_core::Source;
use settings::Settings;
use state::AppState;
use tauri::Manager;

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
