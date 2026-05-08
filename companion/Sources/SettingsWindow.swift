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

private struct DisplayWiFiNetwork {
    let ssid: String
    let rssi: Int
    let secure: Bool
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    // Referenzen, die von aussen injiziert werden
    weak var monitor: UsageMonitor?

    // Header
    private var providerSegmented: NSSegmentedControl!
    private var sectionSegmented: NSSegmentedControl!
    private var contentContainer: NSView!
    private var sectionViews: [NSView] = []
    private var appSettingsToggle: NSButton!
    private var updateChannelPopup: NSPopUpButton!
    private var setupStatusDot: NSTextField!
    private var setupStatusLabel: NSTextField!
    private var setupDetailLabel: NSTextField!
    private var setupTestButton: NSButton!
    private var setupCopyButton: NSButton!

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

    // Linke Spalte — Display-WiFi
    private var wifiStatusDot: NSTextField!
    private var wifiStatusLabel: NSTextField!
    private var wifiNetworkPopup: NSPopUpButton!
    private var wifiPasswordField: NSSecureTextField!
    private var wifiScanButton: NSButton!
    private var wifiConnectButton: NSButton!
    private var wifiForgetButton: NSButton!
    private var wifiNetworks: [DisplayWiFiNetwork] = []
    private var lastWiFiStatusRefresh: Date?

    // Rechte Spalte — Display
    private var deviceRow: NSView!
    private var deviceNameLabel: NSTextField!
    private var deviceEditButton: NSButton!
    private var deviceEditField: NSTextField!
    private var deviceEditSaveButton: NSButton!
    private var deviceEditCancelButton: NSButton!
    private var deviceEditHintLabel: NSTextField!
    private var deviceEditContainer: NSView!
    private var deviceDisplayContainer: NSView!
    private var deviceProfilesPopup: NSPopUpButton!
    private var deviceForgetButton: NSButton!
    private var isEditingDeviceName: Bool = false
    private var themePopup: NSPopUpButton!
    private var percentModePopup: NSPopUpButton!
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
    private var fwVariantLabel: NSTextField!
    private var fwUpdateLabel: NSTextField!
    private var fwFlashButton: NSButton!
    private var fwProgressBar: NSProgressIndicator!
    private var fwProgressLabel: NSTextField!

    // Footer
    private var footerVersionLabel: NSTextField!
    private var footerAboutButton: NSButton!
    private var footerUpdateButton: NSButton!

    private var refreshTimer: Timer?

    private enum SettingsSection: Int, CaseIterable {
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

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Monitor"
        window.isReleasedWhenClosed = false
        window.center()
        // Fixe Groesse — kein Resize.
        window.minSize = NSSize(width: 960, height: 660)
        window.maxSize = NSSize(width: 960, height: 660)
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
            contentContainer.bottomAnchor.constraint(lessThanOrEqualTo: footerDivider.topAnchor, constant: -16),

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

