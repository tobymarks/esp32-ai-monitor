/**
 * SettingsWindow+Overview.swift — Übersichts-Tab des SettingsWindowController.
 *
 * Reine Code-Umschichtung aus SettingsWindow.swift (keine Funktionsänderung):
 * Seitenaufbau (Setup-Status, Nächster-Schritt-Box, Health-Check, CodexBar-Box),
 * die Guidance-/Health-/Next-Step-Update-Logik und die CodexBar-Aktionen.
 */

import Cocoa
import UniformTypeIdentifiers

extension SettingsWindowController {

    func buildOverviewPage() -> NSView {
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

        let nextStepBox = buildNextStepBox()
        nextStepBox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nextStepBox)

        let healthBox = buildHealthCheckBox()
        healthBox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(healthBox)

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
            appSettingsToggle.topAnchor.constraint(equalTo: setupDetailLabel.bottomAnchor, constant: 16),

            helper.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            helper.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            helper.topAnchor.constraint(equalTo: appSettingsToggle.bottomAnchor, constant: 4),

            nextStepBox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nextStepBox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            nextStepBox.topAnchor.constraint(equalTo: helper.bottomAnchor, constant: 20),

            // Health-Check ist keine zweite Spalte mehr, sondern eine eigene
            // voll-breite Sektion im vertikalen Fluss — so werden die Status-Texte
            // (detail-Spalte) nicht mehr am rechten Rand abgeschnitten.
            healthBox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            healthBox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            healthBox.topAnchor.constraint(equalTo: nextStepBox.bottomAnchor, constant: 22),

