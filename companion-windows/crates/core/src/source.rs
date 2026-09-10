//! Zustandsbehaftete Datenquelle: aktiver Provider, letzter Stand, Cache je
//! Provider, Diagnose-Daten. Entspricht `CodexBarSource` der Mac-App, aber
//! ohne Timer und Threads: die App ruft [`Source::begin_fetch`] auf, führt den
//! Aufruf in einem eigenen Thread aus und liefert das Ergebnis mit
//! [`Source::apply`] zurück. Dadurch bleibt alles hier synchron testbar.

use crate::codexbar::{self, Evaluation};
use crate::model::Entry;
use crate::provider::Provider;
use crate::rows::{build_rows, PercentMode, Row};
use crate::runner::{self, RawRun, RunOutcome};
use crate::status::Status;
use crate::{CLI_TIMEOUT, STALE_THRESHOLD};
use chrono::{DateTime, Utc};
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Debug, Clone)]
struct Cached {
    entry: Entry,
    fetched_at: DateTime<Utc>,
}

/// Ergebnis eines Abrufs, wie es aus dem Worker-Thread zurückkommt.
#[derive(Debug, Clone)]
pub struct FetchOutcome {
    pub provider: Provider,
    pub run: RunOutcome,
    pub finished_at: DateTime<Utc>,
}

/// Führt den Abruf für einen Provider aus. Blockiert bis zu `CLI_TIMEOUT`,
/// gehört deshalb in einen Worker-Thread.
pub fn fetch(cli: Option<&std::path::Path>, provider: Provider) -> FetchOutcome {
    let run = runner::run_usage(cli, provider, CLI_TIMEOUT);
    FetchOutcome {
        provider,
        run,
        finished_at: Utc::now(),
    }
}

/// Alles, was Tray und Einstellungsfenster anzeigen. Geht als JSON ans Frontend.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub provider: Provider,
    pub provider_label: &'static str,
    pub login_label: &'static str,
    pub status: Status,
    pub rows: Vec<Row>,
    pub entry: Option<Entry>,
    /// Quelle, die das CLI benutzt hat („web", „oauth", „cli"), nur Anzeige.
    pub source: Option<String>,
    pub updated_at: Option<DateTime<Utc>>,
    pub fetched_at: Option<DateTime<Utc>>,
    pub fetching: bool,
    pub percent_mode: PercentMode,
    pub cli_path: Option<PathBuf>,
    pub cli_version: Option<String>,
    pub fixture_dir: Option<String>,
    pub last_run: Option<RawRun>,
}

#[derive(Debug)]
pub struct Source {
    provider: Provider,
    status: Status,
    last_entry: Option<Entry>,
    last_source: Option<String>,
    last_fetched_at: Option<DateTime<Utc>>,
    cache: HashMap<Provider, Cached>,
    fetching: bool,
    pending_reload: bool,
    cli_path: Option<PathBuf>,
    cli_version: Option<String>,
    last_run: Option<RawRun>,
    stale_after: Duration,
}

impl Source {
    pub fn new(provider: Provider) -> Self {
        let cli_path = runner::resolve_cli_path();
        let cli_version = cli_path.as_deref().and_then(runner::cli_version);
        Self {
            provider,
            status: Status::NotYet,
            last_entry: None,
            last_source: None,
            last_fetched_at: None,
            cache: HashMap::new(),
            fetching: false,
            pending_reload: false,
            cli_path,
            cli_version,
            last_run: None,
            stale_after: STALE_THRESHOLD,
        }
    }

    #[cfg(test)]
    fn with_stale_after(mut self, d: Duration) -> Self {
        self.stale_after = d;
        self
    }

    pub fn provider(&self) -> Provider {
        self.provider
    }

    pub fn status(&self) -> &Status {
        &self.status
    }

    pub fn entry(&self) -> Option<&Entry> {
        self.last_entry.as_ref()
    }

    pub fn is_fetching(&self) -> bool {
        self.fetching
    }

    pub fn cli_path(&self) -> Option<&std::path::Path> {
        self.cli_path.as_deref()
    }

    /// CLI-Pfad neu suchen, z. B. nachdem der Nutzer Win-CodexBar installiert hat.
    pub fn rescan_cli(&mut self) {
        self.cli_path = runner::resolve_cli_path();
        self.cli_version = self.cli_path.as_deref().and_then(runner::cli_version);
    }

