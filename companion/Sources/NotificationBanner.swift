/**
 * NotificationBanner.swift — Nicht-modaler Hinweis im Einstellungsfenster.
 *
 * Ersetzt ab v1.23.0 den unaufgefordert erscheinenden Firmware-Update-Dialog.
 * Der war ein app-modaler NSAlert, der sich selbst nach vorn geholt hat
 * (`settingsController.show()` + `runModal()`) und jede andere Arbeit
 * blockierte, bis man ihn wegklickte — für eine reine Hintergrund-App die
 * denkbar störendste Form.
 *
 * HIG: Alerts sind für Situationen gedacht, die eine Entscheidung erzwingen.
 * Ein verfügbares Update ist das nicht — die Information steht ohnehin schon
 * im Health-Check und im Updates-Tab. Das Banner zeigt sie sichtbar, aber
 * ohne zu unterbrechen, und bleibt stehen, bis der Nutzer handelt oder es
 * schließt.
 */

import Cocoa

final class NotificationBanner: NSView {

    private let indicator = StatusIndicator(state: .info)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton()

    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        // NSBox als Karte: Standard-Komponente, damit Fuellung und Rahmen den
        // Systemfarben folgen und in Hell/Dunkel automatisch stimmen.
        let box = NSBox()
        box.boxType = .custom
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.borderWidth = 1
        box.cornerRadius = 8
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        titleLabel.font = NSFont.appFont(.headline)
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = NSFont.appFont(.subheadline)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(performAction)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Hinweis schließen")
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.toolTip = "Hinweis schließen"
        closeButton.setAccessibilityLabel("Hinweis schließen")

        let row = NSStackView(views: [indicator, textStack, actionButton, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        // Der Text bekommt den freien Platz, die Buttons behalten ihre Groesse.
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        box.contentView?.addSubview(row)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),

            row.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -10),
        ])

        setAccessibilityRole(.group)
    }

    /// Zeigt das Banner. `actionTitle == nil` blendet den Aktionsbutton aus.
    func show(state: StatusIndicator.State,
              title: String,
              detail: String,
              actionTitle: String?,
              action: (() -> Void)?) {
        indicator.state = state
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        self.action = action

        if let actionTitle, action != nil {
            actionButton.title = actionTitle
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }

        setAccessibilityLabel("\(title). \(detail)")
        isHidden = false
    }

    @objc private func performAction() {
        let pending = action
        dismiss()
        pending?()
    }

    @objc func dismiss() {
        isHidden = true
        action = nil
    }
}
