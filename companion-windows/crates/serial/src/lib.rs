//! aimonitor-serial: die eigentliche USB-Serial-Verbindung zur CYD.
//!
//! - [`ports`]: Kandidaten finden, nach USB-Chip filtern, sortieren
//! - [`link`]: Port öffnen (Rezept aus Spec 9.1), Zeilen lesen, Handshake,
//!   Datenframes mit ACK, Kommandos mit Antwort
//!
//! Die Zustandsmaschine (Scan, Reconnect, Debounce, Heartbeat) liegt in der
//! App, damit dieses Crate synchron und ohne Threads bleibt.

pub mod link;
pub mod ports;

pub use link::{FrameReceipt, Link, LinkError};
pub use ports::{list_ports, PortCandidate};
