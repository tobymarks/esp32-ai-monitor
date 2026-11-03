/**
 * Pure editing operations shared by the native editor actions. The window
 * selected for editing is independent of the active window on the display.
 */
struct DisplayViewEditorState {
    var contents: [String]
    var activeIndex: Int
    var selectedIndex: Int

    mutating func add(clock: String, limit: Int) {
        guard contents.count < limit else { return }
        selectedIndex = contents.count
        contents.append(clock)
    }

    mutating func remove(at index: Int) {
        // Window 1 remains present, including when it is the only window.
        guard index > 0, contents.indices.contains(index) else { return }
        contents.remove(at: index)
        if activeIndex == index { activeIndex = 0 }
        else if activeIndex > index { activeIndex -= 1 }
        if selectedIndex == index { selectedIndex = index - 1 }
        else if selectedIndex > index { selectedIndex -= 1 }
    }

    mutating func assign(_ content: String, to index: Int, available: [String]) {
        guard contents.indices.contains(index), available.contains(content) else { return }
        contents[index] = content
        selectedIndex = index
    }

    mutating func show(_ index: Int) {
        guard contents.indices.contains(index) else { return }
        activeIndex = index
    }
}
