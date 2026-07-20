/**
 * SettingsWindow+Diagnostics.swift — Diagnose-Tab des SettingsWindowController.
 *
 * Reine Code-Umschichtung aus SettingsWindow.swift (keine Funktionsänderung):
 * Seitenaufbau (buildDiagnosticsPage), Testbild/Diagnose-Aktionen und der
 * Diagnose-Report.
 */

import Cocoa

extension SettingsWindowController {

    func buildDiagnosticsPage() -> NSView {
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
        helper.font = NSFont.appFont(.callout)
        helper.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, helper, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    @objc func sendTestFrame() {
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

    @objc func copyDiagnostics() {
        let report = diagnosticReport()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        setupDetailLabel.stringValue = "Diagnose wurde in die Zwischenablage kopiert."
        setupDetailLabel.textColor = .secondaryLabelColor
    }

    func diagnosticReport() -> String {
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
        lines.append("- Letzter Flash-Port: \(fw.lastFlashPort ?? "—")")
        lines.append("- Letzte Flash-Variante: \(fw.lastFlashVariant ?? "—")")
        lines.append("- Letzter Flash-Zeitpunkt: \(dateText(fw.lastFlashAt))")
        lines.append("- Letzter Flash-Fehler: \(fw.lastFlashErrorSummary ?? "—")")
        lines.append("- Letzte Flash-Fehlerhilfe: \(fw.lastFlashErrorDetail ?? "—")")

        return lines.joined(separator: "\n")
    }
}
