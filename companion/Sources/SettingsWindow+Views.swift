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
        return [Settings.clockView] + CodexBarProvider.allCases.map(\.rawValue)
            + Array(Set(installed + assigned)).sorted()
    }

    func buildViewsStepContent() -> [NSView] {
        viewsListStack = NSStackView()
        viewsListStack.orientation = .vertical
        viewsListStack.alignment = .leading
        viewsListStack.spacing = 6

        viewsAddButton = NSButton(title: L("views.add"), target: self, action: #selector(addDisplayView))
        viewsAddButton.bezelStyle = .rounded

        viewsModePopup = NSPopUpButton()
        viewsModePopup.addItems(withTitles: [L("views.manual"), L("views.automatic")])
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

        viewsFirmwareHint = NSTextField(wrappingLabelWithString: L("views.firmware"))
        viewsFirmwareHint.font = NSFont.appFont(.subheadline)
        viewsFirmwareHint.textColor = .systemOrange

        updateViewsSection(force: true)
        return [viewsListStack, viewsAddButton, modeRow, viewsIntervalRow, viewsFirmwareHint]
    }

    /// Baut die Fensterzeilen nur neu, wenn sich Liste, Auswahl oder Modus
    /// geändert haben — sonst würde jedes `update()` offene Menüs schließen.
    func updateViewsSection(force: Bool = false) {
        guard viewsListStack != nil else { return }
        let settings = Settings.shared
        viewsModePopup.selectItem(at: settings.displayViewsAutomatic ? 1 : 0)
        viewsIntervalRow.isHidden = !settings.displayViewsAutomatic
        if viewsIntervalField.currentEditor() == nil {
            viewsIntervalField.integerValue = settings.displayViewInterval
        }
        viewsAddButton.isEnabled = settings.displayViews.count < Settings.maxDisplayViews
        let lacksWindows = monitor?.connectedFirmwareLacksViews ?? false
        let lacksScenes = settings.displayViews.contains(where: { DisplayPlugins.id(from: $0) != nil })
            && (monitor?.connectedFirmwareLacksPluginScenes ?? false)
        viewsFirmwareHint.stringValue = lacksScenes ? L("plugins.firmware") : L("views.firmware")
        viewsFirmwareHint.isHidden = !lacksWindows && !lacksScenes

        let signature = "\(settings.displayViews)|\(settings.activeDisplayView)|\(settings.displayViewsAutomatic)|\(DisplayPlugins.shared.records.keys.sorted())"
        guard force || signature != viewsSignature else { return }
        viewsSignature = signature
        viewsListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, content) in settings.displayViews.enumerated() {
            let shown = !settings.displayViewsAutomatic && index == settings.activeDisplayView
            viewsListStack.addArrangedSubview(buildDisplayViewRow(index: index, content: content, shown: shown))
        }
    }

    private func displayViewTitle(_ content: String) -> String {
        if content == Settings.clockView { return L("views.clock") }
        if let id = DisplayPlugins.id(from: content) {
            return DisplayPlugins.shared.records[id] == nil
                ? L("plugins.missing", id) : DisplayPlugins.shared.label(for: content)
        }
        return CodexBarProvider.normalized(content).displayLabel
    }

    private func buildDisplayViewRow(index: Int, content: String, shown: Bool) -> NSView {
        let label = NSTextField(labelWithString: L("views.window", index + 1))
        label.font = NSFont.appFont(.body, weight: shown ? .semibold : .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let popup = NSPopUpButton()
        popup.addItems(withTitles: viewContents.map(displayViewTitle))
        popup.selectItem(at: viewContents.firstIndex(of: content) ?? 0)
        popup.tag = index
        popup.target = self
        popup.action = #selector(displayViewContentChosen(_:))
        popup.setAccessibilityLabel(L("views.window", index + 1))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        var views: [NSView] = [label, popup]
        // Im manuellen Modus wählt „Anzeigen" das Fenster auf dem Display.
        if !Settings.shared.displayViewsAutomatic {
            if shown {
                let current = NSTextField(labelWithString: L("views.active"))
                current.font = NSFont.appFont(.subheadline)
                current.textColor = .secondaryLabelColor
                views.append(current)
            } else {
                let show = NSButton(title: L("views.show"), target: self, action: #selector(showDisplayView(_:)))
                show.bezelStyle = .rounded
                show.controlSize = .small
                show.tag = index
                views.append(show)
            }
        }
        // Fenster 1 bleibt immer bestehen.
        if index > 0 {
            let remove = NSButton(title: L("views.remove"), target: self, action: #selector(removeDisplayView(_:)))
            remove.bezelStyle = .rounded
            remove.controlSize = .small
            remove.tag = index
            remove.setAccessibilityLabel(L("views.remove.a11y", index + 1))
            views.append(remove)
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// Asynchron, weil die Änderung die Zeilen neu aufbaut — auch die, deren
    /// Control gerade seine Aktion auslöst.
    private func applyDisplayViews(_ views: [String], active: Int? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.monitor?.updateDisplayViews(views, active: active)
        }
    }

    @objc private func addDisplayView() {
        var views = Settings.shared.displayViews
        guard views.count < Settings.maxDisplayViews else { return }
        views.append(Settings.clockView)
        applyDisplayViews(views)
    }

    @objc private func removeDisplayView(_ sender: NSButton) {
        var views = Settings.shared.displayViews
        let index = sender.tag
        guard index > 0, index < views.count else { return }
        views.remove(at: index)
        var active = Settings.shared.activeDisplayView
        if active == index { active = 0 } else if active > index { active -= 1 }
        applyDisplayViews(views, active: active)
    }

    @objc private func displayViewContentChosen(_ sender: NSPopUpButton) {
        var views = Settings.shared.displayViews
        let index = sender.tag
        guard index < views.count, sender.indexOfSelectedItem >= 0 else { return }
        guard sender.indexOfSelectedItem < viewContents.count else { return }
        views[index] = viewContents[sender.indexOfSelectedItem]
        applyDisplayViews(views)
    }

    @objc private func showDisplayView(_ sender: NSButton) {
        applyDisplayViews(Settings.shared.displayViews, active: sender.tag)
    }

    @objc private func displayViewModeChosen() {
        let automatic = viewsModePopup.indexOfSelectedItem == 1
        let entered = viewsIntervalField.integerValue
        let interval = entered > 0 ? entered : Settings.shared.displayViewInterval
        DispatchQueue.main.async { [weak self] in
            self?.monitor?.setDisplayViewMode(automatic: automatic, interval: interval)
        }
    }
}
