# Display plugins without a computer

Implementation proposal for [issue #5](https://github.com/tobymarks/esp32-ai-monitor/issues/5),
checked against the integrated plugin-format-4 code on 14 November 2026.
**Not implemented:** current firmware fetches no plugin data over Wi-Fi. This
document does not add a capability flag, enable network requests, or change
the existing USB and standby-clock behavior.

## What is already available

- The companion validates manifests, resolves settings and display location,
  performs HTTPS requests, evaluates bindings/lists, and renders scenes in
  `companion-windows/crates/core/src/plugin.rs` and `crates/plugin-store`.
  Both desktop applications use this Rust implementation.
- `src/plugin_scene.cpp` validates and retains rendered scenes, not manifests:
  at most eight slots, 24 nodes and 1,536 serialized bytes per scene. Scene
  protocol 2 supports printable ASCII, German umlauts and the degree sign.
- `src/wifi_time.cpp` already manages Wi-Fi and NTP. It deliberately starts
  the radio only when credentials exist. Plugin sources must never receive
  those credentials.
- `src/serial_receiver.cpp` owns window assignments and host activity. Valid
  data expires after five minutes; `standby` relinquishes host activity
  immediately. `src/ui_dashboard.cpp` uses that activity to select the clock.
  The firmware therefore needs an explicit display-owner abstraction before
  standalone scenes can work reliably.

The S3 warning in the original issue is historical. `board_persists_config()`
returns true for the S3, and firmware 2.21.0 restored persistence using PSRAM
XIP and IRAM-safe RGB handling. The [September hardware
tests](../hardware-test/esp32s3-4848s040/README.md) recorded zero glitches during
combined NVS writes and Wi-Fi scans. That result does **not** measure sustained
HTTPS/TLS, filesystem writes and plugin rendering together. Espressif documents
both the cache requirement and remaining PSRAM-bandwidth constraints in its
[RGB LCD guide](https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/peripherals/lcd/rgb_lcd.html).

## First usable scope

Start with **one explicitly selected, credential-free plugin per display**.
Keep the normal eight-window USB configuration intact. After the companion
relinquishes the device, show the selected plugin or a status page; reconnecting
the companion restores the existing window configuration. The on-device
settings remain reachable. Multiple offline plugins and offline intelligent
switching are later extensions, not hidden promises of the first version.

The existing `.aimplugin` format remains the desktop package format. The shared
Rust helper exports a smaller, separately versioned **device profile** after
the same manifest/settings validation used for ordinary rendering. Export
resolves the actual HTTPS URL, location, language, theme and screen layout;
it excludes installation metadata, unused layouts and user settings that are
no longer needed at runtime. The ESP32 receives no ZIP and runs no downloaded
code. An existing format-1/2/3/4 package can qualify; its format number alone
does not imply that it fits the embedded subset.

Initial exported operations:

- Bounded dotted-path lookup, including explicit array indices.
- Text, integer, decimal1 and map bindings; fallback, suffix, scale and trim.
- The same text substitution, visibility conditions and four scene primitives
  as the desktop renderer.
- Resolved setting/location bindings as constants. Location names retain the
  scene protocol's character set; the source URL uses the existing
  three-decimal coordinate formatting.

Profiles using list selection or intelligent attention rules are rejected for
the initial embedded version with an explanation in the app; they continue
to work over USB. Implementing array sorting/filtering and its 500-entry host
contract is a later, separately budgeted step. Do not silently drop operations
or render a different meaning on the device. The first real acceptance targets
are small current-weather responses and a service-status endpoint.

## Proposed limits, to be measured before enabling the capability

These are implementation targets, not measured available heap or a claim that
existing plugins satisfy them.

| Resource | Initial target |
|---|---|
| Active standalone profiles | 1 |
| Serialized device profile | 8 KiB |
| Source URL | 2,048 printable ASCII bytes, existing URL rules |
| Source response | 8 KiB decoded body, at most 8 levels of JSON nesting |
| Bindings | 16, at most 8 path segments each |
| Scene | Existing 24 nodes / 1,536 bytes / 64-byte text limits |
| Concurrent requests | 1 |
| Refresh interval | At least 60 seconds, explicitly shown in the app |
| Request deadline | 12 seconds total, including connection and body |
| Failed-request retry | 60, 120, 240, 480, then 900 seconds with bounded jitter |
| Completed-result queue | 1 scene/status result plus configuration generation |

Format 3/4 packages may request a 20-second interval on the desktop. The export
preview must disclose the effective 60-second embedded minimum. If this makes
the plugin unsuitable, leave it USB-only rather than claiming parity.

The worker must bound actual bytes read, including chunked responses, rather
than trusting `Content-Length`. Request `identity` encoding and reject
unsupported compression. Reject incomplete JSON, trailing non-whitespace,
excess nesting and allocation failures without replacing a good scene. Use a
budgeted ArduinoJson allocator and release the response/document before
starting another request. A small body does not by itself bound JSON heap:
measure and cap parsed-node allocations too. TLS allocation, task stack,
largest contiguous internal block and minimum free internal heap require
measurement on both CYDs, not an estimate based on S3 PSRAM.

Network/TLS/JSON work belongs in a low-priority worker. Only the main loop may
call LVGL or replace scene-cache entries. A result carries the profile and
ownership generation; the main loop drops it after any profile edit, removal,
host takeover, layout change or Wi-Fi reset. Never hold a display lock while
waiting for DNS, TLS or an HTTP body.

## HTTPS and clock behavior

Use the same HTTPS-only URL policy as the desktop: no userinfo, fragment,
redirect, cookie persistence, authentication headers or executable transform.
URLs and profile files are not secret storage. Do not print full URLs or
response bodies in device diagnostics. The desktop must describe the exact
source origin and whether a stored location will be sent before export.

The desktop's operating-system root store cannot be copied implicitly to the
device. Ship a maintained public CA bundle with firmware and verify the server
chain, hostname and validity period. Endpoints relying on a corporate/local CA
remain USB-only in this first version; do not fall back to insecure TLS. CA
import, if added later, needs its own explicit per-device workflow. Espressif's
[HTTP client documentation](https://docs.espressif.com/projects/esp-idf/en/v5.0/esp32/api-reference/protocols/esp_http_client.html)
describes certificate bundles and streaming reads; bundle availability and
the cancellation/deadline behavior must be verified on the project's Arduino
core 2.x **and** 3.x builds.

After cold boot, wait for a usable UTC clock from NTP or the companion before
TLS. The existing `CLOCK_VALID_EPOCH` check is only a plausibility floor, not
proof of recent synchronization. Track the clock source and successful sync
in RAM; show `Waiting for time` when none is available. Do not advance the
clock from an unauthenticated HTTP `Date` header or disable certificate checks
to bootstrap it. Clock changes must not alter scheduling or data age: those
use wrap-safe monotonic timestamps.

## Host and standalone ownership

Introduce a small, testable owner/state machine independent of the serial
parser and LVGL:

| Condition | Display behavior |
|---|---|
| No enabled profile | Existing USB/standby-clock behavior |
| Boot with enabled valid profile | Load profile; show Wi-Fi/time/loading status |
| Valid companion configuration/data arrives | USB owns display; invalidate standalone results |
| Companion sends `standby` | Activate standalone immediately |
| Companion disappears without `standby` | Activate after the existing five-minute host timeout |
| Standalone request succeeds | Render validated scene and record successful-update time |
| Request fails after a success | Keep prior scene; visibly mark stale state and age |
| Request fails before any success | Show an explanatory status instead of an empty scene |
| Companion reconnects during a request | USB wins; cancel request where possible and always discard its result |
| Profile is disabled/removed | Cancel work, clear its cache and restore clock/USB behavior |

`get_info` and diagnostic queries must not claim display ownership. Standalone
refreshes must never update `last_host_frame_ms`, and stale plugin data must
never be reported as fresh AI usage. The owner holds a separate offline
selection; it must not overwrite the user's persisted USB window assignments.
Unplug/replug, clean quit, app crashes, old companions and invalid/partial
serial frames all belong in the state-machine tests.

## Transfer, persistence and recovery

Advertise a new `standaloneProtocol: 1` capability only after the implementation
and board-specific acceptance gates pass. Keep `sceneProtocol` separate. Old
firmware simply lacks standalone capability; old companions continue to work
with new firmware and do not automatically install or enable profiles.

Use bounded, acknowledged begin/chunk/commit/abort commands over the existing
AIM1 transport. Each frame stays below 4,095 bytes including its JSON envelope.
The transfer contains a random transaction ID, byte length and SHA-256;
sequence/offset validation rejects gaps, duplicates with changed bytes,
oversize input and conflicting transactions. Expire abandoned staging state.
Validate the entire profile and budgets again on the firmware before activation.
Treat SHA-256 as integrity checking, not publisher authentication.

Do not place two 8 KiB profiles in the shared 20 KiB NVS partition: it also
holds existing settings and Wi-Fi credentials. Prefer two versioned records
in the existing filesystem partition, without changing partition offsets or
OTA sizes. Inspect both board partition tables and available space first.
Mount without automatic formatting; a mount failure must leave USB and NVS
configuration usable. Initialization of unused storage is an explicit setup
operation, never a side effect of boot or plugin refresh.

Write the inactive record on an explicit save, flush/close it, then read it
back and validate length, digest, generation and schema before reporting
success. At boot select the newest valid committed record; a truncated newer
record cannot mask an older valid one. Test interruption at every write and
commit boundary. A filesystem corruption may still make both records
unavailable; handle this as `Profile unavailable`, not a boot loop. Do not
claim transactional durability until the chosen filesystem passes the fault
tests. No periodic source response, render cache or last-fetch time is written
to flash.

The first version may save while the S3 RGB panel runs only under the current
validated XIP/IRAM configuration and after combined HTTPS/display/write tests.
For an older or alternate board configuration lacking that guarantee, disable
profile persistence capability or implement an explicit boot-before-display
maintenance mode. Merely delaying a write until "idle" does not make it safe.
Load persisted profile metadata before scheduling network work; a successful
profile parse must never turn a previously disabled feature on.

## Companion flow

Each device's Display page gets a separate `Use without computer` setting.
The preview names the selected plugin, source origin, location disclosure,
effective interval and any unsupported operation. The user saves a snapshot
of this device's configuration; an installed plugin update or a location edit
marks it out of date instead of silently changing the offline endpoint.
An explicit resync updates it atomically. Theme/orientation/language changes
also require re-export because the first profile contains one resolved scene
template. While disconnected, the app may prepare changes but must not show
them as installed. Readback reports profile identity/version/digest, enabled
state, effective interval, error category and last-success age, never secrets.

## Implementation sequence and completion gates

1. **Export contract and parity harness:** shared Rust export command, strict
   device-profile validator, bounded C++ evaluator runnable natively. Compare
   its scenes with the existing Rust renderer for map/fallback/scale/trim,
   missing values, rounding, UTF-8 boundaries, both themes and all layouts.
   Unsupported manifests fail export without changing installed state.
2. **Firmware runtime:** tested ownership state machine, bounded worker and
   trusted HTTPS on all three firmware targets. Inject fake clock/network
   outcomes for deterministic cancellation, backoff, byte-limit and stale-age
   tests. Existing USB behavior remains the default.
3. **Persistence and transfer:** explicit filesystem setup, bounded upload,
   validation/readback and power-loss recovery. Preserve existing device/Wi-Fi
   settings and partition layouts; malformed transfers cannot enable a profile.
4. **Mac and Windows integration:** shared export via the existing helper/core,
   per-device preview/save/remove/readback, capability gating and localized
   errors. Verify old firmware and old-companion reconnection behavior.
5. **Physical acceptance before release:** current weather and service status
   from cold boot on wall power; no Wi-Fi, no NTP, bad/expired/wrong-host
   certificates, 3xx, slow/chunked/oversize/invalid JSON responses; repeated
   USB takeover during fetch; power cuts during install; 24-hour refresh and
   touch run on ILI9341, ST7789 and S3. Record minimum internal heap, worker
   stack margin, resets, request count and S3 frame-glitch deltas.

Current result: architecture and acceptance work are specified; steps 1–5 are
still implementation work. No standalone runtime, persistence path or device
test is claimed by this document. A disconnected-clock feature is not a
substitute for standalone plugin data.
