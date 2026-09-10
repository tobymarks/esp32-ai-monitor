/**
 * Localization.swift — UI-Sprache der Mac-App (ab v1.26.0).
 *
 * Die App folgt der macOS-Systemsprache: Deutsch und Englisch liegen als
 * de.lproj/en.lproj im Bundle, macOS waehlt anhand der Systemeinstellung.
 *
 * WICHTIG — nicht mit `Settings.shared.language` verwechseln: das ist die
 * Sprache der Labels auf dem ESP32-Display, wird pro Geraet gespeichert und
 * an die Firmware gesendet. Beides ist bewusst entkoppelt: Wer das Display
 * auf Englisch stellt, will deshalb nicht zwingend eine englische App.
 */

import Foundation

/// Uebersetzt einen Key. Faellt auf Englisch zurueck, wenn die aktive
/// Sprache ihn nicht kennt — sonst stuende der rohe Key in der UI.
func L(_ key: String) -> String {
    let s = Bundle.main.localizedString(forKey: key, value: kLocalizationMissing, table: nil)
    if s != kLocalizationMissing { return s }
    if let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
       let fallback = Bundle(path: path) {
        let e = fallback.localizedString(forKey: key, value: kLocalizationMissing, table: nil)
        if e != kLocalizationMissing { return e }
    }
    #if DEBUG
    print("[i18n] Kein Eintrag fuer Key: \(key)")
    #endif
    return key
}

/// Variante fuer Format-Strings, z. B. ein Key mit %@ oder %d.
func L(_ key: String, _ args: CVarArg...) -> String {
    return String(format: L(key), arguments: args)
}

/// Uebersetzt einen Text, der AUF DEM DISPLAY erscheint. Folgt bewusst
/// `Settings.shared.language` (Display-Sprache), nicht der macOS-Systemsprache:
/// Wer das Display auf Englisch stellt, soll dort auch englische Hinweise sehen.
///
/// WICHTIG: Diese Texte muessen reines ASCII sein. Die LVGL-Montserrat-Fonts der
/// Firmware kennen weder Umlaute noch „…" — sonst erscheinen Kaestchen.
func LD(_ key: String) -> String {
    let lang = Settings.shared.language == "en" ? "en" : "de"
    if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
       let b = Bundle(path: path) {
        let v = b.localizedString(forKey: key, value: kLocalizationMissing, table: nil)
        if v != kLocalizationMissing { return v }
    }
    return L(key)
}

private let kLocalizationMissing = "\u{0}__missing__"
