/**
 * SettingsWindow+Connection.swift — Verbindungs-Tab des SettingsWindowController.
 *
 * Reine Code-Umschichtung aus SettingsWindow.swift (keine Funktionsänderung):
 * USB-Port-Box, Display-WiFi-Box samt zugehöriger Status-/Update-Helfer und
 * Aktionen (Scan, Verbinden, Vergessen, Port-Auswahl).
 */

import Cocoa

extension SettingsWindowController {

    func buildConnectionPage() -> NSView {
        let portBox = buildPortBox()
        let wifiBox = buildWiFiBox()

        let stack = NSStackView(views: [portBox, wifiBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        return stack
    }

    func buildPortBox() -> NSView {
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

    func buildWiFiBox() -> NSView {
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

    func updateWiFiControlsEnabled() {
        let ready = (monitor?.serialPort.state == .connected)
        let controls: [NSControl?] = [wifiNetworkPopup, wifiPasswordField, wifiScanButton, wifiConnectButton, wifiForgetButton]
        controls.forEach { $0?.isEnabled = ready }
        if !ready {
            lastWiFiStatusJSON = nil
            wifiStatusDot?.stringValue = "\u{25CB}"
            wifiStatusDot?.textColor = .secondaryLabelColor
            wifiStatusLabel?.stringValue = "ESP32 verbinden, um WiFi einzurichten"
            wifiStatusLabel?.textColor = .secondaryLabelColor
        }
    }

    func applyWiFiStatus(_ json: [String: Any]?) {
        guard wifiStatusLabel != nil else { return }
        lastWiFiStatusJSON = json
        guard let json = json else {
            wifiStatusDot.stringValue = "\u{25CF}"
            wifiStatusDot.textColor = .systemOrange
            wifiStatusLabel.stringValue = "Keine Antwort vom Display"
            wifiStatusLabel.textColor = .systemOrange
            updateOverviewGuidance()
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
        updateOverviewGuidance()
    }

    func requestWiFiStatus(force: Bool = false) {
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

    func updateWiFiNetworkPopup() {
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

    func rebuildPortPopup() {
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

    @objc func refreshPorts() {
        rebuildPortPopup()
    }

    @objc func scanWiFi() {
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

    @objc func wifiNetworkChosen() {
        wifiPasswordField.stringValue = ""
        window?.makeFirstResponder(wifiPasswordField)
    }

    @objc func connectWiFi() {
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

    @objc func forgetWiFi() {
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

    @objc func portChosen() {
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
}
