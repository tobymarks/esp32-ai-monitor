/**
 * AI Monitor v1.15.2 — macOS-Hintergrund-App für ESP32 AI Usage Monitor Display
 *
 * Datenquelle: lokale CodexBar-App (widget-snapshot.json), KEIN direkter API-Poll.
 * Multi-Provider: Claude ODER Codex — per Umschalter im Settings-Fenster.
 * UI-Modus: LSUIElement=YES, unsichtbar. Kein Menubar-Icon. Settings-Fenster beim Launch
 * und beim Reopen-Event (Spotlight / Finder-Doppelklick).
 * ESP32-Protokoll: Envelope um `provider`-Feld erweitert (String, „claude"|„codex").
 *
 * v1.15.2: CodexBar-Container-Erkennung erweitert (inkl. Team-ID-präfixierter
 * Group-Container in CodexBar 0.22), damit widget-snapshot.json wieder
 * zuverlässig gelesen wird.
 *
 * Build: ./build.sh
 * Run:   open "build/AI Monitor.app"
 */

import Cocoa
import Security
import ServiceManagement
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// ============================================================
// MARK: - Configuration
// ============================================================

let kAppVersion = "1.15.2"
let kSerialBaudRate: speed_t = 115200
let kSerialScanInterval: TimeInterval = 3
/// Legacy-Suite aus v1.x (<= 1.11.1). Wird ab v1.12.0 einmalig migriert und dann
/// nicht mehr beschrieben. Der Suite-Name == Bundle-Identifier hatte eine
/// Foundation-Warning verursacht („Using your own bundle identifier as
/// NSUserDefaults suite name"). Ab v1.12.0 läuft alles über `.standard`.
let kLegacyUserDefaultsSuite = "de.aimonitor.app"
let kGitHubRepo = "tobymarks/esp32-ai-monitor"
let kGitHubReleasesAPI = "https://api.github.com/repos/tobymarks/esp32-ai-monitor/releases"
/// Default-Asset (ILI9341-Variante). Wird als Fallback genutzt, wenn der
/// Release keine variantenspezifischen Assets enthaelt (Releases < v2.10.0).
let kFirmwareAssetName = "ai-monitor.bin"

/// Mapping Display-Controller-ID → Release-Asset-Name.
/// Ab App v1.15.0 / FW v2.10.1: Der User waehlt im Flash-Dialog die Board-
/// Variante (ILI9341 vs. ST7789). Das Dictionary ist bewusst ein simples
/// String→String-Mapping, damit kuenftige Boards (S3-Varianten, 3.5"-
/// Displays) ohne Code-Aenderung ergaenzbar sind — einfach neuen Key
/// hinzufuegen.
let kFirmwareAssetByDisplay: [String: String] = [
    "ili9341": "ai-monitor.bin",
    "st7789":  "ai-monitor-st7789.bin",
]

/// Display-Variante: stabile String-IDs. Passen zu den FW-Werten im
/// get_info-`display`-Feld (ab FW v2.10.1).
let kDisplayVariantILI9341 = "ili9341"
let kDisplayVariantST7789  = "st7789"
let kDisplayVariantDefault = kDisplayVariantILI9341
let kFirmwareCheckInterval: TimeInterval = 6 * 3600
let kFlashBaudRate = 460800
let kAppAssetName = "AIMonitor.zip"
let kAppUpdateCheckInterval: TimeInterval = 24 * 3600

/// Der Keychain-Eintrag der alten App-Version (<=1.7.x), der beim App-Start
/// best-effort gelöscht wird. Die Anthropic-Auth läuft ab v1.8.0 über CodexBar.
let kLegacyTokenKeychainService = "de.aimonitor.token"

/// Wie oft wir an den ESP32 senden (Session-Display-Clock lebt davon), wenn
/// CodexBar-Daten stabil bleiben.
let kSerialHeartbeatInterval: TimeInterval = 60

// ============================================================
// MARK: - Localization
// ============================================================

struct Strings {
    let firmware: String
    let flashFirmware: String
    let flashing: String
    let downloading: String
    let noReleaseFound: String
    let couldNotLoadRelease: String
    let downloadFailed: String
    let noESP32Connected: String
    let connectESP32: String
    let flashFirmwareQuestion: String
    let flash: String
    let cancel: String
    let flashSuccess: String
    let flashFailed: String
    let preparing: String
    let noUpdateAvailable: String
    let appUpdateAvailable: String
    let download: String
    let openInBrowser: String
    let later: String
    let skipVersion: String
    let updateFailed: String
    let install: String
    let appIsCurrentSuffix: String
    let installQuestion: String
    let restartInfo: String
    let downloadRunning: String
    let updateDownload: String
    let flashSuccessMessage: String
    let flashFailedPrefix: String
    let errorPrefix: String
    let firmwareCurrent: String
    let firmwareAvailable: String
    // --- Flash-Dialog (ab App v1.15.0) ---
    let flashDialogTitle: String
    let flashDialogBoardVariant: String
    let flashDialogVariantStandard: String
    let flashDialogVariantAlternative: String
    let flashDialogVariantHint: String
    let flashDialogStart: String
}

let stringsDE = Strings(
    firmware: "Firmware:",
    flashFirmware: "Firmware flashen...",
    flashing: "Flash läuft...",
    downloading: "Download...",
    noReleaseFound: "Kein Release gefunden",
    couldNotLoadRelease: "Konnte kein Firmware-Release von GitHub laden.",
    downloadFailed: "Download fehlgeschlagen",
    noESP32Connected: "Kein ESP32 verbunden",
    connectESP32: "Bitte ESP32 per USB verbinden.",
    flashFirmwareQuestion: "Firmware flashen?",
    flash: "Flashen",
    cancel: "Abbrechen",
    flashSuccess: "Flash erfolgreich",
    flashFailed: "Flash fehlgeschlagen",
    preparing: "Vorbereitung...",
    noUpdateAvailable: "Kein Update verfügbar",
    appUpdateAvailable: "App-Update verfügbar",
    download: "Herunterladen",
    openInBrowser: "Im Browser öffnen",
    later: "Später",
    skipVersion: "Version überspringen",
    updateFailed: "Update fehlgeschlagen",
    install: "Installieren",
    appIsCurrentSuffix: "ist aktuell.",
    installQuestion: "Update auf %@ installieren?",
    restartInfo: "Die App wird kurz neu gestartet.",
    downloadRunning: "Download läuft...",
    updateDownload: "Update herunterladen...",
    flashSuccessMessage: "Firmware erfolgreich geflasht!",
    flashFailedPrefix: "Flash fehlgeschlagen:",
    errorPrefix: "Fehler:",
    firmwareCurrent: "(aktuell)",
    firmwareAvailable: "verfügbar",
    flashDialogTitle: "Firmware flashen",
    flashDialogBoardVariant: "Board-Variante",
    flashDialogVariantStandard: "Standard (ILI9341) — CYD-2432S028R",
    flashDialogVariantAlternative: "Alternative (ST7789) — CYD-2432S028",
    flashDialogVariantHint: "Im Zweifel zuerst Standard probieren. Wenn das Display nach dem Flash rauscht oder gekippt ist, die Alternative wählen.",
    flashDialogStart: "Flashen starten"
)

let stringsEN = Strings(
    firmware: "Firmware:",
    flashFirmware: "Flash firmware...",
    flashing: "Flashing...",
    downloading: "Download...",
    noReleaseFound: "No release found",
    couldNotLoadRelease: "Could not load firmware release from GitHub.",
    downloadFailed: "Download failed",
    noESP32Connected: "No ESP32 connected",
    connectESP32: "Please connect ESP32 via USB.",
    flashFirmwareQuestion: "Flash firmware?",
    flash: "Flash",
    cancel: "Cancel",
    flashSuccess: "Flash successful",
    flashFailed: "Flash failed",
    preparing: "Preparing...",
    noUpdateAvailable: "No update available",
    appUpdateAvailable: "App update available",
    download: "Download",
    openInBrowser: "Open in browser",
    later: "Later",
    skipVersion: "Skip version",
    updateFailed: "Update failed",
    install: "Install",
    appIsCurrentSuffix: "is up to date.",
    installQuestion: "Install update %@?",
    restartInfo: "The app will restart briefly.",
    downloadRunning: "Downloading...",
    updateDownload: "Download update...",
    flashSuccessMessage: "Firmware flashed successfully!",
    flashFailedPrefix: "Flash failed:",
    errorPrefix: "Error:",
    firmwareCurrent: "(current)",
    firmwareAvailable: "available",
    flashDialogTitle: "Flash firmware",
    flashDialogBoardVariant: "Board variant",
    flashDialogVariantStandard: "Standard (ILI9341) — CYD-2432S028R",
    flashDialogVariantAlternative: "Alternative (ST7789) — CYD-2432S028",
    flashDialogVariantHint: "When in doubt, try Standard first. If the display shows noise or looks wrong after flashing, pick the alternative.",
    flashDialogStart: "Start flashing"
)

func S() -> Strings {
    return Settings.shared.language == "en" ? stringsEN : stringsDE
}

// ============================================================
// MARK: - Device Registry (Per-Device Settings, ab v1.14.0)
// ============================================================

/// Pseudo-MAC für Geräte mit Firmware < v2.10.0 (ohne MAC im `get_info`-Response).
/// Wird bei erstem echten MAC-Roundtrip durch das Profil mit realer MAC ersetzt.
let kLegacyDeviceMAC = "legacy-device"

/// Adjektiv-Pool (30) + Tier-Pool (30) für Auto-Namen. 900 Kombinationen,
/// Kollisions-Check gegen bestehende `friendlyName`s.
///
/// Ab v1.14.1: Genus-Matching. Jedes Tier trägt sein grammatikalisches Geschlecht
/// (m/f/n), Adjektive halten alle drei Nominativ-stark-Formen als Tupel vor.
/// Der Generator pickt die passende Form gemäß Tier-Genus. Vermeidet Unsinn wie
/// „Schlauer Schildkröte" (fem.) oder „Kühner Seepferdchen" (neutr.).
enum DeviceAutoGenus {
    case masc
    case fem
    case neutr
}

/// `(masc, fem, neutr)` Nominativ-stark-Flexion.
private let kDeviceAutoAdjectives: [(String, String, String)] = [
    ("Flinker",       "Flinke",       "Flinkes"),
    ("Funkelnder",    "Funkelnde",    "Funkelndes"),
    ("Mürrischer",    "Mürrische",    "Mürrisches"),
    ("Stolzer",       "Stolze",       "Stolzes"),
    ("Neugieriger",   "Neugierige",   "Neugieriges"),
    ("Gelassener",    "Gelassene",    "Gelassenes"),
    ("Schelmischer",  "Schelmische",  "Schelmisches"),
    ("Mutiger",       "Mutige",       "Mutiges"),
    ("Verträumter",   "Verträumte",   "Verträumtes"),
    ("Pfiffiger",     "Pfiffige",     "Pfiffiges"),
    ("Wuseliger",     "Wuselige",     "Wuseliges"),
    ("Tapferer",      "Tapfere",      "Tapferes"),
    ("Stürmischer",   "Stürmische",   "Stürmisches"),
    ("Leiser",        "Leise",        "Leises"),
    ("Kniffliger",    "Knifflige",    "Kniffliges"),
    ("Flauschiger",   "Flauschige",   "Flauschiges"),
    ("Glücklicher",   "Glückliche",   "Glückliches"),
    ("Schlauer",      "Schlaue",      "Schlaues"),
    ("Ruhiger",       "Ruhige",       "Ruhiges"),
    ("Verrückter",    "Verrückte",    "Verrücktes"),
    ("Zackiger",      "Zackige",      "Zackiges"),
    ("Emsiger",       "Emsige",       "Emsiges"),
    ("Munterer",      "Muntere",      "Munteres"),
    ("Fröhlicher",    "Fröhliche",    "Fröhliches"),
    ("Weiser",        "Weise",        "Weises"),
    ("Frecher",       "Freche",       "Freches"),
    ("Kühner",        "Kühne",        "Kühnes"),
    ("Sanfter",       "Sanfte",       "Sanftes"),
    ("Granteliger",   "Grantelige",   "Granteliges"),
    ("Glitzernder",   "Glitzernde",   "Glitzerndes"),
]