    /// Provider wechseln. Zuletzt bekannten Stand sofort zeigen, sofern er
    /// nicht veraltet ist; der Aufrufer startet danach einen Abruf.
    /// Gibt `true` zurück, wenn sich der Provider geändert hat.
    pub fn set_provider(&mut self, provider: Provider, now: DateTime<Utc>) -> bool {
        if provider == self.provider {
            return false;
        }
        self.provider = provider;
        match self.cache.get(&provider) {
            Some(c) if now.signed_duration_since(c.fetched_at).num_seconds() as u64 <= self.stale_after.as_secs() => {
                self.last_entry = Some(c.entry.clone());
                self.status = Status::Ok;
            }
            _ => {
                self.last_entry = None;
                self.status = Status::NotYet;
            }
        }
        true
    }

    /// Abruf anmelden. Gibt den Provider zurück, für den gefetcht werden soll,
    /// oder `None`, wenn bereits ein Abruf läuft (dann wird er vorgemerkt).
    pub fn begin_fetch(&mut self) -> Option<Provider> {
        if self.fetching {
            self.pending_reload = true;
            return None;
        }
        if self.cli_path.is_none() && runner::fixture_path(self.provider).is_none() {
            self.rescan_cli();
        }
        self.fetching = true;
        self.pending_reload = false;
        Some(self.provider)
    }

    /// Ergebnis eines Abrufs übernehmen. Gibt `true` zurück, wenn sofort ein
    /// weiterer Abruf nötig ist (Provider hat inzwischen gewechselt oder ein
    /// Abruf wurde während des Laufs angefordert).
    pub fn apply(&mut self, outcome: FetchOutcome) -> bool {
        self.fetching = false;
        self.last_run = Some(outcome.run.raw.clone());

        let provider_changed = outcome.provider != self.provider;
        if !provider_changed {
            self.last_fetched_at = Some(outcome.finished_at);
            match outcome.run.result {
                Err(status) => self.apply_status(status, None, None),
                Ok(result) => {
                    let Evaluation { status, entry, source } =
                        codexbar::evaluate(result, outcome.provider, outcome.finished_at, self.stale_after);
                    self.apply_status(status, entry, source);
                }
            }
        }

        let again = provider_changed || self.pending_reload;
        self.pending_reload = false;
        again
    }

    fn apply_status(&mut self, status: Status, entry: Option<Entry>, source: Option<String>) {
        if let (Some(e), true) = (&entry, status.is_ok()) {
            self.cache.insert(
                self.provider,
                Cached {
                    entry: e.clone(),
                    fetched_at: self.last_fetched_at.unwrap_or_else(Utc::now),
                },
            );
        }
        // Bei einem Fehler den Zwischenspeicher dieses Providers verwerfen,
        // sonst zeigt ein späterer Wechsel wieder veraltete Werte.
        if entry.is_none() && !status.is_ok() {
            self.cache.remove(&self.provider);
        }
        self.status = status;
        self.last_entry = entry;
        self.last_source = source;
    }

