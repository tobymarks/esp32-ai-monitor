# Display plugins: architecture

This document specifies the intended public contract for independently
installable display views. A plugin is an installable **view**, not an AI
provider. The companion ships without a third-party display plugin.

## Ownership and lifecycle

- The desktop companion owns plugin installation, configuration, network access,
  data refresh, and validation. The ESP32 receives render data over the existing
  USB connection. It never receives API credentials.
- Installed plugin views appear alongside the clock and built-in providers in
  the window manager. A view can occupy any of the eight slots, including more
  than one slot. Manual and timed switching work exactly as for built-in views.
- A missing or failing plugin keeps its window slot and shows a clear
  placeholder. It must never silently become another view.
- Plugins use stable IDs such as `org.example.status`. Removing a plugin must
  explicitly resolve or retain its existing window assignments.
- Firmware advertises a scene protocol capability. Older firmware cannot show
  plugin views. The window manager warns when a connected device needs the
  updated firmware.

## Rendering contract

The firmware implements a bounded scene renderer. A plugin sends a scene for a
specific window index, composed of validated primitives (text, rectangles,
circles, and bars). Each
scene can have independent portrait, landscape, and square layouts. Square
falls back to portrait when a plugin does not provide one. The host may refresh data
without reinstalling or reflashing the plugin.

Scene messages use a distinct schema version and are ACKed like existing data
frames. Window selection and scene content are separate: `set_views` assigns a
stable plugin view ID to each slot; scene frames address a slot by `viewIndex`.
The firmware bounds primitive count, text length, coordinates, colors, and
payload size before mutating the visible scene. Assets require chunked upload
and explicit storage budgets; they are outside the first protocol version.
The existing AI dashboard and clock remain native firmware screens.

This contract deliberately does not promise arbitrary ESP32 code. A plugin
needing new device peripherals or unbounded drawing instructions requires a
firmware extension or a custom firmware build. The desktop can eventually
offer an advanced host-rendered bitmap surface, with lower refresh rates due
to USB bandwidth.

## Package contract

An installable `.aimplugin` is a ZIP archive containing a UTF-8 `plugin.json`
manifest and no other entries. The manifest includes a format version,
stable plugin ID, human-readable name and author, plugin version, minimum scene
protocol version, view name, configuration schema, HTTPS source URL, bindings,
and portrait/landscape scene templates with an optional square template. Import by file and download by HTTPS
URL share one validator. GitHub users can link to a release asset; arbitrary
repository URLs are not implicitly executed or built.

The initial transform is declarative and network-only. Each plugin can request
one JSON response from an explicit HTTPS URL, use numeric settings in that URL,
select JSON fields, format text values, and choose scene nodes by conditions.
It does not yet combine multiple APIs, handle OAuth, load images, or run custom
code. A future executable-plugin API needs a process or runtime
isolation design and a separate trust decision. Schema validation alone does
not make executable code safe.

Installation checks archive size, expanded manifest size, path traversal, file
count, manifest schema, scene protocol compatibility, ID conflicts, and scene
budgets. Files are staged and activated with a backup for updates.
Updates preserve configuration and window assignments; failed updates restore
the prior version. Remote downloads use HTTPS and a bounded response size.

Version 1 packages are unsigned. Both apps show this explicitly and compare
the package SHA-256 between inspection and installation. That checksum catches
a changed package but does not establish publisher identity. Optional publisher
signatures can be added in a later package version: they would authenticate
package bytes and continuity on update, not guarantee code safety. Unsigned
local hobby plugins should remain installable with a clear trust decision.

## Contract fixture

The [synthetic fixture](../tests/fixtures/display-plugin/plugin.json) exercises
settings, JSON bindings, conditional nodes, bars, and all three panel layouts.
It is test data with an example URL and is never installed automatically or
used as a live data source. A real plugin can be published separately as an
`.aimplugin` package without changing this repository's firmware.

## Acceptance evidence

Before calling the system ready, verify: package import by file and URL;
malformed and hostile package rejection; Mac and Windows window placement and
restart persistence; scene rendering in portrait, landscape, and square; touch and timed
switching; a live plugin's success, offline, and stale states; old-firmware behavior;
firmware builds for all three board environments; host builds and relevant tests; and a
real CYD hardware run. Record any verification that cannot run in the current
environment explicitly rather than treating a compiler pass as device proof.