/// `(name, genus)` — Tier mit grammatikalischem Geschlecht.
private let kDeviceAutoAnimals: [(String, DeviceAutoGenus)] = [
    ("Dachs",            .masc),
    ("Otter",            .masc),
    ("Igel",             .masc),
    ("Kolibri",          .masc),
    ("Luchs",            .masc),
    ("Biber",            .masc),
    ("Eichhörnchen",     .neutr),
    ("Fuchs",            .masc),
    ("Waschbär",         .masc),
    ("Hirsch",           .masc),
    ("Wolf",             .masc),
    ("Uhu",              .masc),
    ("Seepferdchen",     .neutr),
    ("Marienkäfer",      .masc),
    ("Tintenfisch",      .masc),
    ("Erdmännchen",      .neutr),
    ("Murmeltier",       .neutr),
    ("Pelikan",          .masc),
    ("Elster",           .fem),
    ("Salamander",       .masc),
    ("Feuersalamander",  .masc),
    ("Seeadler",         .masc),
    ("Kakadu",           .masc),
    ("Kranich",          .masc),
    ("Panda",            .masc),
    ("Koala",            .masc),
    ("Quokka",           .neutr),
    ("Ameisenbär",       .masc),
    ("Schildkröte",      .fem),
    ("Nashorn",          .neutr),
]

/// Per-Device-Settings. Jedes am USB verbundene ESP32 hat genau ein Profil,
/// adressiert über die MAC-Adresse (ab FW v2.10.0 im `get_info`-Response).
/// Geräte mit älterer Firmware werden unter `kLegacyDeviceMAC` geführt — beim
/// ersten Upgrade auf FW v2.10.0 wandert das Profil auf die echte MAC.
struct DeviceProfile: Codable {
    var mac: String
    var friendlyName: String
    /// "system" | "dark" | "light" (analog `Settings.themeMode`)
    var theme: String
    /// "portrait" | "landscape_left" | "landscape_right"
    var orientation: String
    /// "de" | "en"
    var language: String
    /// 5..100
    var brightness: Int
    /// Display-Controller-Variante: "ili9341" | "st7789" | nil (unbekannt).
    /// Ab App v1.15.0: Wird im Flash-Dialog vorausgewaehlt (Standard vs.
    /// Alternative). Ab FW v2.10.1 wird das Feld nach einem erfolgreichen
    /// Flash aus dem `display`-Feld des get_info-Response uebernommen.
    /// Geraete mit FW < v2.10.1 behalten `nil` — Fallback ist die zuletzt
    /// manuell gewaehlte Variante des Users. Codable-optional, damit alte
    /// serialisierte Profile ohne Migration weiterhin decodieren.
    var displayVariant: String?

    static func defaultFor(mac: String, friendlyName: String,
                           theme: String = "system",
                           orientation: String = "portrait",
                           language: String = "de",
                           brightness: Int = 80,
                           displayVariant: String? = nil) -> DeviceProfile {
        return DeviceProfile(
            mac: mac,
            friendlyName: friendlyName,
            theme: theme,
            orientation: orientation,
            language: language,
            brightness: brightness,
            displayVariant: displayVariant
        )
    }
}

/// Singleton-Registry aller bekannten Geräte. Serialisiert `[String: DeviceProfile]`
/// als JSON in UserDefaults unter dem Key `devices`. `currentMAC` (persistiert als
/// `lastKnownDeviceMAC`) zeigt auf das gerade verbundene Device — wird beim
/// `get_info`-Response gesetzt.
final class DeviceRegistry {
    static let shared = DeviceRegistry()

    private let defaults = UserDefaults.standard
    private let kDevicesKey = "devices"
    private let kLastKnownDeviceMACKey = "lastKnownDeviceMAC"

    /// MAC des aktuell verbundenen Geräts. `nil` wenn nie verbunden war.
    var currentMAC: String? {
        get { defaults.string(forKey: kLastKnownDeviceMACKey) }
        set {
            if let v = newValue { defaults.set(v, forKey: kLastKnownDeviceMACKey) }
            else { defaults.removeObject(forKey: kLastKnownDeviceMACKey) }
        }
    }

    /// Liefert alle bekannten Profile (MAC → Profile).
    func all() -> [String: DeviceProfile] {
        guard let data = defaults.data(forKey: kDevicesKey) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: DeviceProfile].self, from: data) else {
            return [:]
        }
        return decoded
    }

    /// Liefert das Profil für die gegebene MAC oder `nil`.
    func profile(forMAC mac: String) -> DeviceProfile? {
        return all()[mac]
    }

    /// Profil speichern (überschreibt wenn vorhanden).
    func save(_ profile: DeviceProfile) {
        var current = all()
        current[profile.mac] = profile
        persist(current)
    }

    /// Profil entfernen (z.B. nach Legacy→Real-MAC-Umzug).
    func remove(mac: String) {
        var current = all()
        current.removeValue(forKey: mac)
        persist(current)
    }

    /// Das aktuell aktive Profil — `currentMAC` + Lookup. `nil` wenn nichts
    /// verbunden ist.
    func currentProfile() -> DeviceProfile? {
        guard let mac = currentMAC else { return nil }
        return profile(forMAC: mac)
    }

    /// Atomic update des Current-Profiles via Closure. Kein Effekt wenn kein
    /// aktives Profil vorliegt.
    func updateCurrent(_ transform: (inout DeviceProfile) -> Void) {
        guard let mac = currentMAC else { return }
        var profiles = all()
        guard var p = profiles[mac] else { return }
        transform(&p)
        profiles[mac] = p
        persist(profiles)
    }

    /// Erzeugt einen eindeutigen Auto-Namen (Adjektiv + Tier, deutsch).
    /// Kollisions-Check gegen `existing` (alle bestehenden `friendlyName`s).
    /// Hard-Fallback `"Gerät N"` nach 50 Versuchen.
    static func generateAutoName(existing: Set<String>) -> String {
        for _ in 0..<50 {
            let adj = kDeviceAutoAdjectives.randomElement() ?? ("Flinker", "Flinke", "Flinkes")
            let animal = kDeviceAutoAnimals.randomElement() ?? ("Dachs", .masc)
            let adjForm: String
            switch animal.1 {
            case .masc:  adjForm = adj.0
            case .fem:   adjForm = adj.1
            case .neutr: adjForm = adj.2
            }
            let candidate = "\(adjForm) \(animal.0)"
            if !existing.contains(candidate) { return candidate }
        }
        // Hard-Fallback: „Gerät N" mit kleinster freier N ≥ 1.
        var n = 1
        while existing.contains("Gerät \(n)") { n += 1 }
        return "Gerät \(n)"
    }

    /// Prüft, ob `name` bereits an ein anderes Gerät vergeben ist (gegen
    /// `excludeMAC` als Eigen-Match-Bypass beim Rename).
    func isNameTaken(_ name: String, excludeMAC: String?) -> Bool {
        for (mac, p) in all() {
            if mac == excludeMAC { continue }
            if p.friendlyName == name { return true }
        }
        return false
    }

    private func persist(_ dict: [String: DeviceProfile]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        defaults.set(data, forKey: kDevicesKey)
    }
}

// ============================================================
// MARK: - Settings Manager
// ============================================================

