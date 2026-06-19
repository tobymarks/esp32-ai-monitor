/**
 * SettingsWindow.swift — Einziges sichtbares UI der App (LSUIElement=YES).
 *
 * Ab v1.11.0: Querformat-Layout, 960×560, nicht resizable. Zwei-Spalten-Split
 * statt langer vertikaler Liste. Header mit Provider-Umschalter rechts.
 *
 * Ab v1.20.9: Footer bleibt bewusst schlank. Updates liegen nur noch im
 * Updates-Tab; „Über AI Monitor" bleibt unten sichtbar.
 *
 * Ab v1.21.0: Die fünf Settings-Tabs sind in eigene Extension-Dateien
 * ausgelagert (SettingsWindow+Overview/Display/Connection/Updates/Diagnostics).
 * Diese Kern-Datei hält Klassendeklaration, gespeicherte Properties, Lifecycle,
 * den Seitengerüst-/Header-/Footer-Aufbau, gemeinsame Builder, die zentrale
 * `update()`-Logik sowie FlashDialogController und TimeZoneTableSource.
 */

import Cocoa
import UniformTypeIdentifiers

struct DisplayWiFiNetwork {
    let ssid: String
    let rssi: Int
    let secure: Bool
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    // Referenzen, die von aussen injiziert werden
    weak var monitor: UsageMonitor?

    // Header
    var providerSegmented: NSSegmentedControl!
    var sectionSegmented: NSSegmentedControl!
    var contentContainer: NSView!
    var sectionViews: [NSView] = []
    var appSettingsToggle: NSButton!
    var updateChannelPopup: NSPopUpButton!
    var setupStatusDot: NSTextField!
    var setupStatusLabel: NSTextField!
    var setupDetailLabel: NSTextField!
    var nextStepLabel: NSTextField!
    var nextStepDetailLabel: NSTextField!
    var nextStepPrimaryButton: NSButton!
    var nextStepSecondaryButton: NSButton!
    var nextStepPrimaryAction: OverviewAction = .none
    var nextStepSecondaryAction: OverviewAction = .none
    var healthAppDot: NSTextField!
    var healthAppLabel: NSTextField!
    var healthAppDetailLabel: NSTextField!
    var healthCodexDot: NSTextField!
    var healthCodexLabel: NSTextField!
    var healthCodexDetailLabel: NSTextField!
    var healthUSBDot: NSTextField!
    var healthUSBLabel: NSTextField!
    var healthUSBDetailLabel: NSTextField!
    var healthWiFiDot: NSTextField!
    var healthWiFiLabel: NSTextField!
    var healthWiFiDetailLabel: NSTextField!
    var healthFirmwareDot: NSTextField!
    var healthFirmwareLabel: NSTextField!
    var healthFirmwareDetailLabel: NSTextField!
    var setupTestButton: NSButton!
    var displayTestButton: NSButton!
    var setupCopyButton: NSButton!

    // Linke Spalte — CodexBar
    var codexBarStatusDot: NSTextField!
    var codexBarStatusLabel: NSTextField!
    var codexBarValuesLabel: NSTextField!
    var codexBarResetSessionLabel: NSTextField!
    var codexBarResetWeeklyLabel: NSTextField!
    var codexBarReloadButton: NSButton!

    // Linke Spalte — Port
    var portStatusDot: NSTextField!
    var portStatusLabel: NSTextField!
    var portPopup: NSPopUpButton!
    var portRefreshButton: NSButton!

    // Linke Spalte — Display-WiFi
    var wifiStatusDot: NSTextField!
    var wifiStatusLabel: NSTextField!
    var wifiNetworkPopup: NSPopUpButton!
    var wifiPasswordField: NSSecureTextField!
    var wifiScanButton: NSButton!
    var wifiConnectButton: NSButton!
    var wifiForgetButton: NSButton!
    var wifiNetworks: [DisplayWiFiNetwork] = []
    var lastWiFiStatusRefresh: Date?
    var lastWiFiStatusJSON: [String: Any]?

