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

Set `formatVersion` to `1` for plugins without intelligent-switch rules or `2`
when using `attentionRules`. Each new manifest field after format 2 requires a
new format version. The existing `localizations` and `lightScenes` fields remain
valid in version 1 for compatibility with packages already published. New
companions check `formatVersion` before strict field validation, so a package
with a future version reports that it needs a newer AI Monitor app. Older
companions may still report an unknown field. Set `minSceneProtocol` to `1`
and `version` to three numeric components such as `1.0.0`. The `id` is stable across updates, starts
with a lowercase letter, and contains at most 40 lowercase ASCII letters,
digits, dots, hyphens, or underscores. A changed ID creates a different plugin.
IDs starting with `builtin.` are reserved for built-in windows such as the
[Claude Code window](claude-code-window.md).
`name`, `author`, `description`, `viewLabel`, and optional `attribution` are
shown to users. Version 1 requires printable ASCII in metadata and display
text because the device font and wire validator currently use that subset.

An optional `localizations` object maps locale codes to exact translations of
author-supplied strings. For example:

```json
"localizations": {
  "de": {
    "Weather": "Wetter",
    "HIGH / LOW": "HOCH / TIEF",
    "Humidity {{humidity}}%": "Feuchte {{humidity}}%",
    "Clear sky": "Klarer Himmel"
  }
}
```

Keys are the original text from metadata, setting labels, scene text templates,
binding maps, or fallbacks. The companion selects the display language for
scenes and its UI language for plugin names and setting labels. Missing entries
use the original text. Keep `{{binding_name}}` placeholders in translated scene
templates. `visibleWhen.equals` is compared with the binding's original
formatted value, so a condition need not be duplicated per language. Map
values and text fallbacks are translated for display; numeric fallbacks remain
numeric so they can still drive bars. Non-numeric fallbacks for numeric bindings
can be translated. Translated metadata and setting labels must fit the same
length limits as their originals. Localized display text remains printable
ASCII with the current scene protocol. Companions released before this
extension reject packages containing `localizations`.

Release compatibility note: Unknown `{{...}}` placeholders now cause plugin
installation or startup loading to fail for every package, including packages
without `localizations`. Earlier companions accepted those packages; a node
using the unknown placeholder made the whole plugin view show a render error
when that node was visible. Existing packages with such placeholders must be
corrected and reinstalled before they
load in this version.

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

## Optional intelligent-switch triggers

A format version 2 plugin may declare up to 16 `attentionRules` in `plugin.json`. Each rule
reads a scalar value from the fetched source JSON. Its `id` is stable across
plugin updates; `path` uses the same dotted JSON path syntax as bindings.
Supported `operator` values are `equals`, `atLeast`, and `atMost`.
`value` is a string, number, or boolean for `equals`; the other operators
require a number. Example:

```json
"attentionRules": [
  {"id": "rain-soon", "path": "forecast.rainNext30Minutes",
   "operator": "equals", "value": true},
  {"id": "severe-warning", "path": "alerts.severity",
   "operator": "atLeast", "value": 2}
]
```

The desktop companion observes the first successful fetch as a baseline. It
requests a window switch only when a rule changes from false to true on a later
successful fetch. Repeated true values, failed fetches, missing fields, and
scene redraws do not trigger a switch. The global intelligent-switch policy
applies its minimum dwell, per-window cooldown, and touch hold. Plugins without
`attentionRules` remain fully compatible and do not request switches. The
firmware and scene protocol are unchanged.

## Layouts

`scenes.portrait` and `scenes.landscape` are required. `scenes.square` is
optional and falls back to portrait on the square S3 panel. Each layout has a
decimal RGB `background` from 0 to 16777215 and up to 24 `nodes`. Coordinates
`x`, `y`, `w`, and `h` use a 0–1000 grid relative to the display; each node
must fit inside it. A rendered scene may be at most 1536 JSON bytes.

The required `scenes` are the dark/default appearance. An optional
`lightScenes` object has the same portrait, landscape, and optional square
layout structure. When the device profile resolves to light mode, the
companion renders `lightScenes`; without it, existing plugins continue to use
`scenes`. This also works when the profile follows the operating system theme.
Keep every light layout within the same node, text, coordinate, and frame
limits. The companion uses matching light colors for loading and error scenes.
Companions released before this extension reject manifests containing
`lightScenes`.

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
cargo run --quiet --manifest-path companion-windows/Cargo.toml \
  -p aimonitor-plugin-host -- render path/to/my-plugin.aimplugin - all path/to/response.json --locale=de
cargo run --quiet --manifest-path companion-windows/Cargo.toml \
  -p aimonitor-plugin-host -- render path/to/my-plugin.aimplugin - all path/to/response.json --theme=light --locale=de
```

The optional `--theme=dark|light` and `--locale=<code>` flags can appear in either order, before or after the positional arguments.
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
