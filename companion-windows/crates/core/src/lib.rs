//! aimonitor-core: plattformunabhängige Fachlogik der Companion-App.
//!
//! Portiert aus der Mac-App (`companion/Sources/CodexBarSource.swift`,
//! `companion/Sources/main.swift`, `buildUsageEnvelope`). Enthält keine
//! Tauri-, Serial- oder UI-Abhängigkeiten, damit alles mit `cargo test`
//! auf jeder Plattform prüfbar bleibt.
//!
//! Module:
//! - [`provider`]: die sechs Provider mit Labels, Zeilentiteln und Fenster-Defaults
//! - [`model`]: internes Datenmodell (Fenster, Zusatzfenster, Eintrag)
//! - [`status`]: Zustand der Datenquelle
//! - [`codexbar`]: CLI-JSON von Win-CodexBar (snake_case) und Upstream (camelCase) lesen
//! - [`runner`]: CLI finden, aufrufen, Fixture-Modus
//! - [`rows`]: Anzeigezeilen nach den Regeln der Mac-App aufbauen
//! - [`source`]: zustandsbehaftete Quelle mit Zwischenspeicher je Provider

pub mod codexbar;
pub mod model;
pub mod provider;
pub mod rows;
pub mod runner;
pub mod source;
pub mod status;

pub use model::{Entry, ExtraWindow, Window};
pub use provider::Provider;
pub use rows::{build_rows, PercentMode, Row};
pub use source::{FetchOutcome, Snapshot, Source};
pub use status::Status;

use std::time::Duration;

/// Poll-Intervall. Bewusst groß: die CLI-Abfragen dauern real 1 bis 4 s und
/// laufen gegen drosselnde Endpunkte. Fenster von 5 h bzw. 7 Tagen brauchen
/// keine Sekundenaktualität. (CodexBarSource.swift: kPollInterval)
pub const POLL_INTERVAL: Duration = Duration::from_secs(180);

/// Stale-Schwelle: älter als das heißt, nichts Neues mehr senden.
/// (CodexBarSource.swift: kStaleThresholdSeconds)
pub const STALE_THRESHOLD: Duration = Duration::from_secs(15 * 60);

/// Timeout je CLI-Aufruf. (CodexBarSource.swift: kCLITimeout)
pub const CLI_TIMEOUT: Duration = Duration::from_secs(30);
