/**
 * SettingsWindow.swift — Einziges sichtbares UI der App (LSUIElement=YES).
 *
 * Ab v1.11.0: Querformat-Layout, 960×560, nicht resizable. Zwei-Spalten-Split
 * statt langer vertikaler Liste. Header mit Provider-Umschalter rechts.
 *
 * Ab v1.11.1: „Über AI Monitor" und „Nach Updates suchen …" dauerhaft im
 * Footer sichtbar — der v1.11.0-Pfad ueber das native Main-Menu funktioniert
 * unter .accessory/LSUIElement=YES nicht (macOS rendert keine System-Menueleiste
 * fuer solche Apps). „Beenden" bleibt auf ⌘Q (kein Button im Settings-Fenster).
 */

import Cocoa

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    // Referenzen, die von aussen injiziert werden
    weak var monitor: UsageMonitor?

    // Header
    private var providerSegmented: NSSegmentedControl!

    // Linke Spalte — CodexBar
    private var codexBarStatusDot: NSTextField!
    private var codexBarStatusLabel: NSTextField!
    private var codexBarValuesLabel: NSTextField!
    private var codexBarResetSessionLabel: NSTextField!
    private var codexBarResetWeeklyLabel: NSTextField!
    private var codexBarReloadButton: NSButton!

    // Linke Spalte — Port
    private var portStatusDot: NSTextField!
    private var portStatusLabel: NSTextField!
    private var portPopup: NSPopUpButton!
    private var portRefreshButton: NSButton!

    // Rechte Spalte — Display
    private var themePopup: NSPopUpButton!
    private var orientationPopup: NSPopUpButton!
    private var languagePopup: NSPopUpButton!
    private var timeZonePopup: NSPopUpButton!
    private var brightnessSlider: NSSlider!
    private var brightnessValueLabel: NSTextField!
    private var lastUpdateLabel: NSTextField!

    // Zeitzone: Reihenfolge der häufigen Einträge. Erster Eintrag ist
    // immer „Automatisch (macOS)", dann die IANA-Kurzliste, dann „Weitere …".
    private let kTimeZonePopupIdentifiers: [String] = [
        "auto",
        "Europe/Berlin",
        "Europe/London",
        "America/New_York",
        "America/Los_Angeles",
        "Asia/Tokyo",
        "Australia/Sydney",
    ]

    // Rechte Spalte — Firmware
    private var fwVersionLabel: NSTextField!
    private var fwUpdateLabel: NSTextField!
    private var fwFlashButton: NSButton!
    private var fwProgressBar: NSProgressIndicator!
    private var fwProgressLabel: NSTextField!

    // Footer
    private var footerVersionLabel: NSTextField!
    private var footerAboutButton: NSButton!
    private var footerUpdateButton: NSButton!

    private var refreshTimer: Timer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Monitor"
        window.isReleasedWhenClosed = false
        window.center()
        // Fixe Groesse — kein Resize.
        window.minSize = NSSize(width: 960, height: 560)
        window.maxSize = NSSize(width: 960, height: 560)
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    // Von AppDelegate aufgerufen
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        update()
        startRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        stopRefreshTimer()
    }

    private func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshLiveLabels()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Header (h=48) oben, Footer (h=28) unten, dazwischen zwei Spalten 50/50.
        let header = buildHeader()
        let headerDivider = makeHorizontalDivider()
        let footerDivider = makeHorizontalDivider()
        let footer = buildFooter()
        let leftColumn = buildLeftColumn()
        let rightColumn = buildRightColumn()
        let columnDivider = makeVerticalDivider()

        [header, headerDivider, leftColumn, rightColumn, columnDivider, footerDivider, footer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        let leftGuide = content.leadingAnchor
        let rightGuide = content.trailingAnchor

        NSLayoutConstraint.activate([
            // Header
            header.leadingAnchor.constraint(equalTo: leftGuide, constant: 20),
            header.trailingAnchor.constraint(equalTo: rightGuide, constant: -20),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 0),
            header.heightAnchor.constraint(equalToConstant: 48),

            headerDivider.leadingAnchor.constraint(equalTo: leftGuide),
            headerDivider.trailingAnchor.constraint(equalTo: rightGuide),
            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            // Footer
            footerDivider.leadingAnchor.constraint(equalTo: leftGuide),
            footerDivider.trailingAnchor.constraint(equalTo: rightGuide),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: leftGuide, constant: 20),
            footer.trailingAnchor.constraint(equalTo: rightGuide, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 0),
            footer.heightAnchor.constraint(equalToConstant: 28),

            // Linke Spalte
            leftColumn.leadingAnchor.constraint(equalTo: leftGuide, constant: 20),
            leftColumn.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 16),
            leftColumn.bottomAnchor.constraint(lessThanOrEqualTo: footerDivider.topAnchor, constant: -16),
            leftColumn.widthAnchor.constraint(equalToConstant: 440),

            // Vertikaler Divider zwischen den Spalten
            columnDivider.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            columnDivider.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 12),
            columnDivider.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -12),
            columnDivider.widthAnchor.constraint(equalToConstant: 1),

            // Rechte Spalte
            rightColumn.trailingAnchor.constraint(equalTo: rightGuide, constant: -20),
            rightColumn.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 16),
            rightColumn.bottomAnchor.constraint(lessThanOrEqualTo: footerDivider.topAnchor, constant: -16),
            rightColumn.widthAnchor.constraint(equalToConstant: 440),
        ])
    }

    // MARK: - Header

    private func buildHeader() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "AI Monitor")
        title.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        providerSegmented = NSSegmentedControl(labels: ["Claude", "Codex"],
                                               trackingMode: .selectOne,
                                               target: self,
                                               action: #selector(providerChosen))
        providerSegmented.segmentStyle = .rounded
        providerSegmented.selectedSegment = (Settings.shared.selectedProvider == "codex") ? 1 : 0
        providerSegmented.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerSegmented)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            providerSegmented.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            providerSegmented.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    // MARK: - Footer

    private func buildFooter() -> NSView {
        let container = NSView()

        footerVersionLabel = NSTextField(labelWithString: "AI Monitor v\(kAppVersion)")
        footerVersionLabel.font = NSFont.systemFont(ofSize: 11)
        footerVersionLabel.textColor = .tertiaryLabelColor
        footerVersionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerVersionLabel)

        // Ab v1.11.1 dauerhaft sichtbar — die einzigen Wege zur App-Info und
        // zum Update-Checker, weil unter .accessory kein macOS-App-Menue rendert.
        footerAboutButton = makeLinkButton("Über AI Monitor", action: #selector(showAbout))
        footerUpdateButton = makeLinkButton("Nach Updates suchen …", action: #selector(checkAppUpdate))
        container.addSubview(footerAboutButton)
        container.addSubview(footerUpdateButton)

        NSLayoutConstraint.activate([
            footerVersionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerVersionLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            footerUpdateButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerUpdateButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            footerAboutButton.trailingAnchor.constraint(equalTo: footerUpdateButton.leadingAnchor, constant: -16),
            footerAboutButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeLinkButton(_ title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.bezelStyle = .inline
        b.contentTintColor = .secondaryLabelColor
        b.font = NSFont.systemFont(ofSize: 11)
        b.translatesAutoresizingMaskIntoConstraints = false
        let ps = NSMutableParagraphStyle()
        ps.alignment = .right
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: ps,
        ])
        return b
    }

    // MARK: - Linke Spalte

    private func buildLeftColumn() -> NSView {
        let codexBox = buildCodexBarBox()
        let portBox = buildPortBox()

        let stack = NSStackView(views: [codexBox, portBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        return stack
    }

    private func buildCodexBarBox() -> NSView {
        let heading = makeSectionHeading("CodexBar-Datenquelle")

        codexBarStatusDot = NSTextField(labelWithString: "\u{25CF}")
        codexBarStatusDot.font = NSFont.systemFont(ofSize: 13)
        codexBarStatusDot.textColor = .secondaryLabelColor

        codexBarStatusLabel = NSTextField(labelWithString: "…")
        codexBarStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let statusRow = NSStackView(views: [codexBarStatusDot, codexBarStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6

        codexBarValuesLabel = NSTextField(labelWithString: "Session: — · Weekly: —")
        codexBarValuesLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        codexBarResetSessionLabel = NSTextField(labelWithString: "")
        codexBarResetSessionLabel.font = NSFont.systemFont(ofSize: 11)
        codexBarResetSessionLabel.textColor = .secondaryLabelColor

        codexBarResetWeeklyLabel = NSTextField(labelWithString: "")
        codexBarResetWeeklyLabel.font = NSFont.systemFont(ofSize: 11)
        codexBarResetWeeklyLabel.textColor = .secondaryLabelColor

        codexBarReloadButton = NSButton(title: "Jetzt neu laden", target: self, action: #selector(reloadCodexBar))
        codexBarReloadButton.bezelStyle = .rounded
        codexBarReloadButton.controlSize = .small

        let spacerBeforeButton = NSView()
        spacerBeforeButton.translatesAutoresizingMaskIntoConstraints = false
        spacerBeforeButton.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let stack = NSStackView(views: [
            heading,
            statusRow,
            codexBarValuesLabel,
            codexBarResetSessionLabel,
            codexBarResetWeeklyLabel,
            spacerBeforeButton,
            codexBarReloadButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func buildPortBox() -> NSView {
        let heading = makeSectionHeading("USB-Verbindung zum ESP32")

        portStatusDot = NSTextField(labelWithString: "\u{25CB}")
        portStatusDot.font = NSFont.systemFont(ofSize: 13)
        portStatusDot.textColor = .secondaryLabelColor

        portStatusLabel = NSTextField(labelWithString: "nicht verbunden")
        portStatusLabel.font = NSFont.systemFont(ofSize: 13)

        let statusRow = NSStackView(views: [portStatusDot, portStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6

        portPopup = NSPopUpButton()
        portPopup.target = self
        portPopup.action = #selector(portChosen)
        portPopup.translatesAutoresizingMaskIntoConstraints = false
        portPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        portRefreshButton = NSButton(title: "Ports neu scannen", target: self, action: #selector(refreshPorts))
        portRefreshButton.bezelStyle = .rounded
        portRefreshButton.controlSize = .small

        let controlRow = NSStackView(views: [portPopup, portRefreshButton])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8

        let stack = NSStackView(views: [heading, statusRow, controlRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    // MARK: - Rechte Spalte

    private func buildRightColumn() -> NSView {
        let displayBox = buildDisplayBox()
        let firmwareBox = buildFirmwareBox()

        let stack = NSStackView(views: [displayBox, firmwareBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        return stack
    }

    private func buildDisplayBox() -> NSView {
        let heading = makeSectionHeading("Display-Einstellungen")

        // Theme
        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: ["Automatisch (macOS)", "Dark", "Light"])
        themePopup.target = self
        themePopup.action = #selector(themeChosen)
        let themeRow = twoColumnRow("Theme", themePopup)

        // Orientation
        orientationPopup = NSPopUpButton()
        orientationPopup.addItems(withTitles: [
            "Hochformat",
            "Querformat (USB links)",
            "Querformat (USB rechts)"
        ])
        orientationPopup.target = self
        orientationPopup.action = #selector(orientationChosen)
        let orientRow = twoColumnRow("Ausrichtung", orientationPopup)

        // Language
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Deutsch", "English"])
        languagePopup.target = self
        languagePopup.action = #selector(languageChosen)
        let langRow = twoColumnRow("Sprache", languagePopup)

        // TimeZone (v1.12.0) — steuert displayTime auf dem ESP32.
        timeZonePopup = NSPopUpButton()
        rebuildTimeZonePopup()
        timeZonePopup.target = self
        timeZonePopup.action = #selector(timeZoneChosen)
        timeZonePopup.translatesAutoresizingMaskIntoConstraints = false
        timeZonePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let tzRow = twoColumnRow("Zeitzone", timeZonePopup)

        // Brightness
        brightnessSlider = NSSlider(value: Double(Settings.shared.lastKnownBrightness),
                                    minValue: 5, maxValue: 100,
                                    target: self, action: #selector(brightnessChanged))
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

        let rowsStack = NSStackView(views: [themeRow, orientRow, langRow, tzRow, brightRow])
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8

        let stack = NSStackView(views: [heading, rowsStack, lastUpdateLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func buildFirmwareBox() -> NSView {
        let heading = makeSectionHeading("Firmware")

        fwVersionLabel = NSTextField(labelWithString: "Installiert: —")
        fwVersionLabel.font = NSFont.systemFont(ofSize: 13)

        fwUpdateLabel = NSTextField(labelWithString: "")
        fwUpdateLabel.font = NSFont.systemFont(ofSize: 12)
        fwUpdateLabel.textColor = .secondaryLabelColor

        fwFlashButton = NSButton(title: "Firmware flashen …", target: self, action: #selector(flashFirmware))
        fwFlashButton.bezelStyle = .rounded

        fwProgressBar = NSProgressIndicator()
        fwProgressBar.style = .bar
        fwProgressBar.isIndeterminate = false
        fwProgressBar.minValue = 0
        fwProgressBar.maxValue = 100
        fwProgressBar.isHidden = true
        fwProgressBar.translatesAutoresizingMaskIntoConstraints = false
        fwProgressBar.widthAnchor.constraint(equalToConstant: 360).isActive = true

        fwProgressLabel = NSTextField(labelWithString: "")
        fwProgressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fwProgressLabel.textColor = .secondaryLabelColor
        fwProgressLabel.isHidden = true

        let stack = NSStackView(views: [
            heading,
            fwVersionLabel,
            fwUpdateLabel,
            fwFlashButton,
            fwProgressBar,
            fwProgressLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    // MARK: - Shared builders

    private func makeSectionHeading(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func makeHorizontalDivider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        return v
    }

    private func makeVerticalDivider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return v
    }

    private func twoColumnRow(_ labelText: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: labelText)
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.distribution = .fill
        return row
    }

    // MARK: - Update-Logic

    func update() {
        guard let monitor = monitor else { return }

        // Provider-Segmented
        if providerSegmented != nil {
            let wantIdx = (Settings.shared.selectedProvider == "codex") ? 1 : 0
            if providerSegmented.selectedSegment != wantIdx {
                providerSegmented.selectedSegment = wantIdx
            }
        }

        // CodexBar
        let src = monitor.codexBar
        let entry = src.lastEntry
        codexBarStatusLabel.stringValue = src.status.shortLabel
        if src.status.isOK {
            codexBarStatusDot.stringValue = "\u{25CF}"
            codexBarStatusDot.textColor = .systemGreen
            codexBarStatusLabel.textColor = .labelColor
        } else {
            codexBarStatusDot.stringValue = "\u{25CF}"
            codexBarStatusDot.textColor = .systemOrange
            codexBarStatusLabel.textColor = .systemOrange
        }

        if let e = entry, src.status.isOK {
            let sp = Int((e.primary?.usedPercent ?? 0).rounded())
            let wp = Int((e.secondary?.usedPercent ?? 0).rounded())
            codexBarValuesLabel.stringValue = "Session: \(sp) %   ·   Weekly: \(wp) %"
            if let reset = e.primary?.resetDescription {
                codexBarResetSessionLabel.stringValue = "Session-Reset: \(reset)"
                codexBarResetSessionLabel.isHidden = false
            } else {
                codexBarResetSessionLabel.stringValue = ""
                codexBarResetSessionLabel.isHidden = true
            }
            if let reset = e.secondary?.resetDescription {
                codexBarResetWeeklyLabel.stringValue = "Weekly-Reset: \(reset)"
                codexBarResetWeeklyLabel.isHidden = false
            } else {
                codexBarResetWeeklyLabel.stringValue = ""
                codexBarResetWeeklyLabel.isHidden = true
            }
        } else {
            codexBarValuesLabel.stringValue = "Session: — · Weekly: —"
            let msg: String
            switch src.status {
            case .missing:
                let providerLabel = (src.provider == "codex") ? "Codex" : "Claude"
                msg = "Keine \(providerLabel)-Daten in CodexBar gefunden."
            case .stale(let age):
                msg = "Daten sind \(age/60) Minuten alt."
            case .wrongVersion(let f, let e):
                msg = "Schema-Version unerwartet: \(f), erwartet \(e)."
            case .parseError(let m):
                msg = "Parse-Fehler: \(m)"
            default:
                msg = ""
            }
            codexBarResetSessionLabel.stringValue = msg
            codexBarResetSessionLabel.isHidden = msg.isEmpty
            codexBarResetWeeklyLabel.stringValue = ""
            codexBarResetWeeklyLabel.isHidden = true
        }

        // Port
        let sp = monitor.serialPort
        if sp.isConnected, let p = sp.connectedPort {
            portStatusDot.stringValue = "\u{25CF}"
            portStatusDot.textColor = .systemGreen
            portStatusLabel.stringValue = "verbunden (\((p as NSString).lastPathComponent))"
            portStatusLabel.textColor = .labelColor
        } else {
            portStatusDot.stringValue = "\u{25CB}"
            portStatusDot.textColor = .secondaryLabelColor
            portStatusLabel.stringValue = "nicht verbunden"
            portStatusLabel.textColor = .secondaryLabelColor
        }
        rebuildPortPopup()

        // Firmware
        let fw = FirmwareManager.shared
        fwVersionLabel.stringValue = "Installiert: \(fw.installedVersionDisplay)"
        if fw.hasUpdate {
            fwUpdateLabel.stringValue = "Update verfügbar: \(fw.latestVersionDisplay)"
            fwUpdateLabel.textColor = .systemBlue
            fwFlashButton.isEnabled = sp.isConnected
            fwFlashButton.title = "Firmware flashen …"
        } else if fw.isFlashing {
            fwUpdateLabel.stringValue = "Flash läuft …"
            fwUpdateLabel.textColor = .secondaryLabelColor
            fwFlashButton.isEnabled = false
            fwFlashButton.title = "flashing …"
        } else if fw.isDownloading {
            fwUpdateLabel.stringValue = "Download läuft …"
            fwUpdateLabel.textColor = .secondaryLabelColor
            fwFlashButton.isEnabled = false
            fwFlashButton.title = "downloading …"
        } else {
            fwUpdateLabel.stringValue = "Aktuell."
            fwUpdateLabel.textColor = .secondaryLabelColor
            fwFlashButton.isEnabled = false
            fwFlashButton.title = "Firmware flashen …"
        }

        // Inline Flash-Progress — v1.12.0 mit mehrstufigem Phase-Label unter
        // der ProgressBar (Download/Connect/Erase/Write %/Verify/Reboot/Fertig).
        if fw.isFlashing {
            fwProgressBar.isHidden = false
            fwProgressLabel.isHidden = false
            fwProgressLabel.stringValue = fw.flashProgress
            if case .writing = fw.flashPhase {
                // Determinate während Write — echter Prozentwert aus esptool.
                fwProgressBar.isIndeterminate = false
                fwProgressBar.stopAnimation(nil)
                fwProgressBar.doubleValue = Double(fw.flashWritePercent)
            } else {
                fwProgressBar.isIndeterminate = true
                fwProgressBar.startAnimation(nil)
            }
        } else if fw.isDownloading {
            fwProgressBar.isHidden = false
            fwProgressLabel.isHidden = false
            fwProgressBar.isIndeterminate = false
            fwProgressBar.stopAnimation(nil)
            fwProgressBar.doubleValue = fw.downloadProgress * 100.0
            // Phase-Label aus FirmwareManager, falls gesetzt (Download läuft =
            // „Firmware wird geladen …"), sonst Legacy-Label.
            if !fw.flashProgress.isEmpty {
                fwProgressLabel.stringValue = fw.flashProgress
            } else {
                fwProgressLabel.stringValue = String(format: "Download: %.0f %%", fw.downloadProgress * 100.0)
            }
        } else if case .done = fw.flashPhase {
            // Kurz nach Abschluss den „Fertig."-Status noch anzeigen.
            fwProgressBar.isHidden = false
            fwProgressLabel.isHidden = false
            fwProgressBar.isIndeterminate = false
            fwProgressBar.stopAnimation(nil)
            fwProgressBar.doubleValue = 100
            fwProgressLabel.stringValue = fw.flashProgress
        } else {
            fwProgressBar.isHidden = true
            fwProgressLabel.isHidden = true
            fwProgressBar.stopAnimation(nil)
        }

        // Display-Settings
        switch Settings.shared.orientation {
        case "landscape_left", "landscape": orientationPopup.selectItem(at: 1)
        case "landscape_right": orientationPopup.selectItem(at: 2)
        default: orientationPopup.selectItem(at: 0)
        }
        languagePopup.selectItem(at: Settings.shared.language == "en" ? 1 : 0)
        switch Settings.shared.themeMode {
        case "dark": themePopup.selectItem(at: 1)
        case "light": themePopup.selectItem(at: 2)
        default: themePopup.selectItem(at: 0)
        }

        if brightnessSlider != nil {
            let br = Settings.shared.lastKnownBrightness
            if Int(brightnessSlider.doubleValue.rounded()) != br {
                brightnessSlider.doubleValue = Double(br)
            }
            brightnessValueLabel.stringValue = "\(br) %"
        }

        // Footer-Version (falls kAppVersion sich in einem Hot-Reload mal aendert)
        footerVersionLabel?.stringValue = "AI Monitor v\(kAppVersion)"

        refreshLiveLabels()
    }

    /// Für Timer-Tick (Alter des letzten Updates).
    private func refreshLiveLabels() {
        guard let monitor = monitor else { return }
        if let d = monitor.lastUpdateDate {
            let age = Int(Date().timeIntervalSince(d))
            let txt: String
            if age < 60 { txt = "vor \(age) s" }
            else if age < 3600 { txt = "vor \(age/60) m" }
            else { txt = "vor \(age/3600) h \((age%3600)/60) m" }
            lastUpdateLabel.stringValue = "Letztes Update an ESP32: \(txt)"
        } else {
            lastUpdateLabel.stringValue = "Letztes Update an ESP32: —"
        }

        // Flash-Fortschritts-Text live nachziehen (Phase-Label + Write-%)
        let fw = FirmwareManager.shared
        if fw.isFlashing {
            fwProgressLabel.stringValue = fw.flashProgress
            if case .writing = fw.flashPhase {
                fwProgressBar.isIndeterminate = false
                fwProgressBar.doubleValue = Double(fw.flashWritePercent)
            }
        }
    }

    private func rebuildPortPopup() {
        guard let monitor = monitor else { return }
        portPopup.removeAllItems()
        let available = monitor.serialPort.availablePortPaths()
        if available.isEmpty {
            portPopup.addItem(withTitle: "(keine Ports gefunden)")
            portPopup.isEnabled = false
            return
        }
        portPopup.isEnabled = true
        portPopup.addItem(withTitle: "(automatisch)")
        for p in available {
            portPopup.addItem(withTitle: (p as NSString).lastPathComponent)
        }
        if let manual = Settings.shared.manualPortPath,
           let idx = available.firstIndex(of: manual) {
            portPopup.selectItem(at: idx + 1)
        } else {
            portPopup.selectItem(at: 0)
        }
    }

    // MARK: - Actions

    @objc private func providerChosen() {
        let idx = providerSegmented.selectedSegment
        let provider = (idx == 1) ? "codex" : "claude"
        monitor?.setSelectedProvider(provider)
        update()
    }

    @objc private func reloadCodexBar() {
        monitor?.codexBar.loadOnce()
        update()
    }

    @objc private func refreshPorts() {
        rebuildPortPopup()
    }

    @objc private func portChosen() {
        guard let monitor = monitor else { return }
        let idx = portPopup.indexOfSelectedItem
        if idx <= 0 {
            Settings.shared.manualPortPath = nil
            monitor.serialPort.requestReconnect()
        } else {
            let available = monitor.serialPort.availablePortPaths()
            if idx - 1 < available.count {
                let path = available[idx - 1]
                Settings.shared.manualPortPath = path
                monitor.serialPort.requestReconnect()
            }
        }
    }

    @objc private func themeChosen() {
        let modes = ["system", "dark", "light"]
        let i = themePopup.indexOfSelectedItem
        Settings.shared.themeMode = modes[max(0, min(i, modes.count - 1))]
        monitor?.sendThemeToESP32()
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
    private func rebuildTimeZonePopup() {
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
        monitor?.sendBrightnessToESP32(pct)
    }

    @objc fileprivate func flashFirmware() {
        (NSApp.delegate as? AppDelegate)?.runFirmwareFlash()
    }

    @objc fileprivate func checkAppUpdate() {
        (NSApp.delegate as? AppDelegate)?.runAppUpdateCheck()
    }

    @objc fileprivate func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AI Monitor v\(kAppVersion)"
        alert.informativeText = """
        macOS-Hintergrund-App für das ESP32-Usage-Display.

        Liest Claude- und Codex-Nutzung aus der lokalen CodexBar-App \
        (widget-snapshot.json im Group Container) und sendet Session- und \
        Weekly-Werte per USB-Serial an das ESP32-Display.

        Repo: github.com/tobymarks/esp32-ai-monitor

        © 2026 Tobias Marks
        Chatbot icons created by LAFS — Flaticon
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc fileprivate func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// ============================================================
// MARK: - TimeZone Picker Datasource
// ============================================================

/// Datasource + Delegate für den „Weitere …"-TZ-Picker. Hält die komplette
/// IANA-Liste und ein Live-Filterergebnis. Das Search-Field triggert
/// `searchChanged(_:)`, reloadData + (falls zutreffend) Auswahl-Scrolling.
private final class TimeZoneTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var allIdentifiers: [String] = []
    var filtered: [String] = []
    weak var tableView: NSTableView?
    weak var searchField: NSSearchField?

    @objc func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if query.isEmpty {
            filtered = allIdentifiers
        } else {
            filtered = allIdentifiers.filter { $0.lowercased().contains(query) }
        }
        tableView?.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("tzCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = NSFont.systemFont(ofSize: 12)
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = filtered[row]
        return cell
    }
}
