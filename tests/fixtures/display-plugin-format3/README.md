# Format 3 display contract fixture

Synthetic aircraft data for `scripts/test_display_plugin_scene_contract.sh`.
The `example.org` source is never fetched. The helper receives a local response
and the display location Köln through its real command-line interface.

The checks cover the complete package → helper → firmware parser → LVGL path:

- Location bindings override a conflicting source field.
- Lists discard ground traffic, missing callsigns, and slow aircraft, sort by
  distance, and keep two entries while reporting all four matching entries.
- Callsigns are trimmed and altitude is converted from feet to metres.
- A missing second entry hides its row; an empty list shows fallback text and
  clears the attention rule.
- All supported German characters and the degree sign reach scene protocol 2.
  Protocol 1 receives printable ASCII transliteration with identical geometry.
- Every case is parsed and rendered at 240×320, 320×240, and 480×480.

Set `AIMONITOR_SCENE_OUTPUT_DIR` to retain the rendered PPM files. The legacy
fixture stays at the output root; format 3 cases have named subdirectories.
These native checks do not replace tests on physical panels.
