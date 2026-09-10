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

        let channelHelper = NSTextField(labelWithString: L("upd.channel.intro"))
        channelHelper.font = NSFont.appFont(.subheadline)
        channelHelper.textColor = .secondaryLabelColor
        channelHelper.lineBreakMode = .byWordWrapping
        channelHelper.maximumNumberOfLines = 2
        channelHelper.toolTip = L("upd.channel.tooltip")
        updateChannelPopup.toolTip = channelHelper.toolTip

        let checkButton = NSButton(title: "Nach Updates suchen …", target: self, action: #selector(checkAppUpdate))
        checkButton.bezelStyle = .rounded
        checkButton.toolTip = L("upd.check.tooltip")

        let stack = NSStackView(views: [heading, channelRow, channelHelper, checkButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    func buildFirmwareBox() -> NSView {
        let heading = makeSectionHeading("Firmware")

        fwVersionLabel = NSTextField(labelWithString: "Installiert: —")
        fwVersionLabel.font = NSFont.appFont(.body)

        fwVariantLabel = NSTextField(labelWithString: "Variante: —")
        fwVariantLabel.font = NSFont.appFont(.callout)
        fwVariantLabel.textColor = .secondaryLabelColor

        fwUpdateLabel = NSTextField(labelWithString: "")
        fwUpdateLabel.font = NSFont.appFont(.callout)
        fwUpdateLabel.textColor = .secondaryLabelColor

        fwFlashButton = NSButton(title: L("flash.action.short"), target: self, action: #selector(flashFirmware))
        fwFlashButton.bezelStyle = .rounded
        fwFlashButton.toolTip = L("upd.flash.tooltip")

        fwProgressBar = NSProgressIndicator()
        fwProgressBar.style = .bar
        fwProgressBar.isIndeterminate = false
        fwProgressBar.minValue = 0
        fwProgressBar.maxValue = 100
        fwProgressBar.isHidden = true
        fwProgressBar.translatesAutoresizingMaskIntoConstraints = false
        fwProgressBar.widthAnchor.constraint(equalToConstant: 360).isActive = true

        fwProgressLabel = NSTextField(labelWithString: "")
        fwProgressLabel.font = NSFont.appMonospacedDigit(.subheadline)
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