class Settings {
    static let shared = Settings()
    private let defaults: UserDefaults

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set {
            defaults.set(newValue, forKey: "launchAtLogin")
            updateLaunchAtLogin(newValue)
        }
    }

    var installedFirmwareVersion: String? {
        get { defaults.string(forKey: "installedFirmwareVersion") }
        set { defaults.set(newValue, forKey: "installedFirmwareVersion") }
    }

    var lastFirmwareCheck: Date? {
        get { defaults.object(forKey: "lastFirmwareCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastFirmwareCheck") }
    }

    var lastAppUpdateCheck: Date? {
        get { defaults.object(forKey: "lastAppUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastAppUpdateCheck") }
    }

    var skippedAppVersion: String? {
        get { defaults.string(forKey: "skippedAppVersion") }
        set { defaults.set(newValue, forKey: "skippedAppVersion") }
    }

    /// Ab v1.14.0: Per-Device-Settings. Alle Display-Properties (Sprache,
    /// Orientation, Theme, Brightness) werden im `DeviceProfile` des aktuell
    /// verbundenen Geräts gehalten. Wenn noch kein Profil existiert
    /// (Erstinstallation vor FW v2.10.0-Upgrade), fällt der Lookup auf das
    /// `kLegacyDeviceMAC`-Profil zurück — das die v1.12.0/v1.13.0-Globals
    /// im Migration-Step übernommen hat.
    private func activeProfileMAC() -> String {
        return DeviceRegistry.shared.currentMAC ?? kLegacyDeviceMAC
    }

    private func readProfileString(_ keyPath: (DeviceProfile) -> String, default defaultValue: String) -> String {
        let mac = activeProfileMAC()
        if let p = DeviceRegistry.shared.profile(forMAC: mac) { return keyPath(p) }
        return defaultValue
    }

    private func readProfileInt(_ keyPath: (DeviceProfile) -> Int, default defaultValue: Int) -> Int {
        let mac = activeProfileMAC()
        if let p = DeviceRegistry.shared.profile(forMAC: mac) { return keyPath(p) }
        return defaultValue
    }

    var language: String {
        get { readProfileString({ $0.language }, default: "de") }
        set {
            let mac = activeProfileMAC()
            if var p = DeviceRegistry.shared.profile(forMAC: mac) {
                p.language = newValue
                DeviceRegistry.shared.save(p)
            } else {
                // Fallback: Auto-Legacy-Profil anlegen (extrem selten — sollte
                // durch Migration bereits erledigt sein).
                let existing = Set(DeviceRegistry.shared.all().values.map { $0.friendlyName })
                let name = DeviceRegistry.generateAutoName(existing: existing)
                var p = DeviceProfile.defaultFor(mac: mac, friendlyName: name)
                p.language = newValue
                DeviceRegistry.shared.save(p)
            }
        }
    }

    var orientation: String {
        get { readProfileString({ $0.orientation }, default: "portrait") }
        set {
            DeviceRegistry.shared.updateCurrent { $0.orientation = newValue }
            if DeviceRegistry.shared.currentMAC == nil {
                // Kein verbundenes Gerät — in Legacy-Profil schreiben, falls vorhanden.
                if var p = DeviceRegistry.shared.profile(forMAC: kLegacyDeviceMAC) {
                    p.orientation = newValue
                    DeviceRegistry.shared.save(p)
                }
            }
        }
    }

    /// "system" | "dark" | "light" — steuert, was per set_theme an ESP32 geht.
    var themeMode: String {
        get { readProfileString({ $0.theme }, default: "system") }
        set {
            DeviceRegistry.shared.updateCurrent { $0.theme = newValue }
            if DeviceRegistry.shared.currentMAC == nil {
                if var p = DeviceRegistry.shared.profile(forMAC: kLegacyDeviceMAC) {
                    p.theme = newValue
                    DeviceRegistry.shared.save(p)
                }
            }
        }
    }

    /// Manuell gewählter Serial-Port (/dev/cu.usbserial-...). nil = Autoscan.
    var manualPortPath: String? {
        get { defaults.string(forKey: "manualPortPath") }
        set {
            if let v = newValue { defaults.set(v, forKey: "manualPortPath") }
            else { defaults.removeObject(forKey: "manualPortPath") }
        }
    }

    /// Letzter vom ESP32 gemeldeter Brightness-Wert (0..100). Wird aus `get_info`
    /// gesetzt und für die Settings-UI gecacht. Default 80.
    /// Ab v1.14.0: per-Device gespeichert im `DeviceProfile.brightness`.
    var lastKnownBrightness: Int {
        get { readProfileInt({ $0.brightness }, default: 80) }
        set {
            DeviceRegistry.shared.updateCurrent { $0.brightness = newValue }
            if DeviceRegistry.shared.currentMAC == nil {
                if var p = DeviceRegistry.shared.profile(forMAC: kLegacyDeviceMAC) {
                    p.brightness = newValue
                    DeviceRegistry.shared.save(p)
                }
            }
        }
    }

    /// Aktiver CodexBar-Provider — „claude" oder „codex". Default „claude".
    /// Steuert sowohl welches widget-snapshot-Entry gelesen wird als auch das
    /// `provider`-Feld im Envelope an den ESP32 (Header-Label auf dem Display).
    var selectedProvider: String {
        get {
            let raw = (defaults.string(forKey: "selectedProvider") ?? "claude").lowercased()
            return (raw == "codex") ? "codex" : "claude"
        }
        set {
            let norm = (newValue.lowercased() == "codex") ? "codex" : "claude"
            defaults.set(norm, forKey: "selectedProvider")
        }
    }

    /// Gewählte Zeitzone für `displayTime` auf dem ESP32 und Reset-Berechnungen.
    /// `"auto"` (Default) folgt `TimeZone.current`. Andere Werte sind IANA-Namen
    /// wie „Europe/Berlin" oder „America/New_York".
    var selectedTimeZone: String {
        get { defaults.string(forKey: "selectedTimeZone") ?? "auto" }
        set { defaults.set(newValue, forKey: "selectedTimeZone") }
    }

    /// Löst die effektive TimeZone aus der Settings-Konfiguration auf.
    /// Fällt bei unbekannter IANA-Kennung auf `TimeZone.current` zurück.
    func effectiveTimeZone() -> TimeZone {
        let id = selectedTimeZone
        if id == "auto" { return TimeZone.current }
        return TimeZone(identifier: id) ?? TimeZone.current
    }

    private init() {
        // Ab v1.12.0 läuft alles über `.standard` — das vermeidet die
        // Foundation-Warning und verhält sich sauber unter Sandbox-nahen
        // Defaults. Bestehende Installationen werden einmalig migriert.
        defaults = UserDefaults.standard
        Self.migrateLegacySuiteIfNeeded()
        Self.migrateToPerDeviceIfNeeded()
    }

    /// Einmalige Migration (v1.13.0 → v1.14.0): globale Display-Keys
    /// (`theme`/`themeMode`/`orientation`/`language`/`brightness`) werden in
    /// ein `DeviceProfile` unter `kLegacyDeviceMAC` gepackt. Das Profil dient
    /// als Fallback, solange kein echter MAC-Roundtrip über `get_info`
    /// stattgefunden hat, und wird beim ersten `get_info`-Response mit echter
    /// MAC auf das reale Device umgezogen.
    private static func migrateToPerDeviceIfNeeded() {
        let standard = UserDefaults.standard
        if standard.bool(forKey: "didMigrateToPerDevice_v1140") { return }

        // Globale Keys lesen (Defaults analog zu den alten Gettern)
        let theme = standard.string(forKey: "themeMode") ?? "system"
        let orientation = standard.string(forKey: "orientation") ?? "portrait"
        let language = standard.string(forKey: "language") ?? "de"
        let brightness = (standard.object(forKey: "brightness") as? Int) ?? 80

        // Auto-Name für Legacy-Device (noch keine anderen Devices registriert)
        let existing = Set(DeviceRegistry.shared.all().values.map { $0.friendlyName })
        let friendlyName = DeviceRegistry.generateAutoName(existing: existing)

        let legacyProfile = DeviceProfile(
            mac: kLegacyDeviceMAC,
            friendlyName: friendlyName,
            theme: theme,
            orientation: orientation,
            language: language,
            brightness: brightness,
            displayVariant: nil
        )
        DeviceRegistry.shared.save(legacyProfile)

        // Globale Keys aufräumen — alle weiteren Lookups laufen über Profile.
        standard.removeObject(forKey: "themeMode")
        standard.removeObject(forKey: "orientation")
        standard.removeObject(forKey: "language")
        standard.removeObject(forKey: "brightness")

        standard.set(true, forKey: "didMigrateToPerDevice_v1140")
        NSLog("[Settings] Migrated to per-device settings. Legacy profile created: '%@'", friendlyName)
    }

    /// Einmalige Migration: liest alle bekannten Keys aus der alten
    /// Suite (`de.aimonitor.app`), schreibt nach `.standard` wenn dort noch kein
    /// Wert existiert, und entfernt die Suite-Keys anschließend. Idempotent —
    /// sobald das Marker-Flag gesetzt ist, passiert nichts mehr.
    private static func migrateLegacySuiteIfNeeded() {
        let standard = UserDefaults.standard
        if standard.bool(forKey: "didMigrateLegacySuite_v1120") { return }
        guard let legacy = UserDefaults(suiteName: kLegacyUserDefaultsSuite) else {
            standard.set(true, forKey: "didMigrateLegacySuite_v1120")
            return
        }
        let keys = [
            "launchAtLogin",
            "installedFirmwareVersion",
            "lastFirmwareCheck",
            "lastAppUpdateCheck",
            "skippedAppVersion",
            "language",
            "orientation",
            "themeMode",
            "manualPortPath",
            "brightness",
            "selectedProvider",
            "selectedTimeZone",
        ]
        var copied = 0
        for k in keys {
            guard let v = legacy.object(forKey: k) else { continue }
            if standard.object(forKey: k) == nil {
                standard.set(v, forKey: k)
                copied += 1
            }
            legacy.removeObject(forKey: k)
        }
        legacy.synchronize()
        standard.set(true, forKey: "didMigrateLegacySuite_v1120")
        if copied > 0 {
            NSLog("[Settings] Migrated %d legacy suite keys to UserDefaults.standard", copied)
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled { try service.register() } else { try service.unregister() }
            } catch {
                NSLog("[Settings] SMAppService error: %@", error.localizedDescription)
            }
        }
    }
}

// ============================================================
// MARK: - Legacy Keychain Cleanup
// ============================================================

/// Beim App-Start best-effort: den alten `de.aimonitor.token`-Eintrag löschen,
/// der aus v1.5-1.7 stammt und ab v1.8 nicht mehr genutzt wird.
/// Fehler (z. B. Eintrag existiert nicht) werden NICHT als Fehler behandelt.
func cleanupLegacyKeychainEntry() {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kLegacyTokenKeychainService
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecSuccess {
        NSLog("[Cleanup] Legacy keychain entry '%@' deleted.", kLegacyTokenKeychainService)
    } else if status == errSecItemNotFound {
        // Best-effort: kein Problem.
    } else {
        NSLog("[Cleanup] Legacy keychain delete returned status %d (ignored).", status)
    }
}

// ============================================================
// MARK: - GitHub Release Models
// ============================================================

struct GitHubRelease: Codable {
    let tag_name: String
    let name: String?
    let html_url: String?
    let body: String?
    let assets: [GitHubAsset]
}

struct GitHubAsset: Codable {
    let name: String
    let browser_download_url: String
    let size: Int
}

// ============================================================
// MARK: - App Update Manager
// ============================================================

class AppUpdateManager {
    static let shared = AppUpdateManager()

    var latestRelease: GitHubRelease?
    var isDownloading = false
    var onUpdate: (() -> Void)?

    var hasUpdate: Bool {
        guard let release = latestRelease else { return false }
        let latest = normalizeVersion(release.tag_name)
        let current = normalizeVersion(kAppVersion)
        return compareVersions(latest, current) == .orderedDescending
    }

    var latestVersionDisplay: String {
        guard let release = latestRelease else { return "unbekannt" }
        return release.tag_name.hasPrefix("v") ? release.tag_name : "v\(release.tag_name)"
    }

