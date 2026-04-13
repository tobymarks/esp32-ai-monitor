/**
 * AI Monitor v1.5.5 — macOS Menubar App for ESP32 AI Usage Monitor Display
 *
 * Reads Claude OAuth token from macOS Keychain,
 * polls the Claude Usage API, shows usage in menubar,
 * and sends data via USB-Serial to ESP32.
 *
 * Build: ./build.sh
 * Run:   open "build/AI Monitor.app"
 */

import Cocoa
import Security
import ServiceManagement
import Foundation

// POSIX for serial port
#if canImport(Darwin)
import Darwin
#endif

// ============================================================
// MARK: - Configuration
// ============================================================

let kAppVersion = "1.5.5"
let kCredentialsFilePath = NSString("~/.claude/.credentials.json").expandingTildeInPath
let kUsageEndpoint = "https://api.anthropic.com/api/oauth/usage"
let kOAuthBeta = "oauth-2025-04-20"
// Match Claude Code CLI user-agent to avoid aggressive rate-limiting on unknown agents
let kUserAgent: String = {
    // Try to detect installed Claude Code version
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["claude", "--version"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty {
            return "claude-code/\(version)"
        }
    } catch {}
    return "claude-code/2.1.0"  // fallback
}()
let kPollInterval: TimeInterval = 90
let kMinPollInterval: TimeInterval = 30
let kSerialBaudRate: speed_t = 115200
let kSerialScanInterval: TimeInterval = 3
let kUserDefaultsSuite = "de.aimonitor.app"
let kGitHubRepo = "tobymarks/esp32-ai-monitor"
let kGitHubReleasesAPI = "https://api.github.com/repos/tobymarks/esp32-ai-monitor/releases"
let kFirmwareAssetName = "ai-monitor.bin"
let kFirmwareCheckInterval: TimeInterval = 6 * 3600  // 6 hours
let kFlashBaudRate = 460800
let kAppAssetName = "AIMonitor.zip"
let kAppUpdateCheckInterval: TimeInterval = 24 * 3600  // 24 hours

// ============================================================
// MARK: - Localization
// ============================================================

struct Strings {
    // Menu items
    let sessionPrefix: String
    let weeklyPrefix: String
    let planPrefix: String
    let displayNotConnected: String
    let lastUpdate: String
    let refreshNow: String
    let firmware: String
    let flashFirmware: String
    let searchAppUpdates: String
    let launchAtLogin: String
    let about: String
    let quit: String

    // Status messages
    let tokenExpired: String
    let noToken: String
    let offline: String
    let serverError: String
    let noData: String
    let rateLimited: String
    let pleaseWait: String
    let rateLimitedRemaining: String

    // Display status
    let displayConnected: String

    // Firmware
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
    let flashing: String
    let downloading: String

    // App update
    let noUpdateAvailable: String
    let appUpdateAvailable: String
    let download: String
    let openInBrowser: String
    let later: String
    let skipVersion: String
    let updateFailed: String
    let install: String

    // Dynamic format strings
    let connectedFormat: String
    let firmwareCurrent: String
    let firmwareAvailable: String
    let remainingMinutes: String
    let errorPrefix: String

    // Language menu
    let language: String
    let german: String
    let english: String

    // Time formatting
    let timeAgoSeconds: String   // "vor %ds" / "%ds ago"
    let timeAgoMinutes: String   // "vor %dm" / "%dm ago"
    let timeNow: String          // "jetzt" / "now"
    let timeInDaysHours: String  // "in %dd %dh"
    let timeInHoursMinutes: String // "in %dh %dm"
    let timeInMinutes: String    // "in %dm"

    // Flash completion
    let flashSuccessMessage: String  // "Firmware erfolgreich geflasht!" / "Firmware flashed successfully!"
    let flashFailedPrefix: String    // "Flash fehlgeschlagen:" / "Flash failed:"

    // About
    let aboutInfoText: String

    // App update details
    let appIsCurrentSuffix: String   // "ist aktuell." / "is up to date."
    let installQuestion: String      // "Update auf %@ installieren?" / "Install update %@?"
    let restartInfo: String          // "Die App wird kurz neu gestartet." / "The app will restart briefly."
    let downloadRunning: String      // "Download läuft..." / "Downloading..."
    let updateDownload: String       // "Update herunterladen..." / "Download update..."
}

let stringsDE = Strings(
    sessionPrefix: "Session:",
    weeklyPrefix: "Weekly:",
    planPrefix: "Plan:",
    displayNotConnected: "Display: \u{25CB} Nicht verbunden",
    lastUpdate: "Letztes Update:",
    refreshNow: "Jetzt aktualisieren",
    firmware: "Firmware:",
    flashFirmware: "Firmware flashen...",
    searchAppUpdates: "Nach App-Updates suchen...",
    launchAtLogin: "Bei Login starten",
    about: "Über AI Monitor",
    quit: "Beenden",
    tokenExpired: "Token abgelaufen - Claude Code öffnen",
    noToken: "Kein Token gefunden — Claude Code starten",
    offline: "Offline",
    serverError: "Server-Fehler",
    noData: "Keine Daten",
    rateLimited: "Rate-limited",
    pleaseWait: "Bitte %ds warten",
    rateLimitedRemaining: "Rate-limited (%ds)",
    displayConnected: "Display: \u{25CF} Verbunden",
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
    flashing: "Flash läuft...",
    downloading: "Download...",
    noUpdateAvailable: "Kein Update verfügbar",
    appUpdateAvailable: "App-Update verfügbar",
    download: "Herunterladen",
    openInBrowser: "Im Browser öffnen",
    later: "Später",
    skipVersion: "Version überspringen",
    updateFailed: "Update fehlgeschlagen",
    install: "Installieren",
    connectedFormat: "Display: \u{25CF} Verbunden (%@)%@",
    firmwareCurrent: "(aktuell)",
    firmwareAvailable: "verfügbar",
    remainingMinutes: "Rate-limited (%dm verbleibend)",
    errorPrefix: "Fehler:",
    language: "Sprache",
    german: "Deutsch",
    english: "Englisch",
    timeAgoSeconds: "vor %ds",
    timeAgoMinutes: "vor %dm",
    timeNow: "jetzt",
    timeInDaysHours: "in %dd %dh",
    timeInHoursMinutes: "in %dh %dm",
    timeInMinutes: "in %dm",
    flashSuccessMessage: "Firmware erfolgreich geflasht!",
    flashFailedPrefix: "Flash fehlgeschlagen:",
    aboutInfoText: "macOS Menubar App für ESP32 AI Usage Monitor Display.\n\nLiest Claude OAuth Usage und sendet Daten per USB-Serial an das ESP32 Display.",
    appIsCurrentSuffix: "ist aktuell.",
    installQuestion: "Update auf %@ installieren?",
    restartInfo: "Die App wird kurz neu gestartet.",
    downloadRunning: "Download läuft...",
    updateDownload: "Update herunterladen..."
)

let stringsEN = Strings(
    sessionPrefix: "Session:",
    weeklyPrefix: "Weekly:",
    planPrefix: "Plan:",
    displayNotConnected: "Display: \u{25CB} Not connected",
    lastUpdate: "Last update:",
    refreshNow: "Refresh now",
    firmware: "Firmware:",
    flashFirmware: "Flash firmware...",
    searchAppUpdates: "Check for app updates...",
    launchAtLogin: "Launch at login",
    about: "About AI Monitor",
    quit: "Quit",
    tokenExpired: "Token expired - open Claude Code",
    noToken: "No token found — start Claude Code",
    offline: "Offline",
    serverError: "Server error",
    noData: "No data",
    rateLimited: "Rate-limited",
    pleaseWait: "Please wait %ds",
    rateLimitedRemaining: "Rate-limited (%ds)",
    displayConnected: "Display: \u{25CF} Connected",
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
    flashing: "Flashing...",
    downloading: "Download...",
    noUpdateAvailable: "No update available",
    appUpdateAvailable: "App update available",
    download: "Download",
    openInBrowser: "Open in browser",
    later: "Later",
    skipVersion: "Skip version",
    updateFailed: "Update failed",
    install: "Install",
    connectedFormat: "Display: \u{25CF} Connected (%@)%@",
    firmwareCurrent: "(current)",
    firmwareAvailable: "available",
    remainingMinutes: "Rate-limited (%dm remaining)",
    errorPrefix: "Error:",
    language: "Language",
    german: "German",
    english: "English",
    timeAgoSeconds: "%ds ago",
    timeAgoMinutes: "%dm ago",
    timeNow: "now",
    timeInDaysHours: "in %dd %dh",
    timeInHoursMinutes: "in %dh %dm",
    timeInMinutes: "in %dm",
    flashSuccessMessage: "Firmware flashed successfully!",
    flashFailedPrefix: "Flash failed:",
    aboutInfoText: "macOS Menubar App for ESP32 AI Usage Monitor Display.\n\nReads Claude OAuth Usage and sends data via USB-Serial to the ESP32 display.",
    appIsCurrentSuffix: "is up to date.",
    installQuestion: "Install update %@?",
    restartInfo: "The app will restart briefly.",
    downloadRunning: "Downloading...",
    updateDownload: "Download update..."
)

func S() -> Strings {
    return Settings.shared.language == "en" ? stringsEN : stringsDE
}