    private func showSection(_ section: SettingsSection) {
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

        // Ab v1.11.1 dauerhaft sichtbar — die einzigen Wege zur App-Info und
        // zum Update-Checker, weil unter .accessory kein macOS-App-Menue rendert.
        footerAboutButton = makeLinkButton("Über AI Monitor", action: #selector(showAbout))
        footerUpdateButton = makeLinkButton("Nach Updates suchen …", action: #selector(checkAppUpdate))
        footerUpdateButton.toolTip = "Prüft App- und Firmware-Releases auf GitHub."
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

    // MARK: - App

    private func buildOverviewPage() -> NSView {
        let container = NSView()

        let heading = makeSectionHeading("Übersicht")
        heading.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(heading)

        setupStatusDot = NSTextField(labelWithString: "\u{25CF}")
        setupStatusDot.font = NSFont.systemFont(ofSize: 16)
        setupStatusDot.textColor = .secondaryLabelColor

        setupStatusLabel = NSTextField(labelWithString: "Setup wird geprüft …")
        setupStatusLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)

        let setupStatusRow = NSStackView(views: [setupStatusDot, setupStatusLabel])
        setupStatusRow.orientation = .horizontal
        setupStatusRow.spacing = 6
        setupStatusRow.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(setupStatusRow)

        setupDetailLabel = NSTextField(labelWithString: "")
        setupDetailLabel.font = NSFont.systemFont(ofSize: 11)
        setupDetailLabel.textColor = .secondaryLabelColor
        setupDetailLabel.lineBreakMode = .byWordWrapping
        setupDetailLabel.maximumNumberOfLines = 2
        setupDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(setupDetailLabel)

        appSettingsToggle = NSButton(checkboxWithTitle: "Menüleisten-Schnellmenü aktivieren",
                                     target: self,
                                     action: #selector(menuBarQuickMenuToggled))
        appSettingsToggle.font = NSFont.systemFont(ofSize: 13)
        appSettingsToggle.toolTip = "Zeigt Provider-Auswahl und Status direkt in der macOS-Menüleiste."
        appSettingsToggle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(appSettingsToggle)

        let helper = NSTextField(labelWithString: "Zeigt ein NSStatusItem mit Provider-Auswahl und Einstellungen.")
        helper.font = NSFont.systemFont(ofSize: 11)
        helper.textColor = .secondaryLabelColor
        helper.lineBreakMode = .byWordWrapping
        helper.maximumNumberOfLines = 2
        helper.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(helper)

        let codexBox = buildCodexBarBox()
        codexBox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(codexBox)

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            heading.topAnchor.constraint(equalTo: container.topAnchor),

            setupStatusRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            setupStatusRow.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),

            setupDetailLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            setupDetailLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            setupDetailLabel.topAnchor.constraint(equalTo: setupStatusRow.bottomAnchor, constant: 4),
            setupDetailLabel.widthAnchor.constraint(equalToConstant: 620),

            appSettingsToggle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            appSettingsToggle.topAnchor.constraint(equalTo: setupDetailLabel.bottomAnchor, constant: 18),

            helper.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            helper.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            helper.topAnchor.constraint(equalTo: appSettingsToggle.bottomAnchor, constant: 4),

            codexBox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            codexBox.topAnchor.constraint(equalTo: helper.bottomAnchor, constant: 24),
            codexBox.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])

        return container
    }

