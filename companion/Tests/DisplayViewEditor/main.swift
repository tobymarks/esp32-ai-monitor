// Executable without AppKit; run scripts/test_mac_view_editor.sh.
var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

var state = DisplayViewEditorState(contents: ["claude"], activeIndex: 0, selectedIndex: 0)
state.add(clock: "clock", limit: 8)
expect(state.contents == ["claude", "clock"], "Add a clock window")
expect(state.selectedIndex == 1 && state.activeIndex == 0, "Add selects for editing without switching the display")
for _ in 0..<10 { state.add(clock: "clock", limit: 8) }
expect(state.contents.count == 8 && state.selectedIndex == 7, "Window limit and selection remain valid")
state.remove(at: 0)
expect(state.contents.count == 8 && state.contents[0] == "claude", "Window 1 cannot be removed")
state.remove(at: -1)
state.remove(at: 8)
expect(state.contents.count == 8, "Out-of-range removal is ignored")

state = DisplayViewEditorState(contents: ["claude", "clock", "codex", "plugin:weather"],
                               activeIndex: 3, selectedIndex: 2)
state.remove(at: 1)
expect(state.contents == ["claude", "codex", "plugin:weather"], "Remove only the requested window")
expect(state.activeIndex == 2 && state.selectedIndex == 1, "Keep active and edited contents after an earlier deletion")
expect(state.contents[state.activeIndex] == "plugin:weather" && state.contents[state.selectedIndex] == "codex",
       "The same sources remain displayed and selected")
state.remove(at: 2)
expect(state.activeIndex == 0 && state.selectedIndex == 1, "Removing the active window returns the display to window 1")
state.remove(at: 1)
expect(state.contents == ["claude"] && state.activeIndex == 0 && state.selectedIndex == 0,
       "Removing the edited last window selects its predecessor")

state = DisplayViewEditorState(contents: ["claude", "clock", "codex"], activeIndex: 0, selectedIndex: 2)
state.assign("plugin:weather", to: 1, available: ["claude", "clock", "codex", "plugin:weather"])
expect(state.contents == ["claude", "plugin:weather", "codex"], "A drop assigns a plugin to its target")
expect(state.selectedIndex == 1 && state.activeIndex == 0, "Dropping on another tile selects it without displaying it")
state.assign("unknown", to: 0, available: ["claude", "clock", "codex"])
state.assign("clock", to: -1, available: ["clock"])
state.assign("clock", to: 3, available: ["clock"])
expect(state.contents == ["claude", "plugin:weather", "codex"] && state.selectedIndex == 1,
       "Unknown contents and invalid destinations do not change saved windows")
state.show(2)
expect(state.activeIndex == 2 && state.selectedIndex == 1, "Show changes the display without changing the editing selection")
state.assign("claude", to: 2, available: ["claude", "codex"])
expect(state.activeIndex == 2 && state.contents[state.activeIndex] == "claude",
       "Replacing the active content keeps its window active")
state.show(-1)
state.show(3)
expect(state.activeIndex == 2, "Invalid Show targets are ignored")

var selection = DisplayViewEditorSelection()
selection.update(count: 0, active: 2, deviceID: nil)
selection.update(count: 4, active: 2, deviceID: "device-a")
expect(selection.index == 2, "Initial data selects the active window, even after an empty update")
selection.select(1, count: 4)
selection.update(count: 4, active: 3, deviceID: "device-a")
expect(selection.index == 1, "Live active-window changes preserve the editing selection")
selection.update(count: 4, active: 3, deviceID: nil)
selection.update(count: 4, active: 3, deviceID: "device-a")
expect(selection.index == 1, "Disconnect and reconnect to the same device preserve editing selection")
selection.update(count: 4, active: 3, deviceID: "device-b")
expect(selection.index == 3, "A different device starts from its active window")
selection.update(count: 2, active: 0, deviceID: "device-b")
expect(selection.index == 1, "Shorter window lists keep the selection in range")
selection.select(-1, count: 2)
selection.select(2, count: 2)
expect(selection.index == 1, "Invalid selections are ignored")
selection.reset()
selection.update(count: 3, active: 0, deviceID: "device-b")
expect(selection.index == 0, "Reopening starts from the currently active window")
selection.reset()
selection.update(count: 3, active: 99, deviceID: "device-b")
expect(selection.index == 2, "An oversized active index is clamped")
selection.reset()
selection.update(count: 3, active: -1, deviceID: "device-b")
expect(selection.index == 0, "A negative active index is clamped")
selection.update(count: 0, active: 1, deviceID: "device-b")
expect(selection.index == 0, "Empty contents have a safe selection")
selection.update(count: 3, active: 1, deviceID: "device-b")
expect(selection.index == 1, "New contents after an empty list initialize from the active window")

state = DisplayViewEditorState(contents: ["claude", "plugin:missing", "clock"],
                               activeIndex: 1, selectedIndex: 2)
state.assign("plugin:missing", to: 2, available: ["claude", "clock", "plugin:installed"])
expect(state.contents == ["claude", "plugin:missing", "clock"] && state.selectedIndex == 2 && state.activeIndex == 1,
       "An unavailable plugin stays assigned but cannot be newly assigned")
state.assign("plugin:installed", to: 1, available: ["claude", "clock"])
expect(state.contents[1] == "plugin:missing" && state.selectedIndex == 2,
       "A plugin removed between drop and deferred assignment is rejected")
state.assign("clock", to: 1, available: ["claude", "clock"])
expect(state.contents[1] == "clock" && state.selectedIndex == 1 && state.activeIndex == 1,
       "A missing plugin can be replaced without changing the active window")

selection.reset()
selection.select(2, count: 3)
selection.update(count: 3, active: 0, deviceID: "device-b")
expect(selection.index == 2, "A user selection after reset survives the next update")
print("Display view editor: \(checks) checks passed")
