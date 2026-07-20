/**
 * SettingsWindow.swift — Einziges sichtbares UI der App (LSUIElement=YES).
 *
 * Ab v1.11.0: Querformat-Layout, Zwei-Spalten-Split statt langer vertikaler
 * Liste. Header mit Provider-Umschalter rechts.
 *
 * Ab v1.20.9: Footer bleibt bewusst schlank. Updates liegen nur noch im
 * Updates-Tab.
 *
 * Ab v1.23.0: Fenster ist resizable (Startgroesse 960×760, Minimum 720×520),
 * jede Seite liegt in einer eigenen NSScrollView. „Über AI Monitor" ist im
 * Footer jetzt ein SF-Symbol-Button (zusaetzlich im App-Menue).
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
    var contentContainer: NSView!
    var banner: NotificationBanner!
    var sectionViews: [NSView] = []
    var appSettingsToggle: NSButton!
    var updateChannelPopup: NSPopUpButton!
    var setupStatusDot: StatusIndicator!
    var setupStatusLabel: NSTextField!
    var setupDetailLabel: NSTextField!
    var nextStepLabel: NSTextField!
    var nextStepDetailLabel: NSTextField!
    var nextStepPrimaryButton: NSButton!
    var nextStepSecondaryButton: NSButton!
    var nextStepPrimaryAction: OverviewAction = .none
    var nextStepSecondaryAction: OverviewAction = .none
    var healthAppDot: StatusIndicator!
    var healthAppLabel: NSTextField!
    var healthAppDetailLabel: NSTextField!
    var healthCodexDot: StatusIndicator!
    var healthCodexLabel: NSTextField!
    var healthCodexDetailLabel: NSTextField!
    var healthUSBDot: StatusIndicator!
    var healthUSBLabel: NSTextField!
    var healthUSBDetailLabel: NSTextField!
    var healthWiFiDot: StatusIndicator!
    var healthWiFiLabel: NSTextField!
    var healthWiFiDetailLabel: NSTextField!
    var healthFirmwareDot: StatusIndicator!
    var healthFirmwareLabel: NSTextField!
    var healthFirmwareDetailLabel: NSTextField!
    var setupTestButton: NSButton!
    var displayTestButton: NSButton!
    var setupCopyButton: NSButton!

    // Linke Spalte — CodexBar
    var codexBarStatusDot: StatusIndicator!
    var codexBarStatusLabel: NSTextField!
    var codexBarValuesLabel: NSTextField!
    var codexBarResetSessionLabel: NSTextField!
    var codexBarResetWeeklyLabel: NSTextField!
    var codexBarReloadButton: NSButton!

    // Linke Spalte — Port
    var portStatusDot: StatusIndicator!
    var portStatusLabel: NSTextField!
    var portPopup: NSPopUpButton!
    var portRefreshButton: NSButton!

    // Linke Spalte — Display-WiFi
    var wifiStatusDot: StatusIndicator!
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

        /// SF Symbol fuer das Toolbar-Item. HIG: „Find icons to represent
        /// common actions" — Symbole sind systemweit wiedererkennbar und
        /// skalieren mit den Systemeinstellungen.
        var symbolName: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.33percent"
            case .display: return "display"
            case .connection: return "cable.connector"
            case .updates: return "arrow.down.circle"
            case .diagnostics: return "stethoscope"
            }
        }

        var toolbarIdentifier: NSToolbarItem.Identifier {
            NSToolbarItem.Identifier("de.aimonitor.section.\(rawValue)")
        }

        init?(toolbarIdentifier: NSToolbarItem.Identifier) {
            guard let match = SettingsSection.allCases.first(where: {
                $0.toolbarIdentifier == toolbarIdentifier
            }) else { return nil }
            self = match
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Monitor"
        window.isReleasedWhenClosed = false
        window.center()
        // HIG „Designing for macOS": „Let people resize, hide, show, and move
        // your windows to fit their work style and device configuration."
        // 960x760 ist nur noch die Startgroesse; nach unten begrenzt die
        // Mindestgroesse, nach oben nichts. Die Seiteninhalte liegen jeweils in
        // einer eigenen NSScrollView, deshalb ist Schrumpfen unkritisch.
        window.minSize = NSSize(width: 720, height: 520)
        // Vom Nutzer gewaehlte Groesse/Position ueber Sitzungen hinweg merken.
        window.setFrameAutosaveName("SettingsWindow")
        // Tab-Reihenfolge von AppKit aus der Geometrie berechnen lassen. Vorher
        // gab es weder eine nextKeyView-Kette noch einen Initialfokus — mit
        // „Full Keyboard Access" war das Fenster praktisch nicht bedienbar.
        window.autorecalculatesKeyViewLoop = true
        self.init(window: window)
        window.delegate = self
        buildUI()
    }

    /// Nicht-modaler Hinweis im Fenster. Holt das Fenster bewusst NICHT nach
    /// vorn — der Hinweis bleibt stehen, bis der Nutzer das Fenster oeffnet.
    func showBanner(state: StatusIndicator.State,
                    title: String,
                    detail: String,
                    actionTitle: String? = nil,
                    action: (() -> Void)? = nil) {
        banner?.show(state: state, title: title, detail: detail,
                     actionTitle: actionTitle, action: action)
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

        installToolbar()

        let header = buildHeader()
        let headerDivider = makeHorizontalDivider()
        let footerDivider = makeHorizontalDivider()
        let footer = buildFooter()
        contentContainer = NSView()
        buildSectionPages(in: contentContainer)

        // Banner + Seiteninhalt in einem vertikalen Stack: NSStackView nimmt
        // ausgeblendete Elemente aus dem Layout, das Banner belegt im
        // Normalfall also keinen Platz.
        banner = NotificationBanner()
        banner.isHidden = true
        let contentStack = NSStackView(views: [banner, contentContainer])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.setHuggingPriority(.defaultLow, for: .vertical)

        [header, headerDivider, contentStack, footerDivider, footer].forEach {
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
            header.heightAnchor.constraint(equalToConstant: 44),

            headerDivider.leadingAnchor.constraint(equalTo: leftGuide),
            headerDivider.trailingAnchor.constraint(equalTo: rightGuide),
            headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            contentStack.leadingAnchor.constraint(equalTo: leftGuide, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: rightGuide, constant: -20),
            contentStack.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 16),

            banner.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            // Fest zwischen Kopfbereich und Footer spannen. Der Stack gibt damit
            // die verfuegbare Hoehe vor; die Scroll-Views der Seiten fuellen den
            // Rest aus und scrollen intern, falls der Seiteninhalt laenger ist.
            // Ist das Banner sichtbar, schrumpft der Seitenbereich entsprechend.
            contentStack.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -16),

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
        window?.initialFirstResponder = providerSegmented
    }

    // MARK: - Header

    /// Kopfzeile mit dem Provider-Umschalter.
    ///
    /// Vorher standen hier zwei optisch identische NSSegmentedControls
    /// untereinander — oben die Datenquelle, darunter die Navigation — mit
    /// voellig verschiedener Bedeutung. Die Navigation ist jetzt eine
    /// NSToolbar im Titelbereich; der verbliebene Umschalter bekommt eine
    /// Beschriftung, damit klar ist, was er tut.
    private func buildHeader() -> NSView {
        let container = NSView()

        let caption = NSTextField(labelWithString: "Datenquelle")
        caption.font = NSFont.appFont(.subheadline)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(caption)

        providerSegmented = NSSegmentedControl(labels: CodexBarProvider.allCases.map(\.displayLabel),
                                               trackingMode: .selectOne,
                                               target: self,
                                               action: #selector(providerChosen))
        providerSegmented.segmentStyle = .rounded
        providerSegmented.toolTip = "Wählt, welche CodexBar-Daten auf dem Display angezeigt werden."
        providerSegmented.selectedSegment = CodexBarProvider
            .normalized(Settings.shared.selectedProvider)
            .segmentIndex
        providerSegmented.setAccessibilityLabel("Datenquelle für das Display")
        providerSegmented.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(providerSegmented)

        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            caption.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            providerSegmented.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 10),
            providerSegmented.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            providerSegmented.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    // MARK: - Toolbar-Navigation

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "de.aimonitor.settings.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = SettingsSection.overview.toolbarIdentifier
        window?.toolbar = toolbar
        // .preference ist der Systemstil fuer Einstellungsfenster: zentrierte
        // Items mit Symbol und Label direkt unter dem Fenstertitel.
        window?.toolbarStyle = .preference
    }

    @objc private func toolbarSectionChosen(_ sender: NSToolbarItem) {
        guard let section = SettingsSection(toolbarIdentifier: sender.itemIdentifier) else { return }
        showSection(section)
    }

    private func buildSectionPages(in container: NSView) {
        let pages: [NSView] = [
            buildOverviewPage(),
            buildDisplayPage(),
            buildConnectionPage(),
            buildUpdatesPage(),
            buildDiagnosticsPage()
        ]

        // Jede Seite bekommt eine eigene NSScrollView. Damit ist die Fensterhoehe
        // nicht mehr an den laengsten Seiteninhalt gekoppelt — Voraussetzung
        // dafuer, dass das Fenster ueberhaupt schrumpfen darf.
        sectionViews = pages.map { page in
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            // NSClipView ist per Default nicht geflippt — ohne das hier klebt
            // kuerzerer Seiteninhalt am unteren statt am oberen Rand.
            scroll.contentView = FlippedClipView()
            // Reihenfolge ist wichtig: die frisch gesetzte ClipView bringt ihren
            // eigenen Default mit (undurchsichtig, controlBackgroundColor). Wird
            // drawsBackground vorher am ScrollView gesetzt, malt die ClipView
            // trotzdem weiss — das ergab den hellen Kasten zwischen Kopf- und
            // Fusszeile. Deshalb erst contentView setzen, dann beide auf
            // transparent, damit durchgehend die Fensterfarbe traegt.
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false

            page.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = page

            let clip = scroll.contentView
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                page.topAnchor.constraint(equalTo: clip.topAnchor),
            ])
            return scroll
        }

        for view in sectionViews {
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
    }

    func showSection(_ section: SettingsSection) {
        for (index, view) in sectionViews.enumerated() {
            view.isHidden = index != section.rawValue
        }
        window?.toolbar?.selectedItemIdentifier = section.toolbarIdentifier
    }

    // MARK: - Footer

    private func buildFooter() -> NSView {
        let container = NSView()

        footerVersionLabel = NSTextField(labelWithString: "AI Monitor v\(kAppVersion)")
        footerVersionLabel.font = NSFont.appFont(.subheadline)
        footerVersionLabel.textColor = .tertiaryLabelColor
        footerVersionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerVersionLabel)

        // „Über AI Monitor" steht zwar zusaetzlich im App-Menue, aber unter
        // .accessory/LSUIElement rendert macOS keine Menueleiste — der Eintrag
        // dort liefert nur das Key-Equivalent. Der sichtbare Pfad muss also im
        // Fenster bleiben. Statt des frueheren handgebauten Pseudo-Links jetzt
        // ein Standard-Symbolbutton.
        footerAboutButton = NSButton()
        footerAboutButton.isBordered = false
        footerAboutButton.image = NSImage(systemSymbolName: "info.circle",
                                          accessibilityDescription: "Über AI Monitor")
        footerAboutButton.imagePosition = .imageOnly
        footerAboutButton.contentTintColor = .secondaryLabelColor
        footerAboutButton.target = self
        footerAboutButton.action = #selector(showAbout)
        footerAboutButton.toolTip = "Über AI Monitor"
        footerAboutButton.setAccessibilityLabel("Über AI Monitor")
        footerAboutButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerAboutButton)

        NSLayoutConstraint.activate([
            footerVersionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerVersionLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            footerAboutButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerAboutButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
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
        l.font = NSFont.appFont(.headline)
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
        label.font = NSFont.appFont(.body)
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true

        // Die visuelle Zuordnung „Label links, Control rechts" existiert fuer
        // VoiceOver nicht — ohne Verknuepfung liest es nur den Wert des
        // Controls vor („Deutsch") ohne zu sagen, wozu er gehoert. Beides
        // setzen: das Label als beschriftendes Element und zusaetzlich als
        // Text, falls das Control keine Titel-Beziehung unterstuetzt.
        if control.accessibilityLabel() == nil {
            control.setAccessibilityLabel(labelText)
        }
        control.setAccessibilityTitleUIElement(label)

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
            codexBarStatusDot.state = .ok
            codexBarStatusLabel.textColor = .labelColor
        } else {
            codexBarStatusDot.state = .attention
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
            case .cliMissing:
                msg = "CodexBar-CLI nicht gefunden („brew install codexbar“)."
            case .providerUnavailable(let m):
                let providerLabel = CodexBarProvider.normalized(src.provider).displayLabel
                msg = "\(providerLabel) liefert keine Daten: \(m)"
            case .cliFailed(let m):
                msg = "Abruf fehlgeschlagen: \(m)"
            case .stale(let age):
                msg = "Daten sind \(age/60) Minuten alt."
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
                portStatusDot.state = .ok
                portStatusLabel.stringValue = "verbunden (\(short))"
                portStatusLabel.textColor = .labelColor
            case .foreignFirmware:
                portStatusDot.state = .attention
                portStatusLabel.stringValue = "Port offen, fremde Firmware (\(short))"
                portStatusLabel.textColor = .systemOrange
            case .probing:
                portStatusDot.state = .pending
                portStatusLabel.stringValue = "Handshake … (\(short))"
                portStatusLabel.textColor = .secondaryLabelColor
            case .disconnected:
                portStatusDot.state = .inactive
                portStatusLabel.stringValue = "nicht verbunden"
                portStatusLabel.textColor = .secondaryLabelColor
            }
        } else {
            portStatusDot.state = .inactive
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
            codexBarReloadButton.title = "Jetzt neu laden"
            codexBarReloadButton.toolTip = "Fragt die Daten über das CodexBar-CLI erneut ab."
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

    /// Wird vom App-Menue (AppDelegate) aufgerufen — daher nicht fileprivate.
    @objc func showAbout() {
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
            tf.font = NSFont.appFont(.callout)
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
        title.font = NSFont.appFont(.title3, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let infoLabel = NSTextField(labelWithString: infoText)
        infoLabel.font = NSFont.appFont(.callout)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(infoLabel)

        let preflightTitle = NSTextField(labelWithString: "Preflight-Check")
        preflightTitle.font = NSFont.appFont(.callout, weight: .medium)
        preflightTitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preflightTitle)

        let preflightText = NSTextField(wrappingLabelWithString: preflightItems.joined(separator: "\n"))
        preflightText.font = NSFont.appMonospacedDigit(.subheadline)
        preflightText.textColor = canStart ? .secondaryLabelColor : .systemOrange
        preflightText.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preflightText)

        let warningLabel = NSTextField(wrappingLabelWithString: warning ?? "")
        warningLabel.font = NSFont.appFont(.subheadline)
        warningLabel.textColor = .systemOrange
        warningLabel.isHidden = (warning == nil)
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(warningLabel)

        let groupLabel = NSTextField(labelWithString: S().flashDialogBoardVariant)
        groupLabel.font = NSFont.appFont(.callout, weight: .medium)
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
        hint.font = NSFont.appFont(.subheadline)
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

// ============================================================
// MARK: - Flipped Clip View
// ============================================================

/// NSClipView mit `isFlipped == true`.
///
/// Ohne das liegt der Ursprung einer NSScrollView unten links: ist der
/// Seiteninhalt kuerzer als die sichtbare Flaeche, klebt er am unteren Rand
/// statt oben zu beginnen. Betrifft alle fuenf Seiten des Einstellungsfensters,
/// sobald es groesser gezogen wird als der Inhalt.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// ============================================================
// MARK: - Toolbar-Delegate
// ============================================================

extension SettingsWindowController: NSToolbarDelegate {

    private var sectionIdentifiers: [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        sectionIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        sectionIdentifiers
    }

    /// Nur selektierbare Items bekommen im .preference-Stil die
    /// Auswahl-Hervorhebung.
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        sectionIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let section = SettingsSection(toolbarIdentifier: itemIdentifier) else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = section.title
        item.paletteLabel = section.title
        item.image = NSImage(systemSymbolName: section.symbolName,
                             accessibilityDescription: section.title)
        // HIG: „Provide an accessibility label for every icon."
        item.toolTip = section.title
        item.target = self
        item.action = #selector(toolbarSectionChosen(_:))
        return item
    }
}
