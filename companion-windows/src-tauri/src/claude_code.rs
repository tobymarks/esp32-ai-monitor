//! Fenster „Claude Code wartet“ (Issue #10): lokaler HTTP-Empfang für die
//! Hooks von Claude Code, Zustand und Einrichtung. Auswertung, Szene und das
//! Eintragen in `~/.claude/settings.json` liegen in `aimonitor_core::claude_code`.

use crate::serial_service::Job;
use crate::settings::ViewContent;
use crate::state::AppState;
use aimonitor_core::claude_code::{
    self as core, check_request, parse_request, response, HookStatus, Request, Sessions, Waiting,
};
use aimonitor_core::plugin::SceneLayout;
use aimonitor_core::protocol::{Language, Theme};
use serde::Serialize;
use serde_json::Value;
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::time::Duration;
use tauri::{AppHandle, Manager};

#[derive(Debug, Clone, Default)]
pub enum Listener {
    #[default]
    Starting,
    Running,
    Failed(String),
}

#[derive(Debug, Default)]
pub struct ClaudeCode {
    pub sessions: Sessions,
    pub listener: Listener,
    pub token: String,
    pub hooks: Option<HookStatus>,
}

fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

fn token_path(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("claude-code-token"))
}

fn settings_path(app: &AppHandle) -> Option<PathBuf> {
    app.path().home_dir().ok().map(|home| core::settings_path(&home))
}

/// 128 Bit aus zwei `RandomState`-Schlüsseln, die die Standardbibliothek aus
/// dem Zufallsgenerator des Betriebssystems zieht. Für ein lokales Token
/// reicht das, eine weitere Abhängigkeit braucht es dafür nicht.
fn new_token() -> String {
    (0..2)
        .map(|i| {
            let mut hasher = RandomState::new().build_hasher();
            hasher.write_u64(i);
            format!("{:016x}", hasher.finish())
        })
        .collect()
}

fn load_token(app: &AppHandle) -> String {
    let Some(path) = token_path(app) else {
        return new_token();
    };
    if let Ok(token) = std::fs::read_to_string(&path) {
        let token = token.trim();
        if token.len() >= 16 && token.bytes().all(|b| b.is_ascii_alphanumeric()) {
            return token.to_owned();
        }
    }
    let token = new_token();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Err(e) = std::fs::write(&path, &token) {
        eprintln!("[claude-code] Token nicht gespeichert: {e}");
    }
    token
}

fn window_assigned(app: &AppHandle) -> bool {
    app.state::<AppState>()
        .settings
        .lock()
        .unwrap()
        .views
        .iter()
        .any(|view| matches!(view, ViewContent::Plugin(id) if id == core::VIEW_ID))
}

fn resend_if_assigned(app: &AppHandle) {
    if window_assigned(app) {
        let _ = app.state::<AppState>().serial.send(Job::Resend);
    }
}
fn report_waiting(app: &AppHandle) {
    // Send while holding the sessions lock, so the timer cannot overtake a
    // newer listener observation after reading an older waiting state.
    let state = app.state::<AppState>();
    let cc = state.claude_code.lock().unwrap();
    let waiting = cc.sessions.waiting(now()).iter()
        .filter_map(|s| s.waiting.map(|kind| (s.id.clone(), kind, s.since))).collect();
    let _ = state.serial.send(Job::SmartClaudeCode(waiting));
}

fn refresh_hook_status(app: &AppHandle) -> Option<HookStatus> {
    let token = app.state::<AppState>().claude_code.lock().unwrap().token.clone();
    let status = settings_path(app)
        .and_then(|path| core::file_hook_status(&path, core::PORT, &token).ok());
    let state = app.state::<AppState>();
    let mut cc = state.claude_code.lock().unwrap();
    let changed = cc.hooks != status;
    cc.hooks = status;
    drop(cc);
    if changed {
        resend_if_assigned(app);
    }
    status
}

pub fn start(app: AppHandle) {
    let token = load_token(&app);
    app.state::<AppState>().claude_code.lock().unwrap().token = token;
    refresh_hook_status(&app);

    let listen_app = app.clone();
    if let Err(e) = std::thread::Builder::new()
        .name("aimonitor-claude-code".into())
        .spawn(move || listen(listen_app))
    {
        eprintln!("[claude-code] Empfang nicht gestartet: {e}");
    }
    // Auch wenn Intelligent bereits beim Start gespeichert war, braucht der
    // erste Hook später eine Ausgangsbasis für die steigende Flanke.
    report_waiting(&app);
    // Einmal pro Minute: Wartezeiten auf dem Display weiterzählen, verlassene
    // Sessions aufräumen und eine von Hand geänderte settings.json bemerken.
    let _ = std::thread::Builder::new()
        .name("aimonitor-claude-code-timer".into())
        .spawn(move || loop {
            std::thread::sleep(Duration::from_secs(60));
            refresh_hook_status(&app);
            let resend = app.state::<AppState>().claude_code.lock().unwrap().sessions.tick(now());
            if resend {
                resend_if_assigned(&app);
            }
            report_waiting(&app);
        });
}