    // Rechte Spalte — Display
    var deviceRow: NSView!
    var deviceNameLabel: NSTextField!
    var deviceEditButton: NSButton!
    var deviceEditField: NSTextField!
    var deviceEditSaveButton: NSButton!
    var deviceEditCancelButton: NSButton!
    var deviceEditHintLabel: NSTextField!
    var deviceEditContainer: NSView!
    var deviceDisplayContainer: NSView!
    var deviceProfilesPopup: NSPopUpButton!
    var deviceForgetButton: NSButton!
    var isEditingDeviceName: Bool = false
    var themePopup: NSPopUpButton!
    var percentModePopup: NSPopUpButton!
    var orientationPopup: NSPopUpButton!
    var languagePopup: NSPopUpButton!
    var timeZonePopup: NSPopUpButton!
    var brightnessSlider: NSSlider!
    var brightnessValueLabel: NSTextField!
    var brightnessPersistTimer: Timer?
    var lastUpdateLabel: NSTextField!

    // Zeitzone: Reihenfolge der häufigen Einträge. Erster Eintrag ist
    // immer „Automatisch (macOS)", dann die IANA-Kurzliste, dann „Weitere …".
    let kTimeZonePopupIdentifiers: [String] = [
        "auto",
        "Europe/Berlin",
        "Europe/London",
        "America/New_York",
        "America/Los_Angeles",
        "Asia/Tokyo",
        "Australia/Sydney",
    ]

    // Rechte Spalte — Firmware
    var fwVersionLabel: NSTextField!
    var fwVariantLabel: NSTextField!
    var fwUpdateLabel: NSTextField!
    var fwFlashButton: NSButton!
    var fwProgressBar: NSProgressIndicator!
    var fwProgressLabel: NSTextField!

    // Footer
    var footerVersionLabel: NSTextField!
    var footerAboutButton: NSButton!

    var refreshTimer: Timer?

    enum SettingsSection: Int, CaseIterable {
        case overview
        case display
        case connection
        case updates
        case diagnostics

        var title: String {
            switch self {
            case .overview: return "Übersicht"
            case .display: return "Display"
            case .connection: return "Verbindung"
            case .updates: return "Updates"
            case .diagnostics: return "Diagnose"
            }
        }
    }

    enum OverviewAction {
        case none
        case reloadCodex
        case openDisplay
        case openConnection
        case openUpdates
        case openDiagnostics
        case checkUpdates
        case flashFirmware
        case scanWiFi
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Monitor"
        window.isReleasedWhenClosed = false
        window.center()
        // Fixe Groesse — kein Resize. Höhe 760 (vorher 660): der Health-Check
        // ist jetzt eine eigene voll-breite Sektion im vertikalen Fluss statt
        // einer zweiten Spalte, das braucht mehr Höhe.
        window.minSize = NSSize(width: 960, height: 760)
        window.maxSize = NSSize(width: 960, height: 760)
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
        brightnessPersistTimer?.invalidate()
        brightnessPersistTimer = nil
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

        let header = buildHeader()
        let headerDivider = makeHorizontalDivider()
        let navigation = buildSectionNavigation()
        let footerDivider = makeHorizontalDivider()
        let footer = buildFooter()
        contentContainer = NSView()
        buildSectionPages(in: contentContainer)

        [header, headerDivider, navigation, contentContainer, footerDivider, footer].forEach {
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

            navigation.leadingAnchor.constraint(equalTo: leftGuide, constant: 20),
            navigation.trailingAnchor.constraint(lessThanOrEqualTo: rightGuide, constant: -20),
            navigation.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 12),

