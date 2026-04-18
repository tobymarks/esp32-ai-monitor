/**
 * AI Monitor v1.9.0 — macOS-Hintergrund-App für ESP32 AI Usage Monitor Display
 *
 * Datenquelle: lokale CodexBar-App (widget-snapshot.json), KEIN direkter Anthropic-API-Poll.
 * UI-Modus: LSUIElement=YES, unsichtbar. Kein Menubar-Icon. Settings-Fenster beim Launch
 * und beim Reopen-Event (Spotlight / Finder-Doppelklick).
 * ESP32-Protokoll: unverändert — JSON-Zeile mit time/displayTime/data[].usage.{primary,secondary}.
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

let kAppVersion = "1.9.0"
let kSerialBaudRate: speed_t = 115200
let kSerialScanInterval: TimeInterval = 3
let kUserDefaultsSuite = "de.aimonitor.app"
let kGitHubRepo = "tobymarks/esp32-ai-monitor"
let kGitHubReleasesAPI = "https://api.github.com/repos/tobymarks/esp32-ai-monitor/releases"
let kFirmwareAssetName = "ai-monitor.bin"
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
    firmwareAvailable: "verfügbar"
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
    firmwareAvailable: "available"
)

func S() -> Strings {
    return Settings.shared.language == "en" ? stringsEN : stringsDE
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

    var language: String {
        get { defaults.string(forKey: "language") ?? "de" }
        set { defaults.set(newValue, forKey: "language") }
    }

    var orientation: String {
        get { defaults.string(forKey: "orientation") ?? "portrait" }
        set { defaults.set(newValue, forKey: "orientation") }
    }

    /// "system" | "dark" | "light" — steuert, was per set_theme an ESP32 geht.
    var themeMode: String {
        get { defaults.string(forKey: "themeMode") ?? "system" }
        set { defaults.set(newValue, forKey: "themeMode") }
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
    var lastKnownBrightness: Int {
        get { (defaults.object(forKey: "brightness") as? Int) ?? 80 }
        set { defaults.set(newValue, forKey: "brightness") }
    }

    private init() {
        defaults = UserDefaults(suiteName: kUserDefaultsSuite) ?? UserDefaults.standard
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

class FirmwareManager {
    static let shared = FirmwareManager()

    var latestRelease: GitHubRelease?
    var downloadedBinPath: String?
    var isDownloading = false
    var isFlashing = false
    var downloadProgress: Double = 0
    var flashProgress: String = ""
    var onUpdate: (() -> Void)?

    private var firmwareDir: String {
        let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
        return (appSupport as NSString).appendingPathComponent("AI Monitor/firmware")
    }

    func localBinPath(for version: String) -> String {
        return (firmwareDir as NSString).appendingPathComponent("ai-monitor-\(version).bin")
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
        guard let release = latestRelease else { completion(false, S().noReleaseFound); return }
        guard let asset = release.assets.first(where: { $0.name == kFirmwareAssetName }) else {
            completion(false, "No \(kFirmwareAssetName) in release \(release.tag_name)"); return
        }
        guard let url = URL(string: asset.browser_download_url) else {
            completion(false, "Invalid download URL"); return
        }
        do {
            try FileManager.default.createDirectory(atPath: firmwareDir, withIntermediateDirectories: true)
        } catch {
            completion(false, "Cannot create firmware directory: \(error.localizedDescription)"); return
        }
        let destPath = localBinPath(for: release.tag_name)
        if FileManager.default.fileExists(atPath: destPath) {
            downloadedBinPath = destPath
            completion(true, nil); return
        }
        isDownloading = true
        downloadProgress = 0
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
                DispatchQueue.main.async { self.onUpdate?() }
                completion(true, nil)
            } catch {
                DispatchQueue.main.async { self.onUpdate?() }
                completion(false, error.localizedDescription)
            }
        }
        task.resume()
    }

    func flashFirmware(port: String, completion: @escaping (Bool, String) -> Void) {
        guard let binPath = downloadedBinPath, FileManager.default.fileExists(atPath: binPath) else {
            completion(false, "Keine Firmware-Datei vorhanden"); return
        }
        guard let tool = resolveEsptool() else {
            completion(false, "esptool nicht gefunden.\nInstalliere mit: pip3 install esptool"); return
        }
        isFlashing = true
        flashProgress = S().preparing
        DispatchQueue.main.async { self.onUpdate?() }
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
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    outputText += str
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
                if let str = String(data: data, encoding: .utf8), !str.isEmpty { errorText += str }
            }
            do {
                DispatchQueue.main.async { self.flashProgress = "Flashing..."; self.onUpdate?() }
                try process.run()
                process.waitUntilExit()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let exitCode = process.terminationStatus
                if exitCode == 0 {
                    if let release = self.latestRelease { Settings.shared.installedFirmwareVersion = release.tag_name }
                    DispatchQueue.main.async { self.isFlashing = false; self.flashProgress = ""; self.onUpdate?() }
                    completion(true, S().flashSuccessMessage)
                } else {
                    DispatchQueue.main.async { self.isFlashing = false; self.flashProgress = ""; self.onUpdate?() }
                    let shortError = errorText.isEmpty ? "esptool Exit-Code \(exitCode)" :
                        (errorText.components(separatedBy: "\n").last(where: { !$0.isEmpty }) ?? errorText)
                    completion(false, "\(S().flashFailedPrefix) \(shortError)")
                }
            } catch {
                DispatchQueue.main.async { self.isFlashing = false; self.flashProgress = ""; self.onUpdate?() }
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

class SerialPortManager {
    private var fileDescriptor: Int32 = -1
    private(set) var connectedPort: String?
    private var scanTimer: Timer?
    private var lastDisconnectAt: Date?
    // Nach einem Firmware-Reboot (Legacy-Pfad) dauerte das Wiederherstellen der
    // USB-CDC-Schnittstelle ~2-3 s. Frueher: 5 s Blockwindow = spuerbarer Delay.
    // v1.9.0: auf 1 s reduziert, da v2.8.0-Firmware orientation/theme ohne Reboot
    // handhabt und reale Reconnects nur nach Flash oder Hard-Reset auftreten.
    private let kReconnectBlockWindow: TimeInterval = 1
    var onConnect: (() -> Void)?
    var deviceFirmwareVersion: String?

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
        NSLog("[Serial] Connected to %@ at 115200 baud", port)

        let newline: [UInt8] = [0x0A]
        newline.withUnsafeBufferPointer { buf in _ = Darwin.write(fd, buf.baseAddress!, 1) }
        usleep(200_000)

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
                    for _ in 0..<5 {
                        guard let line = self.readLine(timeout: 2.0) else { break }
                        NSLog("[Serial] read: %@", line)
                        guard line.hasPrefix("{") else { continue }
                        if let jsonData = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let type = json["type"] as? String, type == "info",
                           let version = json["version"] as? String {
                            self.deviceFirmwareVersion = version
                            Settings.shared.installedFirmwareVersion = "v\(version)"
                            NSLog("[Serial] ESP32 firmware: v%@", version)
                            // Firmware ab v2.8.0 meldet Brightness-Wert mit —
                            // cachen, damit Settings-Slider beim Öffnen nicht
                            // auf den Default zurückspringt.
                            if let br = json["brightness"] as? Int {
                                Settings.shared.lastKnownBrightness = br
                            }
                            break
                        }
                    }
                }
            }
            DispatchQueue.main.async { self.onConnect?() }
        }
    }

    func disconnect() {
        if fileDescriptor >= 0 { Darwin.close(fileDescriptor); fileDescriptor = -1 }
        connectedPort = nil
        lastDisconnectAt = Date()
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
        self.codexBar = CodexBarSource()
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
            self.sendThemeToESP32()
            self.sendLanguageToESP32()
            self.sendOrientationToESP32()
            // Brightness wurde von get_info bereits gecacht; senden ist
            // optional, da Firmware den Wert aus NVS wiederherstellt. Wir
            // senden nur wenn er sich lokal (Slider) geändert hat — die
            // Slider-Aktion triggert das selbst via sendBrightnessToESP32.
            if self.codexBar.status.isOK {
                self.sendUsageToESP32()
            }
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
        guard serialPort.isConnected else { return }
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
        guard serialPort.isConnected else { return }
        let lang = Settings.shared.language
        let cmd = "{\"cmd\":\"set_language\",\"value\":\"\(lang)\"}"
        if serialPort.sendJSON(cmd) { NSLog("[Serial] Sent set_language: %@", lang) }
        sendLastUsageSnapshotIfAvailable()
    }

    func sendOrientationToESP32() {
        guard serialPort.isConnected else { return }
        let orient = Settings.shared.orientation
        let cmd = "{\"cmd\":\"set_orientation\",\"value\":\"\(orient)\"}"
        if serialPort.sendJSON(cmd) { NSLog("[Serial] Sent set_orientation: %@", orient) }
        // Firmware v2.8.0+ wechselt live (kein Reboot). Sofort neuen Snapshot
        // hinterherschicken, damit das neu aufgebaute Dashboard Daten hat.
        sendLastUsageSnapshotIfAvailable()
    }

    /// Sendet den aktuellen Brightness-Wert (0..100) an den ESP32. Persistenz
    /// liegt in NVS auf der Firmware; hier nur Cache für UI-Vorbelegung.
    func sendBrightnessToESP32(_ percent: Int) {
        let clamped = max(5, min(100, percent))
        Settings.shared.lastKnownBrightness = clamped
        guard serialPort.isConnected else { return }
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
        guard serialPort.isConnected else { return }
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
        let localTime = timeFmt.string(from: Date())

        // JSON-Envelope: strukturgleich zum alten Format MINUS providerCost.
        // (has_extra_usage=false auf dem ESP32 blendet die Cost-Kachel ohnehin aus.)
        let envelope: [String: Any] = [
            "time": nowISO,
            "displayTime": localTime,
            "data": [
                [
                    "source": "codexbar",
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

        // Settings-Fenster bauen + initial zeigen
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

    func runFirmwareFlash() {
        let fw = FirmwareManager.shared
        if fw.downloadedBinPath == nil {
            guard fw.latestRelease != nil else {
                alert(title: S().noReleaseFound, info: S().couldNotLoadRelease, style: .warning)
                return
            }
            fw.downloadFirmware { [weak self] success, error in
                DispatchQueue.main.async {
                    if success { self?.runFirmwareFlash() }
                    else { self?.alert(title: S().downloadFailed, info: error ?? "Unknown error", style: .warning) }
                }
            }
            return
        }
        guard let port = monitor.serialPort.connectedPort else {
            alert(title: S().noESP32Connected, info: S().connectESP32, style: .warning); return
        }
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

        monitor.serialPort.stopScanning()
        fw.flashFirmware(port: port) { [weak self] success, message in
            DispatchQueue.main.async {
                self?.monitor.serialPort.startScanning()
                self?.alert(title: success ? S().flashSuccess : S().flashFailed, info: message,
                            style: success ? .informational : .critical)
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
