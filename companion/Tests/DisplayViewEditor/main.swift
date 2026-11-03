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
print("Display view editor: \(checks) checks passed")
