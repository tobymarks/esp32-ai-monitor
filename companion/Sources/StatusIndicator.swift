/**
 * StatusIndicator.swift — Statusanzeige für Health-Zeilen und Verbindungen.
 *
 * Ersetzt ab v1.23.0 die früheren Unicode-Zeichen ● / ○ in NSTextFields.
 * Zwei Gründe:
 *
 * 1. HIG „Inclusive color": „Avoid relying solely on color to differentiate
 *    between objects, indicate interactivity, or communicate essential
 *    information." Vorher unterschieden sich alle Zustände außer „getrennt"
 *    ausschließlich durch die Farbe desselben Glyphs ● — für farbenblinde
 *    Nutzer nicht unterscheidbar.
 * 2. VoiceOver las den Zustand als „schwarzer Kreis" vor.
 *
 * Jeder Zustand hat jetzt eine eigene Form, eine eigene semantische Farbe und
 * ein Accessibility-Label.
 */

import Cocoa

final class StatusIndicator: NSImageView {

    enum State {
        /// Alles in Ordnung.
        case ok
        /// Nutzeraktion nötig, aber nicht kaputt.
        case attention
        /// Fehlerzustand.
        case error
        /// Vorgang läuft oder wartet auf etwas.
        case pending
        /// Neutrale Information (z. B. Update verfügbar).
        case info
        /// Inaktiv, nicht geprüft, optional.
        case inactive

        var symbolName: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .attention: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .pending: return "clock.fill"
            case .info: return "arrow.down.circle.fill"
            case .inactive: return "circle.dashed"
            }
        }

        var tint: NSColor {
            switch self {
            case .ok: return .systemGreen
            case .attention: return .systemOrange
            case .error: return .systemRed
            case .pending: return .systemYellow
            case .info: return .systemBlue
            case .inactive: return .secondaryLabelColor
            }
        }

        /// Wird von VoiceOver vorgelesen und als Bildbeschreibung gesetzt.
        var accessibilityText: String {
            switch self {
            case .ok: return "Status: in Ordnung"
            case .attention: return "Status: Achtung"
            case .error: return "Status: Fehler"
            case .pending: return "Status: wird geprüft"
            case .info: return "Status: Hinweis"
            case .inactive: return "Status: inaktiv"
            }
        }
    }

    var state: State = .inactive {
        didSet { applyState() }
    }

    convenience init(state: State = .inactive) {
        self.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        // Feste Kantenlänge: sonst springt die Zeile, wenn ein Zustandswechsel
        // die Symbolform (Kreis ↔ Dreieck ↔ Achteck) ändert.
        widthAnchor.constraint(equalToConstant: 15).isActive = true
        heightAnchor.constraint(equalToConstant: 15).isActive = true
        self.state = state
        applyState()
    }

    private func applyState() {
        image = NSImage(systemSymbolName: state.symbolName,
                        accessibilityDescription: state.accessibilityText)
        contentTintColor = state.tint
        setAccessibilityLabel(state.accessibilityText)
    }
}