            contentContainer.leadingAnchor.constraint(equalTo: leftGuide, constant: 20),
            contentContainer.trailingAnchor.constraint(equalTo: rightGuide, constant: -20),
            contentContainer.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 16),
            // Fest zwischen Navigation und Footer spannen (vorher lessThanOrEqual):
            // ohne festen unteren Anker ist die Container-Hoehe mehrdeutig — die
            // Seiten darin pinnen nur top, also kann Auto-Layout die Hoehe auf 0
            // minimieren, wodurch die Seiteninhalte ueber den Container hinaus
            // ragen und Tab-Leiste/Footer ueberlappen (nicht-deterministisch).
            contentContainer.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -16),

            // Footer
            footerDivider.leadingAnchor.constraint(equalTo: leftGuide),
            footerDivider.trailingAnchor.constraint(equalTo: rightGuide),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            footer.leadingAnchor.constraint(equalTo: leftGuide, constant: 20),
            footer.trailingAnchor.constraint(equalTo: rightGuide, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 0),
            footer.heightAnchor.constraint(equalToConstant: 28),
        ])
        showSection(.overview)
    }

    // MARK: - Header

    private func buildHeader() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "AI Monitor")
        title.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        providerSegmented = NSSegmentedControl(labels: CodexBarProvider.allCases.map(\.displayLabel),
                                               trackingMode: .selectOne,
                                               target: self,
                                               action: #selector(providerChosen))
        providerSegmented.segmentStyle = .rounded
        providerSegmented.toolTip = "Wählt, welche CodexBar-Daten auf dem Display angezeigt werden."
        providerSegmented.selectedSegment = CodexBarProvider
            .normalized(Settings.shared.selectedProvider)
            .segmentIndex
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

    private func buildSectionNavigation() -> NSView {
        let container = NSView()

        sectionSegmented = NSSegmentedControl(labels: SettingsSection.allCases.map(\.title),
                                              trackingMode: .selectOne,
                                              target: self,
                                              action: #selector(sectionChosen))
        sectionSegmented.segmentStyle = .rounded
        sectionSegmented.selectedSegment = SettingsSection.overview.rawValue
        sectionSegmented.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sectionSegmented)

        NSLayoutConstraint.activate([
            sectionSegmented.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sectionSegmented.topAnchor.constraint(equalTo: container.topAnchor),
            sectionSegmented.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func buildSectionPages(in container: NSView) {
        sectionViews = [
            buildOverviewPage(),
            buildDisplayPage(),
            buildConnectionPage(),
            buildUpdatesPage(),
            buildDiagnosticsPage()
        ]

        for view in sectionViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            ])
        }
    }

    func showSection(_ section: SettingsSection) {
        for (index, view) in sectionViews.enumerated() {
            view.isHidden = index != section.rawValue
        }
        sectionSegmented?.selectedSegment = section.rawValue
    }

    @objc private func sectionChosen() {
        let index = sectionSegmented.selectedSegment
        guard let section = SettingsSection(rawValue: index) else { return }
        showSection(section)
    }

    // MARK: - Footer

    private func buildFooter() -> NSView {
        let container = NSView()

        footerVersionLabel = NSTextField(labelWithString: "AI Monitor v\(kAppVersion)")
        footerVersionLabel.font = NSFont.systemFont(ofSize: 11)
        footerVersionLabel.textColor = .tertiaryLabelColor
        footerVersionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerVersionLabel)

        footerAboutButton = makeLinkButton("Über AI Monitor", action: #selector(showAbout))
        container.addSubview(footerAboutButton)

        NSLayoutConstraint.activate([
            footerVersionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerVersionLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            footerAboutButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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
        let wifiBox = buildWiFiBox()

        let stack = NSStackView(views: [codexBox, portBox, wifiBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
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

    // MARK: - Shared builders

    func makeSectionHeading(_ text: String) -> NSTextField {
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

    func twoColumnRow(_ labelText: String, _ control: NSView) -> NSView {
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
            let wantIdx = CodexBarProvider
                .normalized(Settings.shared.selectedProvider)
                .segmentIndex
            if providerSegmented.selectedSegment != wantIdx {
                providerSegmented.selectedSegment = wantIdx
            }
        }

        if appSettingsToggle != nil {
            appSettingsToggle.state = Settings.shared.menuBarQuickMenuEnabled ? .on : .off
        }
        if updateChannelPopup != nil {
            let channel = Settings.shared.updateChannel
            updateChannelPopup.selectItem(at: channel == .beta ? 1 : 0)
        }
        updateSetupBox()

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
            case .accessNotConfigured:
                msg = "CodexBar-Zugriff noch nicht eingerichtet."
            case .missing:
                let providerLabel = CodexBarProvider.normalized(src.provider).displayLabel
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
        // Ab v1.14.2: Dot-Farbe spiegelt den Handshake-State wider — gruen
        // nur bei `.connected`, orange bei `.foreignFirmware` (Port offen,
        // aber keine AI-Monitor-FW), grau bei `.probing`/`.disconnected`.
        let sp = monitor.serialPort
        if sp.isConnected, let p = sp.connectedPort {
            let short = (p as NSString).lastPathComponent
            switch sp.state {
            case .connected:
                portStatusDot.stringValue = "\u{25CF}"
                portStatusDot.textColor = .systemGreen
                portStatusLabel.stringValue = "verbunden (\(short))"
                portStatusLabel.textColor = .labelColor
            case .foreignFirmware:
                portStatusDot.stringValue = "\u{25CF}"
                portStatusDot.textColor = .systemOrange
                portStatusLabel.stringValue = "Port offen, fremde Firmware (\(short))"
                portStatusLabel.textColor = .systemOrange
            case .probing:
                portStatusDot.stringValue = "\u{25CF}"
                portStatusDot.textColor = .systemYellow
                portStatusLabel.stringValue = "Handshake … (\(short))"
                portStatusLabel.textColor = .secondaryLabelColor
            case .disconnected:
                portStatusDot.stringValue = "\u{25CB}"
                portStatusDot.textColor = .secondaryLabelColor
                portStatusLabel.stringValue = "nicht verbunden"
                portStatusLabel.textColor = .secondaryLabelColor
            }
        } else {
            portStatusDot.stringValue = "\u{25CB}"
            portStatusDot.textColor = .secondaryLabelColor
            portStatusLabel.stringValue = "nicht verbunden"
            portStatusLabel.textColor = .secondaryLabelColor
        }
        rebuildPortPopup()

        // Firmware
        // Ab v1.14.2: bei `.foreignFirmware` zeigen wir „Installiert: unbekannt"
        // (die in UserDefaults gecachte Version stammt vom zuletzt aktiven
        // AI-Monitor-Geraet und waere hier irrefuehrend) + einen prominenten
        // Flash-Aufruf. Der Flash-Flow selbst laeuft esptool-seitig gegen
        // den Bootloader und ist damit unabhaengig von der aktuellen FW.
        let fw = FirmwareManager.shared
        let isForeign = (sp.state == .foreignFirmware)
        let profile = DeviceRegistry.shared.currentProfile()
        let missingAssets = fw.missingExpectedAssetNames
        let releaseAssetsOK = missingAssets.isEmpty

        fwVariantLabel.stringValue = firmwareVariantText(profile?.displayVariant, state: sp.state)
        if isForeign {
            fwVersionLabel.stringValue = "Installiert: unbekannt"
            if fw.isFlashing {
                fwUpdateLabel.stringValue = "Flash läuft …"
                fwUpdateLabel.textColor = .secondaryLabelColor
                fwFlashButton.isEnabled = false
                fwFlashButton.title = "flashing …"
            } else if fw.isDownloading {
                fwUpdateLabel.stringValue = "Download läuft …"
                fwUpdateLabel.textColor = .secondaryLabelColor
                fwFlashButton.isEnabled = false
                fwFlashButton.title = "downloading …"
            } else if !releaseAssetsOK {
                fwUpdateLabel.stringValue = "Firmware-Release unvollständig: \(missingAssets.joined(separator: ", "))"
                fwUpdateLabel.textColor = .systemOrange
                fwFlashButton.isEnabled = false
                fwFlashButton.title = "Firmware flashen …"
            } else {
                fwUpdateLabel.stringValue = "Dieses Geraet hat keine AI-Monitor-Firmware. Jetzt flashen, um loszulegen."
                fwUpdateLabel.textColor = .systemRed
                fwFlashButton.isEnabled = true
                fwFlashButton.title = "Firmware flashen"
                fwFlashButton.keyEquivalent = "\r"
            }
        } else {
            fwFlashButton.keyEquivalent = ""
            fwVersionLabel.stringValue = "Installiert: \(fw.installedVersionDisplay)"
            if fw.isFlashing {
                fwUpdateLabel.stringValue = "Flash läuft …"
                fwUpdateLabel.textColor = .secondaryLabelColor
                fwFlashButton.isEnabled = false
                fwFlashButton.title = "flashing …"
            } else if fw.isDownloading {
                fwUpdateLabel.stringValue = "Download läuft …"
                fwUpdateLabel.textColor = .secondaryLabelColor
                fwFlashButton.isEnabled = false
                fwFlashButton.title = "downloading …"
            } else if !releaseAssetsOK {
                fwUpdateLabel.stringValue = "Firmware-Release unvollständig: \(missingAssets.joined(separator: ", "))"
                fwUpdateLabel.textColor = .systemOrange
                fwFlashButton.isEnabled = false
                fwFlashButton.title = "Firmware flashen …"
            } else if fw.hasUpdate {
                fwUpdateLabel.stringValue = "Update verfügbar: \(fw.latestVersionDisplay)"
                fwUpdateLabel.textColor = .systemBlue
                fwFlashButton.isEnabled = (sp.state == .connected)
                fwFlashButton.title = "Firmware flashen …"
            } else {
                fwUpdateLabel.stringValue = "Aktuell."
                fwUpdateLabel.textColor = .secondaryLabelColor
                fwFlashButton.isEnabled = (sp.state == .connected && fw.latestRelease != nil)
                fwFlashButton.title = "Andere Display-Variante flashen …"
            }
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

        // Device-Zeile (ab v1.14.0)
        updateDeviceRow()

        // Display-Settings
        // Ab v1.14.2: nur in State `.connected` werden die Control-Werte aus
        // dem aktiven DeviceProfile gelesen. In allen anderen Zustaenden
        // (`.foreignFirmware`, `.probing`, `.disconnected`) zeigen wir keine
        // profil-spezifischen Werte — stattdessen „—" — damit offensichtlich
        // ist, dass hier nichts aktiv gepusht wird.
        let ready = (sp.state == .connected)
        switch Settings.shared.usagePercentDisplayMode {
        case .remaining: percentModePopup.selectItem(at: 1)
        case .used: percentModePopup.selectItem(at: 0)
        }
        if ready {
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
        } else {
            // Popups auf den ersten „neutralen" Eintrag, Brightness-Label „—".
            orientationPopup.selectItem(at: 0)
            languagePopup.selectItem(at: 0)
            themePopup.selectItem(at: 0)
            if brightnessSlider != nil {
                brightnessValueLabel.stringValue = "—"
            }
        }
        updateDisplayControlsEnabled()
        updateWiFiControlsEnabled()
        requestWiFiStatus()

        if codexBarReloadButton != nil {
            if case .accessNotConfigured = src.status {
                codexBarReloadButton.title = "Zugriff einrichten …"
                codexBarReloadButton.toolTip = "Wählt die widget-snapshot.json aus CodexBar einmalig aus."
            } else {
                codexBarReloadButton.title = "Jetzt neu laden"
                codexBarReloadButton.toolTip = "Liest die aktuellen CodexBar-Daten erneut ein."
            }
        }

        // Footer-Version (falls kAppVersion sich in einem Hot-Reload mal aendert)
        let channelSuffix = Settings.shared.updateChannel == .beta ? " · Beta-Kanal" : ""
        footerVersionLabel?.stringValue = "AI Monitor v\(kAppVersion)\(channelSuffix)"

        updateOverviewGuidance()
        refreshLiveLabels()
    }

    /// Für Timer-Tick (Alter des letzten Updates).
    private func refreshLiveLabels() {
        guard let monitor = monitor else { return }
        // Ab v1.14.2: „Letztes Update an ESP32" nur im State `.connected`
        // anzeigen — sonst ist die Aussage nicht definiert.
        let ready = (monitor.serialPort.state == .connected)
        if !ready {
            lastUpdateLabel.stringValue = ""
            lastUpdateLabel.isHidden = true
        } else {
            lastUpdateLabel.isHidden = false
            if let d = monitor.lastUpdateDate {
                let age = Int(Date().timeIntervalSince(d))
                let txt: String
                if age < 60 { txt = "vor \(age) s" }
                else if age < 3600 { txt = "vor \(age/60) m" }
                else { txt = "vor \(age/3600) h \((age%3600)/60) m" }
                let receipt = serialFrameReceiptText(monitor.serialPort.lastFrameReceipt)
                let detail = monitor.serialLinkDetail.map { " · \($0)" } ?? ""
                lastUpdateLabel.stringValue = "Letztes Update an ESP32: \(txt)\(receipt)\(detail)"
            } else if let detail = monitor.serialLinkDetail {
                lastUpdateLabel.stringValue = "Letztes Update an ESP32: — · \(detail)"
            } else {
                lastUpdateLabel.stringValue = "Letztes Update an ESP32: —"
            }
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

    private func serialFrameReceiptText(_ receipt: SerialFrameReceipt?) -> String {
        guard let receipt else { return " · noch nicht bestätigt" }
        let age = Int(Date().timeIntervalSince(receipt.date))
        let ageText: String
        if age < 60 { ageText = "vor \(age) s" }
        else if age < 3600 { ageText = "vor \(age / 60) m" }
        else { ageText = "vor \(age / 3600) h" }

        switch receipt.type {
        case "ack":
            return " · bestätigt #\(receipt.frameId) \(ageText)"
        case "error":
            return " · Fehler #\(receipt.frameId)"
        default:
            return " · unbestätigt #\(receipt.frameId)"
        }
    }

    private func firmwareVariantText(_ variant: String?, state: DeviceConnectionState) -> String {
        guard state == .connected else { return "Variante: unbekannt" }
        switch variant {
        case kDisplayVariantILI9341:
            return "Variante: ILI9341 / R-Board"
        case kDisplayVariantST7789:
            return "Variante: ST7789 / Hybrid-Board"
        default:
            return "Variante: unbekannt"
        }
    }

    // MARK: - Actions

    @objc private func providerChosen() {
        let idx = providerSegmented.selectedSegment
        let provider = CodexBarProvider.fromSegment(index: idx).rawValue
        monitor?.setSelectedProvider(provider)
        update()
    }

    @objc fileprivate func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AI Monitor v\(kAppVersion)"
        alert.informativeText = """
        macOS-Hintergrund-App für das ESP32-Usage-Display.

        Liest Claude-, Codex- und Antigravity-Nutzung aus der lokalen CodexBar-App \
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
final class TimeZoneTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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

// ============================================================
// MARK: - Flash-Dialog (ab App v1.15.0)
// ============================================================

/// Modaler Dialog fuer die Board-Variant-Auswahl vor dem Firmware-Flash.
/// Ersetzt ab v1.15.0 den simplen NSAlert-Bestaetigungsdialog, weil die
/// CYD-Revisionen (ILI9341 vs. ST7789) am Produktnamen nicht unterscheidbar
/// sind. Der Dialog wird per `presentModal(info:defaultVariant:completion:)`
/// angezeigt und liefert die gewaehlte Variante (oder `nil` bei Abbruch).
final class FlashDialogController: NSWindowController {

    /// Einstiegspunkt. Blockiert nicht (runModal wird selbst aufgerufen).
    /// `defaultVariant` waehlt den Radio-Button vor (aus DeviceProfile oder
    /// Fallback ILI9341). `completion` wird mit der gewaehlten Variante
    /// aufgerufen oder mit `nil` bei Abbruch.
    static func presentModal(info: String,
                             defaultVariant: String,
                             preflightItems: [String],
                             warning: String?,
                             canStart: Bool,
                             completion: @escaping (String?) -> Void) {
        let controller = FlashDialogController(info: info,
                                               defaultVariant: defaultVariant,
                                               preflightItems: preflightItems,
                                               warning: warning,
                                               canStart: canStart)
        controller.completion = completion
        guard let window = controller.window else { completion(nil); return }
        // Modal gegenueber dem Settings-Fenster (falls offen), sonst
        // standalone-Modal. runModal blockiert den Main-Thread — ok, wir
        // kommen aus einer UI-Action.
        window.center()
        NSApp.runModal(for: window)
        window.orderOut(nil)
    }

    private var completion: ((String?) -> Void)?
    private var radioStandard: NSButton!
    private var radioAlternative: NSButton!
    private var startBtn: NSButton!
    private let defaultVariant: String
    private let infoText: String
    private let preflightItems: [String]
    private let warning: String?
    private let canStart: Bool

    init(info: String,
         defaultVariant: String,
         preflightItems: [String],
         warning: String?,
         canStart: Bool) {
        self.infoText = info
        self.defaultVariant = defaultVariant
        self.preflightItems = preflightItems
        self.warning = warning
        self.canStart = canStart
        let rect = NSRect(x: 0, y: 0, width: 520, height: 380)
        let mask: NSWindow.StyleMask = [.titled, .closable]
        let window = NSWindow(contentRect: rect, styleMask: mask,
                              backing: .buffered, defer: false)
        window.title = S().flashDialogTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: S().flashDialogTitle)
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let infoLabel = NSTextField(labelWithString: infoText)
        infoLabel.font = NSFont.systemFont(ofSize: 12)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(infoLabel)

        let preflightTitle = NSTextField(labelWithString: "Preflight-Check")
        preflightTitle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        preflightTitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preflightTitle)

        let preflightText = NSTextField(wrappingLabelWithString: preflightItems.joined(separator: "\n"))
        preflightText.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        preflightText.textColor = canStart ? .secondaryLabelColor : .systemOrange
        preflightText.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preflightText)

        let warningLabel = NSTextField(wrappingLabelWithString: warning ?? "")
        warningLabel.font = NSFont.systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.isHidden = (warning == nil)
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(warningLabel)

        let groupLabel = NSTextField(labelWithString: S().flashDialogBoardVariant)
        groupLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        groupLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(groupLabel)

        radioStandard = NSButton(radioButtonWithTitle: S().flashDialogVariantStandard,
                                 target: self, action: #selector(variantChanged(_:)))
        radioStandard.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(radioStandard)

        radioAlternative = NSButton(radioButtonWithTitle: S().flashDialogVariantAlternative,
                                    target: self, action: #selector(variantChanged(_:)))
        radioAlternative.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(radioAlternative)

        // Default-Auswahl setzen.
        if defaultVariant == kDisplayVariantST7789 {
            radioAlternative.state = .on
        } else {
            radioStandard.state = .on
        }

        let hint = NSTextField(wrappingLabelWithString: S().flashDialogVariantHint)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        startBtn = NSButton(title: S().flashDialogStart, target: self, action: #selector(onStart))
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"  // Enter
        startBtn.isEnabled = canStart
        startBtn.toolTip = canStart
            ? "Startet Download und Flash mit der gewählten Display-Variante."
            : "Flashen ist blockiert, bis der Preflight-Check grün ist."
        startBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(startBtn)

        let cancelBtn = NSButton(title: S().cancel, target: self, action: #selector(onCancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"  // Escape
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            infoLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            infoLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            preflightTitle.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 16),
            preflightTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            preflightTitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            preflightText.topAnchor.constraint(equalTo: preflightTitle.bottomAnchor, constant: 6),
            preflightText.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            preflightText.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            warningLabel.topAnchor.constraint(equalTo: preflightText.bottomAnchor, constant: 6),
            warningLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            warningLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            groupLabel.topAnchor.constraint(equalTo: warningLabel.bottomAnchor, constant: 14),
            groupLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            radioStandard.topAnchor.constraint(equalTo: groupLabel.bottomAnchor, constant: 8),
            radioStandard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            radioStandard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            radioAlternative.topAnchor.constraint(equalTo: radioStandard.bottomAnchor, constant: 6),
            radioAlternative.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            radioAlternative.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            hint.topAnchor.constraint(equalTo: radioAlternative.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            startBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            startBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            cancelBtn.trailingAnchor.constraint(equalTo: startBtn.leadingAnchor, constant: -10),
        ])
    }

    @objc private func variantChanged(_ sender: NSButton) {
        // Radio-Group-Mutex: NSButton als radioButtonWithTitle haelt das
        // Mutex nur, wenn alle Buttons dieselbe `action` haben — was hier
        // der Fall ist.
        _ = sender
    }

    @objc private func onStart() {
        let chosen: String = (radioAlternative.state == .on)
            ? kDisplayVariantST7789 : kDisplayVariantILI9341
        NSApp.stopModal()
        completion?(chosen)
        completion = nil
    }

    @objc private func onCancel() {
        NSApp.stopModal()
        completion?(nil)
        completion = nil
    }
}