    func checkForUpdate(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: kGitHubReleasesAPI) else { completion(false); return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                NSLog("[AppUpdate] GitHub API error: %@", error.localizedDescription)
                completion(false); return
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let data = data else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("[AppUpdate] GitHub API HTTP %d", status)
                completion(false); return
            }
            do {
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                let appRelease = releases.first { $0.tag_name.hasPrefix("app-v") }
                if let release = appRelease {
                    self.latestRelease = release
                    Settings.shared.lastAppUpdateCheck = Date()
                    let latest = self.normalizeVersion(release.tag_name)
                    let current = self.normalizeVersion(kAppVersion)
                    let isNewer = self.compareVersions(latest, current) == .orderedDescending
                    NSLog("[AppUpdate] Latest: %@ | Current: v%@ | Update: %@",
                          release.tag_name, kAppVersion, isNewer ? "YES" : "no")
                    DispatchQueue.main.async { self.onUpdate?() }
                    completion(isNewer)
                } else {
                    Settings.shared.lastAppUpdateCheck = Date()
                    DispatchQueue.main.async { self.onUpdate?() }
                    completion(false)
                }
            } catch {
                NSLog("[AppUpdate] JSON decode error: %@", error.localizedDescription)
                completion(false)
            }
        }.resume()
    }

    func downloadAndInstall(completion: @escaping (Bool, String) -> Void) {
        guard let release = latestRelease else { completion(false, S().noReleaseFound); return }
        guard let asset = release.assets.first(where: { $0.name == kAppAssetName }) else {
            if let htmlUrl = release.html_url, let url = URL(string: htmlUrl) { NSWorkspace.shared.open(url) }
            completion(true, S().openInBrowser); return
        }
        guard let downloadUrl = URL(string: asset.browser_download_url) else {
            completion(false, "Invalid download URL"); return
        }

        isDownloading = true
        DispatchQueue.main.async { self.onUpdate?() }

        let task = URLSession.shared.downloadTask(with: downloadUrl) { [weak self] tempUrl, _, error in
            guard let self = self else { return }
            self.isDownloading = false
            if let error = error {
                DispatchQueue.main.async {
                    self.onUpdate?()
                    completion(false, "Download fehlgeschlagen: \(error.localizedDescription)")
                }
                return
            }
            guard let tempUrl = tempUrl else {
                DispatchQueue.main.async { self.onUpdate?(); completion(false, S().downloadFailed) }
                return
            }
            let downloadDir = NSTemporaryDirectory() + "AIMonitor-Update"
            let zipPath = downloadDir + "/\(kAppAssetName)"
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: downloadDir) { try fm.removeItem(atPath: downloadDir) }
                try fm.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
                try fm.moveItem(at: tempUrl, to: URL(fileURLWithPath: zipPath))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-xk", zipPath, downloadDir]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    DispatchQueue.main.async {
                        self.onUpdate?()
                        completion(false, "Entpacken fehlgeschlagen (exit \(process.terminationStatus))")
                    }
                    return
                }
                let contents = try fm.contentsOfDirectory(atPath: downloadDir)
                if let appName = contents.first(where: { $0.hasSuffix(".app") }) {
                    let extractedAppPath = downloadDir + "/\(appName)"
                    DispatchQueue.main.async { self.onUpdate?(); completion(true, extractedAppPath) }
                } else {
                    DispatchQueue.main.async { self.onUpdate?(); completion(false, "Keine .app im Download gefunden") }
                }
            } catch {
                DispatchQueue.main.async {
                    self.onUpdate?()
                    completion(false, "\(S().errorPrefix) \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }

    func openReleasePage() {
        let urlStr: String
        if let release = latestRelease, let htmlUrl = release.html_url { urlStr = htmlUrl }
        else { urlStr = "https://github.com/\(kGitHubRepo)/releases" }
        if let url = URL(string: urlStr) { NSWorkspace.shared.open(url) }
    }

    func performAutoUpdate(extractedAppPath: String, completion: @escaping (Bool, String) -> Void) {
        let currentAppPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptPath = NSTemporaryDirectory() + "aimonitor-update.sh"

        guard currentAppPath.hasSuffix(".app") else { completion(false, "App-Pfad ungültig: \(currentAppPath)"); return }
        guard FileManager.default.fileExists(atPath: extractedAppPath) else {
            completion(false, "Heruntergeladene App nicht gefunden: \(extractedAppPath)"); return
        }

        let script = """
        #!/bin/bash
        CURRENT_PID=\(pid)
        NEW_APP="\(extractedAppPath)"
        OLD_APP="\(currentAppPath)"
        WAITED=0
        while kill -0 "$CURRENT_PID" 2>/dev/null; do
            sleep 0.5
            WAITED=$((WAITED + 1))
            if [ "$WAITED" -ge 60 ]; then exit 1; fi
        done
        sleep 1
        rm -rf "$OLD_APP"
        cp -R "$NEW_APP" "$OLD_APP"
        if [ $? -ne 0 ]; then exit 1; fi
        xattr -cr "$OLD_APP" 2>/dev/null
        open "$OLD_APP"
        rm -rf "$(dirname "$NEW_APP")"
        rm -f "\(scriptPath)"
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            let chmodProcess = Process()
            chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProcess.arguments = ["+x", scriptPath]
            try chmodProcess.run(); chmodProcess.waitUntilExit()

            let updateProcess = Process()
            updateProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            updateProcess.arguments = [scriptPath]
            updateProcess.standardOutput = FileHandle.nullDevice
            updateProcess.standardError = FileHandle.nullDevice
            updateProcess.qualityOfService = .utility
            try updateProcess.run()
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        } catch {
            completion(false, "Update script failed: \(error.localizedDescription)")
        }
    }

    private func normalizeVersion(_ version: String) -> String {
        var v = version
        if v.hasPrefix("app-v") { v = String(v.dropFirst(5)) }
        else if v.hasPrefix("app-") { v = String(v.dropFirst(4)) }
        else if v.hasPrefix("v") { v = String(v.dropFirst(1)) }
        return v
    }

    private func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return .orderedDescending }
            if av < bv { return .orderedAscending }
        }
        return .orderedSame
    }
}

// ============================================================
// MARK: - Firmware Manager
// ============================================================

/// Mehrstufige Phase der Firmware-Aktualisierung. Zeigt an, wo genau im
/// Download→Flash→Reboot-Ablauf wir gerade stehen. Das Settings-Fenster rendert
/// das zugehörige Label unter der ProgressBar (v1.12.0).
enum FirmwareFlashPhase {
    case idle
    case downloading        // GitHub-Release wird gezogen
    case connecting         // esptool-Handshake mit ESP32
    case erasing            // Flashspeicher löschen
    case writing            // Write mit Prozentangabe
    case verifying          // Hash-Verify
    case rebooting          // Reset nach Flash
    case done               // Erfolgreich, Firmware aktiv
    case failed             // Abbruch

    /// Deutsches, nutzersichtbares Label unter der ProgressBar.
    func label(percent: Int? = nil, version: String? = nil) -> String {
        switch self {
        case .idle:        return ""
        case .downloading: return "Firmware wird geladen …"
        case .connecting:  return "Verbindung zum ESP32 wird hergestellt …"
        case .erasing:     return "Flashspeicher wird gelöscht …"
        case .writing:
            if let p = percent { return "Firmware wird geschrieben … \(p) %" }
            return "Firmware wird geschrieben …"
        case .verifying:   return "Verifikation läuft …"
        case .rebooting:   return "Neustart …"
        case .done:
            if let v = version { return "Fertig. Firmware \(v) aktiv." }
            return "Fertig."
        case .failed:      return "Abgebrochen."
        }
    }
}

class FirmwareManager {
    static let shared = FirmwareManager()

    var latestRelease: GitHubRelease?
    var downloadedBinPath: String?
    var isDownloading = false
    var isFlashing = false
    var downloadProgress: Double = 0
    var flashProgress: String = ""
    /// Aktuelle Phase — wird vom Settings-Fenster live gelesen.
    var flashPhase: FirmwareFlashPhase = .idle
    /// Prozent innerhalb der Write-Phase (nur relevant wenn `.writing`).
    var flashWritePercent: Int = 0
    var onUpdate: (() -> Void)?

    private var firmwareDir: String {
        let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
        return (appSupport as NSString).appendingPathComponent("AI Monitor/firmware")
    }

    func localBinPath(for version: String) -> String {
        return localBinPath(for: version, variant: kDisplayVariantDefault)
    }

    /// Variantenspezifischer Cache-Pfad pro Release-Tag. Ab v1.15.0: die App
    /// laed beide Varianten unterschiedlich ab, damit ein Umschalten im
    /// Flash-Dialog keinen erneuten Download von 0 erzwingt.
    func localBinPath(for version: String, variant: String) -> String {
        let assetName = kFirmwareAssetByDisplay[variant] ?? kFirmwareAssetName
        // Dateiname: z. B. "ai-monitor-v2.10.1.bin" oder
        // "ai-monitor-st7789-v2.10.1.bin". Base ohne `.bin`-Suffix.
        let base: String = {
            if assetName.hasSuffix(".bin") {
                return String(assetName.dropLast(4))
            }
            return assetName
        }()
        return (firmwareDir as NSString).appendingPathComponent("\(base)-\(version).bin")
    }

    /// Prueft, ob das Cache-File fuer (version, variant) lokal liegt und setzt
    /// `downloadedBinPath` entsprechend. Wird nach jedem Variant-Switch im
    /// Flash-Dialog aufgerufen. Liefert `true` wenn bereits heruntergeladen.
    @discardableResult
    func checkCachedBin(version: String, variant: String) -> Bool {
        let path = localBinPath(for: version, variant: variant)
        if FileManager.default.fileExists(atPath: path) {
            downloadedBinPath = path
            return true
        }
        return false
    }

    func resolveEsptool() -> (python: String, mode: String)? {
        guard let python = findPython3() else { return nil }
        if let resourcePath = Bundle.main.resourcePath {
            let bundledDir = (resourcePath as NSString).appendingPathComponent("esptool-pkg")
            let bundledScript = (bundledDir as NSString).appendingPathComponent("esptool.py")
            if FileManager.default.fileExists(atPath: bundledScript) {
                return (python: python, mode: "bundled:\(bundledDir)")
            }
        }
        let platformioScript = NSString("~/.platformio/packages/tool-esptoolpy/esptool.py").expandingTildeInPath
        if FileManager.default.fileExists(atPath: platformioScript) {
            return (python: python, mode: "platformio:\(platformioScript)")
        }
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: python)
        checkProcess.arguments = ["-m", "esptool", "version"]
        checkProcess.standardOutput = Pipe()
        checkProcess.standardError = Pipe()
        do {
            try checkProcess.run(); checkProcess.waitUntilExit()
            if checkProcess.terminationStatus == 0 { return (python: python, mode: "module") }
        } catch {}
        return nil
    }

    private func findPython3() -> String? {
        let candidates = ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func checkForUpdate(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: kGitHubReleasesAPI) else { completion(false); return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if error != nil { completion(false); return }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, let data = data else {
                completion(false); return
            }
            do {
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                let firmwareRelease = releases.first { r in
                    r.tag_name.hasPrefix("v") && !r.tag_name.hasPrefix("app-")
                }
                guard let release = firmwareRelease else {
                    Settings.shared.lastFirmwareCheck = Date()
                    DispatchQueue.main.async { self.onUpdate?() }
                    completion(false); return
                }
                self.latestRelease = release
                Settings.shared.lastFirmwareCheck = Date()
                let installed = Settings.shared.installedFirmwareVersion ?? "unbekannt"
                let hasUpdate = (release.tag_name != installed)
                let binPath = self.localBinPath(for: release.tag_name)
                if FileManager.default.fileExists(atPath: binPath) { self.downloadedBinPath = binPath }
                DispatchQueue.main.async { self.onUpdate?() }
                completion(hasUpdate)
            } catch { completion(false) }
        }.resume()
    }

    func downloadFirmware(completion: @escaping (Bool, String?) -> Void) {
        // Legacy-Aufruf: Default-Variante (ILI9341). Ab v1.15.0 laeuft der
        // Flash-Dialog ueber `downloadFirmware(variant:)`, der Pfad hier
        // bleibt kompatibel.
        downloadFirmware(variant: kDisplayVariantDefault, completion: completion)
    }

    /// Variantenspezifischer Download. Zieht das passende Release-Asset
    /// laut `kFirmwareAssetByDisplay` und cached per-Variant.
    /// Fallback: wenn das variantenspezifische Asset nicht im Release liegt
    /// (z. B. alte Releases < v2.10.0), ziehen wir `kFirmwareAssetName` —
    /// dann aber als Hinweis im `completion`-Text, damit der Dialog den
    /// User warnen kann.
    func downloadFirmware(variant: String, completion: @escaping (Bool, String?) -> Void) {
        guard let release = latestRelease else { completion(false, S().noReleaseFound); return }
        let requestedAsset = kFirmwareAssetByDisplay[variant] ?? kFirmwareAssetName
        let asset: GitHubAsset? = release.assets.first(where: { $0.name == requestedAsset })
            ?? release.assets.first(where: { $0.name == kFirmwareAssetName })
        guard let asset = asset else {
            completion(false, "Kein \(requestedAsset) im Release \(release.tag_name)"); return
        }
        guard let url = URL(string: asset.browser_download_url) else {
            completion(false, "Invalid download URL"); return
        }
        do {
            try FileManager.default.createDirectory(atPath: firmwareDir, withIntermediateDirectories: true)
        } catch {
            completion(false, "Cannot create firmware directory: \(error.localizedDescription)"); return
        }
        let destPath = localBinPath(for: release.tag_name, variant: variant)
        if FileManager.default.fileExists(atPath: destPath) {
            downloadedBinPath = destPath
            completion(true, nil); return
        }
        isDownloading = true
        downloadProgress = 0
        // v1.12.0: Phase-Label im UI setzen, damit der User den GitHub-Download
        // klar von Connect/Erase/Write trennen kann.
        setPhase(.downloading)
        DispatchQueue.main.async { self.onUpdate?() }
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            self.isDownloading = false
            if let error = error {
                DispatchQueue.main.async { self.onUpdate?() }
                completion(false, error.localizedDescription); return
            }
            guard let tempURL = tempURL else {
                DispatchQueue.main.async { self.onUpdate?() }
                completion(false, S().downloadFailed); return
            }
            do {
                if FileManager.default.fileExists(atPath: destPath) { try FileManager.default.removeItem(atPath: destPath) }
                try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: destPath))
                self.downloadedBinPath = destPath
                self.downloadProgress = 1.0
                // Download fertig — Phase zurücksetzen, damit der anschließende
                // Flash-Start mit `.connecting` beginnt.
                DispatchQueue.main.async {
                    self.flashPhase = .idle
                    self.flashProgress = ""
                    self.onUpdate?()
                }
                completion(true, nil)
            } catch {
                DispatchQueue.main.async {
                    self.flashPhase = .idle
                    self.flashProgress = ""
                    self.onUpdate?()
                }
                completion(false, error.localizedDescription)
            }
        }
        task.resume()
    }

    /// Setzt Phase + Label und triggert UI-Refresh. Muss vom Main-Thread aus
    /// konsistent sein, daher immer via DispatchQueue.main.async.
    private func setPhase(_ phase: FirmwareFlashPhase, percent: Int? = nil) {
        DispatchQueue.main.async {
            self.flashPhase = phase
            if case .writing = phase, let p = percent { self.flashWritePercent = p }
            self.flashProgress = phase.label(
                percent: percent,
                version: self.latestRelease?.tag_name
            )
            self.onUpdate?()
        }
    }

    func flashFirmware(port: String, completion: @escaping (Bool, String) -> Void) {
        guard let binPath = downloadedBinPath, FileManager.default.fileExists(atPath: binPath) else {
            completion(false, "Keine Firmware-Datei vorhanden"); return
        }
        guard let tool = resolveEsptool() else {
            completion(false, "esptool nicht gefunden.\nInstalliere mit: pip3 install esptool"); return
        }
        isFlashing = true
        setPhase(.connecting)
        usleep(500_000)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let esptoolArgs = [
                "--chip", "esp32",
                "--port", port,
                "--baud", "\(kFlashBaudRate)",
                "write_flash", "0x0", binPath
            ]
            process.executableURL = URL(fileURLWithPath: tool.python)
            if tool.mode == "module" {
                process.arguments = ["-m", "esptool"] + esptoolArgs
            } else if tool.mode.hasPrefix("bundled:") {
                let bundledDir = String(tool.mode.dropFirst("bundled:".count))
                let scriptPath = (bundledDir as NSString).appendingPathComponent("esptool.py")
                let contribDir = (bundledDir as NSString).appendingPathComponent("_contrib")
                var env = ProcessInfo.processInfo.environment
                let existingPythonPath = env["PYTHONPATH"] ?? ""
                env["PYTHONPATH"] = [bundledDir, contribDir, existingPythonPath]
                    .filter { !$0.isEmpty }.joined(separator: ":")
                process.environment = env
                process.arguments = [scriptPath] + esptoolArgs
            } else if tool.mode.hasPrefix("platformio:") {
                let scriptPath = String(tool.mode.dropFirst("platformio:".count))
                process.arguments = [scriptPath] + esptoolArgs
            }
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            var outputText = ""
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard let str = String(data: data, encoding: .utf8), !str.isEmpty else { return }
                outputText += str
                // Phase-Erkennung anhand von esptool-Output-Markern. esptool
                // schreibt Statuszeilen unmittelbar vor dem jeweiligen Block —
                // das reicht als Trigger für den Phase-Wechsel.
                let lower = str.lowercased()
                if lower.contains("connecting") {
                    self.setPhase(.connecting)
                }
                if lower.contains("erasing flash") || lower.contains("erase") {
                    self.setPhase(.erasing)
                }
                if lower.contains("writing at") || lower.contains("wrote") {
                    // Wir sind in der Write-Phase; konkreter Prozentwert kommt
                    // über das Regex unten.
                    if case .writing = self.flashPhase {} else {
                        self.setPhase(.writing, percent: 0)
                    }
                }
                if let range = str.range(of: #"\((\d+)\s*%\)"#, options: .regularExpression) {
                    let percentStr = str[range].replacingOccurrences(of: "(", with: "")
                        .replacingOccurrences(of: "%)", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let p = Int(percentStr) {
                        self.setPhase(.writing, percent: p)
                    }
                }
                if lower.contains("verifying") || lower.contains("hash of data verified") {
                    self.setPhase(.verifying)
                }
                if lower.contains("hard resetting") || lower.contains("soft reset") || lower.contains("resetting") {
                    self.setPhase(.rebooting)
                }
            }
            var errorText = ""
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty { errorText += str }
            }
            do {
                try process.run()
                process.waitUntilExit()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let exitCode = process.terminationStatus
                if exitCode == 0 {
                    if let release = self.latestRelease { Settings.shared.installedFirmwareVersion = release.tag_name }
                    self.setPhase(.done)
                    DispatchQueue.main.async {
                        self.isFlashing = false
                        self.onUpdate?()
                    }
                    completion(true, S().flashSuccessMessage)
                } else {
                    self.setPhase(.failed)
                    DispatchQueue.main.async {
                        self.isFlashing = false
                        self.flashProgress = ""
                        self.flashPhase = .idle
                        self.onUpdate?()
                    }
                    let shortError = errorText.isEmpty ? "esptool Exit-Code \(exitCode)" :
                        (errorText.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? errorText)
                    completion(false, "\(S().flashFailedPrefix) \(shortError)")
                }
            } catch {
                self.setPhase(.failed)
                DispatchQueue.main.async {
                    self.isFlashing = false
                    self.flashProgress = ""
                    self.flashPhase = .idle
                    self.onUpdate?()
                }
                completion(false, "esptool konnte nicht gestartet werden: \(error.localizedDescription)")
            }
        }
    }

    var hasUpdate: Bool {
        guard let release = latestRelease else { return false }
        let installed = Settings.shared.installedFirmwareVersion
        return release.tag_name != installed
    }

    var installedVersionDisplay: String { Settings.shared.installedFirmwareVersion ?? "unbekannt" }
    var latestVersionDisplay: String { latestRelease?.tag_name ?? "?" }

    func canFlash(serialConnected: Bool) -> Bool {
        return !isFlashing && !isDownloading && serialConnected && downloadedBinPath != nil
    }
}

// ============================================================
// MARK: - Serial Port Manager
// ============================================================

/// Ab v1.14.2: Expliziter Lebenszyklus der USB-Serial-Verbindung. Ersetzt das
/// implizite „verbunden == antwortet" der Vorgaenger. Wichtig fuer Geraete mit
/// Fremd-Firmware (z. B. Hersteller-Vorschau-FW auf CYD), die zwar den
/// USB-CDC-Port oeffnen, aber auf `get_info` nicht antworten — fuer die
/// Display-Settings/Profil-Zuordnung liefen sonst cache-basierte Fehlwerte.
///
/// Transitions:
///   disconnected → probing           (Port geoeffnet, `get_info` gesendet)
///   probing      → connected         (parsebare info-Response, ggf. mit MAC)
///   probing      → foreignFirmware   (5s-Timeout oder unparsebare Antwort)
///   foreignFirmware → connected      (seltene Spaet-Response waehrend
///                                     weiterhin offener Session)
///   *            → disconnected      (Port verschwunden / disconnect())
enum DeviceConnectionState {
    case disconnected
    case probing
    case connected
    case foreignFirmware
}

class SerialPortManager {
    private var fileDescriptor: Int32 = -1
    private(set) var connectedPort: String?
    private var scanTimer: Timer?
    private var lastDisconnectAt: Date?
    private let eventReaderQueue = DispatchQueue(label: "de.aimonitor.serial.events", qos: .utility)
    private var eventReaderGeneration: UInt64 = 0
    // Nach einem Firmware-Reboot (Legacy-Pfad) dauerte das Wiederherstellen der
    // USB-CDC-Schnittstelle ~2-3 s. Frueher: 5 s Blockwindow = spuerbarer Delay.
    // v1.9.0: auf 1 s reduziert, da v2.8.0-Firmware orientation/theme ohne Reboot
    // handhabt und reale Reconnects nur nach Flash oder Hard-Reset auftreten.
    private let kReconnectBlockWindow: TimeInterval = 1
    /// Hartes Response-Deadline fuer `get_info` nach Connect. Bei Fremd-FW
    /// (keine AI-Monitor-Firmware) bleibt die UART stumm — wir muessen den
    /// Probe abbrechen, um nicht mit Cache-Werten fremde Geraete zu
    /// ueberschreiben. 5 s deckt auch langsamere CYD-Klone ab.
    private let kGetInfoTimeout: TimeInterval = 5
    var onConnect: (() -> Void)?
    var onProviderToggleRequest: (() -> Void)?
    var deviceFirmwareVersion: String?

    /// Ab v1.14.2: Lebenszyklus-Status der aktuellen Verbindung. Die UI (und
    /// alle `set_*`-Sends) muessen hier draufhoeren, nicht nur auf `isConnected`.
    private(set) var state: DeviceConnectionState = .disconnected

    /// `true` nur, wenn eine vollstaendige `get_info`-Handshake lief und das
    /// Geraet als AI-Monitor-Firmware identifiziert wurde. Ersatz fuer
    /// alle Push-Gates, die frueher auf `isConnected` standen.
    var isReadyForCommands: Bool { state == .connected }

    var isConnected: Bool { fileDescriptor >= 0 }

    func startScanning() {
        scanTimer = Timer.scheduledTimer(withTimeInterval: kSerialScanInterval, repeats: true) { [weak self] _ in
            self?.scanForPort()
        }
        scanForPort()
    }

    func stopScanning() {
        scanTimer?.invalidate()
        scanTimer = nil
        disconnect()
    }

    /// Liste aller aktuell am System anliegenden USB-Serial-Ports.
    func availablePortPaths() -> [String] {
        let devPath = "/dev"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: devPath) else { return [] }
        return files.filter { $0.hasPrefix("cu.usbserial-") }.map { "\(devPath)/\($0)" }.sorted()
    }

    /// Wird vom SettingsWindow aufgerufen, wenn der User den Port-Popup ändert.
    /// Trennt aktuelle Verbindung sauber und triggert einen Rescan.
    func requestReconnect() {
        disconnect()
        scanForPort()
    }

    func scanForPort() {
        if let port = connectedPort {
            if !FileManager.default.fileExists(atPath: port) {
                NSLog("[Serial] Port %@ disappeared, reconnecting...", port)
                disconnect()
            } else {
                return
            }
        }
        let available = availablePortPaths()
        guard !available.isEmpty else { return }
        let candidate: String
        if let manual = Settings.shared.manualPortPath, available.contains(manual) {
            candidate = manual
        } else {
            candidate = available.first!
        }
        if let lastDisc = lastDisconnectAt {
            let elapsed = Date().timeIntervalSince(lastDisc)
            if elapsed < kReconnectBlockWindow {
                NSLog("[Serial] Reconnect blocked — last disconnect %.1fs ago", elapsed)
                return
            }
        }
        connect(to: candidate)
    }

    private func connect(to port: String) {
        NSLog("[Serial] Connecting to %@...", port)
        let fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { NSLog("[Serial] Failed to open %@: errno %d", port, errno); return }

        var options = termios()
        tcgetattr(fd, &options)
        cfsetispeed(&options, kSerialBaudRate)
        cfsetospeed(&options, kSerialBaudRate)
        options.c_cflag &= ~tcflag_t(PARENB)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        options.c_cflag |= tcflag_t(CLOCAL)
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_oflag &= ~tcflag_t(OPOST)
        tcsetattr(fd, TCSANOW, &options)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        fileDescriptor = fd
        connectedPort = port
        state = .probing
        NSLog("[Serial] Connected to %@ at 115200 baud (state=probing)", port)

        let newline: [UInt8] = [0x0A]
        newline.withUnsafeBufferPointer { buf in _ = Darwin.write(fd, buf.baseAddress!, 1) }
        usleep(200_000)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.fileDescriptor >= 0 else { return }
            self.drainInput()
            let cmd = "{\"cmd\":\"get_info\"}\n"
            guard let cmdData = cmd.data(using: .utf8) else { return }
            let writeResult = cmdData.withUnsafeBytes { rawBuffer -> Int in
                guard let ptr = rawBuffer.baseAddress else { return -1 }
                return Darwin.write(self.fileDescriptor, ptr, rawBuffer.count)
            }
            NSLog("[Serial] Sent get_info (%d bytes)", writeResult)
            var handled = false
            if writeResult > 0 {
                // Hartes Gesamt-Timeout `kGetInfoTimeout`. readLine() nutzt
                // intern ein eigenes Deadline-Fenster; wir begrenzen die Summe.
                let probeDeadline = Date().addingTimeInterval(self.kGetInfoTimeout)
                while Date() < probeDeadline && self.fileDescriptor >= 0 {
                    let remaining = probeDeadline.timeIntervalSinceNow
                    if remaining <= 0 { break }
                    guard let line = self.readLine(timeout: min(remaining, 1.0)) else { continue }
                    NSLog("[Serial] read: %@", line)
                    guard line.hasPrefix("{") else { continue }
                    guard let jsonData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                          let type = json["type"] as? String, type == "info",
                          let version = json["version"] as? String else {
                        continue
                    }
                    self.deviceFirmwareVersion = version
                    Settings.shared.installedFirmwareVersion = "v\(version)"
                    NSLog("[Serial] ESP32 firmware: v%@ (state=connected)", version)

                    // Ab FW v2.10.0: MAC extrahieren und Per-Device-
                    // Registry-Lookup machen. Alte FW (ohne `mac`):
                    // Pseudo-MAC `kLegacyDeviceMAC` nutzen.
                    let reportedMAC = (json["mac"] as? String)?
                        .lowercased()
                        .trimmingCharacters(in: .whitespaces)
                    let effectiveMAC: String = (reportedMAC?.isEmpty ?? true)
                        ? kLegacyDeviceMAC
                        : reportedMAC!
                    self.state = .connected
                    // Ab FW v2.10.1: `display`-Feld liefert die
                    // Board-Variante (ili9341|st7789). Wird ins Profil
                    // uebernommen, damit der Flash-Dialog die Variante
                    // beim naechsten Flash korrekt vorwaehlt.
                    let reportedDisplay = (json["display"] as? String)?
                        .lowercased()
                        .trimmingCharacters(in: .whitespaces)
                    self.resolveDeviceProfile(forMAC: effectiveMAC,
                                             reportedBrightness: json["brightness"] as? Int,
                                             reportedDisplay: reportedDisplay)
                    self.startEventReader(for: fd)
                    handled = true
                    break
                }
            }

            if !handled && self.fileDescriptor >= 0 {
                // Kein parsebarer info-Response innerhalb `kGetInfoTimeout`
                // erhalten → Fremd-Firmware. WICHTIG: KEIN
                // resolveDeviceProfile, KEIN currentMAC-Update, KEINE neue
                // Profilanlage, KEIN Legacy-Migrate. Der letzte bekannte
                // aktive DeviceProfile-Kontext (currentMAC) bleibt
                // unveraendert — aber das SettingsWindow zeigt in diesem
                // State bewusst keine Profil-Werte an (siehe updateDeviceRow
                // / UI-Gates).
                self.state = .foreignFirmware
                NSLog("[Serial] get_info timeout (%.1fs) — treating as foreign firmware", self.kGetInfoTimeout)
                // Grenzfall: Fremd-FW, die spaeter doch antwortet (z. B. der
                // User hat in der Zwischenzeit einen anderen CYD auf AI-
                // Monitor-FW angeschlossen). Wir lauschen noch ein paar
                // Sekunden hintergrundig — wenn ein info-Response kommt,
                // stufen wir auf .connected hoch.
                self.watchForLateInfoResponse()
            }

            DispatchQueue.main.async { self.onConnect?() }
        }
    }

    /// Wird nach `.foreignFirmware` einmal gestartet. Hoert maximal
    /// `kLateResponseWindow` Sekunden auf weiteren Input — falls doch noch
    /// eine `info`-Response reinkommt (User hat zwischendurch flashen
    /// gestartet, oder ein Device bootet spaet), stufen wir auf
    /// `.connected` hoch und loesen onConnect erneut aus.
    private func watchForLateInfoResponse() {
        let kLateResponseWindow: TimeInterval = 8
        let probeFD = self.fileDescriptor
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let deadline = Date().addingTimeInterval(kLateResponseWindow)
            while Date() < deadline && self.fileDescriptor == probeFD && self.state == .foreignFirmware {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                guard let line = self.readLine(timeout: min(remaining, 1.0)) else { continue }
                guard line.hasPrefix("{") else { continue }
                guard let jsonData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let type = json["type"] as? String, type == "info",
                      let version = json["version"] as? String else { continue }
                self.deviceFirmwareVersion = version
                Settings.shared.installedFirmwareVersion = "v\(version)"
                let reportedMAC = (json["mac"] as? String)?
                    .lowercased()
                    .trimmingCharacters(in: .whitespaces)
                let effectiveMAC: String = (reportedMAC?.isEmpty ?? true)
                    ? kLegacyDeviceMAC
                    : reportedMAC!
                self.state = .connected
                NSLog("[Serial] Late info-response received — upgrading foreignFirmware → connected (v%@)", version)
                let reportedDisplay = (json["display"] as? String)?
                    .lowercased()
                    .trimmingCharacters(in: .whitespaces)
                self.resolveDeviceProfile(forMAC: effectiveMAC,
                                         reportedBrightness: json["brightness"] as? Int,
                                         reportedDisplay: reportedDisplay)
                self.startEventReader(for: probeFD)
                DispatchQueue.main.async { self.onConnect?() }
                return
            }
        }
    }

    func disconnect() {
        if fileDescriptor >= 0 { Darwin.close(fileDescriptor); fileDescriptor = -1 }
        connectedPort = nil
        lastDisconnectAt = Date()
        state = .disconnected
        eventReaderGeneration &+= 1
    }

    /// Mappt eine per `get_info` gemeldete MAC auf ein `DeviceProfile`. Legt ein
    /// neues Profil an, wenn noch keines existiert. Wenn ein Gerät mit echter
    /// MAC dort ankommt, wo bisher das `kLegacyDeviceMAC`-Fallback-Profil
    /// seine Settings getragen hat, werden die Settings aus dem Legacy-Profil
    /// übernommen und das Legacy-Profil entfernt.
    /// Setzt am Ende `currentMAC` auf das gefundene/neue Profil.
    /// `reportedBrightness` (FW v2.8.0+) wird in das Profil geschrieben, damit
    /// der Slider beim Öffnen des Settings-Fensters den echten ESP32-Stand zeigt.
    fileprivate func resolveDeviceProfile(forMAC mac: String,
                                          reportedBrightness: Int?,
                                          reportedDisplay: String?) {
        let registry = DeviceRegistry.shared
        // Nur bekannte Varianten akzeptieren; "unknown" / Fremdwerte ignorieren,
        // damit ein altes Profil mit gutem Wert nicht ueberschrieben wird.
        let validDisplay: String? = {
            guard let d = reportedDisplay, !d.isEmpty else { return nil }
            return kFirmwareAssetByDisplay.keys.contains(d) ? d : nil
        }()

        if var existing = registry.profile(forMAC: mac) {
            // Profil bereits bekannt — Brightness + Display-Variante nachziehen
            // und `currentMAC` auf das Profil setzen, damit Settings-Reads/
            // -Writes auf dem richtigen Objekt landen.
            var changed = false
            if let br = reportedBrightness, br != existing.brightness {
                existing.brightness = br
                changed = true
            }
            if let d = validDisplay, d != existing.displayVariant {
                existing.displayVariant = d
                changed = true
            }
            if changed { registry.save(existing) }
            registry.currentMAC = mac
            NSLog("[Device] Matched existing profile: %@ (mac=%@, display=%@)",
                  existing.friendlyName, mac, existing.displayVariant ?? "nil")
            return
        }

        // Profil existiert noch nicht.
        // Spezialfall: Gerät meldet eine ECHTE MAC, aber wir haben ein
        // Legacy-Device-Profil — dann transferiere Settings vom Legacy-Profil,
        // damit der User seinen bisherigen Setup-Stand behält.
        let useLegacyTransfer = (mac != kLegacyDeviceMAC)
            && (registry.profile(forMAC: kLegacyDeviceMAC) != nil)

        if useLegacyTransfer, let legacy = registry.profile(forMAC: kLegacyDeviceMAC) {
            var moved = legacy
            moved.mac = mac
            if let br = reportedBrightness { moved.brightness = br }
            if let d = validDisplay { moved.displayVariant = d }
            registry.save(moved)
            registry.remove(mac: kLegacyDeviceMAC)
            registry.currentMAC = mac
            NSLog("[Device] Migrated legacy profile to real MAC: %@ → %@ (mac=%@, display=%@)",
                  kLegacyDeviceMAC, moved.friendlyName, mac, moved.displayVariant ?? "nil")
            return
        }

        // Komplett neues Gerät — Auto-Name + Default-Settings aus aktuell
        // aktivem Profil (falls es eins gibt), sonst App-Defaults.
        let existingNames = Set(registry.all().values.map { $0.friendlyName })
        let autoName = DeviceRegistry.generateAutoName(existing: existingNames)

        let template = registry.currentProfile()
        var fresh = DeviceProfile.defaultFor(
            mac: mac,
            friendlyName: autoName,
            theme: template?.theme ?? "system",
            orientation: template?.orientation ?? "portrait",
            language: template?.language ?? "de",
            brightness: reportedBrightness ?? template?.brightness ?? 80,
            displayVariant: validDisplay
        )
        if let br = reportedBrightness { fresh.brightness = br }
        registry.save(fresh)
        registry.currentMAC = mac
        NSLog("[Device] Created new profile: '%@' (mac=%@, display=%@)",
              fresh.friendlyName, mac, fresh.displayVariant ?? "nil")
    }

    func send(data: Data) -> Bool {
        guard fileDescriptor >= 0 else { return false }
        let result = data.withUnsafeBytes { rawBuffer -> Int in
            guard let ptr = rawBuffer.baseAddress else { return -1 }
            return Darwin.write(fileDescriptor, ptr, rawBuffer.count)
        }
        if result < 0 {
            NSLog("[Serial] Write failed: errno %d", errno)
            disconnect(); return false
        }
        return true
    }

    func sendJSON(_ jsonString: String) -> Bool {
        guard let data = (jsonString + "\n").data(using: .utf8) else { return false }
        return send(data: data)
    }

    private func startEventReader(for fd: Int32) {
        guard fd >= 0 else { return }
        eventReaderGeneration &+= 1
        let generation = eventReaderGeneration
        eventReaderQueue.async { [weak self] in
            guard let self = self else { return }
            while self.fileDescriptor == fd
                    && self.state == .connected
                    && self.eventReaderGeneration == generation {
                guard let line = self.readLine(timeout: 1.0) else { continue }
                self.handleIncomingDeviceLine(line)
            }
        }
    }

    private func handleIncomingDeviceLine(_ line: String) {
        guard line.hasPrefix("{"),
              let jsonData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = (json["type"] as? String)?.lowercased() else {
            return
        }

        if type == "event",
           let event = (json["event"] as? String)?.lowercased(),
           event == "toggle_provider" {
            NSLog("[Serial] Device requested provider toggle")
            DispatchQueue.main.async { self.onProviderToggleRequest?() }
        }
    }

    func readLine(timeout: TimeInterval = 2.0) -> String? {
        guard fileDescriptor >= 0 else { return nil }
        var buffer = [UInt8]()
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0
        while Date() < deadline {
            var pfd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pfd, 1, 100)
            if pollResult > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let readResult = Darwin.read(fileDescriptor, &byte, 1)
                if readResult == 1 {
                    if byte == 0x0A { return String(bytes: buffer, encoding: .utf8) }
                    if byte != 0x0D { buffer.append(byte) }
                } else { return nil }
            }
        }
        return nil
    }

    private func drainInput() {
        var byte: UInt8 = 0
        while true {
            var pfd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&pfd, 1, 10) > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                _ = Darwin.read(fileDescriptor, &byte, 1)
            } else { break }
        }
    }
}

// ============================================================
// MARK: - Usage Monitor (CodexBar -> Serial)
// ============================================================

class UsageMonitor {
    let serialPort: SerialPortManager
    let codexBar: CodexBarSource
    var lastUpdateDate: Date?
    var onUpdate: (() -> Void)?
    private var heartbeatTimer: Timer?

    init() {
        self.serialPort = SerialPortManager()
        self.codexBar = CodexBarSource(provider: Settings.shared.selectedProvider)
    }

    /// Vom SettingsWindow aufgerufen, wenn der Provider-Picker geändert wurde.
    /// Persistiert, aktualisiert die CodexBar-Source und pusht sofort den neuen
    /// Snapshot an den ESP32 (kein Warten auf den nächsten Heartbeat).
    func setSelectedProvider(_ newProvider: String) {
        let norm = (newProvider.lowercased() == "codex") ? "codex" : "claude"
        Settings.shared.selectedProvider = norm
        codexBar.setProvider(norm)
        // Wenn die CodexBar-Source bereits einen OK-Entry für den neuen Provider
        // hat (setProvider() hat loadOnce() getriggert, das auch onChange feuert
        // und damit sendUsageToESP32 bereits ausgelöst hat), ist das hier
        // redundant aber harmlos — garantiert aber den Resend falls onChange
        // noch nicht drin war (z. B. während das Settings-Fenster updatet).
        if codexBar.status.isOK {
            sendUsageToESP32()
        }
    }

    func toggleSelectedProvider() {
        let toggled = (codexBar.provider == "codex") ? "claude" : "codex"
        setSelectedProvider(toggled)
    }

    func start() {
        // CodexBar-Source: liefert neue Daten → Push an ESP32
        codexBar.onChange = { [weak self] in
            guard let self = self else { return }
            self.onUpdate?()
            // Nur wenn OK: an ESP32 senden. Stale/Missing/WrongVersion -> nix senden,
            // ESP32 friert letzten Wert ein (Timeout im Display handled die Firmware).
            if self.codexBar.status.isOK {
                self.sendUsageToESP32()
            }
        }

        // Serial: bei Connect Theme/Language/Orientation + aktuellen Usage pushen.
        // ACHTUNG: Die einzelnen set_*-Commands rufen intern ebenfalls
        // sendLastUsageSnapshotIfAvailable() — Mehrfach-Sends sind ok (ESP32
        // dedupliziert via Timestamp), garantieren aber, dass jede Variante
        // sofort sichtbare Daten bekommt.
        serialPort.onConnect = { [weak self] in
            guard let self = self else { return }
            self.onUpdate?()
            // Ab v1.14.0: bei Connect ALLE Per-Device-Settings pushen
            // (Theme/Language/Orientation/Brightness), damit ein Gerät, das
            // anderswo verwendet wurde, sofort auf das hier hinterlegte
            // Profil springt. Die einzelnen set_*-Pushes triggern intern
            // sendLastUsageSnapshotIfAvailable — kein Verlust des Dashboards.
            self.sendThemeToESP32()
            self.sendLanguageToESP32()
            self.sendOrientationToESP32()
            self.sendBrightnessToESP32(Settings.shared.lastKnownBrightness)
            if self.codexBar.status.isOK {
                self.sendUsageToESP32()
            }
        }
        serialPort.onProviderToggleRequest = { [weak self] in
            self?.toggleSelectedProvider()
        }
        serialPort.startScanning()

        // CodexBar zuletzt starten (nachdem Callbacks gesetzt sind)
        codexBar.start()

        // Heartbeat: Display-Uhr aktuell halten, auch wenn CodexBar nicht neu schreibt
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: kSerialHeartbeatInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.codexBar.status.isOK {
                self.sendUsageToESP32()
            }
        }
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        codexBar.stop()
        serialPort.stopScanning()
    }

    // ---- Sende-Funktionen ----

    func sendThemeToESP32() {
        guard serialPort.isReadyForCommands else { return }
        let mode = Settings.shared.themeMode
        let resolvedDark: Bool
        switch mode {
        case "dark":  resolvedDark = true
        case "light": resolvedDark = false
        default:      resolvedDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let theme = resolvedDark ? "dark" : "light"
        let cmd = "{\"cmd\":\"set_theme\",\"value\":\"\(theme)\"}"
        if serialPort.sendJSON(cmd) { NSLog("[Serial] Sent set_theme: %@", theme) }
        // Nach Theme-Wechsel (ESP32 recreated dashboard) den letzten Snapshot
        // sofort re-pushen — sonst zeigt das Display bis zum nächsten
        // CodexBar-Tick "--%".
        sendLastUsageSnapshotIfAvailable()
    }

    func sendLanguageToESP32() {
        guard serialPort.isReadyForCommands else { return }
        let lang = Settings.shared.language
        let cmd = "{\"cmd\":\"set_language\",\"value\":\"\(lang)\"}"
        if serialPort.sendJSON(cmd) { NSLog("[Serial] Sent set_language: %@", lang) }
        sendLastUsageSnapshotIfAvailable()
    }

    func sendOrientationToESP32() {
        guard serialPort.isReadyForCommands else { return }
        let orient = Settings.shared.orientation
        let cmd = "{\"cmd\":\"set_orientation\",\"value\":\"\(orient)\"}"
        if serialPort.sendJSON(cmd) { NSLog("[Serial] Sent set_orientation: %@", orient) }
        // Firmware v2.8.0+ wechselt live (kein Reboot). Sofort neuen Snapshot
        // hinterherschicken, damit das neu aufgebaute Dashboard Daten hat.
        sendLastUsageSnapshotIfAvailable()
    }

    /// Wird aus dem SettingsWindow aufgerufen, wenn die Zeitzone geändert wurde.
    /// Der nächste `sendUsageToESP32` nutzt die neue TZ via `Settings.shared
    /// .effectiveTimeZone()`, deshalb reicht ein sofortiger Resend.
    func sendUsageSnapshotForTimeZoneChange() {
        sendLastUsageSnapshotIfAvailable()
    }

    /// Sendet den aktuellen Brightness-Wert (0..100) an den ESP32. Persistenz
    /// liegt in NVS auf der Firmware; hier nur Cache für UI-Vorbelegung.
    func sendBrightnessToESP32(_ percent: Int) {
        let clamped = max(5, min(100, percent))
        Settings.shared.lastKnownBrightness = clamped
        guard serialPort.isReadyForCommands else { return }
        let cmd = "{\"cmd\":\"set_brightness\",\"value\":\(clamped)}"
        if serialPort.sendJSON(cmd) { NSLog("[Serial] Sent set_brightness: %d", clamped) }
    }

    /// Falls CodexBar-Daten vorliegen, wird der letzte Snapshot direkt an den
    /// ESP32 gesendet — ohne auf den nächsten Heartbeat zu warten. Verwendet
    /// von allen set_*-Commands und beim Serial-Connect, um Delay zu minimieren.
    fileprivate func sendLastUsageSnapshotIfAvailable() {
        guard codexBar.status.isOK, codexBar.lastEntry != nil else { return }
        sendUsageToESP32()
    }

    fileprivate func sendUsageToESP32() {
        guard serialPort.isReadyForCommands else { return }
        guard let entry = codexBar.lastEntry else { return }

        let primaryPercent = Int((entry.primary?.usedPercent ?? 0).rounded())
        let secondaryPercent = Int((entry.secondary?.usedPercent ?? 0).rounded())
        let primaryResetsAt = entry.primary?.resetsAt ?? ""
        let secondaryResetsAt = entry.secondary?.resetsAt ?? ""
        let primaryWindow = entry.primary?.windowMinutes ?? 300
        let secondaryWindow = entry.secondary?.windowMinutes ?? 10080

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let nowISO = isoFormatter.string(from: Date())

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        // Ab v1.12.0 berücksichtigt `displayTime` die im Settings-Fenster
        // gewählte Zeitzone. „auto" folgt weiterhin der System-Zeitzone.
        timeFmt.timeZone = Settings.shared.effectiveTimeZone()
        let localTime = timeFmt.string(from: Date())

        // Provider aus der CodexBar-Source (normalisiert), nicht direkt aus
        // Settings — das hält Envelope und tatsächlich gelesene Daten konsistent.
        let activeProvider = codexBar.provider           // „claude" | „codex"
        let loginMethodLabel = (activeProvider == "codex") ? "Codex" : "Claude Max"

        // JSON-Envelope: strukturgleich zum alten Format, ab v1.10.0 mit
        // `provider`-Feld (FW v2.9.0 rendert darauf das Header-Label; ältere FW
        // ignoriert unbekannte Felder und zeigt „CLAUDE" statisch).
        let envelope: [String: Any] = [
            "time": nowISO,
            "displayTime": localTime,
            "data": [
                [
                    "source": "codexbar",
                    "provider": activeProvider,
                    "usage": [
                        "primary": [
                            "usedPercent": primaryPercent,
                            "resetsAt": primaryResetsAt,
                            "windowMinutes": primaryWindow
                        ],
                        "secondary": [
                            "usedPercent": secondaryPercent,
                            "resetsAt": secondaryResetsAt,
                            "windowMinutes": secondaryWindow
                        ],
                        "loginMethod": loginMethodLabel
                    ]
                ]
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: envelope)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                if serialPort.sendJSON(jsonString) {
                    lastUpdateDate = Date()
                    NSLog("[Serial] Sent usage data (%d bytes) s=%d%% w=%d%%",
                          jsonData.count, primaryPercent, secondaryPercent)
                }
            }
        } catch {
            NSLog("[Serial] JSON encode error: %@", error.localizedDescription)
        }
    }
}

// ============================================================
// MARK: - App Delegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var monitor: UsageMonitor!
    var settingsController: SettingsWindowController!
    var appearanceObservation: NSKeyValueObservation?
    var firmwareCheckTimer: Timer?
    var appUpdateCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Best-effort Aufraeumen der alten Keychain-Eintraege (Anthropic OAuth Cache).
        cleanupLegacyKeychainEntry()

        // UsageMonitor initialisieren
        monitor = UsageMonitor()
        monitor.onUpdate = { [weak self] in
            self?.settingsController?.update()
        }
        monitor.start()

        // Firmware + App-Update Manager
        FirmwareManager.shared.onUpdate = { [weak self] in self?.settingsController?.update() }
        checkFirmwareUpdate()
        scheduleFirmwareCheckTimer()

        AppUpdateManager.shared.onUpdate = { [weak self] in self?.settingsController?.update() }
        checkAppUpdate()
        scheduleAppUpdateCheckTimer()

        // macOS-Appearance-Observer (für themeMode=system)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            if Settings.shared.themeMode == "system" {
                self?.monitor.sendThemeToESP32()
            }
        }

        // Unsichtbares Shortcut-Menue: macOS rendert unter .accessory/LSUIElement
        // keine System-Menueleiste, liest aber Key-Equivalents aus NSApp.mainMenu.
        // Daher legen wir ein minimales Menue an, das nie gezeigt wird, aber ⌘Q
        // (Beenden) und ⌘W (Fenster schliessen) funktionsfaehig haelt.
        installShortcutMenu()

        // Settings-Fenster bauen + initial zeigen. App-Aktionen (Über, Updates)
        // liegen direkt im Footer — kein sichtbarer Main-Menu-Pfad.
        settingsController = SettingsWindowController()
        settingsController.monitor = monitor
        settingsController.show()

        NSLog("[App] AI Monitor v%@ started (LSUIElement, CodexBar source)", kAppVersion)
    }

    /// Wird aufgerufen, wenn die App aus Spotlight/Finder erneut gestartet wird.
    /// Liefert true und öffnet das Settings-Fenster.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsController?.show()
        return true
    }

    // ---- Unsichtbares Shortcut-Menue (nur fuer ⌘Q / ⌘W — kein UI) ----

    private func installShortcutMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "AI Monitor")

        let quitItem = NSMenuItem(title: "AI Monitor beenden",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Fenster")

        let closeItem = NSMenuItem(title: "Schließen",
                                   action: #selector(NSWindow.performClose(_:)),
                                   keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(closeItem)

        windowMenuItem.submenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    // ---- Firmware Check Timer ----

    func scheduleFirmwareCheckTimer() {
        firmwareCheckTimer = Timer.scheduledTimer(withTimeInterval: kFirmwareCheckInterval, repeats: true) { [weak self] _ in
            self?.checkFirmwareUpdate()
        }
    }

    func checkFirmwareUpdate() {
        if let lastCheck = Settings.shared.lastFirmwareCheck,
           Date().timeIntervalSince(lastCheck) < kFirmwareCheckInterval {
            FirmwareManager.shared.checkForUpdate { _ in }
            return
        }
        FirmwareManager.shared.checkForUpdate { _ in }
    }

    // ---- App Update Timer ----

    func scheduleAppUpdateCheckTimer() {
        appUpdateCheckTimer = Timer.scheduledTimer(withTimeInterval: kAppUpdateCheckInterval, repeats: true) { [weak self] _ in
            self?.checkAppUpdate()
        }
    }

    func checkAppUpdate() {
        if let lastCheck = Settings.shared.lastAppUpdateCheck,
           Date().timeIntervalSince(lastCheck) < kAppUpdateCheckInterval { return }
        AppUpdateManager.shared.checkForUpdate { _ in }
    }

    // ---- Actions, vom Settings-Fenster aufgerufen ----

    /// Ab App v1.15.0: Flash-Dialog mit Board-Variant-Auswahl.
    /// Ablauf:
    ///   1. Release muss bekannt sein → sonst Warn-Alert.
    ///   2. Port muss verbunden sein → sonst Warn-Alert.
    ///   3. Default-Variante bestimmen: aus `DeviceProfile.displayVariant` des
    ///      aktuell verbundenen Geraets (falls vorhanden), sonst Standard
    ///      (ILI9341). Bei `.foreignFirmware` kein MAC → immer Standard.
    ///   4. Dialog modal zeigen. User waehlt Variante → „Flashen starten".
    ///   5. Variantenspezifisches Asset herunterladen (falls nicht gecached),
    ///      Variant im Profil persistieren, flashen.
    func runFirmwareFlash() {
        let fw = FirmwareManager.shared
        guard fw.latestRelease != nil else {
            alert(title: S().noReleaseFound, info: S().couldNotLoadRelease, style: .warning)
            return
        }
        guard let port = monitor.serialPort.connectedPort else {
            alert(title: S().noESP32Connected, info: S().connectESP32, style: .warning); return
        }

        // Default-Variante bestimmen — aus Profil (falls bekannt), sonst ILI9341.
        let defaultVariant: String = DeviceRegistry.shared.currentProfile()?.displayVariant
            ?? kDisplayVariantDefault

        let version = fw.latestRelease?.tag_name ?? fw.installedVersionDisplay
        let shortPort = (port as NSString).lastPathComponent
        let info = "ESP32 \(shortPort) — Firmware \(version)"

        FlashDialogController.presentModal(info: info,
                                           defaultVariant: defaultVariant) { [weak self] chosenVariant in
            guard let self = self else { return }
            guard let variant = chosenVariant else { return }  // Abbrechen
            self.performFlash(port: port, variant: variant)
        }
    }

    /// Eigentliches Flashen inkl. Download des variantenspezifischen Assets.
    /// Ausgelagert aus `runFirmwareFlash`, damit der Dialog-Callback klar bleibt.
    fileprivate func performFlash(port: String, variant: String) {
        let fw = FirmwareManager.shared

        // Variant im aktiven Profil persistieren (falls Gerät bekannt ist),
        // damit der Dialog beim naechsten Flash dieselbe Wahl vorauswaehlt.
        // Bei `.foreignFirmware` haben wir keine aktuell gueltige currentMAC-
        // Zuordnung fuer DAS Geraet, das geflasht wird — dort schreibt
        // `resolveDeviceProfile` nach dem naechsten get_info dann den
        // finalen Display-Wert aus der FW. Die User-Wahl ist der Fallback,
        // falls die FW das `display`-Feld nicht liefert (alte FW < 2.10.1).
        DeviceRegistry.shared.updateCurrent { profile in
            profile.displayVariant = variant
        }

        let proceed: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.monitor.serialPort.stopScanning()
            fw.flashFirmware(port: port) { [weak self] success, message in
                DispatchQueue.main.async {
                    self?.monitor.serialPort.startScanning()
                    self?.alert(title: success ? S().flashSuccess : S().flashFailed,
                                info: message,
                                style: success ? .informational : .critical)
                }
            }
        }

        // Variantenspezifischer Cache-Check + Download falls noetig.
        if let release = fw.latestRelease,
           fw.checkCachedBin(version: release.tag_name, variant: variant) {
            proceed(); return
        }

        fw.downloadFirmware(variant: variant) { [weak self] success, error in
            DispatchQueue.main.async {
                if success { proceed() }
                else { self?.alert(title: S().downloadFailed,
                                   info: error ?? "Unknown error",
                                   style: .warning) }
            }
        }
    }

    func runAppUpdateCheck() {
        let appMgr = AppUpdateManager.shared
        if appMgr.hasUpdate { downloadAppUpdate(); return }
        appMgr.checkForUpdate { [weak self] hasUpdate in
            DispatchQueue.main.async {
                if hasUpdate { self?.showAppUpdateAlert() }
                else {
                    self?.alert(title: S().noUpdateAvailable,
                                info: "AI Monitor v\(kAppVersion) \(S().appIsCurrentSuffix)",
                                style: .informational)
                }
            }
        }
    }

    func showAppUpdateAlert() {
        let appMgr = AppUpdateManager.shared
        guard appMgr.hasUpdate else { return }
        let alert = NSAlert()
        alert.messageText = S().appUpdateAvailable
        var info = "\(appMgr.latestVersionDisplay) \(S().firmwareAvailable)\nInstalled: v\(kAppVersion)"
        if let body = appMgr.latestRelease?.body, !body.isEmpty {
            let plain = body
                .replacingOccurrences(of: "## ", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "- ", with: "• ")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let truncated = plain.count > 300 ? String(plain.prefix(300)) + "…" : plain
            info += "\n\n\(truncated)"
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        let hasAsset = appMgr.latestRelease?.assets.contains { $0.name == kAppAssetName } ?? false
        alert.addButton(withTitle: hasAsset ? S().download : S().openInBrowser)
        alert.addButton(withTitle: S().later)
        alert.addButton(withTitle: S().skipVersion)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: downloadAppUpdate()
        case .alertThirdButtonReturn:
            if let tag = appMgr.latestRelease?.tag_name { Settings.shared.skippedAppVersion = tag }
        default: break
        }
    }

    func downloadAppUpdate() {
        let appMgr = AppUpdateManager.shared
        let hasAsset = appMgr.latestRelease?.assets.contains { $0.name == kAppAssetName } ?? false
        if !hasAsset { appMgr.openReleasePage(); return }
        appMgr.downloadAndInstall { [weak self] success, extractedPathOrError in
            DispatchQueue.main.async {
                guard success else {
                    self?.alert(title: S().updateFailed, info: extractedPathOrError, style: .critical); return
                }
                let alert = NSAlert()
                alert.messageText = String(format: S().installQuestion, appMgr.latestVersionDisplay)
                alert.informativeText = S().restartInfo
                alert.alertStyle = .informational
                alert.addButton(withTitle: S().install)
                alert.addButton(withTitle: S().later)
                if alert.runModal() == .alertFirstButtonReturn {
                    appMgr.performAutoUpdate(extractedAppPath: extractedPathOrError) { _, errorMessage in
                        DispatchQueue.main.async {
                            self?.alert(title: S().updateFailed, info: errorMessage, style: .critical)
                        }
                    }
                }
            }
        }
    }

    private func alert(title: String, info: String, style: NSAlert.Style) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

// ============================================================
// MARK: - App Entry Point
// ============================================================

let app = NSApplication.shared
// Accessory: kein Dock-Icon. LSUIElement in Info.plist ergänzt dies für den Launch.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
