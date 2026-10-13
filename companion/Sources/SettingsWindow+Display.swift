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
        let intro = NSTextField(wrappingLabelWithString: L("disp.intro"))
        intro.font = NSFont.appFont(.callout)
        intro.textColor = .secondaryLabelColor

        // Geräte-Zeile (ab v1.14.0)
        let deviceRowBuilt = buildDeviceRow()
        let deviceProfilesRow = buildDeviceProfilesRow()

        // Theme
        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: [L("disp.tz.auto"), "Dark", "Light"])
        themePopup.target = self
        themePopup.action = #selector(themeChosen)
        themePopup.toolTip = L("disp.theme.tooltip")
        let themeRow = twoColumnRow("Theme", themePopup)

        // Prozent-Logik (global für alle Provider)
        percentModePopup = NSPopUpButton()
        percentModePopup.addItems(withTitles: [
            "Verbraucht (0 → 100)",
            "Verbleibend (100 → 0)"
        ])
        percentModePopup.target = self
        percentModePopup.action = #selector(percentModeChosen)
        percentModePopup.toolTip = L("disp.percent.tooltip")
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
        orientationPopup.toolTip = L("disp.orient.tooltip")
        let orientRow = twoColumnRow("Ausrichtung", orientationPopup)

        // Language
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Deutsch", "English"])
        languagePopup.target = self
        languagePopup.action = #selector(languageChosen)
        languagePopup.toolTip = L("disp.lang.tooltip")
        let langRow = twoColumnRow("Sprache", languagePopup)

        // TimeZone (v1.12.0) — steuert displayTime auf dem ESP32.
        timeZonePopup = NSPopUpButton()
        rebuildTimeZonePopup()
        timeZonePopup.target = self
        timeZonePopup.action = #selector(timeZoneChosen)
        timeZonePopup.toolTip = L("disp.tz.tooltip")
        timeZonePopup.translatesAutoresizingMaskIntoConstraints = false
        timeZonePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let tzRow = twoColumnRow("Zeitzone", timeZonePopup)

        // Brightness
        brightnessSlider = NSSlider(value: Double(Settings.shared.lastKnownBrightness),
                                    minValue: 5, maxValue: 100,
                                    target: self, action: #selector(brightnessChanged))
        brightnessSlider.toolTip = L("disp.bright.tooltip")
        brightnessSlider.isContinuous = true
        brightnessSlider.numberOfTickMarks = 0
        brightnessSlider.translatesAutoresizingMaskIntoConstraints = false
        brightnessSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        brightnessValueLabel = NSTextField(labelWithString: "\(Settings.shared.lastKnownBrightness) %")
        brightnessValueLabel.font = NSFont.appMonospacedDigit(.callout)
        brightnessValueLabel.textColor = .secondaryLabelColor
        brightnessValueLabel.translatesAutoresizingMaskIntoConstraints = false
        brightnessValueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        brightnessValueLabel.alignment = .right
        let brightControls = NSStackView(views: [brightnessSlider, brightnessValueLabel])
        brightControls.orientation = .horizontal
        brightControls.spacing = 8
        let brightRow = twoColumnRow("Helligkeit", brightControls)

        lastUpdateLabel = NSTextField(labelWithString: L("disp.lastsend.none"))
        lastUpdateLabel.font = NSFont.appFont(.subheadline)
        lastUpdateLabel.textColor = .secondaryLabelColor

        let deviceStep = buildDisplaySetupStep(
            number: "1",
            title: L("disp.step.pick"),
            detail: L("disp.step.pick.detail"),
            views: [deviceRowBuilt, deviceProfilesRow, buildDeviceLocationRow()]
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
            detail: L("disp.step.look.detail"),
            views: [appearanceRows]
        )

        let viewsStep = buildDisplaySetupStep(
            number: "3",
            title: L("views.step"),
            detail: L("views.step.detail"),
            views: buildViewsStepContent()
        )

        let testButton = NSButton(title: "Testbild senden", target: self, action: #selector(sendTestFrame))
        testButton.bezelStyle = .rounded
        testButton.toolTip = L("disp.test.tooltip")
        displayTestButton = testButton

        let testHelper = NSTextField(wrappingLabelWithString: L("disp.test.hint"))
        testHelper.font = NSFont.appFont(.subheadline)
        testHelper.textColor = .secondaryLabelColor

        let testStep = buildDisplaySetupStep(
            number: "4",
            title: L("disp.step.check"),
            detail: L("disp.step.check.detail"),
            views: [testButton, testHelper, lastUpdateLabel]
        )

        let stack = NSStackView(views: [heading, intro, deviceStep, appearanceStep, viewsStep, testStep])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        return stack
    }

    private func buildDisplaySetupStep(number: String,
                                       title: String,
                                       detail: String,
                                       views: [NSView]) -> NSView {
        let numberLabel = AccentBadgeLabel(labelWithString: number)
        numberLabel.font = NSFont.appMonospacedDigit(.callout, weight: .semibold)
        numberLabel.alignment = .center
        // Nicht .white: bei hellen System-Akzentfarben (Gelb, Grün) waere der
        // Kontrast zu gering. .alternateSelectedControlTextColor ist die
        // semantische Vordergrundfarbe fuer Akzent-Hintergruende.
        numberLabel.textColor = .alternateSelectedControlTextColor
        numberLabel.wantsLayer = true
        numberLabel.layer?.cornerRadius = 9
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.widthAnchor.constraint(equalToConstant: 18).isActive = true
        numberLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.appFont(.headline)

        let header = NSStackView(views: [numberLabel, titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.appFont(.subheadline)
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
        deviceNameLabel.font = NSFont.appFont(.body)
        deviceNameLabel.lineBreakMode = .byTruncatingTail
        deviceNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        deviceNameLabel.translatesAutoresizingMaskIntoConstraints = false

        deviceEditButton = NSButton()
        deviceEditButton.bezelStyle = .regularSquare
        deviceEditButton.isBordered = false
        // Vorher das Emoji „✏️" als Button-Titel. Emoji skalieren nicht mit den
        // Systemeinstellungen, faerben sich nicht mit dem Control-Tint und
        // werden von VoiceOver als „Bleistift" statt als Aktion vorgelesen.
        deviceEditButton.image = NSImage(systemSymbolName: "pencil",
                                         accessibilityDescription: L("disp.name.edit"))
        deviceEditButton.imagePosition = .imageOnly
        deviceEditButton.contentTintColor = .secondaryLabelColor
        deviceEditButton.target = self
        deviceEditButton.action = #selector(beginDeviceNameEdit)
        deviceEditButton.setButtonType(.momentaryPushIn)
        deviceEditButton.toolTip = L("disp.name.edit")
        deviceEditButton.setAccessibilityLabel(L("disp.name.edit.tooltip"))
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
        deviceEditField.font = NSFont.appFont(.body)
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
        deviceEditHintLabel.font = NSFont.appFont(.subheadline)
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

    private func buildDeviceLocationRow() -> NSView {
        deviceLocationLabel = NSTextField(labelWithString: L("disp.location.none"))
        deviceLocationLabel.font = NSFont.appFont(.body)
        deviceLocationLabel.lineBreakMode = .byTruncatingTail
        deviceLocationLabel.translatesAutoresizingMaskIntoConstraints = false
        deviceLocationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true

        deviceLocationButton = NSButton(title: L("disp.location.change"), target: self,
                                        action: #selector(presentDeviceLocationPicker))
        deviceLocationButton.bezelStyle = .rounded
        deviceLocationButton.toolTip = L("disp.location.tooltip")

        let controls = NSStackView(views: [deviceLocationLabel, deviceLocationButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        updateDeviceLocationRow()
        return twoColumnRow(L("disp.location.label"), controls)
    }

    func updateDeviceLocationRow() {
        guard deviceLocationLabel != nil else { return }
        let profile = DeviceRegistry.shared.currentProfile()
        deviceLocationLabel.stringValue = profile?.location?.summary ?? L("disp.location.none")
        deviceLocationLabel.textColor = profile?.location == nil ? .secondaryLabelColor : .labelColor
        deviceLocationLabel.toolTip = profile?.location?.summary
        // Der Standort liegt im Profil und lässt sich auch ohne Verbindung pflegen.
        deviceLocationButton.isEnabled = profile != nil
    }

    @objc private func presentDeviceLocationPicker() {
        guard let profile = DeviceRegistry.shared.currentProfile() else { return }
        let alert = NSAlert()
        alert.messageText = L("disp.location.title", profile.friendlyName)
        alert.informativeText = L("disp.location.intro")
        alert.alertStyle = .informational

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 268))
        let search = NSSearchField(frame: NSRect(x: 0, y: 240, width: 272, height: 24))
        search.placeholderString = L("disp.location.placeholder")
        // Erst auf „Suchen“ oder Return suchen, nicht bei jedem Tastendruck abrufen.
        search.sendsSearchStringImmediately = false
        search.sendsWholeSearchString = true
        container.addSubview(search)
        let searchButton = NSButton(title: L("disp.location.search"), target: nil, action: nil)
        searchButton.bezelStyle = .rounded
        searchButton.frame = NSRect(x: 278, y: 236, width: 86, height: 32)
        container.addSubview(searchButton)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 84, width: 360, height: 150))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let tableView = NSTableView(frame: scroll.bounds)
        tableView.style = .inset
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("place"))
        column.width = 340
        tableView.addTableColumn(column)
        tableView.headerView = nil
        scroll.documentView = tableView
        container.addSubview(scroll)

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 0, y: 60, width: 360, height: 18)
        status.font = NSFont.appFont(.subheadline)
        status.textColor = .secondaryLabelColor
        container.addSubview(status)

        let latitude = NSTextField(frame: NSRect(x: 0, y: 30, width: 174, height: 24))
        latitude.placeholderString = L("disp.location.latitude")
        latitude.setAccessibilityLabel(L("disp.location.latitude"))
        let longitude = NSTextField(frame: NSRect(x: 186, y: 30, width: 174, height: 24))
        longitude.placeholderString = L("disp.location.longitude")
        longitude.setAccessibilityLabel(L("disp.location.longitude"))
        container.addSubview(latitude)
        container.addSubview(longitude)

        let credit = NSTextField(labelWithString: L("disp.location.attribution"))
        credit.frame = NSRect(x: 0, y: 4, width: 360, height: 18)
        credit.font = NSFont.appFont(.subheadline)
        credit.textColor = .tertiaryLabelColor
        container.addSubview(credit)

        let source = PlaceSearchSource()
        source.tableView = tableView
        source.statusLabel = status
        source.latitudeField = latitude
        source.longitudeField = longitude
        source.chosen = profile.location
        tableView.dataSource = source
        tableView.delegate = source
        source.searchField = search
        search.target = source
        search.action = #selector(PlaceSearchSource.search(_:))
        searchButton.target = source
        searchButton.action = #selector(PlaceSearchSource.searchPressed(_:))
        if let current = profile.location {
            latitude.stringValue = PlaceSearchSource.text(current.latitude)
            longitude.stringValue = PlaceSearchSource.text(current.longitude)
        }

        alert.accessoryView = container
        alert.addButton(withTitle: "Übernehmen")
        alert.addButton(withTitle: "Abbrechen")
        if profile.location != nil { alert.addButton(withTitle: L("disp.location.clear")) }
        alert.window.initialFirstResponder = search

        let response = alert.runModal()
        let updated: DeviceLocation?
        switch response {
        case .alertFirstButtonReturn:
            guard let lat = PlaceSearchSource.number(latitude.stringValue),
                  let lon = PlaceSearchSource.number(longitude.stringValue) else {
                presentDeviceLocationError()
                return
            }
            // Ein Ortsname gilt nur, solange die Koordinaten noch zu ihm passen.
            let named = source.chosen.flatMap { $0.latitude == lat && $0.longitude == lon ? $0.name : nil }
            let location = DeviceLocation(name: named ?? "", latitude: lat, longitude: lon)
            guard location.isValid else {
                presentDeviceLocationError()
                return
            }
            updated = location
        case .alertThirdButtonReturn:
            updated = nil
        default:
            return
        }
        // Das Profil kann während des Dialogs gewechselt haben; gezielt dieses Gerät ändern.
        guard var target = DeviceRegistry.shared.profile(forMAC: profile.mac) else { return }
        target.location = updated
        DeviceRegistry.shared.save(target)
        updateDeviceLocationRow()
        updatePluginsSection(force: true)
        // Standortabhängige Plugins verwerfen ihre Daten und rufen neu ab.
        DisplayPlugins.shared.refresh(views: Settings.shared.displayViews)
        DisplayPlugins.shared.onChange?()
    }

    private func presentDeviceLocationError() {
        let alert = NSAlert()
        alert.messageText = L("disp.location.err.invalid")
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func buildDeviceProfilesRow() -> NSView {
        deviceProfilesPopup = NSPopUpButton()
        deviceProfilesPopup.translatesAutoresizingMaskIntoConstraints = false
        deviceProfilesPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true

        deviceForgetButton = NSButton(title: "Vergessen", target: self, action: #selector(forgetCurrentDeviceProfile))
        deviceForgetButton.bezelStyle = .rounded
        deviceForgetButton.toolTip = L("disp.profile.forget.tooltip")

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
            deviceEditHintLabel.stringValue = L("disp.name.err.empty")
            deviceEditHintLabel.isHidden = false
            return
        }
        if raw.count > 30 {
            deviceEditHintLabel.stringValue = L("disp.name.err.long")
            deviceEditHintLabel.isHidden = false
            return
        }
        if DeviceRegistry.shared.isNameTaken(raw, excludeMAC: profile.mac) {
            deviceEditHintLabel.stringValue = L("disp.name.err.dup")
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
        updateDeviceLocationRow()
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
                deviceNameLabel.stringValue = L("disp.profile.none")
                deviceNameLabel.textColor = .tertiaryLabelColor
                deviceEditButton.isEnabled = false
                deviceEditButton.isHidden = true
                deviceNameLabel.toolTip = nil
                deviceRow.toolTip = nil
            }
        case .foreignFirmware:
            deviceNameLabel.stringValue = L("disp.fw.foreign")
            deviceNameLabel.textColor = .systemRed
            deviceEditButton.isEnabled = false
            deviceEditButton.isHidden = true
            deviceNameLabel.toolTip = L("disp.fw.foreign.detail")
            deviceRow.toolTip = deviceNameLabel.toolTip
        case .probing:
            deviceNameLabel.stringValue = L("disp.device.handshake")
            deviceNameLabel.textColor = .secondaryLabelColor
            deviceEditButton.isEnabled = false
            deviceEditButton.isHidden = true
            deviceNameLabel.toolTip = nil
            deviceRow.toolTip = nil
        case .disconnected:
            deviceNameLabel.stringValue = L("disp.device.disconnected")
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
            deviceProfilesPopup.addItem(withTitle: L("disp.profile.empty"))
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
        alert.messageText = L("disp.forget.title")
        alert.informativeText = L("disp.forget.info", profile.friendlyName)
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
        timeZonePopup.addItem(withTitle: L("disp.tz.more"))

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
        alert.messageText = L("disp.tz.title")
        alert.informativeText = L("disp.tz.intro")
        alert.alertStyle = .informational

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))
        let search = NSSearchField(frame: NSRect(x: 0, y: 230, width: 360, height: 24))
        search.placeholderString = L("disp.tz.filter")
        container.addSubview(search)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
        scroll.hasVerticalScroller = true
        // .bezelBorder ist der gravierte Rahmen aus der 10.x-Aera. Moderne
        // Listen stehen rahmenlos; die Abgrenzung uebernimmt der .inset-Stil
        // der Tabelle.
        scroll.borderType = .noBorder
        let tableView = NSTableView(frame: scroll.bounds)
        tableView.style = .inset
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
        DisplayPlugins.shared.refresh(views: Settings.shared.displayViews)
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

// ============================================================
// MARK: - Accent Badge
// ============================================================

/// Runder Akzent-Badge fuer die Schritt-Nummerierung der Display-Einrichtung.
///
/// `layer.backgroundColor` ist ein CGColor und damit — anders als NSColor —
/// nicht appearance-aware: einmal aufgeloest bleibt der Wert fix. Ohne
/// Nachfaerben behaelt der Badge beim Wechsel Hell/Dunkel oder beim Aendern
/// der System-Akzentfarbe die alte Farbe. Diese Subklasse faerbt bei beiden
/// Ereignissen nach.
final class AccentBadgeLabel: NSTextField {

    private var systemColorObserver: NSObjectProtocol?

    deinit {
        if let systemColorObserver {
            NotificationCenter.default.removeObserver(systemColorObserver)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAccentBackground()

        // Akzentfarben-Wechsel loest KEIN viewDidChangeEffectiveAppearance aus,
        // sondern nur diese Notification.
        guard window != nil, systemColorObserver == nil else { return }
        systemColorObserver = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAccentBackground()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccentBackground()
    }

    private func applyAccentBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }
}
