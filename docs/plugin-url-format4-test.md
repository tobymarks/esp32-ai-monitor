# Configurable plugin URL preview: validation

Date: 2026-10-13. Base: upstream PR #25 (`4cb7e744`), which includes #23/#24.
Windows preview: 1.4.3-beta.1. Package contract: format 4; formats 1–3 retained.
No firmware changes belong to this URL extension.

## Automated and live checks

- 119 Rust tests passed across core, plugin store/host, serial, and flash crates,
  including endpoint persistence, rejected stale responses, invalid inputs,
  location requirements, format gates, and inherited list/UTF-8 behavior.
- TypeScript and Vite production builds passed.
- Weather 1.5.0 and Claude Status 1.2.0 rendered live HTTPS data and fixtures
  in portrait, landscape, and square, with both themes and both locales.
- 84 service-status attention/render checks passed for operational, degraded,
  major, critical, maintenance, missing, and unknown states.
- Published Weather 1.1.0/1.2.0/1.3.0/1.4.0 and Claude Status 1.1.0 packages
  were accepted by the new host.
- Native firmware scene validation and LVGL rendering passed for both plugins
  at 240x320, 320x240, and 480x480.
- A temporary Linux-local HTTPS source was rejected with an untrusted CA and
  accepted using platform trust for both plugins. No certificate verification
  bypass or Windows trust-store change was used.
- The Windows helper fetched both live sources; an unreachable configured
  source failed, and the restored source succeeded.

## Connected ESP

COM5, ILI9341 CYD, firmware 2.23.0-beta.1, scene protocol 1. German dark/light
scenes for both plugins were ACKed (frames 4101–4104); the device's configured
landscape layout was ACKed for both (4201–4202). The operator confirmed that both
views were readable and that touch switching worked. The firmware was kept.

## Windows GUI and CI builds

- The production-mode Windows preview started with its embedded frontend.
- Importing Weather 1.5.0 over 1.4.0 preserved the configured city and
  coordinates. Claude Status 1.2.0 updated the installed 1.0.1 package.
- The generated Data URL fields were editable. HTTP was rejected on save;
  a different HTTPS origin was saved and displayed, including after restart.
- An unreachable configured source produced an error. Restoring the official
  Claude endpoint recovered live data. Changing the weather URL while retaining
  numeric coordinate placeholders produced a fresh successful fetch.
- [Mac bundle build](https://github.com/dlahmapollon/esp32-ai-monitor/actions/runs/38425907941)
  passed, including its bundled host smoke test.
- [Windows NSIS build](https://github.com/dlahmapollon/esp32-ai-monitor/actions/runs/38425912099)
  passed, including the installer smoke test.
- Both plugin repository CI workflows passed with the pinned format-4 host.

A Mac runtime/hardware test is unavailable on this Windows host. Physical S3
and scene-protocol-2 hardware tests were not performed for this URL extension.
The pre-test Windows configuration and installed plugins were backed up and
restored after validation; preview binaries and format-4 packages remain
available separately.
