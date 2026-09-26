# Write a display plugin

Display plugins add their own window to the Mac and Windows companions. The
companion fetches data and sends a bounded scene to the ESP32. A plugin does not
run code on the desktop or device, and installing one does not rebuild firmware.
Start from the [synthetic manifest](../tests/fixtures/display-plugin/plugin.json)
and its [response fixture](../tests/fixtures/display-plugin/response.json).

## Package and compatibility

An `.aimplugin` file is a ZIP with **exactly one entry** named `plugin.json` at
the archive root. The uncompressed UTF-8 manifest may be at most 64 KiB; the
whole ZIP may be at most 256 KiB. The test fixture demonstrates the format
without shipping a plugin with the companion.

Set `formatVersion` to `1`, `minSceneProtocol` to `1`, and `version` to three
numeric components such as `1.0.0`. The `id` is stable across updates, starts
with a lowercase letter, and contains at most 40 lowercase ASCII letters,
digits, dots, hyphens, or underscores. A changed ID creates a different plugin.
`name`, `author`, `description`, `viewLabel`, and optional `attribution` are
shown to users. Version 1 requires printable ASCII in metadata and display
text because the device font and wire validator currently use that subset.

Firmware reports `sceneProtocol: 1` through `get_info`. Older firmware cannot
display plugin windows. The companion keeps up to 20 installed plugins; the
window manager has eight slots and can place the same plugin in several slots.

## Data and settings

The required `source` object has an HTTPS `url` and `intervalSeconds` between
60 and 86400. It returns one JSON document of at most 64 KiB. Source requests
have a 12 second timeout and do not follow redirects. Authentication headers,
multiple sources, and executable transforms are outside format version 1.

Declare `settings` as an array, even when empty. Each setting has `key`,
`label`, `kind` (`number` or `text`), `default`, and optional `min` and `max`.
The settings UI is generated from this list. Only numeric settings may appear
as `{key}` placeholders in the source URL; the URL's HTTPS origin must remain
fixed. Text settings can still supply labels in the scene. Keep secrets out of
the manifest and URL: version 1 has no secret store.

Declare `bindings` as an array. A binding reads a dotted JSON path such as
`current.temperature_2m` or an array index such as
`daily.temperature_2m_max.0`. `settings.city` reads a setting. Its `format` is
`text`, `integer`, `decimal1`, or `map`; `suffix`, `map`, and `fallback` control
the displayed result. A missing field uses the fallback. Formatted results
must fit 64 printable ASCII characters.

## Layouts

`scenes.portrait` and `scenes.landscape` are required. `scenes.square` is
optional and falls back to portrait on the square S3 panel. Each layout has a
decimal RGB `background` from 0 to 16777215 and up to 24 `nodes`. Coordinates
`x`, `y`, `w`, and `h` use a 0–1000 grid relative to the display; each node
must fit inside it. A rendered scene may be at most 1536 JSON bytes.

Every node has `type`, geometry, and decimal RGB `color`. Supported types are
`text`, `rect`, `circle`, and `bar`. Text nodes add `text`, optional `font`
(`12`, `14`, `16`, `20`, `24`, `36`, or `48`), and optional `align` (`left`,
`center`, `right`). Insert a formatted binding with `{{binding_name}}`.
A `visibleWhen` object can show a node only when a binding's formatted value
equals a specified string. Text is clipped to its box on the device.

A bar has `trackColor` and either a fixed integer `value` from 0 to 100 or a
`valueBinding`. A dynamic bar's binding must use `integer`, have an empty
suffix, and have a fallback from 0 to 100. Its current result must also be a
whole number in that range. The [test fixture](../tests/fixtures/display-plugin/plugin.json)
uses a synthetic level to demonstrate this. The desktop resolves bindings and
conditions before sending the scene; firmware validates the resolved result.

## Build, validate, and publish

From the repository root, package any manifest with the standard library:

```sh
python3 scripts/package_display_plugin.py path/to/plugin.json path/to/my-plugin.aimplugin
```

The packer creates a deterministic ZIP. It only checks JSON syntax; validate
the full contract with the same helper used by the Mac app:

```sh
cargo run --quiet --manifest-path companion-windows/Cargo.toml \
  -p aimonitor-plugin-host -- inspect path/to/my-plugin.aimplugin
cargo run --quiet --manifest-path companion-windows/Cargo.toml \
  -p aimonitor-plugin-host -- render path/to/my-plugin.aimplugin - all path/to/response.json
```

`render` accepts a local JSON response fixture, so layout changes can be
checked without calling the live API. Also test a live request by omitting the
fixture path. Inspect the rendered nodes for all three layouts, then install
the package from **Plugins** and place it in **Window Manager**. A screenshot
or device run is needed to check readability; JSON validation cannot prove it.

Publish the `.aimplugin` as a GitHub release asset or another direct HTTPS
download. Paste that URL into the Plugins tab; a repository page URL is not a
package download. The manager checks the SHA-256 between preview and install,
but format version 1 has no author signature. Show source attribution in the
scene and package metadata when the data provider requires it.