    private func buildUpdatesPage() -> NSView {
        let appUpdateBox = buildAppUpdateBox()
        let firmwareBox = buildFirmwareBox()

        let stack = NSStackView(views: [appUpdateBox, firmwareBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        return stack
    }

    private func buildAppUpdateBox() -> NSView {
        let heading = makeSectionHeading("App & Updates")

        updateChannelPopup = NSPopUpButton()
        updateChannelPopup.addItems(withTitles: UpdateChannel.allCases.map(\.displayLabel))
        updateChannelPopup.target = self
        updateChannelPopup.action = #selector(updateChannelChosen)
        updateChannelPopup.translatesAutoresizingMaskIntoConstraints = false
        updateChannelPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let channelRow = twoColumnRow("Update-Kanal", updateChannelPopup)

        let channelHelper = NSTextField(labelWithString: "Stable nutzt veröffentlichte Releases. Beta zeigt zusätzlich Vorabversionen für App und Firmware.")
        channelHelper.font = NSFont.systemFont(ofSize: 11)
        channelHelper.textColor = .secondaryLabelColor
        channelHelper.lineBreakMode = .byWordWrapping
        channelHelper.maximumNumberOfLines = 2
        channelHelper.toolTip = "Stable zeigt nur veröffentlichte Versionen. Beta zeigt zusätzlich Vorabversionen."
        updateChannelPopup.toolTip = channelHelper.toolTip

        let checkButton = NSButton(title: "Nach Updates suchen …", target: self, action: #selector(checkAppUpdate))
        checkButton.bezelStyle = .rounded
        checkButton.toolTip = "Prüft App- und Firmware-Releases auf GitHub."

        let stack = NSStackView(views: [heading, channelRow, channelHelper, checkButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func buildConnectionPage() -> NSView {
        let portBox = buildPortBox()
        let wifiBox = buildWiFiBox()

        let stack = NSStackView(views: [portBox, wifiBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        return stack
    }

    private func buildDisplayPage() -> NSView {
        return buildDisplayBox()
    }

    private func buildDiagnosticsPage() -> NSView {
        let heading = makeSectionHeading("Diagnose")

        setupTestButton = NSButton(title: "Testbild senden", target: self, action: #selector(sendTestFrame))
        setupTestButton.bezelStyle = .rounded
        setupTestButton.toolTip = "Sendet einen Beispiel-Screen an das Display, um Verbindung und Darstellung zu prüfen."

        setupCopyButton = NSButton(title: "Diagnose kopieren", target: self, action: #selector(copyDiagnostics))
        setupCopyButton.bezelStyle = .rounded
        setupCopyButton.toolTip = "Kopiert einen technischen Bericht für Fehlersuche und Support."

        let actions = NSStackView(views: [setupTestButton, setupCopyButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let helper = NSTextField(wrappingLabelWithString: "Technische Funktionen für Fehlersuche, Support und Setup-Kontrolle.")
        helper.font = NSFont.systemFont(ofSize: 12)
        helper.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, helper, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
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
        codexBarReloadButton.toolTip = "Liest die aktuellen CodexBar-Daten erneut ein."

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
        portPopup.toolTip = "Automatisch wählt den ersten passenden USB-Serial-Port. Manuelle Auswahl pinnt ein bestimmtes Gerät."
        portPopup.translatesAutoresizingMaskIntoConstraints = false
        portPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        portRefreshButton = NSButton(title: "Ports neu scannen", target: self, action: #selector(refreshPorts))
        portRefreshButton.bezelStyle = .rounded
        portRefreshButton.controlSize = .small
        portRefreshButton.toolTip = "Sucht erneut nach angeschlossenen ESP32-Geräten."

        let controlRow = NSStackView(views: [portPopup, portRefreshButton])
        controlRow.orientation = .horizontal
        controlRow.spacing = 8

        let stack = NSStackView(views: [heading, statusRow, controlRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func buildWiFiBox() -> NSView {
        let heading = makeSectionHeading("Display-WiFi")

        wifiStatusDot = NSTextField(labelWithString: "\u{25CB}")
        wifiStatusDot.font = NSFont.systemFont(ofSize: 13)
        wifiStatusDot.textColor = .secondaryLabelColor

        wifiStatusLabel = NSTextField(labelWithString: "Status unbekannt")
        wifiStatusLabel.font = NSFont.systemFont(ofSize: 13)
        wifiStatusLabel.lineBreakMode = .byTruncatingTail
        wifiStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        wifiStatusLabel.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let statusRow = NSStackView(views: [wifiStatusDot, wifiStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6

        wifiNetworkPopup = NSPopUpButton()
        wifiNetworkPopup.addItem(withTitle: "Noch nicht gescannt")
        wifiNetworkPopup.target = self
        wifiNetworkPopup.action = #selector(wifiNetworkChosen)
        wifiNetworkPopup.toolTip = "Netzwerke, die das ESP32-Display aktuell sieht."
        wifiNetworkPopup.translatesAutoresizingMaskIntoConstraints = false
        wifiNetworkPopup.widthAnchor.constraint(equalToConstant: 260).isActive = true

        wifiScanButton = NSButton(title: "Scannen", target: self, action: #selector(scanWiFi))
        wifiScanButton.bezelStyle = .rounded
        wifiScanButton.controlSize = .small
        wifiScanButton.toolTip = "Sucht WLAN-Netzwerke aus Sicht des ESP32-Displays."

        let scanRow = NSStackView(views: [wifiNetworkPopup, wifiScanButton])
        scanRow.orientation = .horizontal
        scanRow.spacing = 8

        wifiPasswordField = NSSecureTextField()
        wifiPasswordField.placeholderString = "Passwort"
        wifiPasswordField.toolTip = "WLAN-Passwort für das ausgewählte Netzwerk. Wird auf dem Display gespeichert."
        wifiPasswordField.translatesAutoresizingMaskIntoConstraints = false
        wifiPasswordField.widthAnchor.constraint(equalToConstant: 180).isActive = true

        wifiConnectButton = NSButton(title: "Verbinden", target: self, action: #selector(connectWiFi))
        wifiConnectButton.bezelStyle = .rounded
        wifiConnectButton.controlSize = .small
        wifiConnectButton.toolTip = "Speichert das WLAN auf dem Display und verbindet es."

        wifiForgetButton = NSButton(title: "Vergessen", target: self, action: #selector(forgetWiFi))
        wifiForgetButton.bezelStyle = .rounded
        wifiForgetButton.controlSize = .small
        wifiForgetButton.toolTip = "Löscht die gespeicherten WLAN-Daten auf dem Display."

        let connectRow = NSStackView(views: [wifiPasswordField, wifiConnectButton, wifiForgetButton])
        connectRow.orientation = .horizontal
        connectRow.spacing = 8

        let stack = NSStackView(views: [heading, statusRow, scanRow, connectRow])
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

        let rowsStack = NSStackView(views: [
            deviceRowBuilt,
            deviceProfilesRow,
            themeRow,
            percentModeRow,
            orientRow,
            langRow,
            tzRow,
            brightRow
        ])
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 8

        let stack = NSStackView(views: [heading, rowsStack, lastUpdateLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
    private func updateDeviceRow() {
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
    private func updateDisplayControlsEnabled() {
        let ready = (monitor?.serialPort.state == .connected)
        let controls: [NSControl?] = [themePopup, orientationPopup, languagePopup, timeZonePopup, brightnessSlider]
        controls.forEach { $0?.isEnabled = ready }
        brightnessValueLabel?.textColor = ready ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func updateWiFiControlsEnabled() {
        let ready = (monitor?.serialPort.state == .connected)
        let controls: [NSControl?] = [wifiNetworkPopup, wifiPasswordField, wifiScanButton, wifiConnectButton, wifiForgetButton]
        controls.forEach { $0?.isEnabled = ready }
        if !ready {
            wifiStatusDot?.stringValue = "\u{25CB}"
            wifiStatusDot?.textColor = .secondaryLabelColor
            wifiStatusLabel?.stringValue = "ESP32 verbinden, um WiFi einzurichten"
            wifiStatusLabel?.textColor = .secondaryLabelColor
        }
    }

    private func applyWiFiStatus(_ json: [String: Any]?) {
        guard wifiStatusLabel != nil else { return }
        guard let json = json else {
            wifiStatusDot.stringValue = "\u{25CF}"
            wifiStatusDot.textColor = .systemOrange
            wifiStatusLabel.stringValue = "Keine Antwort vom Display"
            wifiStatusLabel.textColor = .systemOrange
            return
        }

        let configured = json["configured"] as? Bool ?? false
        let connected = json["connected"] as? Bool ?? false
        let timeSynced = json["timeSynced"] as? Bool ?? false
        let ssid = (json["ssid"] as? String) ?? ""
        let ip = (json["ip"] as? String) ?? ""
        let rssi = json["rssi"] as? Int ?? 0

        if connected {
            wifiStatusDot.stringValue = "\u{25CF}"
            wifiStatusDot.textColor = timeSynced ? .systemGreen : .systemYellow
            wifiStatusLabel.textColor = .labelColor
            let syncText = timeSynced ? "Zeit synchron" : "warte auf Zeit"
            wifiStatusLabel.stringValue = "\(ssid) · \(ip) · \(rssi) dBm · \(syncText)"
        } else if configured {
            wifiStatusDot.stringValue = "\u{25CF}"
            wifiStatusDot.textColor = .systemOrange
            wifiStatusLabel.textColor = .systemOrange
            wifiStatusLabel.stringValue = ssid.isEmpty ? "Gespeichert, nicht verbunden" : "\(ssid) gespeichert, nicht verbunden"
        } else {
            wifiStatusDot.stringValue = "\u{25CB}"
            wifiStatusDot.textColor = .secondaryLabelColor
            wifiStatusLabel.textColor = .secondaryLabelColor
            wifiStatusLabel.stringValue = "Kein WiFi gespeichert"
        }
    }

    private func requestWiFiStatus(force: Bool = false) {
        guard let monitor = monitor, monitor.serialPort.state == .connected else {
            updateWiFiControlsEnabled()
            return
        }
        if !force, let last = lastWiFiStatusRefresh, Date().timeIntervalSince(last) < 10 {
            return
        }
        lastWiFiStatusRefresh = Date()
        monitor.serialPort.performJSONCommand(["cmd": "wifi_status"],
                                              acceptedTypes: ["wifi_status"],
                                              timeout: 4.0) { [weak self] json in
            self?.applyWiFiStatus(json)
        }
    }

    private func updateWiFiNetworkPopup() {
        wifiNetworkPopup.removeAllItems()
        if wifiNetworks.isEmpty {
            wifiNetworkPopup.addItem(withTitle: "Keine Netzwerke")
            wifiNetworkPopup.isEnabled = false
            return
        }

        wifiNetworkPopup.isEnabled = monitor?.serialPort.state == .connected
        for network in wifiNetworks {
            let secureText = network.secure ? " · gesichert" : ""
            wifiNetworkPopup.addItem(withTitle: "\(network.ssid) · \(network.rssi) dBm\(secureText)")
        }
        wifiNetworkPopup.selectItem(at: 0)
    }

    private func buildFirmwareBox() -> NSView {
        let heading = makeSectionHeading("Firmware")

        fwVersionLabel = NSTextField(labelWithString: "Installiert: —")
        fwVersionLabel.font = NSFont.systemFont(ofSize: 13)

        fwVariantLabel = NSTextField(labelWithString: "Variante: —")
        fwVariantLabel.font = NSFont.systemFont(ofSize: 12)
        fwVariantLabel.textColor = .secondaryLabelColor

        fwUpdateLabel = NSTextField(labelWithString: "")
        fwUpdateLabel.font = NSFont.systemFont(ofSize: 12)
        fwUpdateLabel.textColor = .secondaryLabelColor

        fwFlashButton = NSButton(title: "Firmware flashen …", target: self, action: #selector(flashFirmware))
        fwFlashButton.bezelStyle = .rounded
        fwFlashButton.toolTip = "Installiert die aktuelle Display-Firmware über USB. Nutze die andere Variante, wenn das Bild falsch wirkt."

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
            fwVariantLabel,
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

        // Footer-Version (falls kAppVersion sich in einem Hot-Reload mal aendert)
        let channelSuffix = Settings.shared.updateChannel == .beta ? " · Beta-Kanal" : ""
        footerVersionLabel?.stringValue = "AI Monitor v\(kAppVersion)\(channelSuffix)"

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

    private func updateSetupBox() {
        guard let monitor = monitor, setupStatusLabel != nil else { return }

        let codexOK = monitor.codexBar.status.isOK
        let serialState = monitor.serialPort.state
        let ready = codexOK && serialState == .connected

        setupTestButton.isEnabled = (serialState == .connected)
        setupCopyButton.isEnabled = true

        if ready {
            setupStatusDot.stringValue = "\u{25CF}"
            setupStatusDot.textColor = .systemGreen
            setupStatusLabel.stringValue = "Alles bereit"
            setupStatusLabel.textColor = .labelColor
            let provider = CodexBarProvider.normalized(monitor.codexBar.provider).displayLabel
            let device = DeviceRegistry.shared.currentProfile()?.friendlyName ?? "ESP32"
            setupDetailLabel.stringValue = "\(provider)-Daten sind aktuell, \(device) ist verbunden."
            setupDetailLabel.textColor = .secondaryLabelColor
            return
        }

        switch serialState {
        case .connected:
            setupStatusDot.stringValue = "\u{25CF}"
            setupStatusDot.textColor = .systemOrange
            setupStatusLabel.stringValue = "CodexBar prüfen"
            setupStatusLabel.textColor = .systemOrange
            setupDetailLabel.stringValue = setupDetailForCodexStatus(monitor.codexBar.status,
                                                                     provider: monitor.codexBar.provider)
            setupDetailLabel.textColor = .secondaryLabelColor
        case .foreignFirmware:
            setupStatusDot.stringValue = "\u{25CF}"
            setupStatusDot.textColor = .systemRed
            setupStatusLabel.stringValue = "Firmware fehlt"
            setupStatusLabel.textColor = .systemRed
            var detail = "Der USB-Port ist offen, aber das Gerät antwortet nicht als AI-Monitor."
            if !codexOK { detail += " CodexBar ist ebenfalls nicht bereit." }
            setupDetailLabel.stringValue = detail
            setupDetailLabel.textColor = .secondaryLabelColor
        case .probing:
            setupStatusDot.stringValue = "\u{25CF}"
            setupStatusDot.textColor = .systemYellow
            setupStatusLabel.stringValue = "ESP32-Handshake läuft"
            setupStatusLabel.textColor = .labelColor
            var detail = "Die App prüft gerade, ob auf dem verbundenen Gerät AI-Monitor läuft."
            if !codexOK { detail += " CodexBar ist noch nicht bereit." }
            setupDetailLabel.stringValue = detail
            setupDetailLabel.textColor = .secondaryLabelColor
        case .disconnected:
            setupStatusDot.stringValue = "\u{25CB}"
            setupStatusDot.textColor = codexOK ? .secondaryLabelColor : .systemOrange
            setupStatusLabel.stringValue = codexOK ? "ESP32 verbinden" : "Setup unvollständig"
            setupStatusLabel.textColor = codexOK ? .secondaryLabelColor : .systemOrange
            if codexOK {
                setupDetailLabel.stringValue = "Kein passender USB-Serial-Port erkannt. Kabel, Board oder Port-Auswahl prüfen."
            } else {
                setupDetailLabel.stringValue = "\(setupDetailForCodexStatus(monitor.codexBar.status, provider: monitor.codexBar.provider)) ESP32 ist nicht verbunden."
            }
            setupDetailLabel.textColor = .secondaryLabelColor
        }
    }

    private func setupDetailForCodexStatus(_ status: CodexBarStatus, provider: String) -> String {
        let providerLabel = CodexBarProvider.normalized(provider).displayLabel
        switch status {
        case .ok:
            return "\(providerLabel)-Daten sind aktuell."
        case .missing:
            return "Keine \(providerLabel)-Daten gefunden. CodexBar öffnen und Provider aktivieren."
        case .stale(let age):
            if age == Int.max { return "CodexBar-Snapshot hat keinen gültigen Zeitstempel." }
            return "CodexBar-Daten sind \(age / 60) Minuten alt."
        case .wrongVersion(let found, let expected):
            return "CodexBar-Schema \(found), erwartet \(expected). CodexBar/AI Monitor aktualisieren."
        case .parseError(let message):
            return "CodexBar-Snapshot konnte nicht gelesen werden: \(message)"
        case .notYet:
            return "CodexBar-Daten werden geladen …"
        }
    }

    private func diagnosticReport() -> String {
        guard let monitor = monitor else { return "AI Monitor Diagnose\nMonitor nicht initialisiert." }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium

        func dateText(_ date: Date?) -> String {
            guard let date else { return "—" }
            return df.string(from: date)
        }

        func connectionStateText(_ state: DeviceConnectionState) -> String {
            switch state {
            case .disconnected: return "disconnected"
            case .probing: return "probing"
            case .connected: return "connected"
            case .foreignFirmware: return "foreignFirmware"
            }
        }

        let src = monitor.codexBar
        let serial = monitor.serialPort
        let profile = DeviceRegistry.shared.currentProfile()
        let fw = FirmwareManager.shared
        let availablePorts = serial.availablePortPaths()
        let entry = src.lastEntry

        var lines: [String] = []
        lines.append("AI Monitor Diagnose")
        lines.append("Erstellt: \(df.string(from: Date()))")
        lines.append("")
        lines.append("App")
        lines.append("- Version: \(kAppVersion)")
        lines.append("- Update-Kanal: \(Settings.shared.updateChannel.rawValue)")
        lines.append("- Provider: \(CodexBarProvider.normalized(Settings.shared.selectedProvider).displayLabel)")
        lines.append("- Prozentmodus: \(Settings.shared.usagePercentDisplayMode.rawValue)")
        lines.append("- Zeitzone: \(Settings.shared.selectedTimeZone)")
        lines.append("")
        lines.append("CodexBar")
        lines.append("- Status: \(src.status.shortLabel)")
        lines.append("- Hinweis: \(setupDetailForCodexStatus(src.status, provider: src.provider))")
        lines.append("- Letzter Ladeversuch: \(dateText(src.lastLoadedAt))")
        lines.append("- Snapshot erzeugt: \(dateText(src.lastSnapshotGeneratedAt))")
        lines.append("- Entry updatedAt: \(entry?.updatedAt ?? "—")")
        lines.append("- Session: \(entry?.primary?.usedPercent ?? -1) %")
        lines.append("- Weekly: \(entry?.secondary?.usedPercent ?? -1) %")
        lines.append("")
        lines.append("ESP32")
        lines.append("- Verbindung: \(connectionStateText(serial.state))")
        lines.append("- Aktiver Port: \(serial.connectedPort ?? "—")")
        lines.append("- Manuell gewählter Port: \(Settings.shared.manualPortPath ?? "automatisch")")
        lines.append("- Gefundene Ports: \(availablePorts.isEmpty ? "—" : availablePorts.joined(separator: ", "))")
        lines.append("- Firmware-Version: \(serial.deviceFirmwareVersion ?? "—")")
        lines.append("- Letztes Senden: \(dateText(monitor.lastUpdateDate))")
        if let receipt = serial.lastConfirmedFrameReceipt {
            lines.append("- Letzte bestätigte Frame-ID: #\(receipt.frameId) um \(dateText(receipt.date))")
        } else {
            lines.append("- Letzte bestätigte Frame-ID: —")
        }
        if let receipt = serial.lastFrameReceipt {
            lines.append("- Letzte Frame-Bestätigung: \(receipt.type) #\(receipt.frameId) um \(dateText(receipt.date))")
            lines.append("- Letzte Frame-Nachricht: \(receipt.message ?? "—")")
            lines.append("- Letzte Frame-Größe: \(receipt.bytes.map { "\($0) bytes" } ?? "—")")
            lines.append("- Letzte Frame-Schema-Version: \(receipt.schemaVersion.map(String.init) ?? "—")")
        } else {
            lines.append("- Letzte Frame-Bestätigung: —")
        }
        lines.append("- Unbestätigte Frames in Folge: \(monitor.serialConsecutiveUnconfirmedFrames)")
        lines.append("- Serial-Hinweis: \(monitor.serialLinkDetail ?? "—")")
        lines.append("- Letzter Auto-Reconnect: \(dateText(monitor.lastSerialAutoRepairDate))")
        lines.append("")
        lines.append("Geräteprofil")
        lines.append("- Name: \(profile?.friendlyName ?? "—")")
        lines.append("- MAC: \(profile?.mac ?? "—")")
        lines.append("- Display-Variante: \(profile?.displayVariant ?? "—")")
        lines.append("- Ausrichtung: \(profile?.orientation ?? "—")")
        lines.append("- Theme: \(profile?.theme ?? "—")")
        lines.append("- Sprache: \(profile?.language ?? "—")")
        lines.append("- Helligkeit: \(profile.map { "\($0.brightness) %" } ?? "—")")
        lines.append("")
        lines.append("Bekannte Geräte")
        let profiles = DeviceRegistry.shared.all().values.sorted {
            ($0.lastSeenAt ?? .distantPast) > ($1.lastSeenAt ?? .distantPast)
        }
        if profiles.isEmpty {
            lines.append("- —")
        } else {
            for known in profiles {
                let current = known.mac == DeviceRegistry.shared.currentMAC ? " (aktuell)" : ""
                let lastSeen = dateText(known.lastSeenAt)
                let firmware = known.firmwareVersion.map { "v\($0)" } ?? "—"
                lines.append("- \(known.friendlyName)\(current): \(known.mac), \(known.displayVariant ?? "—"), FW \(firmware), zuletzt \(lastSeen)")
            }
        }
        lines.append("")
        lines.append("Firmware-Update")
        lines.append("- Installiert: \(fw.installedVersionDisplay)")
        lines.append("- Latest: \(fw.latestVersionDisplay)")
        lines.append("- Update verfügbar: \(fw.hasUpdate ? "ja" : "nein")")
        lines.append("- Release-Assets vollständig: \(fw.hasExpectedReleaseAssets ? "ja" : "nein")")
        lines.append("- Fehlende Release-Assets: \(fw.missingExpectedAssetNames.isEmpty ? "—" : fw.missingExpectedAssetNames.joined(separator: ", "))")
        lines.append("- Flash läuft: \(fw.isFlashing ? "ja" : "nein")")

        return lines.joined(separator: "\n")
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
        let provider = CodexBarProvider.fromSegment(index: idx).rawValue
        monitor?.setSelectedProvider(provider)
        update()
    }

    @objc private func menuBarQuickMenuToggled() {
        Settings.shared.menuBarQuickMenuEnabled = (appSettingsToggle.state == .on)
    }

    @objc private func updateChannelChosen() {
        Settings.shared.updateChannel = updateChannelPopup.indexOfSelectedItem == 1 ? .beta : .stable
        update()
    }

    @objc private func reloadCodexBar() {
        monitor?.codexBar.loadOnce()
        update()
    }

    @objc private func sendTestFrame() {
        guard let monitor = monitor else { return }
        if monitor.sendDiagnosticTestFrame() {
            setupDetailLabel.stringValue = "Testbild gesendet. Echte Daten werden automatisch wiederhergestellt."
            setupDetailLabel.textColor = .secondaryLabelColor
        } else {
            setupDetailLabel.stringValue = "Testbild konnte nicht gesendet werden. ESP32-Verbindung prüfen."
            setupDetailLabel.textColor = .systemRed
            NSSound.beep()
        }
    }

    @objc private func copyDiagnostics() {
        let report = diagnosticReport()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        setupDetailLabel.stringValue = "Diagnose wurde in die Zwischenablage kopiert."
        setupDetailLabel.textColor = .secondaryLabelColor
    }

    @objc private func refreshPorts() {
        rebuildPortPopup()
    }

    @objc private func scanWiFi() {
        guard let monitor = monitor, monitor.serialPort.state == .connected else { return }
        wifiScanButton.isEnabled = false
        wifiNetworkPopup.removeAllItems()
        wifiNetworkPopup.addItem(withTitle: "Scan läuft …")
        wifiStatusLabel.stringValue = "Display scannt WiFi-Netzwerke …"
        wifiStatusLabel.textColor = .secondaryLabelColor

        monitor.serialPort.performJSONCommand(["cmd": "wifi_scan"],
                                              acceptedTypes: ["wifi_scan"],
                                              timeout: 18.0) { [weak self] json in
            guard let self = self else { return }
            self.wifiScanButton.isEnabled = (self.monitor?.serialPort.state == .connected)
            guard let items = json?["networks"] as? [[String: Any]] else {
                self.wifiNetworks = []
                self.updateWiFiNetworkPopup()
                self.wifiStatusLabel.stringValue = "Scan fehlgeschlagen"
                self.wifiStatusLabel.textColor = .systemOrange
                return
            }

            var seen = Set<String>()
            self.wifiNetworks = items.compactMap { item in
                guard let ssid = item["ssid"] as? String, !ssid.isEmpty, !seen.contains(ssid) else {
                    return nil
                }
                seen.insert(ssid)
                return DisplayWiFiNetwork(
                    ssid: ssid,
                    rssi: item["rssi"] as? Int ?? 0,
                    secure: item["secure"] as? Bool ?? true
                )
            }
            self.updateWiFiNetworkPopup()
            self.requestWiFiStatus(force: true)
        }
    }

    @objc private func wifiNetworkChosen() {
        wifiPasswordField.stringValue = ""
        window?.makeFirstResponder(wifiPasswordField)
    }

    @objc private func connectWiFi() {
        guard let monitor = monitor, monitor.serialPort.state == .connected else { return }
        let idx = wifiNetworkPopup.indexOfSelectedItem
        guard idx >= 0 && idx < wifiNetworks.count else {
            wifiStatusLabel.stringValue = "Bitte zuerst ein Netzwerk scannen und auswählen."
            wifiStatusLabel.textColor = .systemOrange
            return
        }

        let network = wifiNetworks[idx]
        wifiConnectButton.isEnabled = false
        wifiStatusLabel.stringValue = "Verbinde mit \(network.ssid) …"
        wifiStatusLabel.textColor = .secondaryLabelColor

        monitor.serialPort.performJSONCommand([
            "cmd": "wifi_set",
            "ssid": network.ssid,
            "password": wifiPasswordField.stringValue,
        ], acceptedTypes: ["wifi_status"], timeout: 15.0) { [weak self] json in
            guard let self = self else { return }
            self.wifiConnectButton.isEnabled = (self.monitor?.serialPort.state == .connected)
            self.wifiPasswordField.stringValue = ""
            self.lastWiFiStatusRefresh = Date()
            self.applyWiFiStatus(json)
        }
    }

    @objc private func forgetWiFi() {
        guard let monitor = monitor, monitor.serialPort.state == .connected else { return }
        wifiForgetButton.isEnabled = false
        monitor.serialPort.performJSONCommand(["cmd": "wifi_forget"],
                                              acceptedTypes: ["wifi_status"],
                                              timeout: 5.0) { [weak self] json in
            guard let self = self else { return }
            self.wifiForgetButton.isEnabled = (self.monitor?.serialPort.state == .connected)
            self.lastWiFiStatusRefresh = Date()
            self.applyWiFiStatus(json)
        }
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
                             completion: @escaping (String?) -> Void) {
        let controller = FlashDialogController(info: info, defaultVariant: defaultVariant)
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
    private let defaultVariant: String
    private let infoText: String

    init(info: String, defaultVariant: String) {
        self.infoText = info
        self.defaultVariant = defaultVariant
        let rect = NSRect(x: 0, y: 0, width: 460, height: 270)
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

        let startBtn = NSButton(title: S().flashDialogStart, target: self, action: #selector(onStart))
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"  // Enter
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

            groupLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 18),
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
