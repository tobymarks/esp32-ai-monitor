/**
 * SettingsWindow+Display.swift — Display-Tab des SettingsWindowController.
 *
 * Reine Code-Umschichtung aus SettingsWindow.swift (keine Funktionsänderung):
 * Display-Einrichtung in drei Schritten (Geräte-Zeile inkl. Inline-Edit,
 * Profil-Auswahl, Darstellung), zugehörige Update-Helfer, Zeitzonen-Popup und
 * alle Display-bezogenen Aktionen.
 */

import Cocoa

extension SettingsWindowController {

    func buildDisplayPage() -> NSView {
        return buildDisplayBox()
    }

    func buildDisplayBox() -> NSView {
        let heading = makeSectionHeading("Display einrichten")
        let intro = NSTextField(wrappingLabelWithString: "Stelle das verbundene Display in drei Schritten ein: Gerät erkennen, Darstellung wählen, Ergebnis prüfen.")
        intro.font = NSFont.systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        // Geräte-Zeile (ab v1.14.0)
        let deviceRowBuilt = buildDeviceRow()
        let deviceProfilesRow = buildDeviceProfilesRow()

        // Theme
        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: ["Automatisch (macOS)", "Dark", "Light"])
        themePopup.target = self
        themePopup.action = #selector(themeChosen)
        themePopup.toolTip = "Legt fest, ob das Display hell, dunkel oder passend zu macOS angezeigt wird."
        let themeRow = twoColumnRow("Theme", themePopup)

        // Prozent-Logik (global für alle Provider)
        percentModePopup = NSPopUpButton()
        percentModePopup.addItems(withTitles: [
            "Verbraucht (0 → 100)",
            "Verbleibend (100 → 0)"
        ])
        percentModePopup.target = self
        percentModePopup.action = #selector(percentModeChosen)
        percentModePopup.toolTip = "Wählt, ob Nutzung oder verbleibendes Kontingent angezeigt wird."
        percentModePopup.translatesAutoresizingMaskIntoConstraints = false
        percentModePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let percentModeRow = twoColumnRow("Prozentmodus", percentModePopup)

        // Orientation
        orientationPopup = NSPopUpButton()
        orientationPopup.addItems(withTitles: [
            "Hochformat",
            "Querformat (USB links)",
            "Querformat (USB rechts)"
        ])
        orientationPopup.target = self
        orientationPopup.action = #selector(orientationChosen)
        orientationPopup.toolTip = "Dreht die Anzeige passend zur USB-Position."
        let orientRow = twoColumnRow("Ausrichtung", orientationPopup)

        // Language
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Deutsch", "English"])
        languagePopup.target = self
        languagePopup.action = #selector(languageChosen)
        languagePopup.toolTip = "Sprache der Labels auf dem ESP32-Display."
        let langRow = twoColumnRow("Sprache", languagePopup)

        // TimeZone (v1.12.0) — steuert displayTime auf dem ESP32.
        timeZonePopup = NSPopUpButton()
        rebuildTimeZonePopup()
        timeZonePopup.target = self
        timeZonePopup.action = #selector(timeZoneChosen)
        timeZonePopup.toolTip = "Bestimmt Uhrzeit und Reset-Zeiten auf dem Display."
        timeZonePopup.translatesAutoresizingMaskIntoConstraints = false
        timeZonePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let tzRow = twoColumnRow("Zeitzone", timeZonePopup)

