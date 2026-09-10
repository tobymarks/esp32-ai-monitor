//! Handshake und Testframe gegen ein echtes Gerät.
//!
//!   cargo run -p aimonitor-serial --example probe -- [PORT] [--frame] [--brightness N]
//!
//! Ohne PORT wird der erste Kandidat mit bekanntem Chip genommen. `--frame`
//! schickt den Diagnose-Testframe und wartet auf das ACK. Die Mac-App muss
//! dafür beendet sein, sie hält den Port sonst.

use aimonitor_core::envelope::{diagnostic_envelope, FrameContext};
use aimonitor_core::protocol::{Command, GET_INFO_TIMEOUT};
use aimonitor_core::Provider;
use aimonitor_serial::{list_ports, Link};
use chrono::{Local, Utc};
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let want_frame = args.iter().any(|a| a == "--frame");
    let brightness = args
        .iter()
        .position(|a| a == "--brightness")
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse::<i64>().ok());
    let manual = args.iter().find(|a| !a.starts_with("--") && Some(a.as_str()) != brightness.map(|_| "").as_deref() && a.parse::<i64>().is_err());

    let ports = list_ports();
    println!("Kandidaten:");
    for p in &ports {
        println!("  {:<32} {:04X?}:{:04X?} {:<8} {}", p.name, p.vid, p.pid, p.chip.unwrap_or("-"), p.product.as_deref().unwrap_or(""));
    }
    let Some(port) = aimonitor_serial::ports::choose_port(&ports, manual.map(String::as_str)) else {
        eprintln!("kein Port gefunden");
        std::process::exit(1);
    };
    println!("\nÖffne {} …", port.name);
    let started = Instant::now();
    let mut link = match Link::open(&port.name) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    match link.handshake(GET_INFO_TIMEOUT) {
        Ok(info) => {
            println!("info nach {:?}: {}", started.elapsed(), serde_json::to_string_pretty(&info).unwrap());
            println!("framed={} ack={} preview={} max={}", info.supports_framed(), info.supports_ack(), info.supports_brightness_preview(), info.max_frame_bytes());

            if let Some(b) = brightness {
                link.send_command(&Command::set_brightness(b, true)).unwrap();
                println!("set_brightness {b} gesendet");
            }

            if want_frame {
                let offset = Local::now().offset().local_minus_utc() / 60;
                let ctx = FrameContext::new(Utc::now(), offset, false);
                let payload = diagnostic_envelope(Provider::Claude, &ctx, 1);
                let t = Instant::now();
                let receipt = link.send_frame(&payload, 1, info.supports_framed(), info.max_frame_bytes()).unwrap();
                println!("frame ({} Bytes) -> {:?} nach {:?}", payload.len(), receipt, t.elapsed());
            }
        }
        Err(e) => {
            eprintln!("Handshake fehlgeschlagen: {e}");
            for l in &link.log {
                eprintln!("  {l}");
            }
            std::process::exit(3);
        }
    }
    if !link.log.is_empty() {
        println!("\nWeitere Gerätezeilen:");
        for l in &link.log {
            println!("  {l}");
        }
    }
}
