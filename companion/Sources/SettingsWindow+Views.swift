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

    /// Zuweisbar sind die Uhr, Provider, Claude Code und installierte Plugins.
    private var availableViewContents: [String] {
        let installed = DisplayPlugins.shared.records.keys.map { DisplayPlugins.prefix + $0 }
        return [Settings.clockView] + CodexBarProvider.allCases.map(\.rawValue) + [ClaudeCodeWindow.view]
            + Array(Set(installed).subtracting([ClaudeCodeWindow.view])).sorted()
    }

    /// Fehlende Plugins bleiben für die Beschriftung bestehender Fenster bekannt.
    private var viewItems: [DisplayViewEditorItem] {
        let available = availableViewContents
        let missing = Set(Settings.shared.displayViews).subtracting(available).sorted()
        return (available + missing).map { content in
            displayViewItem(content, isAvailable: available.contains(content))
        }
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

        updateViewsSection()
        return [viewsEditor, modeRow, viewsIntervalRow, viewsIntelligentHint, viewsFirmwareHint]
    }

    /// Der Editor baut Controls nur bei geänderten Inhalten neu auf. Regelmäßige
    /// Updates und Touch-Ereignisse erhalten dadurch Tastaturfokus und Drag-Quellen.
    func updateViewsSection() {
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
        viewsEditor.update(contents: settings.displayViews, items: viewItems,
                           active: settings.activeDisplayView, mode: settings.displayViewMode,
                           deviceID: DeviceRegistry.shared.currentMAC)
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

    private func displayViewItem(_ content: String, isAvailable: Bool) -> DisplayViewEditorItem {
        let symbol: String
        switch content {
        case Settings.clockView: symbol = "clock"
        case "claude": symbol = "asterisk"
        case "codex": symbol = "circle.dotted"
        case "antigravity": symbol = "sparkles"
        case "gemini": symbol = "sparkle"
        case "copilot": symbol = "diamond.fill"
        case "cursor": symbol = "hexagon"
        case ClaudeCodeWindow.view: symbol = "terminal"
        default: symbol = "puzzlepiece.extension"
        }
        return DisplayViewEditorItem(content: content, title: displayViewTitle(content), symbol: symbol, isAvailable: isAvailable)
    }

    /// Änderungen erst nach Abschluss des Klicks/Drops ausführen und dabei die
    /// aktuellen Einstellungen lesen, damit keine veralteten Daten gespeichert werden.
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
            state.assign(content, to: index, available: self?.availableViewContents ?? [])
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