        // Brightness
        brightnessSlider = NSSlider(value: Double(Settings.shared.lastKnownBrightness),
                                    minValue: 5, maxValue: 100,
                                    target: self, action: #selector(brightnessChanged))
        brightnessSlider.toolTip = "Helligkeit des angeschlossenen Displays."
        brightnessSlider.isContinuous = true
        brightnessSlider.numberOfTickMarks = 0
        brightnessSlider.translatesAutoresizingMaskIntoConstraints = false
        brightnessSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        brightnessValueLabel = NSTextField(labelWithString: "\(Settings.shared.lastKnownBrightness) %")
        brightnessValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        brightnessValueLabel.textColor = .secondaryLabelColor
        brightnessValueLabel.translatesAutoresizingMaskIntoConstraints = false
        brightnessValueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        brightnessValueLabel.alignment = .right
        let brightControls = NSStackView(views: [brightnessSlider, brightnessValueLabel])
        brightControls.orientation = .horizontal
        brightControls.spacing = 8
        let brightRow = twoColumnRow("Helligkeit", brightControls)

        lastUpdateLabel = NSTextField(labelWithString: "Letztes Update an ESP32: —")
        lastUpdateLabel.font = NSFont.systemFont(ofSize: 11)
        lastUpdateLabel.textColor = .secondaryLabelColor

        let deviceStep = buildDisplaySetupStep(
            number: "1",
            title: "Display auswählen",
            detail: "Name und Profil helfen, mehrere Displays auseinanderzuhalten.",
            views: [deviceRowBuilt, deviceProfilesRow]
        )

        let appearanceRows = NSStackView(views: [
            orientRow,
            brightRow,
            themeRow,
            percentModeRow,
            langRow,
            tzRow
        ])
        appearanceRows.orientation = .vertical
        appearanceRows.alignment = .leading
        appearanceRows.spacing = 8

        let appearanceStep = buildDisplaySetupStep(
            number: "2",
            title: "Darstellung einstellen",
            detail: "Ausrichtung und Helligkeit sind die wichtigsten Werte. Alles wird direkt an das ESP32-Display gesendet.",
            views: [appearanceRows]
        )

        let testButton = NSButton(title: "Testbild senden", target: self, action: #selector(sendTestFrame))
        testButton.bezelStyle = .rounded
        testButton.toolTip = "Sendet einen Beispiel-Screen, um Ausrichtung, Helligkeit und Verbindung zu prüfen."
        displayTestButton = testButton

        let testHelper = NSTextField(wrappingLabelWithString: "Sende nach Änderungen ein Testbild. Wenn es falsch gedreht ist, ändere die Ausrichtung und teste erneut.")
        testHelper.font = NSFont.systemFont(ofSize: 11)
        testHelper.textColor = .secondaryLabelColor

        let testStep = buildDisplaySetupStep(
            number: "3",
            title: "Ergebnis prüfen",
            detail: "Das Testbild bestätigt, dass Darstellung und USB-Verbindung zusammenpassen.",
            views: [testButton, testHelper, lastUpdateLabel]
        )

        let stack = NSStackView(views: [heading, intro, deviceStep, appearanceStep, testStep])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    private func buildDisplaySetupStep(number: String,
                                       title: String,
                                       detail: String,
                                       views: [NSView]) -> NSView {
        let numberLabel = NSTextField(labelWithString: number)
        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        numberLabel.alignment = .center
        numberLabel.textColor = .white
        numberLabel.wantsLayer = true
        numberLabel.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        numberLabel.layer?.cornerRadius = 9
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.widthAnchor.constraint(equalToConstant: 18).isActive = true
        numberLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let header = NSStackView(views: [numberLabel, titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 620).isActive = true

        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8

        let stack = NSStackView(views: [header, detailLabel, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    /// Geräte-Zeile: „Gerät: <FriendlyName>   ✏️" mit Inline-Edit (Stift-Icon →
    /// NSTextField). Bei nicht-verbundenem ESP32: dimmed „Gerät: — (nicht
    /// verbunden)". Tooltip über dem Namen zeigt die MAC.
    private func buildDeviceRow() -> NSView {
        // --- Display-Container ---
        deviceNameLabel = NSTextField(labelWithString: "—")
        deviceNameLabel.font = NSFont.systemFont(ofSize: 13)
        deviceNameLabel.lineBreakMode = .byTruncatingTail
        deviceNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        deviceNameLabel.translatesAutoresizingMaskIntoConstraints = false

        deviceEditButton = NSButton()
        deviceEditButton.bezelStyle = .regularSquare
        deviceEditButton.isBordered = false
        deviceEditButton.title = "✏️"
        deviceEditButton.target = self
        deviceEditButton.action = #selector(beginDeviceNameEdit)
        deviceEditButton.setButtonType(.momentaryPushIn)
        deviceEditButton.font = NSFont.systemFont(ofSize: 13)
        deviceEditButton.toolTip = "Name ändern"
        deviceEditButton.translatesAutoresizingMaskIntoConstraints = false
        deviceEditButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let displayStack = NSStackView(views: [deviceNameLabel, deviceEditButton])
        displayStack.orientation = .horizontal
        displayStack.spacing = 6
        displayStack.alignment = .centerY
        deviceDisplayContainer = displayStack

        // --- Edit-Container (initial versteckt) ---
        deviceEditField = NSTextField()
        deviceEditField.placeholderString = "Gerätename"
        deviceEditField.font = NSFont.systemFont(ofSize: 13)
        deviceEditField.translatesAutoresizingMaskIntoConstraints = false
        deviceEditField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        deviceEditField.target = self
        deviceEditField.action = #selector(commitDeviceNameEdit)

        deviceEditSaveButton = NSButton(title: "Speichern", target: self, action: #selector(commitDeviceNameEdit))
        deviceEditSaveButton.bezelStyle = .rounded
        deviceEditSaveButton.keyEquivalent = "\r"

        deviceEditCancelButton = NSButton(title: "Abbrechen", target: self, action: #selector(cancelDeviceNameEdit))
        deviceEditCancelButton.bezelStyle = .rounded
        deviceEditCancelButton.keyEquivalent = "\u{1B}" // Escape

        let editStack = NSStackView(views: [deviceEditField, deviceEditSaveButton, deviceEditCancelButton])
        editStack.orientation = .horizontal
        editStack.spacing = 6
        editStack.alignment = .centerY
        deviceEditContainer = editStack
        deviceEditContainer.isHidden = true

        deviceEditHintLabel = NSTextField(labelWithString: "")
        deviceEditHintLabel.font = NSFont.systemFont(ofSize: 11)
        deviceEditHintLabel.textColor = .systemRed
        deviceEditHintLabel.isHidden = true

        // --- Zeilen-Container: Display- und Edit-Container übereinander ---
        let containersStack = NSStackView(views: [deviceDisplayContainer, deviceEditContainer, deviceEditHintLabel])
        containersStack.orientation = .vertical
        containersStack.alignment = .leading
        containersStack.spacing = 4

        deviceRow = twoColumnRow("Gerät", containersStack)
        return deviceRow
    }

    private func buildDeviceProfilesRow() -> NSView {
        deviceProfilesPopup = NSPopUpButton()
        deviceProfilesPopup.translatesAutoresizingMaskIntoConstraints = false
        deviceProfilesPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true

        deviceForgetButton = NSButton(title: "Vergessen", target: self, action: #selector(forgetCurrentDeviceProfile))
        deviceForgetButton.bezelStyle = .rounded
        deviceForgetButton.toolTip = "Aktuelles Geräteprofil entfernen"

        let controls = NSStackView(views: [deviceProfilesPopup, deviceForgetButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY

        return twoColumnRow("Profile", controls)
    }

    @objc private func beginDeviceNameEdit() {
        guard let profile = DeviceRegistry.shared.currentProfile() else { return }
        deviceEditField.stringValue = profile.friendlyName
        deviceEditHintLabel.isHidden = true
        deviceDisplayContainer.isHidden = true
        deviceEditContainer.isHidden = false
        isEditingDeviceName = true
        window?.makeFirstResponder(deviceEditField)
        deviceEditField.currentEditor()?.selectAll(nil)
    }

    @objc private func commitDeviceNameEdit() {
        guard let profile = DeviceRegistry.shared.currentProfile() else {
            cancelDeviceNameEdit()
            return
        }
        let raw = deviceEditField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            deviceEditHintLabel.stringValue = "Name darf nicht leer sein."
            deviceEditHintLabel.isHidden = false
            return
        }
        if raw.count > 30 {
            deviceEditHintLabel.stringValue = "Name darf max. 30 Zeichen haben."
            deviceEditHintLabel.isHidden = false
            return
        }
        if DeviceRegistry.shared.isNameTaken(raw, excludeMAC: profile.mac) {
            deviceEditHintLabel.stringValue = "Name bereits vergeben."
            deviceEditHintLabel.isHidden = false
            return
        }
        var updated = profile
        updated.friendlyName = raw
        DeviceRegistry.shared.save(updated)

        deviceEditContainer.isHidden = true
        deviceEditHintLabel.isHidden = true
        deviceDisplayContainer.isHidden = false
        isEditingDeviceName = false
        update()
    }

    @objc private func cancelDeviceNameEdit() {
        deviceEditContainer.isHidden = true
        deviceEditHintLabel.isHidden = true
        deviceDisplayContainer.isHidden = false
        isEditingDeviceName = false
        update()
    }

    /// Aktualisiert die Geräte-Zeile basierend auf Verbindungsstatus +
    /// DeviceRegistry. Im Edit-Modus wird nichts überschrieben.
    /// Ab v1.14.2: drei Darstellungen — `.connected` (normaler Geraetename
    /// inkl. Edit-Button), `.foreignFirmware` (roter Warnhinweis statt Name,
    /// kein Edit) und `.disconnected`/`.probing` (dimmed „—").
    func updateDeviceRow() {
        guard deviceNameLabel != nil else { return }
        if isEditingDeviceName { return }
        let state = monitor?.serialPort.state ?? .disconnected
        switch state {
        case .connected:
            if let profile = DeviceRegistry.shared.currentProfile() {
                deviceNameLabel.stringValue = profile.friendlyName
                deviceNameLabel.textColor = .labelColor
                deviceEditButton.isEnabled = true
                deviceEditButton.isHidden = false
                let macTip: String
                if profile.mac == kLegacyDeviceMAC {
                    macTip = "MAC: — (Firmware < v2.10.0)"
                } else {
                    macTip = "MAC: \(profile.mac)"
                }
                deviceNameLabel.toolTip = macTip
                deviceRow.toolTip = macTip
            } else {
                deviceNameLabel.stringValue = "— (kein Profil)"
                deviceNameLabel.textColor = .tertiaryLabelColor
                deviceEditButton.isEnabled = false
                deviceEditButton.isHidden = true
                deviceNameLabel.toolTip = nil
                deviceRow.toolTip = nil
            }
        case .foreignFirmware:
            deviceNameLabel.stringValue = "Fremde Firmware — bitte flashen"
            deviceNameLabel.textColor = .systemRed
            deviceEditButton.isEnabled = false
            deviceEditButton.isHidden = true
            deviceNameLabel.toolTip = "Dieses ESP32-Geraet antwortet nicht auf get_info und hat vermutlich keine AI-Monitor-Firmware."
            deviceRow.toolTip = deviceNameLabel.toolTip
        case .probing:
            deviceNameLabel.stringValue = "— (Geraete-Handshake …)"
            deviceNameLabel.textColor = .secondaryLabelColor
            deviceEditButton.isEnabled = false
            deviceEditButton.isHidden = true
            deviceNameLabel.toolTip = nil
            deviceRow.toolTip = nil
        case .disconnected:
            deviceNameLabel.stringValue = "— (nicht verbunden)"
            deviceNameLabel.textColor = .tertiaryLabelColor
            deviceEditButton.isEnabled = false
            deviceEditButton.isHidden = true
            deviceNameLabel.toolTip = nil
            deviceRow.toolTip = nil
        }
        updateDeviceProfilesRow()
    }

    private func updateDeviceProfilesRow() {
        guard deviceProfilesPopup != nil else { return }
        let registry = DeviceRegistry.shared
        let profiles = registry.all().values.sorted {
            let lhsDate = $0.lastSeenAt ?? .distantPast
            let rhsDate = $1.lastSeenAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.friendlyName.localizedCaseInsensitiveCompare($1.friendlyName) == .orderedAscending
        }
        let currentMAC = registry.currentMAC

        deviceProfilesPopup.removeAllItems()
        if profiles.isEmpty {
            deviceProfilesPopup.addItem(withTitle: "Keine Profile")
            deviceProfilesPopup.isEnabled = false
        } else {
            for profile in profiles {
                let title = deviceProfileMenuTitle(profile, isCurrent: profile.mac == currentMAC)
                deviceProfilesPopup.addItem(withTitle: title)
                deviceProfilesPopup.lastItem?.representedObject = profile.mac
                deviceProfilesPopup.lastItem?.toolTip = deviceProfileTooltip(profile)
            }
            if let currentMAC,
               let index = profiles.firstIndex(where: { $0.mac == currentMAC }) {
                deviceProfilesPopup.selectItem(at: index)
            } else {
                deviceProfilesPopup.selectItem(at: 0)
            }
            deviceProfilesPopup.isEnabled = true
        }

        deviceForgetButton.isEnabled = (monitor?.serialPort.state == .connected && registry.currentProfile() != nil)
    }

    private func deviceProfileMenuTitle(_ profile: DeviceProfile, isCurrent: Bool) -> String {
        let current = isCurrent ? "Aktuell · " : ""
        let variant = displayVariantShortText(profile.displayVariant)
        let firmware = profile.firmwareVersion.map { " · v\($0)" } ?? ""
        return "\(current)\(profile.friendlyName) · \(variant)\(firmware)"
    }

    private func deviceProfileTooltip(_ profile: DeviceProfile) -> String {
        let mac = profile.mac == kLegacyDeviceMAC ? "MAC unbekannt" : "MAC: \(profile.mac)"
        let lastSeen: String
        if let date = profile.lastSeenAt {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            lastSeen = "zuletzt: \(df.string(from: date))"
        } else {
            lastSeen = "zuletzt: —"
        }
        return "\(mac) · \(displayVariantShortText(profile.displayVariant)) · \(lastSeen)"
    }

    private func displayVariantShortText(_ variant: String?) -> String {
        switch variant {
        case kDisplayVariantILI9341: return "ILI9341"
        case kDisplayVariantST7789: return "ST7789"
        default: return "Variante unbekannt"
        }
    }

    @objc private func forgetCurrentDeviceProfile() {
        guard let profile = DeviceRegistry.shared.currentProfile() else { return }
        let alert = NSAlert()
        alert.messageText = "Gerät vergessen?"
        alert.informativeText = "\(profile.friendlyName) wird aus der Profilliste entfernt. Anzeige-Einstellungen für dieses Gerät gehen verloren."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Vergessen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DeviceRegistry.shared.remove(mac: profile.mac)
        monitor?.serialPort.requestReconnect()
        update()
    }

    /// Ab v1.14.2: Display-Controls (Theme/Ausrichtung/Sprache/Zeitzone/
    /// Helligkeit) sind nur aktiv, wenn ein Geraet mit AI-Monitor-FW
    /// verbunden ist. Bei `.foreignFirmware`/`.disconnected`/`.probing` werden
    /// Werte auf „—" zurueckgestellt und die Controls disabled — damit keine
    /// Settings an ein Fremd-Geraet oder ins Leere gepusht werden.
    func updateDisplayControlsEnabled() {
        let ready = (monitor?.serialPort.state == .connected)
        let controls: [NSControl?] = [themePopup, orientationPopup, languagePopup, timeZonePopup, brightnessSlider]
        controls.forEach { $0?.isEnabled = ready }
        brightnessValueLabel?.textColor = ready ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func themeChosen() {
        let modes = ["system", "dark", "light"]
        let i = themePopup.indexOfSelectedItem
        Settings.shared.themeMode = modes[max(0, min(i, modes.count - 1))]
        monitor?.sendThemeToESP32()
    }

    @objc private func percentModeChosen() {
        let modes: [UsagePercentDisplayMode] = [.used, .remaining]
        let i = percentModePopup.indexOfSelectedItem
        Settings.shared.usagePercentDisplayMode = modes[max(0, min(i, modes.count - 1))]
        monitor?.sendUsageSnapshotForPercentModeChange()
    }

    @objc private func orientationChosen() {
        let modes = ["portrait", "landscape_left", "landscape_right"]
        let i = orientationPopup.indexOfSelectedItem
        Settings.shared.orientation = modes[max(0, min(i, modes.count - 1))]
        monitor?.sendOrientationToESP32()
    }

    /// Füllt das Zeitzonen-Popup mit „Automatisch (macOS)", der IANA-Kurzliste
    /// und einem „Weitere …"-Eintrag. Wenn die aktuell gewählte TZ nicht in der
    /// Kurzliste steckt, wird sie als zusätzliche Zeile vor „Weitere …"
    /// eingeblendet, damit der User sieht, was aktiv ist.
    func rebuildTimeZonePopup() {
        timeZonePopup.removeAllItems()
        let current = Settings.shared.selectedTimeZone
        for id in kTimeZonePopupIdentifiers {
            timeZonePopup.addItem(withTitle: Self.titleForTimeZone(id))
        }
        // Custom-Eintrag, falls gewählter Wert nicht in der Kurzliste ist.
        if current != "auto" && !kTimeZonePopupIdentifiers.contains(current) {
            timeZonePopup.addItem(withTitle: Self.titleForTimeZone(current))
        }
        timeZonePopup.menu?.addItem(.separator())
        timeZonePopup.addItem(withTitle: "Weitere …")

        // Auswahl setzen
        if let idx = kTimeZonePopupIdentifiers.firstIndex(of: current) {
            timeZonePopup.selectItem(at: idx)
        } else if current != "auto" {
            // Custom-Zeile liegt direkt hinter der Kurzliste.
            timeZonePopup.selectItem(at: kTimeZonePopupIdentifiers.count)
        } else {
            timeZonePopup.selectItem(at: 0)
        }
    }

    private static func titleForTimeZone(_ id: String) -> String {
        if id == "auto" {
            let current = TimeZone.current.identifier
            return "Automatisch (macOS) — \(current)"
        }
        return id
    }

    @objc private func timeZoneChosen() {
        let idx = timeZonePopup.indexOfSelectedItem
        let lastRegularIdx = kTimeZonePopupIdentifiers.count // ggf. Custom-Zeile
        let hasCustomRow = Settings.shared.selectedTimeZone != "auto" &&
            !kTimeZonePopupIdentifiers.contains(Settings.shared.selectedTimeZone)
        let weitereIdx: Int = hasCustomRow
            ? lastRegularIdx + 2   // +Custom +Separator → „Weitere …"
            : lastRegularIdx + 1   // +Separator → „Weitere …"

        if idx == weitereIdx {
            // Modal mit allen IANA-Zonen.
            presentTimeZonePicker()
            return
        }
        if idx < kTimeZonePopupIdentifiers.count {
            Settings.shared.selectedTimeZone = kTimeZonePopupIdentifiers[idx]
        } else if hasCustomRow && idx == lastRegularIdx {
            // Custom-Zeile — Auswahl bleibt wie sie war, keine Änderung nötig.
        }
        // TZ-Änderung: sofort neuen Snapshot mit neuem displayTime senden.
        monitor?.sendUsageSnapshotForTimeZoneChange()
        update()
    }

    private func presentTimeZonePicker() {
        let alert = NSAlert()
        alert.messageText = "Zeitzone wählen"
        alert.informativeText = "Filter und Auswahl — die ausgewählte IANA-Zone wird für die Display-Uhr und Reset-Berechnungen genutzt."
        alert.alertStyle = .informational

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        let search = NSSearchField(frame: NSRect(x: 0, y: 230, width: 360, height: 24))
        search.placeholderString = "Filter (z. B. Berlin, New_York, UTC)"
        container.addSubview(search)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tableView = NSTableView(frame: scroll.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tz"))
        column.title = "IANA"
        column.width = 340
        tableView.addTableColumn(column)
        tableView.headerView = nil
        let datasource = TimeZoneTableSource()
        datasource.allIdentifiers = TimeZone.knownTimeZoneIdentifiers.sorted()
        datasource.filtered = datasource.allIdentifiers
        tableView.dataSource = datasource
        tableView.delegate = datasource
        datasource.tableView = tableView

        // Live-Filter verdrahten
        search.target = datasource
        search.action = #selector(TimeZoneTableSource.searchChanged(_:))
        datasource.searchField = search

        scroll.documentView = tableView
        container.addSubview(scroll)
        alert.accessoryView = container
        alert.addButton(withTitle: "Übernehmen")
        alert.addButton(withTitle: "Abbrechen")

        // Vorauswahl setzen
        let current = Settings.shared.selectedTimeZone
        if current != "auto", let idx = datasource.filtered.firstIndex(of: current) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let row = tableView.selectedRow
            if row >= 0 && row < datasource.filtered.count {
                Settings.shared.selectedTimeZone = datasource.filtered[row]
                rebuildTimeZonePopup()
                monitor?.sendUsageSnapshotForTimeZoneChange()
                update()
                return
            }
        }
        // Abbruch oder keine Auswahl → Popup auf aktuellen Wert resetten.
        rebuildTimeZonePopup()
    }

    @objc private func languageChosen() {
        let langs = ["de", "en"]
        let i = languagePopup.indexOfSelectedItem
        Settings.shared.language = langs[max(0, min(i, langs.count - 1))]
        monitor?.sendLanguageToESP32()
    }

    @objc private func brightnessChanged() {
        let pct = Int(brightnessSlider.doubleValue.rounded())
        brightnessValueLabel.stringValue = "\(pct) %"
        monitor?.sendBrightnessToESP32(pct, persist: false)
        brightnessPersistTimer?.invalidate()
        brightnessPersistTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let finalPct = Int(self.brightnessSlider.doubleValue.rounded())
            self.monitor?.sendBrightnessToESP32(finalPct, persist: true)
        }
    }
}
