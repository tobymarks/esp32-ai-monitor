/**
 * Typography.swift — Semantische Schrift-Ebene.
 *
 * Vorher standen im UI 42 hartkodierte Punktgrößen in acht Varianten
 * (11/12/13/15/16 pt, teils mit Gewicht), teils inkonsistent für gleichrangige
 * Elemente. Ab v1.23.0 leiten sich alle Größen aus den System-Textstilen ab.
 *
 * Wichtig zur Einordnung: macOS unterstützt **kein** Dynamic Type — die
 * Textstile liefern hier feste Größen. Der Gewinn ist deshalb nicht
 * Skalierbarkeit, sondern dass die Schrift denselben Metriken folgt wie die
 * System-Controls daneben (HIG: „use dynamic system font variants to match the
 * text in standard controls"), und dass es nur noch eine Stelle gibt, an der
 * die Skala definiert ist.
 */

import Cocoa

extension NSFont {

    /// Systemschrift in der Größe eines Textstils, optional mit eigener Stärke.
    ///
    /// `preferredFont(forTextStyle:)` liefert immer die Standardstärke des
    /// Stils. Wo eine andere Stärke gebraucht wird, übernehmen wir nur die
    /// Punktgröße des Stils.
    static func appFont(_ style: NSFont.TextStyle, weight: NSFont.Weight? = nil) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        guard let weight else { return base }
        return NSFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    /// Wie `appFont`, aber mit Ziffern fester Breite — für Werte, die sich
    /// laufend ändern (Prozente, Fortschritt, Uhrzeiten), damit die Zeile beim
    /// Aktualisieren nicht springt.
    static func appMonospacedDigit(_ style: NSFont.TextStyle,
                                   weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: style).pointSize,
            weight: weight
        )
    }
}