    pub fn snapshot(&self, mode: PercentMode) -> Snapshot {
        let rows = self
            .last_entry
            .as_ref()
            .map(|e| build_rows(e, mode))
            .unwrap_or_default();
        Snapshot {
            provider: self.provider,
            provider_label: self.provider.display_label(),
            login_label: self.provider.login_label(),
            status: self.status.clone(),
            rows,
            entry: self.last_entry.clone(),
            source: self.last_source.clone(),
            updated_at: self.last_entry.as_ref().and_then(|e| e.updated_at),
            fetched_at: self.last_fetched_at,
            fetching: self.fetching,
            percent_mode: mode,
            cli_path: self.cli_path.clone(),
            cli_version: self.cli_version.clone(),
            fixture_dir: std::env::var(runner::FIXTURE_DIR_ENV).ok().filter(|s| !s.is_empty()),
            last_run: self.last_run.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codexbar::parse_output;
    use chrono::TimeZone;

    fn outcome(provider: Provider, json: &str, at: DateTime<Utc>) -> FetchOutcome {
        FetchOutcome {
            provider,
            run: RunOutcome {
                raw: RawRun {
                    command: "test".into(),
                    stdout: json.into(),
                    stderr: String::new(),
                    exit_code: Some(0),
                    duration_ms: 1,
                    from_fixture: true,
                },
                result: parse_output(json.as_bytes()),
            },
            finished_at: at,
        }
    }

    fn t(min: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 11, 8, min, 0).unwrap()
    }

    const CLAUDE: &str = r#"[{"provider":"claude","source":"oauth","usage":{"primary":{"used_percent":30,"window_minutes":300},"updated_at":"2026-09-11T08:00:00Z"}}]"#;
    const GEMINI: &str = r#"[{"provider":"gemini","source":"auto","usage":{"primary":{"used_percent":10,"window_minutes":1440},"updated_at":"2026-09-11T08:00:00Z"}}]"#;

    #[test]
    fn switch_uses_cache_when_fresh_and_drops_it_when_stale() {
        let mut s = Source::new(Provider::Claude).with_stale_after(Duration::from_secs(900));
        assert_eq!(s.begin_fetch(), Some(Provider::Claude));
        assert!(!s.apply(outcome(Provider::Claude, CLAUDE, t(1))));
        assert_eq!(s.status(), &Status::Ok);

        s.set_provider(Provider::Gemini, t(2));
        assert_eq!(s.status(), &Status::NotYet);
        s.begin_fetch();
        s.apply(outcome(Provider::Gemini, GEMINI, t(3)));

        // Zurück zu Claude innerhalb der Schwelle: Cache greift sofort.
        assert!(s.set_provider(Provider::Claude, t(10)));
        assert_eq!(s.status(), &Status::Ok);
        assert_eq!(s.entry().unwrap().primary.as_ref().unwrap().used_percent, 30.0);

        // Nach der Schwelle: kein Cache mehr.
        s.set_provider(Provider::Gemini, t(30));
        assert_eq!(s.status(), &Status::NotYet);
        assert!(s.entry().is_none());
    }

    #[test]
    fn result_for_old_provider_is_discarded_and_refetch_requested() {
        let mut s = Source::new(Provider::Claude).with_stale_after(Duration::from_secs(900));
        s.begin_fetch();
        s.set_provider(Provider::Cursor, t(1));
        // Ergebnis für Claude kommt an, während Cursor aktiv ist.
        let again = s.apply(outcome(Provider::Claude, CLAUDE, t(2)));
        assert!(again, "sofort neu abrufen");
        assert_eq!(s.status(), &Status::NotYet);
        assert!(s.entry().is_none());
    }

    #[test]
    fn overlapping_fetch_is_deferred() {
        let mut s = Source::new(Provider::Claude).with_stale_after(Duration::from_secs(900));
        assert_eq!(s.begin_fetch(), Some(Provider::Claude));
        assert_eq!(s.begin_fetch(), None, "zweiter Abruf wird vorgemerkt");
        assert!(s.apply(outcome(Provider::Claude, CLAUDE, t(1))), "Vormerkung löst Nachholen aus");
        assert!(!s.is_fetching());
    }

    #[test]
    fn error_clears_cache() {
        let mut s = Source::new(Provider::Claude).with_stale_after(Duration::from_secs(900));
        s.begin_fetch();
        s.apply(outcome(Provider::Claude, CLAUDE, t(1)));
        s.begin_fetch();
        s.apply(outcome(Provider::Claude, r#"[{"provider":"claude","error":"gone"}]"#, t(2)));
        assert!(matches!(s.status(), Status::ProviderUnavailable { .. }));
        s.set_provider(Provider::Gemini, t(3));
        s.set_provider(Provider::Claude, t(4));
        assert_eq!(s.status(), &Status::NotYet, "kein veralteter Cache nach Fehler");
    }

    #[test]
    fn snapshot_carries_rows_and_diagnostics() {
        let mut s = Source::new(Provider::Claude).with_stale_after(Duration::from_secs(900));
        s.begin_fetch();
        s.apply(outcome(Provider::Claude, CLAUDE, t(1)));
        let snap = s.snapshot(PercentMode::Remaining);
        assert_eq!(snap.rows.len(), 1);
        assert_eq!(snap.rows[0].used_percent, 70);
        assert_eq!(snap.last_run.as_ref().unwrap().stdout, CLAUDE);
        assert_eq!(snap.provider_label, "Claude");
    }
}
