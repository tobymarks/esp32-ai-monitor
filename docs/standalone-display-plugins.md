# Display plugins without a computer

The development implementation for [issue #5](https://github.com/tobymarks/esp32-ai-monitor/issues/5)
adds one explicitly selected, credential-free HTTPS display plugin per device.
It is experimental software, **not a hardware-qualified release**. No version
numbers or release artifacts have been changed. Existing AI usage still comes
from USB; standalone plugins never receive account or Wi-Fi credentials.

## Using the feature

Both companions have a separate **Use without computer** section on the Display
page. Connect firmware advertising `standaloneProtocol: 1`, select an installed
plugin, and review its source origin, location disclosure and effective refresh
interval. Installation is an explicit action: normal plugin installation,
updates and USB polling do not install an offline profile.

If the filesystem is unused, **Set up storage** explicitly initializes it. Boot
never formats storage. This setup may erase an unreadable filesystem; it does
not change NVS, Wi-Fi credentials, partition offsets or OTA partitions. The
companion explains this before the action. A mounted filesystem is never
reformatted by setup. Then save the selected snapshot. Success requires device
commit acknowledgement and matching digest/enabled-state readback.

The snapshot contains the resolved location, settings, language, theme and one
layout. Select the same plugin to compare the current export with the installed
digest; changes require explicit resync. Device layout/theme/language changes
stop the old profile until a matching snapshot is installed. Disable and remove
are separate controls. Disconnected preparation is not reported as installation;
older firmware has no standalone controls enabled.

Configure Wi-Fi using the existing per-device Wi-Fi page. After a clean companion
quit (`standby`) standalone takes over immediately. After a cable pull or app
crash it takes over when the existing five-minute USB activity lease expires.
Valid USB data or a valid `set_views` restores USB ownership immediately.
`get_info`, readback and other diagnostic queries do not claim the display.
The offline scene has separate storage and never overwrites any of the eight
USB window assignments. Long-press settings remain available.

## Supported plugin subset

The existing `.aimplugin` remains the desktop format. Formats 1–4 can qualify
according to operations, rather than format number. The shared Rust exporter
validates the manifest/settings and produces a separate protocol-1 profile:

- Dotted paths with explicit array indices, up to eight segments.
- Text, integer, decimal1 and map bindings, fallback, suffix, scale and trim.
- Text substitution and visibility conditions, including localization of maps
  and fallbacks without changing condition comparisons.
- Text, bar, rectangle and circle primitives and scene protocol 2's ASCII,
  German umlaut and degree-sign alphabet.
- Resolved setting/location bindings as constants; source location coordinates
  use the same three-decimal URL formatting as ordinary host rendering.

Lists and attention rules are rejected with an explanation; they remain usable
through USB. There is no downloaded executable code, ZIP extraction on the
board, authentication, custom CA import or automatic export of user plugins.
Public source fixtures live in `tests/fixtures/standalone-weather` (small current
Open-Meteo fields) and `tests/fixtures/standalone-status` (Statuspage-shaped data).
Their responses are deterministic test inputs, not claims of live network tests.

The shared helper command is:

```sh
aimonitor-plugin-host export-standalone PACKAGE.aimplugin SETTINGS.json portrait \
  --theme=dark --locale=en
```

Use `-` for default settings, `landscape`/`square` for the other layouts and the
existing `--location=...` option for a location-dependent plugin. Output includes
the exact profile string, SHA-256, identity, origin and effective interval.

## Enforced budgets and HTTPS behavior

| Resource | Limit |
|---|---|
| Enabled standalone profiles | 1 |
| Profile / decoded response | 8,192 bytes each |
| Parsed JSON | 8 nesting levels; 28 KiB per budgeted document, including allocator headers |
| Bindings / map entries | 16 / 32 per map |
| Source URL | 2,048 printable ASCII bytes, HTTPS port 443, DNS hostname |
| Scene | 24 nodes, 1,536 serialized bytes, 64 UTF-8 bytes per text |
| Concurrent requests / completion queue | 1 / 1 |
| Refresh interval | 60–86,400 seconds; export discloses the 60-second floor |
| Network deadline | 12 seconds for async DNS, TLS, request and response |
| Transfer chunk / staging lifetime | 1,024 bytes / 60 seconds of inactivity |

One low-priority worker performs DNS, TLS, HTTP and JSON evaluation. It never
calls LVGL. Generation checks invalidate results after USB takeover, profile
changes, configuration changes and Wi-Fi resets. The main loop alone replaces
the offline scene. Scheduling and age use wrap-safe monotonic time.

TLS uses ESP-IDF's firmware-bundled public roots, peer verification and the
original hostname for SNI and certificate checks. It never calls `setInsecure`.
Arduino core 2's similarly named custom-bundle wrapper is deliberately bypassed;
it does not initialize the IDF default roots. CA updates require updating the
pinned SDK/firmware; local/corporate trust stores are not imported. A RAM-only
NTP callback or successfully applied companion clock update is required before
TLS. A plausible retained RTC value alone does not open the gate.

DNS resolution currently uses IPv4. The streaming HTTP decoder accepts a 200 response with fixed-length, chunked
or connection-close framing. It caps actual bytes and framing metadata, rejects
redirects, compression, chunk extensions, conflicting framing and incomplete
responses. No cookies
or authorization headers are sent. Common secret-bearing query names, userinfo
and fragments are rejected; opaque secrets cannot be inferred from arbitrary
path names, so the product explicitly requires public credential-free sources.
URLs and response bodies are not printed in diagnostics.

Failures retry after 60, 120, 240, 480 and then 900 seconds plus bounded jitter.
Before the first successful response, the display shows a waiting/error status.
After a success it retains the previous scene and visibly marks stale data and
its age. A configuration mismatch clears the incompatible scene. Readback gives
identity/version/digest, enabled state, interval, state, last error and successful
update age; no source bodies, settings or credentials.

## Transfer and persistence

AIM1-framed commands are `standalone_status`, `standalone_setup`,
`standalone_begin`, `standalone_chunk`, `standalone_commit`, `standalone_abort`,
`standalone_enabled` and `standalone_remove`. Companions send UTF-8-safe chunks
of at most 512 bytes, leaving room for JSON escaping below the 4,095-byte frame
limit. ACKs correlate command, transaction and resulting offset. Firmware
rejects gaps, changed duplicates, overflows, expired and conflicting transfers.
SHA-256 checks transfer integrity, not publisher authenticity.

Two versioned records live in LittleFS on the existing `spiffs` partition
(128 KiB on CYD, 3.375 MiB on S3). The record digest covers generation, enabled
flag, length and profile. An explicit save writes the inactive record, flushes,
adds its commit marker, closes, rereads and validates it before acknowledging.
Boot selects the newest valid committed record. Removal writes a newer disabled
tombstone so an older profile cannot reappear after reboot. No refresh result,
scene, successful-update time or polling counter is written to flash.

S3 configuration persistence has been available since 2.21 through PSRAM XIP
and IRAM-safe RGB handling; old no-flash comments in the issue are obsolete.
That earlier evidence does not qualify this new combined filesystem/TLS/display
workload. Filesystem redundancy offers recovery from partial records, not a
claim of immunity to filesystem corruption or hardware power-loss durability.

## Software validation and remaining hardware gates

Reproducible checks:

```sh
cargo test --workspace --locked --manifest-path companion-windows/Cargo.toml
bash scripts/test_display_owner_native.sh
bash scripts/test_standalone_bounds_native.sh
bash scripts/test_standalone_transfer_native.sh
bash scripts/test_standalone_http_native.sh
bash scripts/test_standalone_record_native.sh
bash scripts/test_standalone_policy_native.sh
bash scripts/test_standalone_contract.sh
bash scripts/test_display_plugin_scene_contract.sh
bash scripts/test_mac_view_editor.sh
python3 tests/standalone_mac_connection.py
```

The S3 custom-SDK build writes generated archives into PlatformIO's package
cache. Serialize firmware builds on a machine, or set task-specific
`PLATFORMIO_PACKAGES_DIR` and `IDF_COMPONENT_CACHE_PATH` directories when other
projects are building concurrently. Concurrent builds can corrupt shared SDK
archives; such linker failures do not establish a source-code defect.

The contract suite compares actual Rust desktop scenes and the native firmware
evaluator for both sources, all three layouts, both themes and languages,
missing/null values, visibility, maps, Unicode trim, UTF-8 boundaries and scaled
rounding. Malformed JSON/resource tests exercise the actual firmware parser,
allocator and renderer. HTTP tests fragment inputs and exercise chunk framing,
redirect/compression rejection and bounds. Transfer tests use the same staging
class as firmware. Record fault tests exercise every truncation boundary and
every-byte corruption against the production record codec, including disabled
records and removal tombstones (with an injected deterministic hash; firmware
uses SHA-256). Companion upload mocks cover framing, offset failures,
abort behavior and digest mismatch. Worker policy checks cover deadline boundaries, cancellation, ownership, timer
wraparound, retry saturation and jitter limits. The old scene/rendering checks
remain intact.

Validation run on 14 November 2026:

- Rust workspace: 163 tests passed, including four companion upload mocks.
- Host/firmware golden scenes: 408 comparisons passed with ASan/UBSan,
  including original JSON number bytes and canonicalized source URLs.
- Native bounds: 125 checks; HTTP framing: 137 checks; record recovery: 33,136
  checks; worker deadline/cancellation/backoff: 100,046 checks. Transfer and
  USB lease tests passed, including wraparound and changed duplicate chunks.
- Existing scene contract: 15 native rendered scenes passed. Mac editor state:
  31 checks passed. The committed standalone React harness passed eight scenarios;
  the earlier temporary location harness also passed its eight scenarios.
- Five Mac command/reconnect checks execute the production methods with a mock
  transport, covering queued mutations and descriptor lifetime. All six website
  screenshots render with the optional offline runtime disabled.
- Frontend production build and Mac arm64/x86_64 typechecks passed. English and
  German localization files passed validation.
- `esp32dev`, `esp32dev-st7789` and `esp32s3-4848s040` firmware builds passed.
  S3 required private SDK packages/component cache after shared-cache corruption
  during concurrent builds. Its final application uses 1,825,935 flash bytes and
  110,460 static RAM bytes. These are linker figures, **not runtime heap margins**.

**No serial ports, physical boards, installed applications, private plugin
settings, Wi-Fi credentials, preferences or keychain were accessed for this
implementation.** The supplied S3 baseline was firmware 2.23.0 with scene protocol
1 and no configured Wi-Fi. Physical protocol 2, CYD touch and Wi-Fi runtime
validation were unavailable during that implementation phase. Builds and mocks
cannot establish those results.

A subsequent [S3 hardware test on 14 November 2026](../hardware-test/esp32s3-4848s040/standalone-2026-11-14.md)
flashed commit `36edce5` after a verified full backup. It confirmed protocol-2
scene acceptance, profile transfer and rejection, persistence across commanded
reboots, removal, and USB ownership transitions without Wi-Fi. Actual panel
readability remains unconfirmed; Wi-Fi/TLS, interrupted writes, touch and
sustained operation are still hardware gates.

Before release, test all three boards from wall power with current weather and
service status; absent Wi-Fi/NTP; expired/wrong-host certificates; slow, chunked,
oversized and malformed responses; USB takeover during fetch; interrupted saves;
and a 24-hour refresh/touch run. Measure minimum internal heap, largest free
block, worker stack margin, resets and S3 frame glitches under simultaneous
HTTPS and explicit filesystem saves. No such physical acceptance is claimed.