// ============================================================
// MARK: - Usage Data Model
// ============================================================

struct UsageResponse: Codable {
    let five_hour: UsageBucket?
    let seven_day: UsageBucket?
    let extra_usage: ExtraUsage?
}

struct UsageBucket: Codable {
    let utilization: Double
    let resets_at: String?
}

struct ExtraUsage: Codable {
    let is_enabled: Bool?
    let monthly_limit: Double?
    let used_credits: Double?
    let utilization: Double?
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

    /// Persisted rate-limit state — survives app restarts
    var rateLimitUntil: Date? {
        get { defaults.object(forKey: "rateLimitUntil") as? Date }
        set { defaults.set(newValue, forKey: "rateLimitUntil") }
    }

    var rateLimitConsecutive: Int {
        get { defaults.integer(forKey: "rateLimitConsecutive") }
        set { defaults.set(newValue, forKey: "rateLimitConsecutive") }
    }

    var lastPollDate: Date? {
        get { defaults.object(forKey: "lastPollDate") as? Date }
        set { defaults.set(newValue, forKey: "lastPollDate") }
    }

    /// Currently installed/flashed firmware version (tag name from GitHub)
    var installedFirmwareVersion: String? {
        get { defaults.string(forKey: "installedFirmwareVersion") }
        set { defaults.set(newValue, forKey: "installedFirmwareVersion") }
    }

    /// Last firmware check timestamp
    var lastFirmwareCheck: Date? {
        get { defaults.object(forKey: "lastFirmwareCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastFirmwareCheck") }
    }

    /// Last app update check timestamp
    var lastAppUpdateCheck: Date? {
        get { defaults.object(forKey: "lastAppUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastAppUpdateCheck") }
    }

    /// App version the user chose to skip
    var skippedAppVersion: String? {
        get { defaults.string(forKey: "skippedAppVersion") }
        set { defaults.set(newValue, forKey: "skippedAppVersion") }
    }

    /// UI language ("de" or "en"), default "de"
    var language: String {
        get { defaults.string(forKey: "language") ?? "de" }
        set { defaults.set(newValue, forKey: "language") }
    }

    private init() {
        defaults = UserDefaults(suiteName: kUserDefaultsSuite) ?? UserDefaults.standard
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                NSLog("[Settings] SMAppService error: %@", error.localizedDescription)
            }
        }
    }
}

// ============================================================
// MARK: - Keychain Reader
// ============================================================

class KeychainReader {
    private static let ownService = "de.aimonitor.token"
    private static let claudeService = "Claude Code-credentials"

    /// Read OAuth token: own keychain cache → Claude Code keychain → claude CLI
    static func readAccessToken() -> String? {
        // 1. Eigener Keychain-Eintrag (kein Passwort-Dialog)
        if let token = readFromOwnKeychain() {
            return token
        }

        // 2. Claude Code Keychain lesen (löst einmalig Passwort-Dialog aus)
        if let token = readFromClaudeKeychain() {
            NSLog("[Auth] Token aus Claude Code Keychain gelesen, speichere in eigenem Eintrag")
            saveToOwnKeychain(token)
            return token
        }

        // 3. Credentials-Datei als Fallback
        if let token = readFromFile() {
            saveToOwnKeychain(token)
            return token
        }

        // 4. claude CLI als letzter Fallback
        if let token = readFromCLI() {
            saveToOwnKeychain(token)
            return token
        }

        NSLog("[Auth] Kein Token gefunden")
        return nil
    }

    // MARK: - Own Keychain (no password prompt)

    private static func readFromOwnKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func saveToOwnKeychain(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }
        // Alten Eintrag löschen falls vorhanden
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Neuen Eintrag anlegen
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: "oauth-token",
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            NSLog("[Auth] Token im eigenen Keychain gespeichert")
        } else {
            NSLog("[Auth] Keychain-Speichern fehlgeschlagen: %d", status)
        }
    }

    /// Eigenen gecachten Token löschen (bei 401 / Token-Refresh)
    static func clearCachedToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService
        ]
        SecItemDelete(query as CFDictionary)
        NSLog("[Auth] Gecachter Token gelöscht")
    }

    // MARK: - Claude Code Keychain (triggers password prompt once)

    private static func readFromClaudeKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                NSLog("[Auth] Kein Eintrag für '%@' im Keychain", claudeService)
            } else if status != errSecSuccess {
                NSLog("[Auth] Keychain-Fehler: %d", status)
            }
            return nil
        }
        return extractToken(from: data)
    }

    // MARK: - Credentials File

    private static func readFromFile() -> String? {
        guard let data = FileManager.default.contents(atPath: kCredentialsFilePath) else {
            return nil
        }
        return extractToken(from: data)
    }

    private static func extractToken(from data: Data) -> String? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let oauth = json["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String, !token.isEmpty {
                return token
            }
            if let token = json["accessToken"] as? String, !token.isEmpty {
                return token
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Claude CLI

    private static func readFromCLI() -> String? {
        NSLog("[Auth] Versuche Token über claude CLI")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        process.arguments = ["--print-access-token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty == false) ? token : nil
        } catch {
            NSLog("[Auth] CLI-Fehler: %@", error.localizedDescription)
            return nil
        }
    }

    /// Attempt token refresh — clears cache and re-reads
    static func refreshToken() -> Bool {
        clearCachedToken()
        // claude CLI holt neuen Token
        if let token = readFromCLI() {
            saveToOwnKeychain(token)
            return true
        }
        // Fallback: Claude Code Keychain neu lesen
        if let token = readFromClaudeKeychain() {
            saveToOwnKeychain(token)
            return true
        }
        return false
    }
}

// ============================================================
// MARK: - Claude Usage API
// ============================================================

class ClaudeAPI {
    /// Retry-After until date — persisted across restarts via Settings
    static var retryAfterUntil: Date? {
        get { Settings.shared.rateLimitUntil }
        set { Settings.shared.rateLimitUntil = newValue }
    }
    /// Whether a token refresh has been attempted for this cycle
    static var tokenRefreshAttempted = false
    /// Consecutive 429 count — persisted across restarts via Settings
    static var consecutive429Count: Int {
        get { Settings.shared.rateLimitConsecutive }
        set { Settings.shared.rateLimitConsecutive = newValue }
    }

    // Exponential backoff constants
    static let kBackoffBase: Double = 60       // first 429 → wait 60s
    static let kBackoffMultiplier: Double = 2  // double each consecutive 429
    static let kBackoffMax: Double = 600       // cap at 10 minutes
    static let kBackoffJitter: Double = 0.25   // ±25% randomization

    static var rateLimitRemaining: Int {
        guard let until = retryAfterUntil else { return 0 }
        let remaining = Int(until.timeIntervalSinceNow)
        return max(0, remaining)
    }

    static var isRateLimited: Bool {
        guard let until = retryAfterUntil else { return false }
        return Date() < until
    }

    /// Calculate backoff with exponential increase and jitter
    static func calculateBackoff(consecutive: Int, serverRetryAfter: Int) -> Int {
        // If server gives a meaningful Retry-After, respect it
        if serverRetryAfter > 0 {
            let jitter = Double.random(in: -kBackoffJitter...kBackoffJitter)
            return Int(Double(serverRetryAfter) * (1.0 + jitter))
        }
        // Exponential backoff: base * 2^(n-1), capped at max
        let exponent = Double(max(0, consecutive - 1))
        let delay = min(kBackoffBase * pow(kBackoffMultiplier, exponent), kBackoffMax)
        // Add jitter (±25%) to desynchronize from other clients
        let jitter = Double.random(in: -kBackoffJitter...kBackoffJitter)
        let finalDelay = delay * (1.0 + jitter)
        return Int(max(finalDelay, kBackoffBase * 0.75))  // never less than 45s
    }

