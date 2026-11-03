/**
 * SettingsWindow+Views.swift — Fensterverwaltung im Display-Tab (ab v1.30.0).
 *
 * Mehrere Display-Fenster, jedes mit einer Datenquelle oder der Uhr. Das
 * Display wechselt per Touch (links zurück, rechts weiter) oder automatisch
 * nach der eingestellten Anzeigedauer. Gegenstück zu ViewManager.tsx der
 * Windows-App; braucht Firmware ab 2.19.0.
 */

import Cocoa

extension SettingsWindowController {

    /// Inhalte, die ein Fenster zeigen kann: die Uhr und jeder Provider.
    private var viewContents: [String] {
        let installed = DisplayPlugins.shared.records.keys.map { DisplayPlugins.prefix + $0 }
        let assigned = Settings.shared.displayViews.filter { DisplayPlugins.id(from: $0) != nil }
        return [Settings.clockView] + CodexBarProvider.allCases.map(\.rawValue) + [ClaudeCodeWindow.view]
            + Array(Set(installed + assigned).subtracting([ClaudeCodeWindow.view])).sorted()
    }

    func buildViewsStepContent() -> [NSView] {
        viewsEditor = DisplayViewEditor(frame: .zero)
        viewsEditor.onAssign = { [weak self] index, content in self?.assignDisplayView(index, content: content) }
        viewsEditor.onAdd = { [weak self] in self?.addDisplayView() }
        viewsEditor.onRemove = { [weak self] index in self?.removeDisplayView(index) }
        viewsEditor.onShow = { [weak self] index in self?.showDisplayView(index) }

        viewsModePopup = NSPopUpButton()
        viewsModePopup.addItems(withTitles: [L("views.manual"), L("views.automatic"), L("views.intelligent")])
        viewsModePopup.target = self
        viewsModePopup.action = #selector(displayViewModeChosen)
        let modeRow = twoColumnRow(L("views.switch"), viewsModePopup)

        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 2
        formatter.maximum = 3600
        viewsIntervalField = NSTextField(string: "\(Settings.shared.displayViewInterval)")
        viewsIntervalField.formatter = formatter
        viewsIntervalField.alignment = .right
        viewsIntervalField.target = self
        viewsIntervalField.action = #selector(displayViewModeChosen)
        viewsIntervalField.translatesAutoresizingMaskIntoConstraints = false
        viewsIntervalField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let secondsLabel = NSTextField(labelWithString: L("views.seconds"))
        secondsLabel.font = NSFont.appFont(.body)
        let intervalControls = NSStackView(views: [viewsIntervalField, secondsLabel])
        intervalControls.orientation = .horizontal
        intervalControls.spacing = 6
        viewsIntervalRow = twoColumnRow(L("views.interval"), intervalControls)

        viewsIntelligentHint = NSTextField(wrappingLabelWithString: L("views.intelligent.hint"))
        viewsIntelligentHint.font = NSFont.appFont(.subheadline)
        viewsIntelligentHint.textColor = .secondaryLabelColor

        viewsFirmwareHint = NSTextField(wrappingLabelWithString: L("views.firmware"))
        viewsFirmwareHint.font = NSFont.appFont(.subheadline)
        viewsFirmwareHint.textColor = .systemOrange

        updateViewsSection(force: true)
        return [viewsEditor, modeRow, viewsIntervalRow, viewsIntelligentHint, viewsFirmwareHint]
    }

