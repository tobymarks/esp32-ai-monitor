//! CLI finden und aufrufen, Fixture-Modus für Entwicklung und Tests.
//! Entspricht `resolveCLIPath`, `runCLI` und `decodeCLIOutput` der Mac-App.

use crate::codexbar::{self, CliResult};
use crate::provider::Provider;
use crate::status::Status;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Entwicklermodus: Ist die Variable gesetzt, wird statt des CLI die Datei
/// `<dir>/<provider>.json` gelesen. Nur Provider mit vorhandener Datei werden
/// ersetzt, die übrigen laufen weiter über das echte CLI.
pub const FIXTURE_DIR_ENV: &str = "AIMONITOR_CODEXBAR_FIXTURE_DIR";

/// Was ein Lauf hinterlässt, für die Diagnose-Ansicht.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RawRun {
    pub command: String,
    pub stdout: String,
    pub stderr: String,
    pub exit_code: Option<i32>,
    pub duration_ms: u64,
    pub from_fixture: bool,
}

/// Kandidaten in Prioritätsreihenfolge. GUI-Apps erben den Login-PATH nicht
/// zuverlässig, deshalb zuerst feste Pfade, PATH nur als Ergänzung.
pub fn candidate_paths() -> Vec<PathBuf> {
    let mut out = Vec::new();

    #[cfg(windows)]
    {
        if let Ok(local) = std::env::var("LOCALAPPDATA") {
            out.push(Path::new(&local).join("Programs").join("CodexBar").join("codexbar-cli.exe"));
        }
        if let Ok(pf) = std::env::var("ProgramFiles") {
            out.push(Path::new(&pf).join("CodexBar").join("codexbar-cli.exe"));
        }
    }

    #[cfg(not(windows))]
    {
        out.push(PathBuf::from("/opt/homebrew/bin/codexbar"));
        out.push(PathBuf::from("/usr/local/bin/codexbar"));
        out.push(PathBuf::from("/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"));
        if let Ok(home) = std::env::var("HOME") {
            out.push(Path::new(&home).join("Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"));
        }
        out.push(PathBuf::from("/usr/bin/codexbar"));
    }

    let names: &[&str] = if cfg!(windows) {
        &["codexbar-cli.exe", "codexbar.exe"]
    } else {
        &["codexbar"]
    };
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            for name in names {
                out.push(dir.join(name));
            }
        }
    }
    out
}

