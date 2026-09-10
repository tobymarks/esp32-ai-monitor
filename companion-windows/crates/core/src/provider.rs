//! Die sechs Provider und ihre Anzeige-Regeln.
//! Quelle: `CodexBarSource.swift`, `enum CodexBarProvider`.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Claude,
    Codex,
    Antigravity,
    Gemini,
    Copilot,
    Cursor,
}

impl Provider {
    /// Reihenfolge wie im Mac-Segment-Control und im Tray-Menü.
    pub const ALL: [Provider; 6] = [
        Provider::Claude,
        Provider::Codex,
        Provider::Antigravity,
        Provider::Gemini,
        Provider::Copilot,
        Provider::Cursor,
    ];

    pub const DEFAULT: Provider = Provider::Claude;

    /// Schlüssel auf dem Draht (CLI-Argument, Wire-Key zum Gerät, Settings).
    pub fn key(self) -> &'static str {
        match self {
            Provider::Claude => "claude",
            Provider::Codex => "codex",
            Provider::Antigravity => "antigravity",
            Provider::Gemini => "gemini",
            Provider::Copilot => "copilot",
            Provider::Cursor => "cursor",
        }
    }

    /// Unbekannte oder leere Eingabe ergibt den Default, wie `CodexBarProvider.normalized`.
    pub fn normalized(raw: &str) -> Provider {
        raw.trim().to_ascii_lowercase().parse().unwrap_or(Self::DEFAULT)
    }

    /// Label in der Oberfläche.
    pub fn display_label(self) -> &'static str {
        match self {
            Provider::Claude => "Claude",
            Provider::Codex => "ChatGPT",
            Provider::Antigravity => "Antigravity",
            Provider::Gemini => "Gemini",
            Provider::Copilot => "Copilot",
            Provider::Cursor => "Cursor",
        }
    }

    /// Klartext des Kontos, geht als `loginMethod` mit zum Gerät.
    pub fn login_label(self) -> &'static str {
        match self {
            Provider::Claude => "Claude Max",
            Provider::Codex => "ChatGPT",
            Provider::Antigravity => "Antigravity",
            Provider::Gemini => "Gemini CLI",
            Provider::Copilot => "GitHub Copilot",
            Provider::Cursor => "Cursor",
        }
    }

    /// `true`, wenn der Provider drei feste Modell-Zeilen statt der generischen
    /// Session/Weekly/Tertiary-Fenster nutzt. Steuert den Zeilenaufbau.
    pub fn uses_model_rows(self) -> bool {
        matches!(self, Provider::Antigravity)
    }

    /// Default-Titel je Zeilenindex.
    pub fn default_row_titles(self) -> [&'static str; 3] {
        match self {
            Provider::Antigravity => ["Claude", "Gemini Pro", "Gemini Flash"],
            Provider::Claude | Provider::Codex => ["Session", "Weekly", "Tertiary"],
            Provider::Gemini => ["Pro", "Flash", "Flash Lite"],
            Provider::Copilot => ["Premium", "Chat", "Extra"],
            Provider::Cursor => ["Plan", "Auto", "API"],
        }
    }

    /// Titel für Zeilen jenseits der drei Default-Titel.
    pub fn fallback_row_title(self) -> &'static str {
        match self {
            Provider::Antigravity | Provider::Gemini => "Model",
            Provider::Copilot => "Quota",
            Provider::Claude | Provider::Codex | Provider::Cursor => "Window",
        }
    }

    pub fn default_row_title(self, index: usize) -> &'static str {
        self.default_row_titles()
            .get(index)
            .copied()
            .unwrap_or_else(|| self.fallback_row_title())
    }

    /// Fensterlänge in Minuten, wenn das CLI keine liefert. Die Firmware
    /// leitet daraus den Fortschritt bis zum Reset ab. Copilot liefert
    /// grundsätzlich keine, Cursor je nach Plan.
    pub fn default_window_minutes(self, index: usize) -> u32 {
        match self {
            Provider::Claude | Provider::Codex | Provider::Antigravity => {
                if index == 0 {
                    300
                } else {
                    10080
                }
            }
            Provider::Gemini => 1440,
            Provider::Copilot | Provider::Cursor => 43200,
        }
    }
}

impl FromStr for Provider {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|p| p.key() == s)
            .ok_or(())
    }
}

impl fmt::Display for Provider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.key())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_case_and_whitespace() {
        assert_eq!(Provider::normalized("  Gemini\n"), Provider::Gemini);
        assert_eq!(Provider::normalized("unbekannt"), Provider::Claude);
        assert_eq!(Provider::normalized(""), Provider::Claude);
    }

    #[test]
    fn serde_uses_lowercase_keys() {
        let json = serde_json::to_string(&Provider::Copilot).unwrap();
        assert_eq!(json, "\"copilot\"");
        let back: Provider = serde_json::from_str("\"cursor\"").unwrap();
        assert_eq!(back, Provider::Cursor);
    }

    #[test]
    fn window_defaults_follow_mac_app() {
        assert_eq!(Provider::Claude.default_window_minutes(0), 300);
        assert_eq!(Provider::Claude.default_window_minutes(2), 10080);
        assert_eq!(Provider::Gemini.default_window_minutes(1), 1440);
        assert_eq!(Provider::Copilot.default_window_minutes(0), 43200);
        assert_eq!(Provider::Cursor.default_row_title(5), "Window");
        assert_eq!(Provider::Gemini.default_row_title(3), "Model");
    }
}