            codexBox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            codexBox.topAnchor.constraint(equalTo: healthBox.bottomAnchor, constant: 22),
            codexBox.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])

        return container
    }

    private func buildNextStepBox() -> NSView {
        let heading = makeSectionHeading("Nächster Schritt")

        nextStepLabel = NSTextField(labelWithString: "Setup wird geprüft …")
        nextStepLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        nextStepLabel.lineBreakMode = .byWordWrapping
        nextStepLabel.maximumNumberOfLines = 2

        nextStepDetailLabel = NSTextField(wrappingLabelWithString: "")
        nextStepDetailLabel.font = NSFont.systemFont(ofSize: 12)
        nextStepDetailLabel.textColor = .secondaryLabelColor
        nextStepDetailLabel.maximumNumberOfLines = 3

        nextStepPrimaryButton = NSButton(title: "Öffnen", target: self, action: #selector(performNextStepPrimary))
        nextStepPrimaryButton.bezelStyle = .rounded
        nextStepPrimaryButton.toolTip = "Öffnet den wichtigsten nächsten Schritt für den aktuellen Zustand."

        nextStepSecondaryButton = NSButton(title: "Diagnose", target: self, action: #selector(performNextStepSecondary))
        nextStepSecondaryButton.bezelStyle = .rounded
        nextStepSecondaryButton.toolTip = "Öffnet die Diagnose oder einen passenden zweiten Schritt."

        let buttons = NSStackView(views: [nextStepPrimaryButton, nextStepSecondaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, nextStepLabel, nextStepDetailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func buildHealthCheckBox() -> NSView {
        let heading = makeSectionHeading("Health-Check")

        let appRow = buildHealthRow(title: "App", dot: &healthAppDot,
                                    label: &healthAppLabel,
                                    detail: &healthAppDetailLabel,
                                    tooltip: "Zeigt, ob die macOS-App aktuell ist oder ein Update bekannt ist.")
        let codexRow = buildHealthRow(title: "CodexBar", dot: &healthCodexDot,
                                      label: &healthCodexLabel,
                                      detail: &healthCodexDetailLabel,
                                      tooltip: "Prüft, ob aktuelle Provider-Daten aus CodexBar gelesen werden.")
        let usbRow = buildHealthRow(title: "USB", dot: &healthUSBDot,
                                    label: &healthUSBLabel,
                                    detail: &healthUSBDetailLabel,
                                    tooltip: "Zeigt, ob das ESP32-Display per USB erreichbar ist.")
        let wifiRow = buildHealthRow(title: "Display-WiFi", dot: &healthWiFiDot,
                                     label: &healthWiFiLabel,
                                     detail: &healthWiFiDetailLabel,
                                     tooltip: "Zeigt, ob das Display im WLAN ist und die Uhr synchronisiert wurde.")
        let firmwareRow = buildHealthRow(title: "Firmware", dot: &healthFirmwareDot,
                                         label: &healthFirmwareLabel,
                                         detail: &healthFirmwareDetailLabel,
                                         tooltip: "Zeigt, ob die Display-Firmware bekannt, passend und aktuell ist.")

        let stack = NSStackView(views: [heading, appRow, codexRow, usbRow, wifiRow, firmwareRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func buildHealthRow(title: String,
                                dot: inout NSTextField!,
                                label: inout NSTextField!,
                                detail: inout NSTextField!,
                                tooltip: String) -> NSView {
        dot = NSTextField(labelWithString: "\u{25CB}")
        dot.font = NSFont.systemFont(ofSize: 12)
        dot.textColor = .secondaryLabelColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true

        label = NSTextField(labelWithString: "—")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 112).isActive = true

        detail = NSTextField(labelWithString: "")
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let row = NSStackView(views: [dot, titleLabel, label, detail])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.toolTip = tooltip
        return row
    }

    func buildCodexBarBox() -> NSView {
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

    func updateOverviewGuidance() {
        guard let monitor = monitor, nextStepLabel != nil else { return }

        let app = AppUpdateManager.shared
        if app.latestRelease == nil {
            setHealth(dot: healthAppDot, label: healthAppLabel, detail: healthAppDetailLabel,
                      status: "Nicht geprüft", detailText: "Update-Check starten", color: .secondaryLabelColor)
        } else if app.hasUpdate {
            setHealth(dot: healthAppDot, label: healthAppLabel, detail: healthAppDetailLabel,
                      status: "Update bereit", detailText: app.latestVersionDisplay, color: .systemBlue)
        } else {
            setHealth(dot: healthAppDot, label: healthAppLabel, detail: healthAppDetailLabel,
                      status: "Aktuell", detailText: "v\(kAppVersion)", color: .systemGreen)
        }

        let provider = CodexBarProvider.normalized(monitor.codexBar.provider).displayLabel
        if monitor.codexBar.status.isOK {
            setHealth(dot: healthCodexDot, label: healthCodexLabel, detail: healthCodexDetailLabel,
                      status: "OK", detailText: "\(provider)-Daten aktuell", color: .systemGreen)
        } else {
            setHealth(dot: healthCodexDot, label: healthCodexLabel, detail: healthCodexDetailLabel,
                      status: "Prüfen", detailText: setupDetailForCodexStatus(monitor.codexBar.status,
                                                                              provider: monitor.codexBar.provider),
                      color: .systemOrange)
        }

        let serial = monitor.serialPort
        switch serial.state {
        case .connected:
            let device = DeviceRegistry.shared.currentProfile()?.friendlyName ?? "ESP32"
            setHealth(dot: healthUSBDot, label: healthUSBLabel, detail: healthUSBDetailLabel,
                      status: "Verbunden", detailText: device, color: .systemGreen)
        case .foreignFirmware:
            setHealth(dot: healthUSBDot, label: healthUSBLabel, detail: healthUSBDetailLabel,
                      status: "Port offen", detailText: "Firmware installieren", color: .systemOrange)
        case .probing:
            setHealth(dot: healthUSBDot, label: healthUSBLabel, detail: healthUSBDetailLabel,
                      status: "Handshake", detailText: "Gerät wird geprüft", color: .systemYellow)
        case .disconnected:
            setHealth(dot: healthUSBDot, label: healthUSBLabel, detail: healthUSBDetailLabel,
                      status: "Fehlt", detailText: "Kabel oder Port prüfen", color: .secondaryLabelColor)
        }

        updateWiFiHealth(serialState: serial.state)
        updateFirmwareHealth(serialState: serial.state)
        updateNextStep(serialState: serial.state)
    }

    private func updateWiFiHealth(serialState: DeviceConnectionState) {
        guard serialState == .connected else {
            setHealth(dot: healthWiFiDot, label: healthWiFiLabel, detail: healthWiFiDetailLabel,
                      status: "Wartet", detailText: "Erst USB verbinden", color: .secondaryLabelColor)
            return
        }

        guard let json = lastWiFiStatusJSON else {
            setHealth(dot: healthWiFiDot, label: healthWiFiLabel, detail: healthWiFiDetailLabel,
                      status: "Unbekannt", detailText: "Status wird geladen", color: .secondaryLabelColor)
            return
        }

        let configured = json["configured"] as? Bool ?? false
        let connected = json["connected"] as? Bool ?? false
        let timeSynced = json["timeSynced"] as? Bool ?? false
        let ssid = (json["ssid"] as? String) ?? "WLAN"
        let rssi = json["rssi"] as? Int ?? 0

        if connected && timeSynced {
            setHealth(dot: healthWiFiDot, label: healthWiFiLabel, detail: healthWiFiDetailLabel,
                      status: "OK", detailText: "\(ssid), \(rssi) dBm", color: .systemGreen)
        } else if connected {
            setHealth(dot: healthWiFiDot, label: healthWiFiLabel, detail: healthWiFiDetailLabel,
                      status: "Wartet", detailText: "\(ssid), Zeit noch nicht synchron", color: .systemYellow)
        } else if configured {
            setHealth(dot: healthWiFiDot, label: healthWiFiLabel, detail: healthWiFiDetailLabel,
                      status: "Getrennt", detailText: "\(ssid) gespeichert", color: .systemOrange)
        } else {
            setHealth(dot: healthWiFiDot, label: healthWiFiLabel, detail: healthWiFiDetailLabel,
                      status: "Optional", detailText: "Kein WLAN gespeichert", color: .secondaryLabelColor)
        }
    }

    private func updateFirmwareHealth(serialState: DeviceConnectionState) {
        let fw = FirmwareManager.shared
        if serialState == .foreignFirmware {
            setHealth(dot: healthFirmwareDot, label: healthFirmwareLabel, detail: healthFirmwareDetailLabel,
                      status: "Fehlt", detailText: "AI-Monitor-Firmware flashen", color: .systemRed)
        } else if fw.isFlashing {
            setHealth(dot: healthFirmwareDot, label: healthFirmwareLabel, detail: healthFirmwareDetailLabel,
                      status: "Flash läuft", detailText: fw.flashProgress, color: .systemBlue)
        } else if fw.latestRelease == nil {
            setHealth(dot: healthFirmwareDot, label: healthFirmwareLabel, detail: healthFirmwareDetailLabel,
                      status: "Nicht geprüft", detailText: "Release-Daten laden", color: .secondaryLabelColor)
        } else if !fw.hasExpectedReleaseAssets {
            setHealth(dot: healthFirmwareDot, label: healthFirmwareLabel, detail: healthFirmwareDetailLabel,
                      status: "Prüfen", detailText: "Release unvollständig", color: .systemOrange)
        } else if fw.hasUpdate {
            setHealth(dot: healthFirmwareDot, label: healthFirmwareLabel, detail: healthFirmwareDetailLabel,
                      status: "Update bereit", detailText: fw.latestVersionDisplay, color: .systemBlue)
        } else if serialState == .connected {
            setHealth(dot: healthFirmwareDot, label: healthFirmwareLabel, detail: healthFirmwareDetailLabel,
                      status: "Aktuell", detailText: fw.installedVersionDisplay, color: .systemGreen)
        } else {
            setHealth(dot: healthFirmwareDot, label: healthFirmwareLabel, detail: healthFirmwareDetailLabel,
                      status: "Wartet", detailText: "ESP32 verbinden", color: .secondaryLabelColor)
        }
    }

    private func updateNextStep(serialState: DeviceConnectionState) {
        let codexOK = monitor?.codexBar.status.isOK ?? false
        let fw = FirmwareManager.shared

        if serialState == .foreignFirmware {
            setNextStep(title: "Firmware installieren",
                        detail: "Der USB-Port ist erreichbar, aber auf dem Gerät läuft noch keine AI-Monitor-Firmware.",
                        primaryTitle: "Firmware flashen",
                        primaryAction: .flashFirmware,
                        secondaryTitle: "Diagnose öffnen",
                        secondaryAction: .openDiagnostics)
        } else if serialState == .disconnected {
            setNextStep(title: "Display per USB verbinden",
                        detail: "Schließe das Display an und scanne bei Bedarf die Ports neu.",
                        primaryTitle: "Verbindung öffnen",
                        primaryAction: .openConnection,
                        secondaryTitle: "Diagnose öffnen",
                        secondaryAction: .openDiagnostics)
        } else if serialState == .probing {
            setNextStep(title: "Verbindung wird geprüft",
                        detail: "Die App wartet auf die Antwort des ESP32. Wenn das länger dauert, öffne Verbindung und scanne die Ports neu.",
                        primaryTitle: "Verbindung öffnen",
                        primaryAction: .openConnection,
                        secondaryTitle: "Diagnose öffnen",
                        secondaryAction: .openDiagnostics)
        } else if !codexOK {
            setNextStep(title: "CodexBar-Daten prüfen",
                        detail: setupDetailForCodexStatus(monitor?.codexBar.status ?? .notYet,
                                                          provider: monitor?.codexBar.provider ?? Settings.shared.selectedProvider),
                        primaryTitle: "CodexBar neu laden",
                        primaryAction: .reloadCodex,
                        secondaryTitle: "Diagnose öffnen",
                        secondaryAction: .openDiagnostics)
        } else if fw.hasUpdate {
            setNextStep(title: "Firmware aktualisieren",
                        detail: "Für das Display ist \(fw.latestVersionDisplay) verfügbar.",
                        primaryTitle: "Firmware flashen",
                        primaryAction: .flashFirmware,
                        secondaryTitle: "Updates öffnen",
                        secondaryAction: .openUpdates)
        } else if AppUpdateManager.shared.hasUpdate {
            setNextStep(title: "App-Update installieren",
                        detail: "Für die macOS-App ist \(AppUpdateManager.shared.latestVersionDisplay) verfügbar.",
                        primaryTitle: "Update laden",
                        primaryAction: .checkUpdates,
                        secondaryTitle: "Updates öffnen",
                        secondaryAction: .openUpdates)
        } else if lastWiFiStatusJSON == nil {
            setNextStep(title: "Display-WiFi prüfen",
                        detail: "USB ist bereit. Der WiFi-Status wird noch geladen oder wurde noch nicht abgefragt.",
                        primaryTitle: "WiFi scannen",
                        primaryAction: .scanWiFi,
                        secondaryTitle: "Verbindung öffnen",
                        secondaryAction: .openConnection)
        } else {
            setNextStep(title: "Alles bereit",
                        detail: "App, CodexBar und ESP32 sind einsatzbereit. Änderungen findest du in den Bereichen oben.",
                        primaryTitle: "Display öffnen",
                        primaryAction: .openDisplay,
                        secondaryTitle: "Updates prüfen",
                        secondaryAction: .checkUpdates)
        }
    }

    private func setHealth(dot: NSTextField?,
                           label: NSTextField?,
                           detail: NSTextField?,
                           status: String,
                           detailText: String,
                           color: NSColor) {
        dot?.stringValue = "\u{25CF}"
        dot?.textColor = color
        label?.stringValue = status
        label?.textColor = color
        detail?.stringValue = detailText
        detail?.toolTip = detailText
    }

    private func setNextStep(title: String,
                             detail: String,
                             primaryTitle: String,
                             primaryAction: OverviewAction,
                             secondaryTitle: String,
                             secondaryAction: OverviewAction) {
        nextStepLabel.stringValue = title
        nextStepDetailLabel.stringValue = detail
        nextStepDetailLabel.toolTip = detail
        nextStepPrimaryButton.title = primaryTitle
        nextStepSecondaryButton.title = secondaryTitle
        nextStepPrimaryButton.isEnabled = primaryAction != .none
        nextStepSecondaryButton.isEnabled = secondaryAction != .none
        nextStepPrimaryAction = primaryAction
        nextStepSecondaryAction = secondaryAction
    }

    func updateSetupBox() {
        guard let monitor = monitor, setupStatusLabel != nil else { return }

        let codexOK = monitor.codexBar.status.isOK
        let serialState = monitor.serialPort.state
        let ready = codexOK && serialState == .connected

        setupTestButton?.isEnabled = (serialState == .connected)
        displayTestButton?.isEnabled = (serialState == .connected)
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

    func setupDetailForCodexStatus(_ status: CodexBarStatus, provider: String) -> String {
        let providerLabel = CodexBarProvider.normalized(provider).displayLabel
        switch status {
        case .ok:
            return "\(providerLabel)-Daten sind aktuell."
        case .accessNotConfigured:
            return "CodexBar-Zugriff ist noch nicht eingerichtet. Wähle einmalig die widget-snapshot.json aus."
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

    @objc private func performNextStepPrimary() {
        performOverviewAction(nextStepPrimaryAction)
    }

    @objc private func performNextStepSecondary() {
        performOverviewAction(nextStepSecondaryAction)
    }

    private func performOverviewAction(_ action: OverviewAction) {
        switch action {
        case .none:
            break
        case .reloadCodex:
            reloadCodexBar()
        case .openDisplay:
            showSection(.display)
        case .openConnection:
            showSection(.connection)
        case .openUpdates:
            showSection(.updates)
        case .openDiagnostics:
            showSection(.diagnostics)
        case .checkUpdates:
            checkAppUpdate()
        case .flashFirmware:
            flashFirmware()
        case .scanWiFi:
            showSection(.connection)
            scanWiFi()
        }
    }

    @objc private func menuBarQuickMenuToggled() {
        Settings.shared.menuBarQuickMenuEnabled = (appSettingsToggle.state == .on)
    }

    @objc private func reloadCodexBar() {
        if Settings.shared.codexBarSnapshotBookmarkData == nil {
            configureCodexBarAccess()
            return
        }
        monitor?.codexBar.loadOnce()
        update()
    }

    private func configureCodexBarAccess() {
        let panel = NSOpenPanel()
        panel.title = "CodexBar-Datenquelle wählen"
        panel.message = "Wähle die Datei widget-snapshot.json aus dem CodexBar-Ordner aus."
        panel.prompt = "Auswählen"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        // Direkt im aktuellen CodexBar-Container starten, damit die Datei mit
        // einem Klick wählbar ist (Pfad-Vorgabe, kein App-Zugriff -> kein Prompt).
        panel.directoryURL = URL(fileURLWithPath: CodexBarSource.suggestedSnapshotDirectory())
        panel.nameFieldStringValue = "widget-snapshot.json"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            Settings.shared.codexBarSnapshotBookmarkData = bookmark
            Settings.shared.codexBarSnapshotPath = url.path
            monitor?.codexBar.loadOnce()
            update()
        } catch {
            let alert = NSAlert()
            alert.messageText = "CodexBar-Zugriff fehlgeschlagen"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