    /// The editor compares its contents before rebuilding controls. Periodic
    /// updates and touch events therefore keep keyboard focus and drag sources.
    func updateViewsSection(force _: Bool = false) {
        guard viewsEditor != nil else { return }
        let settings = Settings.shared
        viewsModePopup.selectItem(at: ["manual", "automatic", "intelligent"].firstIndex(of: settings.displayViewMode) ?? 0)
        viewsIntervalRow.isHidden = settings.displayViewMode != "automatic"
        viewsIntelligentHint.isHidden = settings.displayViewMode != "intelligent"
        if viewsIntervalField.currentEditor() == nil {
            viewsIntervalField.integerValue = settings.displayViewInterval
        }
        let lacksWindows = monitor?.connectedFirmwareLacksViews ?? false
        let lacksScenes = settings.displayViews.contains(where: { DisplayPlugins.id(from: $0) != nil })
            && (monitor?.connectedFirmwareLacksPluginScenes ?? false)
        viewsFirmwareHint.stringValue = lacksScenes ? L("plugins.firmware") : L("views.firmware")
        viewsFirmwareHint.isHidden = !lacksWindows && !lacksScenes
        viewsEditor.update(contents: settings.displayViews, items: viewContents.map(displayViewItem),
                           active: settings.activeDisplayView, mode: settings.displayViewMode)
    }

    private func displayViewTitle(_ content: String) -> String {
        if content == Settings.clockView { return L("views.clock") }
        if content == ClaudeCodeWindow.view { return ClaudeCodeWindow.label }
        if let id = DisplayPlugins.id(from: content) {
            return DisplayPlugins.shared.records[id] == nil
                ? L("plugins.missing", id) : DisplayPlugins.shared.label(for: content)
        }
        return CodexBarProvider.normalized(content).displayLabel
    }

    private func displayViewItem(_ content: String) -> DisplayViewEditorItem {
        let glyph: String
        let symbol: String
        switch content {
        case Settings.clockView: glyph = "◷"; symbol = "clock"
        case "claude": glyph = "✳"; symbol = "asterisk"
        case "codex": glyph = "◎"; symbol = "circle.dotted"
        case "antigravity": glyph = "✦"; symbol = "sparkles"
        case "gemini": glyph = "✧"; symbol = "sparkle"
        case "copilot": glyph = "◆"; symbol = "diamond.fill"
        case "cursor": glyph = "⬡"; symbol = "hexagon"
        case ClaudeCodeWindow.view: glyph = "✳"; symbol = "terminal"
        default: glyph = "◇"; symbol = "puzzlepiece.extension"
        }
        return DisplayViewEditorItem(content: content, title: displayViewTitle(content), glyph: glyph, symbol: symbol)
    }

    /// Defer changes until the originating click/drop has finished, and read the
    /// latest settings inside that block rather than queuing stale snapshots.
    private func editDisplayViews(_ edit: @escaping (inout DisplayViewEditorState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let monitor = self.monitor else { return }
            let settings = Settings.shared
            var state = DisplayViewEditorState(contents: settings.displayViews,
                                               activeIndex: settings.activeDisplayView,
                                               selectedIndex: self.viewsEditor.selectedIndex)
            edit(&state)
            if state.contents != settings.displayViews || state.activeIndex != settings.activeDisplayView {
                monitor.updateDisplayViews(state.contents, active: state.activeIndex)
            }
            self.updateViewsSection()
            self.viewsEditor.selectWindow(state.selectedIndex)
        }
    }

    private func addDisplayView() {
        editDisplayViews { $0.add(clock: Settings.clockView, limit: Settings.maxDisplayViews) }
    }

    private func removeDisplayView(_ index: Int) {
        editDisplayViews { $0.remove(at: index) }
    }

    private func assignDisplayView(_ index: Int, content: String) {
        editDisplayViews { [weak self] state in
            state.assign(content, to: index, available: self?.viewContents ?? [])
        }
    }

    private func showDisplayView(_ index: Int) {
        editDisplayViews { state in
            guard Settings.shared.displayViewMode != "automatic" else { return }
            state.show(index)
        }
    }

    @objc private func displayViewModeChosen() {
        let mode = ["manual", "automatic", "intelligent"][max(0, viewsModePopup.indexOfSelectedItem)]
        let entered = viewsIntervalField.integerValue
        let interval = entered > 0 ? entered : Settings.shared.displayViewInterval
        DispatchQueue.main.async { [weak self] in
            self?.monitor?.setDisplayViewMode(mode, interval: interval)
        }
    }
}