    static func fetchUsage(token: String, completion: @escaping (UsageResponse?, Int?, Error?) -> Void) {
        // Respect Retry-After from previous 429
        if let until = retryAfterUntil {
            if Date() < until {
                let remaining = Int(until.timeIntervalSinceNow)
                NSLog("[API] Rate-limit cooldown: %d sec remaining (attempt #%d)", remaining, consecutive429Count)
                completion(nil, 429, NSError(domain: "API", code: 429,
                    userInfo: [NSLocalizedDescriptionKey: "Rate-limited (\(remaining)s)"]))
                return
            } else {
                // Cooldown expired — proceed with real request
                retryAfterUntil = nil
                NSLog("[API] Rate-limit cooldown expired, retrying (attempt #%d)", consecutive429Count + 1)
            }
        }

        guard let url = URL(string: kUsageEndpoint) else {
            completion(nil, nil, NSError(domain: "API", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(kOAuthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue(kUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, nil, error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, nil, NSError(domain: "API", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No HTTP response"]))
                return
            }

            let statusCode = httpResponse.statusCode

            if statusCode == 429 {
                consecutive429Count += 1
                let headerVal = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Int($0) } ?? 0
                let backoff = calculateBackoff(consecutive: consecutive429Count, serverRetryAfter: headerVal)
                retryAfterUntil = Date().addingTimeInterval(TimeInterval(backoff))
                NSLog("[API] 429 Rate Limited (#%d) - backing off %d sec (header: %d, base: %.0f)",
                      consecutive429Count, backoff, headerVal,
                      min(kBackoffBase * pow(kBackoffMultiplier, Double(max(0, consecutive429Count - 1))), kBackoffMax))
                completion(nil, 429, NSError(domain: "API", code: 429,
                    userInfo: [NSLocalizedDescriptionKey: "Rate limited (\(backoff)s)"]))
                return
            }

            guard statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                NSLog("[API] HTTP %d: %@", statusCode, body)
                completion(nil, statusCode, NSError(domain: "API", code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(statusCode)"]))
                return
            }

            // Clear rate-limit on success
            retryAfterUntil = nil
            tokenRefreshAttempted = false
            if consecutive429Count > 0 {
                NSLog("[API] Success after %d consecutive 429s - backoff reset", consecutive429Count)
            }
            consecutive429Count = 0

            guard let data = data else {
                completion(nil, statusCode, NSError(domain: "API", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "No data"]))
                return
            }

            do {
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                completion(usage, 200, nil)
            } catch {
                NSLog("[API] Decode error: %@", error.localizedDescription)
                completion(nil, statusCode, error)
            }
        }.resume()
    }

}

// ============================================================
// MARK: - Firmware Manager
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

    /// Whether an app update is available (newer version on GitHub)
    var hasUpdate: Bool {
        guard let release = latestRelease else { return false }
        let latest = normalizeVersion(release.tag_name)
        let current = normalizeVersion(kAppVersion)
        return compareVersions(latest, current) == .orderedDescending
    }

    /// Display string for the latest version
    var latestVersionDisplay: String {
        guard let release = latestRelease else { return "unbekannt" }
        return release.tag_name.hasPrefix("v") ? release.tag_name : "v\(release.tag_name)"
    }

    /// Check GitHub for the latest app release
    /// We look for releases with a tag starting with "app-v" or a .zip asset named AIMonitor.zip
    func checkForUpdate(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: kGitHubReleasesAPI) else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("[AppUpdate] GitHub API error: %@", error.localizedDescription)
                completion(false)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("[AppUpdate] GitHub API HTTP %d", status)
                completion(false)
                return
            }

            guard let data = data else {
                completion(false)
                return
            }

            do {
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

                // Find latest release with "app-v" tag prefix (firmware uses plain "v" prefix)
                let appRelease = releases.first { release in
                    release.tag_name.hasPrefix("app-v")
                }

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
                    NSLog("[AppUpdate] No suitable app release found in %d releases", releases.count)
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

    /// Download the app update ZIP, extract, and open in Finder
    func downloadAndInstall(completion: @escaping (Bool, String) -> Void) {
        guard let release = latestRelease else {
            completion(false, "Kein Release gefunden")
            return
        }

        guard let asset = release.assets.first(where: { $0.name == kAppAssetName }) else {
            // No direct asset — open the release page in browser instead
            if let htmlUrl = release.html_url, let url = URL(string: htmlUrl) {
                NSWorkspace.shared.open(url)
                completion(true, S().openInBrowser)
            } else {
                let repoUrl = "https://github.com/\(kGitHubRepo)/releases/tag/\(release.tag_name)"
                if let url = URL(string: repoUrl) {
                    NSWorkspace.shared.open(url)
                }
                completion(true, S().openInBrowser)
            }
            return
        }

        guard let downloadUrl = URL(string: asset.browser_download_url) else {
            completion(false, "Invalid download URL")
            return
        }

        isDownloading = true
        DispatchQueue.main.async { self.onUpdate?() }

        let task = URLSession.shared.downloadTask(with: downloadUrl) { [weak self] tempUrl, response, error in
            guard let self = self else { return }
            self.isDownloading = false

            if let error = error {
                NSLog("[AppUpdate] Download error: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.onUpdate?()
                    completion(false, "Download fehlgeschlagen: \(error.localizedDescription)")
                }
                return
            }

            guard let tempUrl = tempUrl else {
                DispatchQueue.main.async {
                    self.onUpdate?()
                    completion(false, S().downloadFailed)
                }
                return
            }

            // Move to a persistent temp location
            let downloadDir = NSTemporaryDirectory() + "AIMonitor-Update"
            let zipPath = downloadDir + "/\(kAppAssetName)"
            let fm = FileManager.default

            do {
                // Clean up old downloads
                if fm.fileExists(atPath: downloadDir) {
                    try fm.removeItem(atPath: downloadDir)
                }
                try fm.createDirectory(atPath: downloadDir, withIntermediateDirectories: true)
                try fm.moveItem(at: tempUrl, to: URL(fileURLWithPath: zipPath))

                // Unzip using ditto (macOS built-in, handles .zip properly)
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

                // Find the .app in the extracted directory
                let contents = try fm.contentsOfDirectory(atPath: downloadDir)
                if let appName = contents.first(where: { $0.hasSuffix(".app") }) {
                    let extractedAppPath = downloadDir + "/\(appName)"

                    NSLog("[AppUpdate] Downloaded and extracted to: %@", extractedAppPath)
                    DispatchQueue.main.async {
                        self.onUpdate?()
                        completion(true, extractedAppPath)
                    }
                } else {
                    // No .app found, just reveal the folder
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: downloadDir)
                    DispatchQueue.main.async {
                        self.onUpdate?()
                        completion(false, "Keine .app im Download gefunden")
                    }
                }
            } catch {
                NSLog("[AppUpdate] File operation error: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.onUpdate?()
                    completion(false, "\(S().errorPrefix) \(error.localizedDescription)")
                }
            }
        }
        task.resume()
    }

    /// Open the GitHub releases page in browser
    func openReleasePage() {
        let urlStr: String
        if let release = latestRelease, let htmlUrl = release.html_url {
            urlStr = htmlUrl
        } else {
            urlStr = "https://github.com/\(kGitHubRepo)/releases"
        }
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Perform auto-update: write a shell script that replaces the running app, then launch it and quit
    /// - Parameters:
    ///   - extractedAppPath: Path to the newly downloaded .app in temp dir
    ///   - completion: Called with (success, errorMessage) — only called on failure; on success the app terminates
    func performAutoUpdate(extractedAppPath: String, completion: @escaping (Bool, String) -> Void) {
        let currentAppPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptPath = NSTemporaryDirectory() + "aimonitor-update.sh"

        // Safety check: make sure the current app path looks valid
        guard currentAppPath.hasSuffix(".app") else {
            completion(false, "App-Pfad ungültig: \(currentAppPath)")
            return
        }

        // Safety check: make sure the extracted app exists
        guard FileManager.default.fileExists(atPath: extractedAppPath) else {
            completion(false, "Heruntergeladene App nicht gefunden: \(extractedAppPath)")
            return
        }

        let script = """
        #!/bin/bash
        # AI Monitor Auto-Update Script
        # Wartet bis die alte App beendet ist, ersetzt sie, startet neu

        CURRENT_PID=\(pid)
        NEW_APP="\(extractedAppPath)"
        OLD_APP="\(currentAppPath)"

        # Warten bis der aktuelle Prozess beendet ist (max 30 Sekunden)
        WAITED=0
        while kill -0 "$CURRENT_PID" 2>/dev/null; do
            sleep 0.5
            WAITED=$((WAITED + 1))
            if [ "$WAITED" -ge 60 ]; then
                echo "Timeout: App hat sich nicht beendet" >&2
                exit 1
            fi
        done

        # Kurz warten damit alle Dateien freigegeben sind
        sleep 1

        # Alte App entfernen und neue kopieren
        rm -rf "$OLD_APP"
        cp -R "$NEW_APP" "$OLD_APP"

        if [ $? -ne 0 ]; then
            echo "Fehler beim Kopieren der neuen App" >&2
            exit 1
        fi

        # Gatekeeper Quarantine-Attribute entfernen
        xattr -cr "$OLD_APP" 2>/dev/null

        # Neue App starten
        open "$OLD_APP"

        # Temp-Dateien aufraeumen
        rm -rf "$(dirname "$NEW_APP")"
        rm -f "\(scriptPath)"
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

            // Make script executable
            let chmodProcess = Process()
            chmodProcess.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmodProcess.arguments = ["+x", scriptPath]
            try chmodProcess.run()
            chmodProcess.waitUntilExit()

            // Launch the script as a detached process
            let updateProcess = Process()
            updateProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
            updateProcess.arguments = [scriptPath]
            updateProcess.standardOutput = FileHandle.nullDevice
            updateProcess.standardError = FileHandle.nullDevice
            // QualityOfService: detach from parent process
            updateProcess.qualityOfService = .utility
            try updateProcess.run()

            NSLog("[AppUpdate] Update-Script gestartet (PID %d), beende App...", updateProcess.processIdentifier)

            // Terminate the app — the shell script will handle the rest
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            NSLog("[AppUpdate] Fehler beim Erstellen/Starten des Update-Scripts: %@", error.localizedDescription)
            completion(false, "Update script failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Version Comparison Helpers

    /// Strip "v", "app-v", or "app-" prefix from version string
    private func normalizeVersion(_ version: String) -> String {
        var v = version
        if v.hasPrefix("app-v") { v = String(v.dropFirst(5)) }
        else if v.hasPrefix("app-") { v = String(v.dropFirst(4)) }
        else if v.hasPrefix("v") { v = String(v.dropFirst(1)) }
        return v
    }

    /// Compare semver strings (e.g. "1.2.0" vs "1.1.0")
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

class FirmwareManager {
    static let shared = FirmwareManager()

    var latestRelease: GitHubRelease?
    var downloadedBinPath: String?
    var isDownloading = false
    var isFlashing = false
    var downloadProgress: Double = 0
    var flashProgress: String = ""
    var onUpdate: (() -> Void)?

    /// Directory for downloaded firmware files
    private var firmwareDir: String {
        let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
        return (appSupport as NSString).appendingPathComponent("AI Monitor/firmware")
    }

    /// Check if a firmware binary is already downloaded for the given version
    func localBinPath(for version: String) -> String {
        return (firmwareDir as NSString).appendingPathComponent("ai-monitor-\(version).bin")
    }

    /// Resolve esptool path — tries bundled resource first, then PlatformIO, then system pip
    /// Returns (python3_path, esptool_mode) where esptool_mode is:
    ///   - "module" → use python3 -m esptool
    ///   - "bundled:/path" → use python3 /path/esptool.py (with PYTHONPATH set)
    ///   - "platformio:/path" → use python3 /path/esptool.py
    func resolveEsptool() -> (python: String, mode: String)? {
        guard let python = findPython3() else {
            NSLog("[Firmware] No python3 found")
            return nil
        }

        // 1. Bundled esptool package in app Resources
        if let resourcePath = Bundle.main.resourcePath {
            let bundledDir = (resourcePath as NSString).appendingPathComponent("esptool-pkg")
            let bundledScript = (bundledDir as NSString).appendingPathComponent("esptool.py")
            if FileManager.default.fileExists(atPath: bundledScript) {
                NSLog("[Firmware] Using bundled esptool: %@", bundledScript)
                return (python: python, mode: "bundled:\(bundledDir)")
            }
        }

        // 2. PlatformIO esptool.py (uses its own _contrib for deps)
        let platformioScript = NSString("~/.platformio/packages/tool-esptoolpy/esptool.py").expandingTildeInPath
        if FileManager.default.fileExists(atPath: platformioScript) {
            NSLog("[Firmware] Using PlatformIO esptool: %@", platformioScript)
            return (python: python, mode: "platformio:\(platformioScript)")
        }

        // 3. System esptool via python3 -m esptool (pip installed)
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: python)
        checkProcess.arguments = ["-m", "esptool", "version"]
        checkProcess.standardOutput = Pipe()
        checkProcess.standardError = Pipe()
        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()
            if checkProcess.terminationStatus == 0 {
                NSLog("[Firmware] Using system esptool (pip)")
                return (python: python, mode: "module")
            }
        } catch {}

        NSLog("[Firmware] No esptool found")
        return nil
    }

    /// Find python3 binary
    private func findPython3() -> String? {
        let candidates = [
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Check GitHub for latest release
    func checkForUpdate(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: kGitHubReleasesAPI) else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("[Firmware] GitHub API error: %@", error.localizedDescription)
                completion(false)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                NSLog("[Firmware] GitHub API HTTP %d", status)
                completion(false)
                return
            }

            guard let data = data else {
                completion(false)
                return
            }

            do {
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

                // Only consider firmware releases: tags like "v2.0.0" but NOT "app-v1.1.0"
                let firmwareRelease = releases.first { release in
                    release.tag_name.hasPrefix("v") && !release.tag_name.hasPrefix("app-")
                }

                guard let release = firmwareRelease else {
                    NSLog("[Firmware] No firmware release found in %d releases", releases.count)
                    Settings.shared.lastFirmwareCheck = Date()
                    DispatchQueue.main.async { self.onUpdate?() }
                    completion(false)
                    return
                }

                self.latestRelease = release
                Settings.shared.lastFirmwareCheck = Date()

                let installed = Settings.shared.installedFirmwareVersion ?? "unbekannt"
                let hasUpdate = (release.tag_name != installed)

                // Check if binary is already downloaded
                let binPath = self.localBinPath(for: release.tag_name)
                if FileManager.default.fileExists(atPath: binPath) {
                    self.downloadedBinPath = binPath
                }

                NSLog("[Firmware] Latest: %@ | Installed: %@ | Update: %@",
                      release.tag_name, installed, hasUpdate ? "YES" : "no")

                DispatchQueue.main.async { self.onUpdate?() }
                completion(hasUpdate)
            } catch {
                NSLog("[Firmware] JSON decode error: %@", error.localizedDescription)
                completion(false)
            }
        }.resume()
    }

    /// Download firmware binary from GitHub release
    func downloadFirmware(completion: @escaping (Bool, String?) -> Void) {
        guard let release = latestRelease else {
            completion(false, S().noReleaseFound)
            return
        }

        guard let asset = release.assets.first(where: { $0.name == kFirmwareAssetName }) else {
            completion(false, "No \(kFirmwareAssetName) in release \(release.tag_name)")
            return
        }

        guard let url = URL(string: asset.browser_download_url) else {
            completion(false, "Invalid download URL")
            return
        }

        // Create firmware directory
        do {
            try FileManager.default.createDirectory(atPath: firmwareDir, withIntermediateDirectories: true)
        } catch {
            completion(false, "Cannot create firmware directory: \(error.localizedDescription)")
            return
        }

        let destPath = localBinPath(for: release.tag_name)

        // Already downloaded?
        if FileManager.default.fileExists(atPath: destPath) {
            downloadedBinPath = destPath
            NSLog("[Firmware] Already downloaded: %@", destPath)
            completion(true, nil)
            return
        }

        isDownloading = true
        downloadProgress = 0
        DispatchQueue.main.async { self.onUpdate?() }

        NSLog("[Firmware] Downloading %@ (%d bytes)...", asset.name, asset.size)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            self.isDownloading = false

            if let error = error {
                NSLog("[Firmware] Download error: %@", error.localizedDescription)
                DispatchQueue.main.async { self.onUpdate?() }
                completion(false, error.localizedDescription)
                return
            }

            guard let tempURL = tempURL else {
                DispatchQueue.main.async { self.onUpdate?() }
                completion(false, S().downloadFailed)
                return
            }

            do {
                // Remove old file if exists
                if FileManager.default.fileExists(atPath: destPath) {
                    try FileManager.default.removeItem(atPath: destPath)
                }
                try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: destPath))
                self.downloadedBinPath = destPath
                self.downloadProgress = 1.0
                NSLog("[Firmware] Downloaded to %@", destPath)
                DispatchQueue.main.async { self.onUpdate?() }
                completion(true, nil)
            } catch {
                NSLog("[Firmware] File move error: %@", error.localizedDescription)
                DispatchQueue.main.async { self.onUpdate?() }
                completion(false, error.localizedDescription)
            }
        }
        task.resume()
    }

    /// Flash firmware to ESP32 via esptool
    func flashFirmware(port: String, completion: @escaping (Bool, String) -> Void) {
        guard let binPath = downloadedBinPath, FileManager.default.fileExists(atPath: binPath) else {
            completion(false, "Keine Firmware-Datei vorhanden")
            return
        }

        guard let tool = resolveEsptool() else {
            completion(false, "esptool nicht gefunden.\nInstalliere mit: pip3 install esptool")
            return
        }

        isFlashing = true
        flashProgress = S().preparing
        DispatchQueue.main.async { self.onUpdate?() }

        // Serial already disconnected by stopScanning() before this call
        // Small delay to ensure port is released by OS
        usleep(500_000)  // 500ms

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
                // python3 -m esptool ...
                process.arguments = ["-m", "esptool"] + esptoolArgs
            } else if tool.mode.hasPrefix("bundled:") {
                // python3 esptool.py ... with PYTHONPATH including _contrib
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
                // python3 /path/to/esptool.py ...
                let scriptPath = String(tool.mode.dropFirst("platformio:".count))
                process.arguments = [scriptPath] + esptoolArgs
            }

            process.standardOutput = outputPipe
            process.standardError = errorPipe

            // Read output for progress
            var outputText = ""
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    outputText += str
                    // Parse progress from esptool output (e.g., "Writing at 0x00010000... (5 %)")
                    if let range = str.range(of: #"\((\d+)\s*%\)"#, options: .regularExpression) {
                        let percentStr = str[range].replacingOccurrences(of: "(", with: "")
                            .replacingOccurrences(of: "%)", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        DispatchQueue.main.async {
                            self.flashProgress = "Flashing... \(percentStr)%"
                            self.onUpdate?()
                        }
                    }
                }
            }

            var errorText = ""
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    errorText += str
                }
            }

            do {
                NSLog("[Firmware] Starting flash: %@ on %@", binPath, port)
                DispatchQueue.main.async {
                    self.flashProgress = "Flashing..."
                    self.onUpdate?()
                }

                try process.run()
                process.waitUntilExit()

                // Clean up handlers
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                let exitCode = process.terminationStatus
                NSLog("[Firmware] esptool exited with code %d", exitCode)

                if exitCode == 0 {
                    // Save installed version
                    if let release = self.latestRelease {
                        Settings.shared.installedFirmwareVersion = release.tag_name
                    }

                    DispatchQueue.main.async {
                        self.isFlashing = false
                        self.flashProgress = ""
                        self.onUpdate?()
                    }

                    NSLog("[Firmware] Flash successful")
                    completion(true, S().flashSuccessMessage)
                } else {
                    let combinedOutput = outputText + "\n" + errorText
                    NSLog("[Firmware] Flash failed:\n%@", combinedOutput)

                    DispatchQueue.main.async {
                        self.isFlashing = false
                        self.flashProgress = ""
                        self.onUpdate?()
                    }

                    let shortError = errorText.isEmpty ? "esptool Exit-Code \(exitCode)" :
                        errorText.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? errorText
                    completion(false, "\(S().flashFailedPrefix) \(shortError)")
                }
            } catch {
                NSLog("[Firmware] Failed to start esptool: %@", error.localizedDescription)

                DispatchQueue.main.async {
                    self.isFlashing = false
                    self.flashProgress = ""
                    self.onUpdate?()
                }

                completion(false, "esptool konnte nicht gestartet werden: \(error.localizedDescription)")
            }
        }
    }

    /// Whether a new firmware version is available
    var hasUpdate: Bool {
        guard let release = latestRelease else { return false }
        let installed = Settings.shared.installedFirmwareVersion
        return release.tag_name != installed
    }

    /// Version string for display
    var installedVersionDisplay: String {
        return Settings.shared.installedFirmwareVersion ?? "unbekannt"
    }

    var latestVersionDisplay: String {
        return latestRelease?.tag_name ?? "?"
    }

    /// Whether flashing is possible right now
    func canFlash(serialConnected: Bool) -> Bool {
        return !isFlashing && !isDownloading && serialConnected && downloadedBinPath != nil
    }
}

// ============================================================
// MARK: - Serial Port Manager
// ============================================================

class SerialPortManager {
    private var fileDescriptor: Int32 = -1
    private(set) var connectedPort: String?
    private var scanTimer: Timer?
    var onConnect: (() -> Void)?

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

    func scanForPort() {
        // If already connected, check if port still exists
        if let port = connectedPort {
            if !FileManager.default.fileExists(atPath: port) {
                NSLog("[Serial] Port %@ disappeared, reconnecting...", port)
                disconnect()
            } else {
                return // Still connected
            }
        }

        // Find USB serial ports
        let devPath = "/dev"
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: devPath)
            let serialPorts = files.filter { $0.hasPrefix("cu.usbserial-") }
                                   .map { "\(devPath)/\($0)" }

            if let port = serialPorts.first {
                connect(to: port)
            }
        } catch {
            NSLog("[Serial] Failed to scan /dev: %@", error.localizedDescription)
        }
    }

    private func connect(to port: String) {
        NSLog("[Serial] Connecting to %@...", port)

        // Open port with POSIX
        let fd = Darwin.open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            NSLog("[Serial] Failed to open %@: errno %d", port, errno)
            return
        }

        // Configure with termios
        var options = termios()
        tcgetattr(fd, &options)

        // Set baud rate (both directions)
        cfsetispeed(&options, kSerialBaudRate)
        cfsetospeed(&options, kSerialBaudRate)

        // 8N1, no flow control
        options.c_cflag &= ~tcflag_t(PARENB)  // No parity
        options.c_cflag &= ~tcflag_t(CSTOPB)  // 1 stop bit
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)       // 8 data bits
        options.c_cflag &= ~tcflag_t(CRTSCTS)  // No HW flow control
        options.c_cflag |= tcflag_t(CLOCAL)    // Ignore modem status

        // Raw mode
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_oflag &= ~tcflag_t(OPOST)

        tcsetattr(fd, TCSANOW, &options)

        // Clear NONBLOCK after setup
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)

        fileDescriptor = fd
        connectedPort = port
        NSLog("[Serial] Connected to %@ at 115200 baud", port)

        // Flush ESP32 serial buffer — after flash/reboot there may be
        // partial data in the buffer that would cause a JSON parse error
        let newline: [UInt8] = [0x0A]  // \n
        newline.withUnsafeBufferPointer { buf in
            _ = Darwin.write(fd, buf.baseAddress!, 1)
        }
        usleep(200_000)  // 200ms settle time

        // Query device info on background thread, THEN notify onConnect
        // (onConnect triggers poll() which also sends serial data — must not overlap)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.fileDescriptor >= 0 else { return }

            self.drainInput()

            let cmd = "{\"cmd\":\"get_info\"}\n"
            if let cmdData = cmd.data(using: .utf8) {
                let writeResult = cmdData.withUnsafeBytes { rawBuffer -> Int in
                    guard let ptr = rawBuffer.baseAddress else { return -1 }
                    return Darwin.write(self.fileDescriptor, ptr, rawBuffer.count)
                }
                NSLog("[Serial] Sent get_info (%d bytes)", writeResult)

                if writeResult > 0 {
                    // ESP32 may send debug log lines before the JSON response
                    // Read up to 5 lines, looking for the JSON info response
                    var found = false
                    for _ in 0..<5 {
                        guard let line = self.readLine(timeout: 2.0) else { break }
                        NSLog("[Serial] read: %@", line)

                        // Skip non-JSON lines (debug logs like "[Serial] Command received: ...")
                        guard line.hasPrefix("{") else { continue }

                        if let jsonData = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let type = json["type"] as? String, type == "info",
                           let version = json["version"] as? String {
                            self.deviceFirmwareVersion = version
                            Settings.shared.installedFirmwareVersion = "v\(version)"
                            NSLog("[Serial] ESP32 firmware: v%@", version)
                            found = true
                            break
                        }
                    }
                    if !found {
                        NSLog("[Serial] get_info: no JSON info response received")
                    }
                }
            }

            // Now notify — safe to send usage data
            DispatchQueue.main.async {
                self.onConnect?()
            }
        }
    }

    func disconnect() {
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        connectedPort = nil
    }

    func send(data: Data) -> Bool {
        guard fileDescriptor >= 0 else { return false }

        let result = data.withUnsafeBytes { rawBuffer -> Int in
            guard let ptr = rawBuffer.baseAddress else { return -1 }
            return Darwin.write(fileDescriptor, ptr, rawBuffer.count)
        }

        if result < 0 {
            NSLog("[Serial] Write failed: errno %d", errno)
            disconnect()
            return false
        }

        return true
    }

    func sendJSON(_ jsonString: String) -> Bool {
        guard let data = (jsonString + "\n").data(using: .utf8) else { return false }
        return send(data: data)
    }

    /// Read a line from serial (blocking, with timeout in seconds)
    /// Returns nil on timeout or error. Must be called from background thread.
    func readLine(timeout: TimeInterval = 2.0) -> String? {
        guard fileDescriptor >= 0 else { return nil }

        var buffer = [UInt8]()
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0

        while Date() < deadline {
            var pfd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pfd, 1, 100) // 100ms timeout

            if pollResult > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                let readResult = Darwin.read(fileDescriptor, &byte, 1)
                if readResult == 1 {
                    if byte == 0x0A { // newline
                        return String(bytes: buffer, encoding: .utf8)
                    }
                    if byte != 0x0D { // skip CR
                        buffer.append(byte)
                    }
                } else {
                    return nil
                }
            }
        }
        return nil
    }

    /// Drain any pending bytes from serial input
    private func drainInput() {
        var byte: UInt8 = 0
        while true {
            var pfd = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&pfd, 1, 10) > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                _ = Darwin.read(fileDescriptor, &byte, 1)
            } else {
                break
            }
        }
    }

    /// Query ESP32 device info (version, orientation, uptime, heap)
    /// Must be called from a background thread (readLine is blocking)
    var deviceFirmwareVersion: String?

    func queryDeviceInfo() {
        guard isConnected else { return }

        drainInput()

        guard sendJSON("{\"cmd\":\"get_info\"}") else {
            NSLog("[Serial] Failed to send get_info")
            return
        }

        guard let response = readLine(timeout: 2.0) else {
            NSLog("[Serial] No response to get_info")
            return
        }

        NSLog("[Serial] Device info: %@", response)

        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "info",
              let version = json["version"] as? String else {
            NSLog("[Serial] Failed to parse device info")
            return
        }

        deviceFirmwareVersion = version
        Settings.shared.installedFirmwareVersion = "v\(version)"
        NSLog("[Serial] ESP32 firmware version: %@", version)
    }
}

// ============================================================
// MARK: - Usage Monitor (Timer + Poll + Serial)
// ============================================================

class UsageMonitor {
    var serialPort: SerialPortManager
    var timer: Timer?
    var lastUsage: UsageResponse?
    var lastError: String?
    var lastUpdateDate: Date?
    var lastPollDate: Date?
    var status: MonitorStatus = .idle
    var onUpdate: (() -> Void)?

    enum MonitorStatus {
        case idle
        case ok
        case error
        case offline
        case rateLimited
        case tokenExpired
    }

    init() {
        self.serialPort = SerialPortManager()
    }

    func start() {
        // When a USB serial device connects, poll only if not rate-limited
        serialPort.onConnect = { [weak self] in
            // Firmware version already queried in connect() before this callback
            self?.onUpdate?()

            // Sync macOS appearance and language to ESP32 on connect
            self?.sendThemeToESP32()
            self?.sendLanguageToESP32()

            if !ClaudeAPI.isRateLimited {
                NSLog("[Monitor] Serial connected — triggering immediate poll")
                self?.poll()
            } else {
                NSLog("[Monitor] Serial connected — skipping poll (rate-limited, %ds remaining)", ClaudeAPI.rateLimitRemaining)
            }
        }
        serialPort.startScanning()

        // Check persisted state — don't poll if still in cooldown or polled recently
        if ClaudeAPI.isRateLimited {
            let remaining = ClaudeAPI.rateLimitRemaining
            NSLog("[Monitor] Resuming with active rate-limit cooldown: %ds remaining (#%d)", remaining, ClaudeAPI.consecutive429Count)
            status = .rateLimited
            lastError = String(format: S().rateLimitedRemaining, remaining)
        } else if let lastPoll = Settings.shared.lastPollDate,
                  Date().timeIntervalSince(lastPoll) < kPollInterval {
            let elapsed = Int(Date().timeIntervalSince(lastPoll))
            NSLog("[Monitor] Last poll was %ds ago — skipping initial poll", elapsed)
        } else {
            poll()
        }
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        serialPort.stopScanning()
    }

    func scheduleTimer() {
        timer?.invalidate()

        // Add jitter (0-15s) to avoid collision with other apps polling the same endpoint
        let jitter = Double.random(in: 0...15)
        let now = Date()
        let calendar = Calendar.current
        let seconds = calendar.component(.second, from: now)
        let fireDate = now.addingTimeInterval(TimeInterval(60 - seconds) + jitter)

        timer = Timer(fire: fireDate, interval: kPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.current.add(timer!, forMode: .common)
        NSLog("[Monitor] Next poll in %.0fs (incl. %.0fs jitter)", fireDate.timeIntervalSinceNow, jitter)
    }

    /// Manual refresh with minimum interval enforcement
    func manualRefresh() {
        if let lastPoll = lastPollDate {
            let elapsed = Date().timeIntervalSince(lastPoll)
            if elapsed < kMinPollInterval {
                let remaining = Int(kMinPollInterval - elapsed)
                NSLog("[Monitor] Manual refresh blocked - %d sec cooldown remaining", remaining)
                lastError = String(format: S().pleaseWait, remaining)
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }
        }
        poll()
    }

    func poll() {
        lastPollDate = Date()
        Settings.shared.lastPollDate = lastPollDate

        // 1. Read token
        guard let token = KeychainReader.readAccessToken() else {
            lastError = S().noToken
            status = .tokenExpired
            DispatchQueue.main.async { self.onUpdate?() }
            return
        }

        // 2. Fetch usage
        ClaudeAPI.fetchUsage(token: token) { [weak self] usage, statusCode, error in
            guard let self = self else { return }

            if let statusCode = statusCode, statusCode == 401 {
                // Token expired - try refresh once
                if !ClaudeAPI.tokenRefreshAttempted {
                    ClaudeAPI.tokenRefreshAttempted = true
                    NSLog("[Monitor] Token expired, attempting refresh...")
                    if KeychainReader.refreshToken() {
                        // Retry with new token
                        if let newToken = KeychainReader.readAccessToken() {
                            ClaudeAPI.fetchUsage(token: newToken) { [weak self] usage2, _, error2 in
                                guard let self = self else { return }
                                if let usage2 = usage2 {
                                    self.handleSuccess(usage: usage2)
                                } else {
                                    self.lastError = S().tokenExpired
                                    self.status = .tokenExpired
                                    DispatchQueue.main.async { self.onUpdate?() }
                                }
                            }
                            return
                        }
                    }
                    self.lastError = S().tokenExpired
                    self.status = .tokenExpired
                    DispatchQueue.main.async { self.onUpdate?() }
                    return
                } else {
                    self.lastError = S().tokenExpired
                    self.status = .tokenExpired
                    DispatchQueue.main.async { self.onUpdate?() }
                    return
                }
            }

            if let statusCode = statusCode, statusCode == 429 {
                self.status = .rateLimited
                self.lastError = String(format: S().rateLimitedRemaining, ClaudeAPI.rateLimitRemaining)
                // Still send cached data with current time to keep display clock alive
                self.resendCachedData()
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }

            if let error = error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain {
                    self.status = .offline
                    self.lastError = S().offline
                } else if let statusCode = statusCode, statusCode >= 500 {
                    self.status = .error
                    self.lastError = "\(S().serverError) (\(statusCode))"
                } else {
                    self.status = .error
                    self.lastError = error.localizedDescription
                }
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }

            guard let usage = usage else {
                self.lastError = S().noData
                self.status = .error
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }

            self.handleSuccess(usage: usage)
        }
    }

    private func handleSuccess(usage: UsageResponse) {
        lastUsage = usage
        lastError = nil
        lastUpdateDate = Date()
        status = .ok

        // Send to ESP32 via serial
        sendToESP32(usage: usage)

        DispatchQueue.main.async { self.onUpdate?() }
    }

    /// Re-send cached data with current time to keep display clock updated
    private func resendCachedData() {
        guard let usage = lastUsage else { return }
        sendToESP32(usage: usage)
    }

    // ---- Theme (Dark/Light Mode) ----

    func sendThemeToESP32() {
        guard serialPort.isConnected else { return }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = isDark ? "dark" : "light"
        let cmd = "{\"cmd\":\"set_theme\",\"value\":\"\(theme)\"}"
        if serialPort.sendJSON(cmd) {
            NSLog("[Serial] Sent set_theme: %@", theme)
        }
    }

    func sendLanguageToESP32() {
        guard serialPort.isConnected else { return }

        let lang = Settings.shared.language
        let cmd = "{\"cmd\":\"set_language\",\"value\":\"\(lang)\"}"
        if serialPort.sendJSON(cmd) {
            NSLog("[Serial] Sent set_language: %@", lang)
        }
    }

    private func sendToESP32(usage: UsageResponse) {
        guard serialPort.isConnected else { return }

        // API returns utilization as percentage (0-100)
        let primaryPercent = Int(round((usage.five_hour?.utilization ?? 0)))
        let secondaryPercent = Int(round((usage.seven_day?.utilization ?? 0)))
        let primaryResetsAt = usage.five_hour?.resets_at ?? ""
        let secondaryResetsAt = usage.seven_day?.resets_at ?? ""
        // API returns costs in cents, convert to dollars/euros
        let costUsed = (usage.extra_usage?.used_credits ?? 0) / 100.0
        let costLimit = (usage.extra_usage?.monthly_limit ?? 0) / 100.0

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let nowISO = isoFormatter.string(from: Date())

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let localTime = timeFmt.string(from: Date())

        // Build envelope JSON
        let envelope: [String: Any] = [
            "time": nowISO,
            "displayTime": localTime,
            "data": [
                [
                    "source": "oauth",
                    "usage": [
                        "primary": [
                            "usedPercent": primaryPercent,
                            "resetsAt": primaryResetsAt,
                            "windowMinutes": 300
                        ],
                        "secondary": [
                            "usedPercent": secondaryPercent,
                            "resetsAt": secondaryResetsAt,
                            "windowMinutes": 10080
                        ],
                        "providerCost": [
                            "used": costUsed,
                            "limit": costLimit
                        ],
                        "loginMethod": "Claude Max"
                    ],
                    "provider": "claude"
                ]
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: envelope)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                if serialPort.sendJSON(jsonString) {
                    NSLog("[Serial] Sent usage data (%d bytes)", jsonData.count)
                }
            }
        } catch {
            NSLog("[Serial] JSON encode error: %@", error.localizedDescription)
        }
    }
}

// ============================================================
// MARK: - App Delegate (Menubar)
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var monitor: UsageMonitor!
    var appearanceObservation: NSKeyValueObservation?

    // Menu item tags
    let kTagTitle = 10
    let kTagSession = 100
    let kTagWeekly = 101
    let kTagPlan = 102
    let kTagDisplay = 103
    let kTagLastUpdate = 104
    let kTagRefresh = 105
    let kTagFirmwareStatus = 200
    let kTagFirmwareFlash = 201
    let kTagAppUpdateStatus = 300
    let kTagAppUpdateAction = 301
    let kTagLaunchAtLogin = 400

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup menubar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenubarTitle(status: .idle, usage: nil)
        buildMenu()

        // Start monitor
        monitor = UsageMonitor()
        monitor.onUpdate = { [weak self] in
            self?.updateMenu()
        }
        monitor.start()

        // Setup firmware manager
        FirmwareManager.shared.onUpdate = { [weak self] in
            self?.updateMenu()
        }
        checkFirmwareUpdate()
        scheduleFirmwareCheckTimer()

        // Setup app update manager
        AppUpdateManager.shared.onUpdate = { [weak self] in
            self?.updateMenu()
        }
        checkAppUpdate()
        scheduleAppUpdateCheckTimer()

        // Observe macOS appearance changes (Dark/Light Mode) and sync to ESP32
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            NSLog("[App] macOS appearance changed — syncing theme to ESP32")
            self?.monitor.sendThemeToESP32()
        }

        NSLog("[App] AI Monitor v%@ started - polling every %.0fs", kAppVersion, kPollInterval)
    }

    // ---- Firmware Check Timer ----

    var firmwareCheckTimer: Timer?

    func scheduleFirmwareCheckTimer() {
        firmwareCheckTimer = Timer.scheduledTimer(withTimeInterval: kFirmwareCheckInterval, repeats: true) { [weak self] _ in
            self?.checkFirmwareUpdate()
        }
    }

    func checkFirmwareUpdate() {
        // Skip if checked recently (within interval)
        if let lastCheck = Settings.shared.lastFirmwareCheck,
           Date().timeIntervalSince(lastCheck) < kFirmwareCheckInterval {
            NSLog("[Firmware] Skipping check — last check %.0fm ago", Date().timeIntervalSince(lastCheck) / 60)
            // Still load cached release info
            FirmwareManager.shared.checkForUpdate { _ in }
            return
        }

        FirmwareManager.shared.checkForUpdate { hasUpdate in
            if hasUpdate {
                NSLog("[Firmware] Update available: %@", FirmwareManager.shared.latestVersionDisplay)
            }
        }
    }

    // ---- App Update Check Timer ----

    var appUpdateCheckTimer: Timer?

    func scheduleAppUpdateCheckTimer() {
        appUpdateCheckTimer = Timer.scheduledTimer(withTimeInterval: kAppUpdateCheckInterval, repeats: true) { [weak self] _ in
            self?.checkAppUpdate()
        }
    }

    func checkAppUpdate() {
        // Skip if checked recently (within interval)
        if let lastCheck = Settings.shared.lastAppUpdateCheck,
           Date().timeIntervalSince(lastCheck) < kAppUpdateCheckInterval {
            NSLog("[AppUpdate] Skipping check — last check %.0fm ago", Date().timeIntervalSince(lastCheck) / 60)
            return
        }

        AppUpdateManager.shared.checkForUpdate { hasUpdate in
            if hasUpdate {
                NSLog("[AppUpdate] Update available: %@", AppUpdateManager.shared.latestVersionDisplay)
            }
        }
    }

    // ---- Menubar Title ----

    func updateMenubarTitle(status: UsageMonitor.MonitorStatus, usage: UsageResponse?) {
        guard let button = statusItem.button else { return }

        // Load template icon from app bundle
        if button.image == nil {
            if let resourcePath = Bundle.main.resourcePath {
                let iconPath = (resourcePath as NSString).appendingPathComponent("MenuBarIconTemplate@2x.png")
                if let img = NSImage(contentsOfFile: iconPath) {
                    img.size = NSSize(width: 18, height: 18)
                    img.isTemplate = true
                    button.image = img
                    button.imagePosition = .imageLeft
                }
            }
        }

        // Show flashing status in menubar
        if FirmwareManager.shared.isFlashing {
            button.title = " \(FirmwareManager.shared.flashProgress)"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            return
        }

        if let usage = usage, status == .ok {
            let sp = Int(round((usage.five_hour?.utilization ?? 0)))
            button.title = " \(sp)%"
        } else {
            switch status {
            case .idle:         button.title = " --"
            case .error:        button.title = " !"
            case .offline:      button.title = " ~"
            case .rateLimited:  button.title = " ..."
            case .tokenExpired: button.title = " !"
            case .ok:           button.title = "AI --"
            }
        }
        button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    }

    // ---- Menu Building ----

    func buildMenu() {
        let menu = NSMenu()

        // Session
        let sessionItem = NSMenuItem(title: "\(S().sessionPrefix) --", action: nil, keyEquivalent: "")
        sessionItem.tag = kTagSession
        sessionItem.isEnabled = false
        menu.addItem(sessionItem)

        // Weekly
        let weeklyItem = NSMenuItem(title: "\(S().weeklyPrefix)  --", action: nil, keyEquivalent: "")
        weeklyItem.tag = kTagWeekly
        weeklyItem.isEnabled = false
        menu.addItem(weeklyItem)

        // Plan
        let planItem = NSMenuItem(title: "\(S().planPrefix)    --", action: nil, keyEquivalent: "")
        planItem.tag = kTagPlan
        planItem.isEnabled = false
        menu.addItem(planItem)

        menu.addItem(NSMenuItem.separator())

        // Display status
        let displayItem = NSMenuItem(title: S().displayNotConnected, action: nil, keyEquivalent: "")
        displayItem.tag = kTagDisplay
        displayItem.isEnabled = false
        menu.addItem(displayItem)

        // Last update
        let updateItem = NSMenuItem(title: "\(S().lastUpdate) --", action: nil, keyEquivalent: "")
        updateItem.tag = kTagLastUpdate
        updateItem.isEnabled = false
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        // Refresh
        let refreshItem = NSMenuItem(title: S().refreshNow, action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.tag = kTagRefresh
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Firmware section
        let fwStatusItem = NSMenuItem(title: "\(S().firmware) --", action: nil, keyEquivalent: "")
        fwStatusItem.tag = kTagFirmwareStatus
        fwStatusItem.isEnabled = false
        menu.addItem(fwStatusItem)

        let fwFlashItem = NSMenuItem(title: S().flashFirmware, action: #selector(flashFirmware), keyEquivalent: "")
        fwFlashItem.tag = kTagFirmwareFlash
        fwFlashItem.isEnabled = false
        menu.addItem(fwFlashItem)

        menu.addItem(NSMenuItem.separator())

        // App update section
        let appUpdateStatusItem = NSMenuItem(title: "App: v\(kAppVersion)", action: nil, keyEquivalent: "")
        appUpdateStatusItem.tag = kTagAppUpdateStatus
        appUpdateStatusItem.isEnabled = false
        menu.addItem(appUpdateStatusItem)

        let appUpdateActionItem = NSMenuItem(title: S().searchAppUpdates, action: #selector(checkForAppUpdate), keyEquivalent: "")
        appUpdateActionItem.tag = kTagAppUpdateAction
        menu.addItem(appUpdateActionItem)

        menu.addItem(NSMenuItem.separator())

        // Language submenu
        let langMenu = NSMenu()
        let langDE = NSMenuItem(title: S().german, action: #selector(setLanguageDE), keyEquivalent: "")
        let langEN = NSMenuItem(title: S().english, action: #selector(setLanguageEN), keyEquivalent: "")
        if Settings.shared.language == "de" { langDE.state = .on }
        if Settings.shared.language == "en" { langEN.state = .on }
        langMenu.addItem(langDE)
        langMenu.addItem(langEN)
        let langItem = NSMenuItem(title: S().language, action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // Launch at login
        let loginItem = NSMenuItem(title: S().launchAtLogin, action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.tag = kTagLaunchAtLogin
        loginItem.state = Settings.shared.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // About
        menu.addItem(withTitle: S().about, action: #selector(showAbout), keyEquivalent: "")

        // Quit
        menu.addItem(withTitle: S().quit, action: #selector(quit), keyEquivalent: "q")

        statusItem.menu = menu
    }

    // ---- Menu Update ----

    func updateMenu() {
        guard let menu = statusItem.menu else { return }

        updateMenubarTitle(status: monitor.status, usage: monitor.lastUsage)

        if let usage = monitor.lastUsage {
            let sp = Int(round((usage.five_hour?.utilization ?? 0)))
            let wp = Int(round((usage.seven_day?.utilization ?? 0)))

            let sessionReset = formatCountdown(usage.five_hour?.resets_at)
            let weeklyReset = formatCountdown(usage.seven_day?.resets_at)

            let sessionText = sessionReset.isEmpty ? "\(S().sessionPrefix) \(sp)%" : "\(S().sessionPrefix) \(sp)%  (Reset \(sessionReset))"
            let weeklyText = weeklyReset.isEmpty ? "\(S().weeklyPrefix)  \(wp)%" : "\(S().weeklyPrefix)  \(wp)%  (Reset \(weeklyReset))"

            menu.item(withTag: kTagSession)?.title = sessionText
            menu.item(withTag: kTagWeekly)?.title = weeklyText

            // Plan info
            if let extra = usage.extra_usage {
                // API returns costs in cents
                let used = (extra.used_credits ?? 0) / 100.0
                let limit = (extra.monthly_limit ?? 0) / 100.0
                menu.item(withTag: kTagPlan)?.title = "\(S().planPrefix)    Claude Max ($\(formatCurrency(used))/$\(formatCurrency(limit)))"
            } else {
                menu.item(withTag: kTagPlan)?.title = "\(S().planPrefix)    Claude Pro"
            }
        }

        if let error = monitor.lastError {
            if monitor.status == .rateLimited {
                let remaining = ClaudeAPI.rateLimitRemaining
                let minutes = remaining / 60
                menu.item(withTag: kTagSession)?.title = String(format: S().remainingMinutes, minutes)
            } else if monitor.lastUsage == nil {
                menu.item(withTag: kTagSession)?.title = "\(S().errorPrefix) \(error)"
            }
        }

        // Display status
        if monitor.serialPort.isConnected, let port = monitor.serialPort.connectedPort {
            let shortPort = (port as NSString).lastPathComponent
            let fwVersion = monitor.serialPort.deviceFirmwareVersion.map { " · FW v\($0)" } ?? ""
            menu.item(withTag: kTagDisplay)?.title = String(format: S().connectedFormat, shortPort, fwVersion)
        } else {
            menu.item(withTag: kTagDisplay)?.title = S().displayNotConnected
        }

        // Last update
        if let lastUpdate = monitor.lastUpdateDate {
            let elapsed = Int(Date().timeIntervalSince(lastUpdate))
            let text: String
            if elapsed < 60 {
                text = String(format: S().timeAgoSeconds, elapsed)
            } else {
                text = String(format: S().timeAgoMinutes, elapsed / 60)
            }
            menu.item(withTag: kTagLastUpdate)?.title = "\(S().lastUpdate) \(text)"
        }

        // Firmware status
        let fw = FirmwareManager.shared
        if fw.isFlashing {
            menu.item(withTag: kTagFirmwareStatus)?.title = "\(S().firmware) \(fw.flashProgress)"
            menu.item(withTag: kTagFirmwareFlash)?.isEnabled = false
            menu.item(withTag: kTagFirmwareFlash)?.title = S().flashing
        } else if fw.isDownloading {
            menu.item(withTag: kTagFirmwareStatus)?.title = "\(S().firmware) \(S().downloading)"
            menu.item(withTag: kTagFirmwareFlash)?.isEnabled = false
        } else if fw.hasUpdate {
            menu.item(withTag: kTagFirmwareStatus)?.title = "Firmware Update: \(fw.latestVersionDisplay) \(S().firmwareAvailable)"
            menu.item(withTag: kTagFirmwareFlash)?.title = S().flashFirmware
            menu.item(withTag: kTagFirmwareFlash)?.isEnabled = fw.canFlash(serialConnected: monitor.serialPort.isConnected)
        } else if fw.latestRelease != nil {
            menu.item(withTag: kTagFirmwareStatus)?.title = "\(S().firmware) \(fw.installedVersionDisplay) \(S().firmwareCurrent)"
            menu.item(withTag: kTagFirmwareFlash)?.title = S().flashFirmware
            menu.item(withTag: kTagFirmwareFlash)?.isEnabled = fw.canFlash(serialConnected: monitor.serialPort.isConnected)
        } else {
            menu.item(withTag: kTagFirmwareStatus)?.title = "\(S().firmware) \(fw.installedVersionDisplay)"
            menu.item(withTag: kTagFirmwareFlash)?.isEnabled = false
        }

        // App update status
        let appMgr = AppUpdateManager.shared
        if appMgr.isDownloading {
            menu.item(withTag: kTagAppUpdateStatus)?.title = "App: \(S().downloading)"
            menu.item(withTag: kTagAppUpdateAction)?.isEnabled = false
            menu.item(withTag: kTagAppUpdateAction)?.title = S().downloadRunning
        } else if appMgr.hasUpdate {
            menu.item(withTag: kTagAppUpdateStatus)?.title = "App Update: \(appMgr.latestVersionDisplay) \(S().firmwareAvailable)"
            menu.item(withTag: kTagAppUpdateAction)?.isEnabled = true
            menu.item(withTag: kTagAppUpdateAction)?.title = S().updateDownload
        } else if appMgr.latestRelease != nil {
            menu.item(withTag: kTagAppUpdateStatus)?.title = "App: v\(kAppVersion) \(S().firmwareCurrent)"
            menu.item(withTag: kTagAppUpdateAction)?.isEnabled = true
            menu.item(withTag: kTagAppUpdateAction)?.title = S().searchAppUpdates
        } else {
            menu.item(withTag: kTagAppUpdateStatus)?.title = "App: v\(kAppVersion)"
            menu.item(withTag: kTagAppUpdateAction)?.isEnabled = true
            menu.item(withTag: kTagAppUpdateAction)?.title = S().searchAppUpdates
        }

        // Update launch at login checkmark
        if let loginItem = menu.item(withTag: kTagLaunchAtLogin) {
            loginItem.state = Settings.shared.launchAtLogin ? .on : .off
        }
    }

    // ---- Formatting Helpers ----

    func formatCountdown(_ isoDate: String?) -> String {
        guard let dateStr = isoDate, !dateStr.isEmpty else { return "" }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let resetDate = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) else {
            return ""
        }

        let diff = resetDate.timeIntervalSinceNow
        if diff <= 0 { return S().timeNow }

        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60

        if hours >= 24 {
            let days = hours / 24
            let remainHours = hours % 24
            return String(format: S().timeInDaysHours, days, remainHours)
        } else if hours > 0 {
            return String(format: S().timeInHoursMinutes, hours, minutes)
        } else {
            return String(format: S().timeInMinutes, minutes)
        }
    }

    func formatCurrency(_ value: Double) -> String {
        if value == value.rounded() && value < 10000 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    // ---- Actions ----

    @objc func refreshNow() {
        monitor.manualRefresh()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newValue = !Settings.shared.launchAtLogin
        Settings.shared.launchAtLogin = newValue
        sender.state = newValue ? .on : .off
    }

    @objc func flashFirmware() {
        let fw = FirmwareManager.shared

        // If no firmware downloaded yet, download first
        if fw.downloadedBinPath == nil {
            guard fw.latestRelease != nil else {
                let alert = NSAlert()
                alert.messageText = S().noReleaseFound
                alert.informativeText = S().couldNotLoadRelease
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            fw.downloadFirmware { [weak self] success, error in
                DispatchQueue.main.async {
                    if success {
                        self?.flashFirmware()  // Retry with downloaded firmware
                    } else {
                        let alert = NSAlert()
                        alert.messageText = S().downloadFailed
                        alert.informativeText = error ?? "Unknown error"
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
            return
        }

        guard let port = monitor.serialPort.connectedPort else {
            let alert = NSAlert()
            alert.messageText = S().noESP32Connected
            alert.informativeText = S().connectESP32
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Confirmation dialog
        let version = fw.latestRelease?.tag_name ?? fw.installedVersionDisplay
        let shortPort = (port as NSString).lastPathComponent
        let confirm = NSAlert()
        confirm.messageText = S().flashFirmwareQuestion
        confirm.informativeText = "ESP32 \(shortPort) — Firmware \(version)"
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: S().flash)
        confirm.addButton(withTitle: S().cancel)

        let response = confirm.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Stop serial scanning during flash (saves port path before disconnect)
        monitor.serialPort.stopScanning()

        fw.flashFirmware(port: port) { [weak self] success, message in
            DispatchQueue.main.async {
                // Restart serial scanning
                self?.monitor.serialPort.startScanning()

                let alert = NSAlert()
                alert.messageText = success ? S().flashSuccess : S().flashFailed
                alert.informativeText = message
                alert.alertStyle = success ? .informational : .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    @objc func checkForAppUpdate() {
        let appMgr = AppUpdateManager.shared

        // If we already know there's an update, download it
        if appMgr.hasUpdate {
            downloadAppUpdate()
            return
        }

        // Otherwise, check for updates (force check regardless of timer)
        appMgr.checkForUpdate { [weak self] hasUpdate in
            DispatchQueue.main.async {
                if hasUpdate {
                    self?.showAppUpdateAlert()
                } else {
                    let alert = NSAlert()
                    alert.messageText = S().noUpdateAvailable
                    alert.informativeText = "AI Monitor v\(kAppVersion) \(S().appIsCurrentSuffix)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
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
            // Strip Markdown formatting for plain-text display
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

        // Check if there's a downloadable asset
        let hasAsset = appMgr.latestRelease?.assets.contains { $0.name == kAppAssetName } ?? false
        if hasAsset {
            alert.addButton(withTitle: S().download)
        } else {
            alert.addButton(withTitle: S().openInBrowser)
        }
        alert.addButton(withTitle: S().later)
        alert.addButton(withTitle: S().skipVersion)

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            downloadAppUpdate()
        case .alertThirdButtonReturn:
            // Skip this version
            if let tag = appMgr.latestRelease?.tag_name {
                Settings.shared.skippedAppVersion = tag
                NSLog("[AppUpdate] User skipped version %@", tag)
            }
        default:
            break
        }
    }

    func downloadAppUpdate() {
        let appMgr = AppUpdateManager.shared

        let hasAsset = appMgr.latestRelease?.assets.contains { $0.name == kAppAssetName } ?? false
        if !hasAsset {
            // No downloadable asset — open release page
            appMgr.openReleasePage()
            return
        }

        appMgr.downloadAndInstall { success, extractedPathOrError in
            DispatchQueue.main.async {
                guard success else {
                    // Download or extraction failed
                    let alert = NSAlert()
                    alert.messageText = S().updateFailed
                    alert.informativeText = extractedPathOrError
                    alert.alertStyle = .critical
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                // Download successful — ask user to confirm install + restart
                let alert = NSAlert()
                alert.messageText = String(format: S().installQuestion, appMgr.latestVersionDisplay)
                alert.informativeText = S().restartInfo
                alert.alertStyle = .informational
                alert.addButton(withTitle: S().install)
                alert.addButton(withTitle: S().later)

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // User confirmed — perform auto-update
                    appMgr.performAutoUpdate(extractedAppPath: extractedPathOrError) { _, errorMessage in
                        DispatchQueue.main.async {
                            let errAlert = NSAlert()
                            errAlert.messageText = S().updateFailed
                            errAlert.informativeText = errorMessage
                            errAlert.alertStyle = .critical
                            errAlert.addButton(withTitle: "OK")
                            errAlert.runModal()
                        }
                    }
                } else {
                    NSLog("[AppUpdate] User deferred update, new app at: %@", extractedPathOrError)
                }
            }
        }
    }

    @objc func setLanguageDE() {
        Settings.shared.language = "de"
        monitor.sendLanguageToESP32()
        buildMenu()
        updateMenu()
    }

    @objc func setLanguageEN() {
        Settings.shared.language = "en"
        monitor.sendLanguageToESP32()
        buildMenu()
        updateMenu()
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "\(S().about) v\(kAppVersion)"
        alert.informativeText = S().aboutInfoText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func quit() {
        monitor.stop()
        NSApplication.shared.terminate(nil)
    }
}

// ============================================================
// MARK: - App Entry Point
// ============================================================

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
