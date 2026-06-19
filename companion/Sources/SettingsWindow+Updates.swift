/**
 * SettingsWindow+Updates.swift — Updates-Tab des SettingsWindowController.
 *
 * Reine Code-Umschichtung aus SettingsWindow.swift (keine Funktionsänderung):
 * Seitenaufbau (App-Update-Box + Firmware-Box) und die zugehörigen Aktionen
 * für Update-Kanal, App-Update-Check und Firmware-Flash.
 */

import Cocoa

extension SettingsWindowController {

    func buildUpdatesPage() -> NSView {
        let appUpdateBox = buildAppUpdateBox()
        let firmwareBox = buildFirmwareBox()

        let stack = NSStackView(views: [appUpdateBox, firmwareBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        return stack
    }

    func buildAppUpdateBox() -> NSView {
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

    func buildFirmwareBox() -> NSView {
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

    @objc func updateChannelChosen() {
        Settings.shared.updateChannel = updateChannelPopup.indexOfSelectedItem == 1 ? .beta : .stable
        update()
    }

    @objc func flashFirmware() {
        (NSApp.delegate as? AppDelegate)?.runFirmwareFlash()
    }

    @objc func checkAppUpdate() {
        (NSApp.delegate as? AppDelegate)?.runAppUpdateCheck()
    }
}
