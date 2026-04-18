/**
 * SettingsWindow.swift — Einziges sichtbares UI der App (LSUIElement=YES).
 *
 * Enthaelt alle Features, die frueher im Menubar-Menue waren:
 *  - Port-Status + Port-Auswahl
 *  - CodexBar-Status (OK / stale / missing / wrong version)
 *  - Firmware-Version + Flash-Button + Flash-/Download-Fortschritt
 *  - Theme (System / Dark / Light) — wirkt auf ESP32
 *  - Orientation
 *  - Sprache (DE / EN)
 *  - Letztes Update
 *  - About
 *
 * Brightness wird vom Firmware-Protokoll aktuell nicht unterstuetzt und
 * deshalb hier nicht implementiert — siehe Backlog im Thread.
 */

import Cocoa

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    // Referenzen, die von aussen injiziert werden
    weak var monitor: UsageMonitor?

    // Views (re-used via update())
    private var codexBarStatusLabel: NSTextField!
    private var codexBarDetailLabel: NSTextField!
    private var portStatusLabel: NSTextField!
    private var portPopup: NSPopUpButton!
    private var portRefreshButton: NSButton!

    private var fwVersionLabel: NSTextField!
    private var fwUpdateLabel: NSTextField!
    private var fwFlashButton: NSButton!
    private var fwProgressBar: NSProgressIndicator!
    private var fwProgressLabel: NSTextField!

    private var languagePopup: NSPopUpButton!
    private var orientationPopup: NSPopUpButton!
    private var themePopup: NSPopUpButton!

    private var lastUpdateLabel: NSTextField!

    private var appVersionLabel: NSTextField!
    private var appUpdateButton: NSButton!

    private var refreshTimer: Timer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Monitor"
        window.isReleasedWhenClosed = false
        window.center()
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

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        stack.addArrangedSubview(buildHeader())
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(buildCodexBarSection())
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(buildPortSection())
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(buildFirmwareSection())
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(buildDisplaySection())
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(buildAppSection())
    }

    private func makeSeparator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        v.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return v
    }

    private func buildHeader() -> NSView {
        let title = NSTextField(labelWithString: "AI Monitor")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "Claude-Usage aus CodexBar -> ESP32-Display")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let v = NSStackView(views: [title, subtitle])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 2
        return v
    }

    // --- CodexBar ---

    private func buildCodexBarSection() -> NSView {
        let heading = makeSectionHeading("CodexBar-Datenquelle")

        codexBarStatusLabel = NSTextField(labelWithString: "Status: …")
        codexBarStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        codexBarDetailLabel = NSTextField(labelWithString: "")
        codexBarDetailLabel.font = NSFont.systemFont(ofSize: 11)
        codexBarDetailLabel.textColor = .secondaryLabelColor
        codexBarDetailLabel.lineBreakMode = .byWordWrapping
        codexBarDetailLabel.maximumNumberOfLines = 3
        codexBarDetailLabel.preferredMaxLayoutWidth = 480

        let refresh = NSButton(title: "Jetzt neu laden", target: self, action: #selector(reloadCodexBar))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small

        let stack = NSStackView(views: [heading, codexBarStatusLabel, codexBarDetailLabel, refresh])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    // --- Port ---

    private func buildPortSection() -> NSView {
        let heading = makeSectionHeading("USB-Verbindung zum ESP32")

        portStatusLabel = NSTextField(labelWithString: "Port: nicht verbunden")
        portStatusLabel.font = NSFont.systemFont(ofSize: 13)

        portPopup = NSPopUpButton()
        portPopup.target = self
        portPopup.action = #selector(portChosen)

        portRefreshButton = NSButton(title: "Ports neu scannen", target: self, action: #selector(refreshPorts))
        portRefreshButton.bezelStyle = .rounded
        portRefreshButton.controlSize = .small

        let row = NSStackView(views: [portPopup, portRefreshButton])
        row.orientation = .horizontal
        row.spacing = 8

        let stack = NSStackView(views: [heading, portStatusLabel, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    // --- Firmware ---

    private func buildFirmwareSection() -> NSView {
        let heading = makeSectionHeading("Firmware")

        fwVersionLabel = NSTextField(labelWithString: "Installiert: -")
        fwVersionLabel.font = NSFont.systemFont(ofSize: 13)

        fwUpdateLabel = NSTextField(labelWithString: "")
        fwUpdateLabel.font = NSFont.systemFont(ofSize: 11)
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
        fwProgressBar.widthAnchor.constraint(equalToConstant: 480).isActive = true

        fwProgressLabel = NSTextField(labelWithString: "")
        fwProgressLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        fwProgressLabel.textColor = .secondaryLabelColor
        fwProgressLabel.isHidden = true

        let stack = NSStackView(views: [heading, fwVersionLabel, fwUpdateLabel, fwFlashButton, fwProgressBar, fwProgressLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    // --- Display-Settings ---

    private func buildDisplaySection() -> NSView {
        let heading = makeSectionHeading("Display-Einstellungen")

        // Theme
        let themeLabel = NSTextField(labelWithString: "Theme")
        themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: ["Automatisch (macOS)", "Dark", "Light"])
        themePopup.target = self
        themePopup.action = #selector(themeChosen)
        let themeRow = twoColumnRow(themeLabel, themePopup)

        // Orientation
        let orientLabel = NSTextField(labelWithString: "Ausrichtung")
        orientationPopup = NSPopUpButton()
        orientationPopup.addItems(withTitles: ["Hochformat", "Querformat (USB links)", "Querformat (USB rechts)"])
        orientationPopup.target = self
        orientationPopup.action = #selector(orientationChosen)
        let orientRow = twoColumnRow(orientLabel, orientationPopup)

        // Language
        let langLabel = NSTextField(labelWithString: "Sprache")
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Deutsch", "English"])
        languagePopup.target = self
        languagePopup.action = #selector(languageChosen)
        let langRow = twoColumnRow(langLabel, languagePopup)

        lastUpdateLabel = NSTextField(labelWithString: "Letztes Update: -")
        lastUpdateLabel.font = NSFont.systemFont(ofSize: 11)
        lastUpdateLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, themeRow, orientRow, langRow, lastUpdateLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    // --- App-Version / About ---

    private func buildAppSection() -> NSView {
        let heading = makeSectionHeading("App")

        appVersionLabel = NSTextField(labelWithString: "AI Monitor v\(kAppVersion)")
        appVersionLabel.font = NSFont.systemFont(ofSize: 13)

        appUpdateButton = NSButton(title: "Nach App-Updates suchen …", target: self, action: #selector(checkAppUpdate))
        appUpdateButton.bezelStyle = .rounded
        appUpdateButton.controlSize = .small

        let aboutButton = NSButton(title: "Ueber AI Monitor", target: self, action: #selector(showAbout))
        aboutButton.bezelStyle = .rounded
        aboutButton.controlSize = .small

        let quitButton = NSButton(title: "Beenden", target: self, action: #selector(quitApp))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small

        let buttonRow = NSStackView(views: [appUpdateButton, aboutButton, quitButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [heading, appVersionLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func makeSectionHeading(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        return l
    }

    private func twoColumnRow(_ label: NSView, _ control: NSView) -> NSView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.distribution = .fill
        if let l = label as? NSTextField {
            l.widthAnchor.constraint(equalToConstant: 100).isActive = true
            l.alignment = .left
        }
        return row
    }

    // MARK: - Update-Logic

    func update() {
        guard let monitor = monitor else { return }

        // CodexBar
        let src = monitor.codexBar
        let entry = src.lastEntry
        codexBarStatusLabel.stringValue = "Status: " + src.status.shortLabel
        codexBarStatusLabel.textColor = src.status.isOK ? .systemGreen : .systemOrange
        if let e = entry, src.status.isOK {
            let sp = Int((e.primary?.usedPercent ?? 0).rounded())
            let wp = Int((e.secondary?.usedPercent ?? 0).rounded())
            var detail = "Session: \(sp) %   ·   Weekly: \(wp) %"
            if let reset = e.primary?.resetDescription { detail += "\nSession-Reset: \(reset)" }
            if let reset = e.secondary?.resetDescription { detail += "\nWeekly-Reset: \(reset)" }
            codexBarDetailLabel.stringValue = detail
        } else {
            switch src.status {
            case .missing:
                codexBarDetailLabel.stringValue = "widget-snapshot.json nicht gefunden. Ist CodexBar installiert und einmal gelaufen?"
            case .stale(let age):
                codexBarDetailLabel.stringValue = "Daten sind \(age/60) Minuten alt. AI Monitor sendet nichts Neues an den ESP32, bis CodexBar wieder aktualisiert."
            case .wrongVersion(let f, let e):
                codexBarDetailLabel.stringValue = "Schema-Version unerwartet: claude.json version=\(f), erwartet \(e). AI Monitor-Update noetig."
            case .parseError(let msg):
                codexBarDetailLabel.stringValue = "Konnte Snapshot nicht parsen: \(msg)"
            default:
                codexBarDetailLabel.stringValue = ""
            }
        }

        // Port
        let sp = monitor.serialPort
        if sp.isConnected, let p = sp.connectedPort {
            portStatusLabel.stringValue = "Port: \u{25CF} verbunden (\((p as NSString).lastPathComponent))"
            portStatusLabel.textColor = .systemGreen
        } else {
            portStatusLabel.stringValue = "Port: \u{25CB} nicht verbunden"
            portStatusLabel.textColor = .secondaryLabelColor
        }
        rebuildPortPopup()

        // Firmware
        let fw = FirmwareManager.shared
        fwVersionLabel.stringValue = "Installiert: \(fw.installedVersionDisplay)"
        if fw.hasUpdate {
            fwUpdateLabel.stringValue = "Update verfuegbar: \(fw.latestVersionDisplay)"
            fwUpdateLabel.textColor = .systemBlue
            fwFlashButton.isEnabled = sp.isConnected
            fwFlashButton.title = "Firmware flashen …"
        } else if fw.isFlashing {
            fwUpdateLabel.stringValue = "Flash laeuft …"
            fwFlashButton.isEnabled = false
            fwFlashButton.title = "flashing …"
        } else if fw.isDownloading {
            fwUpdateLabel.stringValue = "Download laeuft …"
            fwFlashButton.isEnabled = false
            fwFlashButton.title = "downloading …"
        } else {
            fwUpdateLabel.stringValue = "Aktuell."
            fwUpdateLabel.textColor = .secondaryLabelColor
            fwFlashButton.isEnabled = false
            fwFlashButton.title = "Firmware flashen …"
        }

        // Progress
        if fw.isFlashing {
            fwProgressBar.isHidden = false
            fwProgressLabel.isHidden = false
            // flashProgress ist Freitext ("Writing at 0x... (12 %)")
            fwProgressLabel.stringValue = fw.flashProgress
            fwProgressBar.isIndeterminate = true
            fwProgressBar.startAnimation(nil)
        } else if fw.isDownloading {
            fwProgressBar.isHidden = false
            fwProgressLabel.isHidden = false
            fwProgressBar.isIndeterminate = false
            fwProgressBar.stopAnimation(nil)
            fwProgressBar.doubleValue = fw.downloadProgress * 100.0
            fwProgressLabel.stringValue = String(format: "Download: %.0f %%", fw.downloadProgress * 100.0)
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

        refreshLiveLabels()
    }

    /// Fuer Timer-Tick (Alter des letzten Updates).
    private func refreshLiveLabels() {
        guard let monitor = monitor else { return }
        if let d = monitor.lastUpdateDate {
            let age = Int(Date().timeIntervalSince(d))
            let txt: String
            if age < 60 { txt = "vor \(age)s" }
            else if age < 3600 { txt = "vor \(age/60)m" }
            else { txt = "vor \(age/3600)h \((age%3600)/60)m" }
            lastUpdateLabel.stringValue = "Letztes Update an ESP32: \(txt)"
        } else {
            lastUpdateLabel.stringValue = "Letztes Update an ESP32: -"
        }

        // Flash-Fortschritts-Text live nachziehen
        let fw = FirmwareManager.shared
        if fw.isFlashing {
            fwProgressLabel.stringValue = fw.flashProgress
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
        // selected item
        if let manual = Settings.shared.manualPortPath,
           let idx = available.firstIndex(of: manual) {
            portPopup.selectItem(at: idx + 1)
        } else {
            portPopup.selectItem(at: 0)
        }
    }

    // MARK: - Actions

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

    @objc private func languageChosen() {
        let langs = ["de", "en"]
        let i = languagePopup.indexOfSelectedItem
        Settings.shared.language = langs[max(0, min(i, langs.count - 1))]
        monitor?.sendLanguageToESP32()
    }

    @objc private func flashFirmware() {
        (NSApp.delegate as? AppDelegate)?.runFirmwareFlash()
    }

    @objc private func checkAppUpdate() {
        (NSApp.delegate as? AppDelegate)?.runAppUpdateCheck()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AI Monitor v\(kAppVersion)"
        alert.informativeText = """
        macOS-Hintergrund-App fuer das ESP32-Usage-Display.

        Liest Claude-Usage aus der lokalen CodexBar-App \
        (widget-snapshot.json im Group Container) und sendet Session- und Weekly-Werte per USB-Serial an das ESP32-Display.

        Repo: github.com/tobymarks/esp32-ai-monitor
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