pub fn resolve_cli_path() -> Option<PathBuf> {
    candidate_paths().into_iter().find(|p| is_executable(p))
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// `codexbar-cli --version`, erste Zeile. Für die Diagnose-Ansicht.
pub fn cli_version(cli: &Path) -> Option<String> {
    let out = hidden_command(cli).arg("--version").output().ok()?;
    let text = String::from_utf8_lossy(if out.stdout.is_empty() { &out.stderr } else { &out.stdout });
    text.lines().next().map(|l| l.trim().to_string()).filter(|l| !l.is_empty())
}

/// Fixture-Datei für den Provider, falls der Modus aktiv ist und die Datei existiert.
pub fn fixture_path(provider: Provider) -> Option<PathBuf> {
    let dir = std::env::var_os(FIXTURE_DIR_ENV)?;
    if dir.is_empty() {
        return None;
    }
    let file = Path::new(&dir).join(format!("{}.json", provider.key()));
    file.is_file().then_some(file)
}

/// Ergebnis eines Laufs: Rohdaten plus geparstes Ergebnis oder Fehlerstatus.
#[derive(Debug, Clone)]
pub struct RunOutcome {
    pub raw: RawRun,
    pub result: Result<CliResult, Status>,
}

/// `usage --provider <p> --json` ausführen oder die Fixture lesen.
pub fn run_usage(cli: Option<&Path>, provider: Provider, timeout: Duration) -> RunOutcome {
    if let Some(file) = fixture_path(provider) {
        let started = Instant::now();
        let data = std::fs::read(&file).unwrap_or_default();
        let raw = RawRun {
            command: format!("fixture {}", file.display()),
            stdout: String::from_utf8_lossy(&data).into_owned(),
            stderr: String::new(),
            exit_code: Some(0),
            duration_ms: started.elapsed().as_millis() as u64,
            from_fixture: true,
        };
        let result = decode(&data, b"", Some(0));
        return RunOutcome { raw, result };
    }

    let Some(cli) = cli else {
        return RunOutcome {
            raw: RawRun {
                command: String::new(),
                stdout: String::new(),
                stderr: String::new(),
                exit_code: None,
                duration_ms: 0,
                from_fixture: false,
            },
            result: Err(Status::CliMissing),
        };
    };

    let args = ["usage", "--provider", provider.key(), "--json"];
    let command = format!("{} {}", cli.display(), args.join(" "));
    let started = Instant::now();

    let mut child = match hidden_command(cli)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            return RunOutcome {
                raw: RawRun {
                    command,
                    stdout: String::new(),
                    stderr: e.to_string(),
                    exit_code: None,
                    duration_ms: 0,
                    from_fixture: false,
                },
                result: Err(Status::CliFailed {
                    message: format!("Start fehlgeschlagen: {e}"),
                }),
            }
        }
    };

    // Pipes in Threads leeren, sonst blockiert ein gesprächiges CLI am vollen Puffer.
    let stdout_handle = child.stdout.take().map(|mut s| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = std::io::Read::read_to_end(&mut s, &mut buf);
            buf
        })
    });
    let stderr_handle = child.stderr.take().map(|mut s| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = std::io::Read::read_to_end(&mut s, &mut buf);
            buf
        })
    });

    // Watchdog: nach `timeout` hart beenden, sonst hängt der Poll-Zyklus.
    let mut timed_out = false;
    let exit_code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code(),
            Ok(None) => {
                if started.elapsed() >= timeout {
                    timed_out = true;
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(_) => break None,
        }
    };

    let stdout = stdout_handle.and_then(|h| h.join().ok()).unwrap_or_default();
    let stderr = stderr_handle.and_then(|h| h.join().ok()).unwrap_or_default();

    let raw = RawRun {
        command,
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
        exit_code,
        duration_ms: started.elapsed().as_millis() as u64,
        from_fixture: false,
    };

    let result = if timed_out {
        Err(Status::CliFailed {
            message: format!("Timeout nach {} s", timeout.as_secs()),
        })
    } else {
        decode(&stdout, &stderr, exit_code)
    };

    RunOutcome { raw, result }
}

/// Wie `decodeCLIOutput`: leere Ausgabe ist ein Aufruffehler mit stderr als Text.
fn decode(stdout: &[u8], stderr: &[u8], exit_code: Option<i32>) -> Result<CliResult, Status> {
    if stdout.iter().all(|b| b.is_ascii_whitespace()) {
        let msg = String::from_utf8_lossy(stderr).trim().to_string();
        let message = if msg.is_empty() {
            format!("Keine Ausgabe (Exit {})", exit_code.map(|c| c.to_string()).unwrap_or_else(|| "?".into()))
        } else {
            msg.chars().take(160).collect()
        };
        return Err(Status::CliFailed { message });
    }
    codexbar::parse_output(stdout)
}

/// Prozess ohne Konsolenfenster starten (Windows), sonst unverändert.
fn hidden_command(program: &Path) -> Command {
    #[cfg_attr(not(windows), allow(unused_mut))]
    let mut cmd = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_output_becomes_cli_failed_with_stderr() {
        let r = decode(b"  \n", b"boom: no config", Some(1));
        assert_eq!(r.unwrap_err(), Status::CliFailed { message: "boom: no config".into() });
        let r = decode(b"", b"", Some(3));
        assert_eq!(r.unwrap_err(), Status::CliFailed { message: "Keine Ausgabe (Exit 3)".into() });
    }

    #[test]
    fn missing_cli_without_fixture_is_cli_missing() {
        std::env::remove_var(FIXTURE_DIR_ENV);
        let out = run_usage(None, Provider::Claude, Duration::from_secs(1));
        assert_eq!(out.result.unwrap_err(), Status::CliMissing);
    }
}
