//! Firmware-Image auf ein echtes Gerät schreiben.
//!
//!   cargo run -p aimonitor-flash --example flash -- <PORT> <IMAGE.bin>
//!
//! Die Mac-App muss beendet sein, sie hält den Port sonst.

use aimonitor_flash::{flash_image, FlashEvent, TargetChip, FLASH_BAUD};
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(port), Some(path)) = (args.first(), args.get(1)) else {
        eprintln!("Aufruf: flash <PORT> <IMAGE.bin>");
        std::process::exit(1);
    };
    let image = std::fs::read(path).unwrap_or_else(|e| {
        eprintln!("{path}: {e}");
        std::process::exit(1);
    });
    // Beim S3 liegt der Bootloader an 0x0, beim ESP32 an 0x1000.
    let chip = if image.first() == Some(&0xE9) { TargetChip::Esp32S3 } else { TargetChip::Esp32 };
    println!("{} Bytes -> {port} @ {FLASH_BAUD} ({chip:?})", image.len());
    let started = Instant::now();
    let mut last_percent = None;
    let result = flash_image(port, &image, FLASH_BAUD, chip, &mut |ev| match &ev {
        FlashEvent::Writing { .. } => {
            let p = ev.percent();
            if p != last_percent && p.map(|v| v % 10 == 0).unwrap_or(false) {
                println!("  {:>6.1?}  write {}%", started.elapsed(), p.unwrap());
                last_percent = p;
            }
        }
        other => println!("  {:>6.1?}  {other:?}", started.elapsed()),
    });
    match result {
        Ok(()) => println!("fertig nach {:?}", started.elapsed()),
        Err(e) => {
            eprintln!("Fehler: {e}");
            std::process::exit(2);
        }
    }
}
