# Display-plugin acceptance test

The repository contains a synthetic [manifest](../tests/fixtures/display-plugin/plugin.json)
and [JSON response](../tests/fixtures/display-plugin/response.json) for contract
tests. The fixture's `example.org` URL is deliberately not a live service. No
display plugin is shipped with the companion or flashed onto the ESP32.

## Automated checks

1. Run `cargo test --locked -p aimonitor-core -p aimonitor-plugin-store
   -p aimonitor-plugin-host` from `companion-windows`. This covers manifest and
   archive validation, scene generation, settings persistence, updates,
   rejected stale fetches, and error scenes.
2. Build the ILI9341 firmware once to install the pinned ArduinoJson and LVGL
   dependencies. Then run `bash scripts/test_display_plugin_scene_contract.sh`
   from the repository root. It packages the synthetic fixture, renders its
   portrait, landscape, and square scenes through the plugin host, checks
   firmware scene acceptance, and draws them with the native LVGL renderer at
   240x320, 320x240, and 480x480. Set `AIMONITOR_SCENE_OUTPUT_DIR` to keep the
   generated PPM images for visual inspection.
3. Run the Mac, Windows, and firmware build workflows on the feature branch.
   The Mac workflow must start the bundled plugin host from the finished app
   and render the fixture. The Windows workflow builds and smoke tests its
   installer. Firmware builds must pass for ILI9341, ST7789, and ST7701.

## Manual checks with a separately installed live plugin

Use an independently published `.aimplugin` with a working HTTPS JSON source.
Flash firmware that reports `"sceneProtocol":1` through `get_info` before
placing plugin windows.

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
   altered packages; each must be rejected. Connect old firmware and assign a
   plugin window to verify the companion warns that updated firmware is needed.

Compiler passes, scene ACKs, and native rendering do not prove physical panel
output, touch behavior, or USB timing. Record those results before release.
