# Display-plugin acceptance test

The repository contains synthetic [legacy](../tests/fixtures/display-plugin/plugin.json),
[format-3](../tests/fixtures/display-plugin-format3/plugin.json), and
[format-4 URL](../tests/fixtures/display-plugin-url/plugin.json) manifests with
JSON responses for contract tests. Their `example.org` URLs are deliberately
not live services. No display plugin is shipped with the companion or flashed
onto the ESP32.

## Automated checks

1. Run `cargo test --workspace --locked` from `companion-windows`. This covers
   manifest and archive validation, scene generation, settings persistence, updates,
   rejected stale fetches, location changes, list transformations, protocol-1
   text adaptation, and error scenes. The format-4 URL fixture is rendered in
   all three layouts; URL-default migration, custom URL preservation, recovery
   of valid settings, and interrupted package updates have regression tests.
   Run `pnpm install --frozen-lockfile` and `pnpm build` for the Windows frontend.
2. Build the ILI9341 firmware once to install the pinned ArduinoJson and LVGL
   dependencies. Then run `bash scripts/test_display_plugin_scene_contract.sh`
   from the repository root. It packages the legacy and format-3 fixtures and
   renders portrait, landscape, and square scenes through the plugin host.
   It checks location text, filtered and sorted lists, scaling, optional rows,
   empty results, and protocol-1 adaptation before checking firmware scene
   acceptance and drawing with the native LVGL renderer at 240x320, 320x240,
   and 480x480. Set `AIMONITOR_SCENE_OUTPUT_DIR` to keep the generated PPM images
   for visual inspection.
3. Run the Mac, Windows, and firmware build workflows on the feature branch.
   The Mac workflow must start the bundled plugin host from the finished app
   and render the fixture. The Windows workflow builds and smoke tests its
   installer. Firmware builds must pass for ILI9341, ST7789, and ST7701.

## Manual checks with a separately installed live plugin

Use an independently published `.aimplugin` with a working HTTPS JSON source.
Use firmware that reports `"sceneProtocol":2` through `get_info` for the full
character set, and separately repeat the compatibility checks with protocol 1.
Record the exact app versions, firmware version, board, orientation, language,
plugin version, and result for each run. The checks below are an acceptance
procedure, not a claim that hardware or GUI testing has been completed.

1. Inspect and install the package first from a file, then from its direct
   HTTPS GitHub release asset. Confirm name, author, data origin, SHA-256, and
   unsigned state are visible before installation. A changed package between
   inspection and installation must be rejected.
2. Place the plugin in the window manager on both Mac and Windows. Verify
   portrait, both CYD landscape modes, and the S3 square layout on available
   hardware. Check the actual display for readable content, clipping, colors,
   and attribution where required. Rotate through views with touch, then use
   automatic switching. Built-in AI and clock views must still work.
3. Change a plugin setting that affects its data request and verify the next
   frame changes. Disconnect the network and trigger a refresh: the plugin
   slot must show an error. Reconnect and verify recovery. Leave the app
   disconnected long enough to check its stale-data state.
4. Restart the companion and power cycle the display. Confirm plugin settings,
   window assignments, and switching mode survive. Update the plugin and
   confirm settings and placement remain. Remove it and confirm its assigned
   windows become clocks.
5. Try invalid ZIP files, extra ZIP entries, HTTP links, invalid settings, and
   altered packages; each must be rejected. Connect firmware without
   `sceneProtocol` and assign a plugin window to verify the companion warns
   that updated firmware is needed. Protocol-1 firmware remains supported.

Compiler passes, scene ACKs, and native rendering do not prove physical panel
output, touch behavior, or USB timing. Record those results before release.

## Display location and asynchronous searches (formats 3 and 4)

Use a plugin with `requires: ["location"]` and a controlled HTTPS source that
can log requested coordinates and delay responses.

1. With no location set, assign the plugin and verify its location hint appears
   without any data-source request. Set a location by search, then by explicit
   coordinates. Check the displayed name and the three-decimal coordinates sent
   to the source. Confirm the install preview and plugin list name the origin
   receiving the location.
2. Change the location while an earlier data request is pending. The previous
   response must not replace data for the new location. Remove the location:
   old data must disappear, the hint must return, and subsequent fetches must
   stop. Restart and confirm the stored location survives.
3. Switch between two displays with different locations, then connect a new
   display. Each existing display must retain its own location; the new display
   must not inherit one. Data and intelligent-switch baselines must follow the
   selected location.
4. On Windows, begin an address search and change its input before it finishes.
   Search for a second place and let the first request finish last. Only the
   latest results or error may appear; an older completion must not end the
   current loading state. Repeat with an error from the first request.
5. While a Windows search is pending, switch displays, change the app language,
   edit coordinates, save or remove a location, and navigate away from the
   Display page. Delayed results and errors must not reappear for the new
   context. Verify a new search can start immediately after editing the input
   or switching displays.

## Lists, conversion, and text compatibility

1. Feed a format-3 or format-4 plugin an unsorted array containing matching,
   filtered-out, and missing entries. Verify ordering, the requested item
   limit, the count of matching entries before that limit, numeric `scale`,
   and text `trim`. Rows hidden with `visibleWhen.notEquals` must disappear
   when their entry is absent and return when data becomes available again.
2. Configure the minimum 20-second interval and inspect request timestamps.
   The companion checks due plugins every five seconds; requests must not be
   sent more frequently than the declared interval. Check intelligent-switch
   behavior against list-derived values without repeatedly triggering on
   unchanged samples.
3. On protocol-2 firmware, display `FLÜGE`, `München`, `Straße`, and `12 °C` in
   all supported layouts and both themes. Inspect the actual panel for missing
   glyphs, clipped lines, and legibility; a serial ACK alone is insufficient.
4. Reconnect protocol-1 firmware with the same plugin. Verify `FLUEGE`,
   `Muenchen`, `Strasse`, and `12 C` are transmitted and accepted. Switching
   back to protocol 2 must restore the original characters without reinstalling
   the plugin. Check that long labels stay inside the 64-byte scene-text limit.
5. Repeat installation and rendering with existing format-1 and format-2
   plugins to confirm their metadata, settings, language, and layouts still
   behave as before.

## Configurable URL acceptance (format 4)

The additional [URL fixture](../tests/fixtures/display-plugin-url/plugin.json)
uses `source.urlSetting`. Package it with `scripts/package_display_plugin.py`
and inspect/render it through the plugin host with its `response.json`.

For a plugin upgraded from an earlier format to format 4, verify importing
preserves valid settings and window placement. Save a valid alternate HTTPS
data URL with surrounding spaces or a trailing newline: the UI must trim them,
update its source-origin label immediately, and retain the custom URL after
restart and package update. Numeric and location placeholders must still update
the request URL.

Update a package whose default URL changes. An unchanged URL must follow the
new default; an explicit custom URL must remain. Repeat with a full settings
file written by an older app. In a disposable profile, replace only the saved
URL with an invalid one: startup must restore that setting's default while
retaining valid labels and coordinates.

Invalid HTTP, credentials, fragments, unknown placeholders, non-numeric
placeholders, and substitutions that change the origin must be rejected before
saving, with a localized error in German and English. Internationalized host
names must be entered as Punycode. A failed fetch must show an error scene;
restoring the source must recover. Change the URL while a fetch is pending and
verify the old response cannot replace the new source's data.

A temporary private CA test should reject the endpoint before trust is added
and succeed with platform trust. Do this in an isolated test environment.
Do not disable certificate verification. Record the connected ESP's scene
protocol and ACKs separately from physical readability and touch observations.