fn set_listener(app: &AppHandle, listener: Listener) {
    app.state::<AppState>().claude_code.lock().unwrap().listener = listener;
    resend_if_assigned(app);
}

fn listen(app: AppHandle) {
    let listener = match TcpListener::bind((Ipv4Addr::LOCALHOST, core::PORT)) {
        Ok(listener) => listener,
        Err(e) => {
            eprintln!("[claude-code] Port {} nicht verfügbar: {e}", core::PORT);
            set_listener(&app, Listener::Failed(e.to_string()));
            return;
        }
    };
    set_listener(&app, Listener::Running);
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => handle(&app, stream),
            Err(e) => eprintln!("[claude-code] Verbindung abgelehnt: {e}"),
        }
    }
}

/// Eine Anfrage lesen, prüfen, übernehmen und sofort beantworten.
fn handle(app: &AppHandle, mut stream: TcpStream) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let status = loop {
        match parse_request(&buffer) {
            Request::Complete { method, path, token, body } => {
                let expected = app.state::<AppState>().claude_code.lock().unwrap().token.clone();
                let status = check_request(&method, &path, token.as_deref(), &expected);
                if status != 200 {
                    break status;
                }
                let Ok(event) = serde_json::from_slice::<Value>(&body) else {
                    break 400;
                };
                let changed = app
                    .state::<AppState>()
                    .claude_code
                    .lock()
                    .unwrap()
                    .sessions
                    .apply(&event, now());
                if changed {
                    report_waiting(app);
                    resend_if_assigned(app);
                }
                break 200;
            }
            Request::Invalid => break 400,
            Request::Incomplete => {}
        }
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => buffer.extend_from_slice(&chunk[..n]),
        }
    };
    let _ = stream.write_all(response(status).as_bytes());
}

/// Szene für den Serial-Thread.
pub fn scene(app: &AppHandle, language: Language, theme: Theme, layout: SceneLayout) -> Value {
    let state = app.state::<AppState>();
    let cc = state.claude_code.lock().unwrap();
    let now = now();
    let setup = core::setup(
        matches!(cc.listener, Listener::Failed(_)),
        matches!(cc.hooks, Some(HookStatus::Installed)),
        cc.sessions.receiving(now),
    );
    core::scene(&cc.sessions.waiting(now), setup, now, language, theme, layout)
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitingSession {
    project: String,
    state: &'static str,
    since: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeCodeStatus {
    listener: &'static str,
    error: Option<String>,
    port: u16,
    hooks: Option<&'static str>,
    settings_path: Option<String>,
    /// Hook-Ereignisse kommen an, egal aus welcher Einstellungsdatei.
    receiving: bool,
    waiting: Vec<WaitingSession>,
}

fn status(app: &AppHandle) -> ClaudeCodeStatus {
    let state = app.state::<AppState>();
    let cc = state.claude_code.lock().unwrap();
    let (listener, error) = match &cc.listener {
        Listener::Starting => ("starting", None),
        Listener::Running => ("running", None),
        Listener::Failed(e) => ("failed", Some(e.clone())),
    };
    let waiting = cc
        .sessions
        .waiting(now())
        .into_iter()
        .map(|s| WaitingSession {
            project: s.project.clone(),
            state: match s.waiting {
                Some(Waiting::Permission) => "permission",
                Some(Waiting::Input) => "input",
                _ => "done",
            },
            since: s.since,
        })
        .collect();
    ClaudeCodeStatus {
        listener,
        error,
        port: core::PORT,
        hooks: cc.hooks.map(HookStatus::wire),
        settings_path: settings_path(app).map(|p| p.display().to_string()),
        receiving: cc.sessions.receiving(now()),
        waiting,
    }
}

#[tauri::command]
pub fn claude_code_status(app: AppHandle) -> ClaudeCodeStatus {
    refresh_hook_status(&app);
    status(&app)
}

/// Hooks eintragen (`install = true`) oder entfernen. Die Oberfläche fragt
/// vorher nach; hier wird nur noch geschrieben.
#[tauri::command]
pub async fn claude_code_set_hooks(app: AppHandle, install: bool) -> Result<ClaudeCodeStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let path = settings_path(&app).ok_or("Benutzerordner nicht gefunden")?;
        let token = app.state::<AppState>().claude_code.lock().unwrap().token.clone();
        core::write_hooks_file(&path, install, core::PORT, &token)?;
        refresh_hook_status(&app);
        Ok(status(&app))
    })
    .await
    .map_err(|e| e.to_string())?
}
