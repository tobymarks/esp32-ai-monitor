/**
 * AI Monitor Companion — macOS Menubar App
 *
 * Reads Claude OAuth token from macOS Keychain (Claude Code credentials),
 * polls the usage API every 60 seconds, and pushes results to the ESP32
 * display device on the local network.
 *
 * Build: ./build.sh
 * Run:   open AIMonitorCompanion.app
 */

import Cocoa
import Security
import Foundation

// ============================================================
// MARK: - Configuration
// ============================================================

let kDefaultESP32Host = "192.168.178.252"
let kDefaultPollInterval: TimeInterval = 120
let kKeychainService = "Claude Code-credentials"
let kUsageEndpoint = "https://api.anthropic.com/api/oauth/usage"
let kOAuthBeta = "oauth-2025-04-20"
let kUserDefaultsHostKey = "esp32_host"
let kUserDefaultsIntervalKey = "poll_interval"

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
// MARK: - Keychain Reader
// ============================================================

class KeychainReader {
    /// Read Claude Code OAuth access token from macOS Keychain
    static func readAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                NSLog("[Keychain] No entry for '%@'", kKeychainService)
            } else {
                NSLog("[Keychain] Error: %d", status)
            }
            return nil
        }

        guard let data = result as? Data else {
            NSLog("[Keychain] Result is not Data")
            return nil
        }

        // Parse JSON: { "claudeAiOauth": { "accessToken": "sk-ant-oat01-..." } }
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String,
                  !token.isEmpty else {
                NSLog("[Keychain] Could not extract accessToken from credentials JSON")
                return nil
            }
            return token
        } catch {
            NSLog("[Keychain] JSON parse error: %@", error.localizedDescription)
            return nil
        }
    }
}

// ============================================================
// MARK: - Claude Usage API
// ============================================================

class ClaudeAPI {
    /// Retry-After seconds from last 429 response (0 = no backoff)
    static var retryAfterUntil: Date?

    static func fetchUsage(token: String, completion: @escaping (UsageResponse?, Error?) -> Void) {
        // Respect Retry-After from previous 429
        if let until = retryAfterUntil, Date() < until {
            let remaining = Int(until.timeIntervalSinceNow)
            NSLog("[API] Rate-limit cooldown: %d sec remaining", remaining)
            completion(nil, NSError(domain: "API", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate-limit Cooldown (\(remaining)s)"]))
            return
        }

        guard let url = URL(string: kUsageEndpoint) else {
            completion(nil, NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(kOAuthBeta, forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(nil, NSError(domain: "API", code: -2, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"]))
                return
            }

            if httpResponse.statusCode == 429 {
                // Parse Retry-After header
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Int($0) } ?? 120
                retryAfterUntil = Date().addingTimeInterval(TimeInterval(retryAfter))
                NSLog("[API] 429 Rate Limited — backing off %d sec", retryAfter)
                completion(nil, NSError(domain: "API", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited (\(retryAfter)s)"]))
                return
            }

            guard httpResponse.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                NSLog("[API] HTTP %d: %@", httpResponse.statusCode, body)
                let msg = httpResponse.statusCode == 401 ? "Token expired — Claude Code CLI neu starten" :
                          "HTTP \(httpResponse.statusCode)"
                completion(nil, NSError(domain: "API", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: msg]))
                return
            }

            // Clear rate-limit backoff on success
            retryAfterUntil = nil

            guard let data = data else {
                completion(nil, NSError(domain: "API", code: -3, userInfo: [NSLocalizedDescriptionKey: "No data"]))
                return
            }

            do {
                let usage = try JSONDecoder().decode(UsageResponse.self, from: data)
                completion(usage, nil)
            } catch {
                completion(nil, error)
            }
        }.resume()
    }
}

// ============================================================
// MARK: - ESP32 Push Client
// ============================================================

class ESP32Client {
    var host: String

    init(host: String = kDefaultESP32Host) {
        self.host = host
    }

    func pushUsage(_ usage: UsageResponse, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(host)/api/usage-push") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        // Build JSON matching ESP32's expected format
        do {
            let body = try JSONEncoder().encode(usage)
            request.httpBody = body
        } catch {
            NSLog("[ESP32] JSON encode error: %@", error.localizedDescription)
            completion(false)
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("[ESP32] Push error: %@", error.localizedDescription)
                completion(false)
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let ok = httpResponse?.statusCode == 200
            if !ok {
                NSLog("[ESP32] Push failed: HTTP %d", httpResponse?.statusCode ?? -1)
            }
            completion(ok)
        }.resume()
    }
}

// ============================================================
// MARK: - Usage Monitor (Timer + Poll + Push)
// ============================================================

class UsageMonitor {
    var pollInterval: TimeInterval
    var esp32: ESP32Client
    var timer: Timer?
    var lastUsage: UsageResponse?
    var lastError: String?
    var esp32Connected = false
    var onUpdate: (() -> Void)?

    init(host: String = kDefaultESP32Host, interval: TimeInterval = kDefaultPollInterval) {
        self.esp32 = ESP32Client(host: host)
        self.pollInterval = interval
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        // 0. Check ESP32 connectivity (always, even without data)
        checkESP32()

        // 1. Read token from Keychain
        guard let token = KeychainReader.readAccessToken() else {
            lastError = "Kein Token im Keychain"
            DispatchQueue.main.async { self.onUpdate?() }
            return
        }

        // 2. Fetch usage from API
        ClaudeAPI.fetchUsage(token: token) { [weak self] usage, error in
            guard let self = self else { return }

            if let error = error {
                self.lastError = error.localizedDescription
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }

            guard let usage = usage else {
                self.lastError = "Keine Daten"
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }

            self.lastUsage = usage
            self.lastError = nil

            // 3. Push to ESP32
            self.esp32.pushUsage(usage) { ok in
                self.esp32Connected = ok
                DispatchQueue.main.async { self.onUpdate?() }
            }
        }
    }

    func checkESP32() {
        guard let url = URL(string: "http://\(esp32.host)/api/status") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            self?.esp32Connected = ok
        }.resume()
    }
}

// ============================================================
// MARK: - App Delegate (Menubar)
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var monitor: UsageMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load saved settings
        let host = UserDefaults.standard.string(forKey: kUserDefaultsHostKey) ?? kDefaultESP32Host
        let interval = UserDefaults.standard.double(forKey: kUserDefaultsIntervalKey)
        let pollInterval = interval > 0 ? interval : kDefaultPollInterval

        // Setup menubar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenubarIcon(status: .idle)
        buildMenu()

        // Start monitor
        monitor = UsageMonitor(host: host, interval: pollInterval)
        monitor.onUpdate = { [weak self] in
            self?.updateMenu()
        }
        monitor.start()

        NSLog("[App] AI Monitor Companion started — polling %@ every %.0fs", host, pollInterval)
    }

    // ---- Menubar Icon ----

    enum Status { case idle, ok, error }

    func updateMenubarIcon(status: Status) {
        if let button = statusItem.button {
            let icon: String
            switch status {
            case .idle:  icon = "◻"
            case .ok:    icon = "◼"
            case .error: icon = "◻"
            }
            button.title = "AI \(icon)"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        }
    }

    // ---- Menu ----

    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "AI Usage Monitor", action: nil, keyEquivalent: "").isEnabled = false

        menu.addItem(NSMenuItem.separator())

        let sessionItem = NSMenuItem(title: "Session: --", action: nil, keyEquivalent: "")
        sessionItem.tag = 100
        sessionItem.isEnabled = false
        menu.addItem(sessionItem)

        let weeklyItem = NSMenuItem(title: "Weekly: --", action: nil, keyEquivalent: "")
        weeklyItem.tag = 101
        weeklyItem.isEnabled = false
        menu.addItem(weeklyItem)

        menu.addItem(NSMenuItem.separator())

        let esp32Item = NSMenuItem(title: "ESP32: --", action: nil, keyEquivalent: "")
        esp32Item.tag = 102
        esp32Item.isEnabled = false
        menu.addItem(esp32Item)

        let lastUpdateItem = NSMenuItem(title: "Letztes Update: --", action: nil, keyEquivalent: "")
        lastUpdateItem.tag = 103
        lastUpdateItem.isEnabled = false
        menu.addItem(lastUpdateItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Jetzt aktualisieren", action: #selector(refreshNow), keyEquivalent: "r")
        menu.addItem(withTitle: "ESP32 Web-UI öffnen", action: #selector(openWebUI), keyEquivalent: "w")

        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Beenden", action: #selector(quit), keyEquivalent: "q")

        statusItem.menu = menu
    }

    func updateMenu() {
        guard let menu = statusItem.menu else { return }

        if let usage = monitor.lastUsage {
            let sp = Int(round((usage.five_hour?.utilization ?? 0) * 100))
            let wp = Int(round((usage.seven_day?.utilization ?? 0) * 100))

            let sessionReset = formatCountdown(usage.five_hour?.resets_at)
            let weeklyReset = formatCountdown(usage.seven_day?.resets_at)

            menu.item(withTag: 100)?.title = "Session: \(sp)%\(sessionReset.isEmpty ? "" : " — Reset \(sessionReset)")"
            menu.item(withTag: 101)?.title = "Weekly: \(wp)%\(weeklyReset.isEmpty ? "" : " — Reset \(weeklyReset)")"

            updateMenubarIcon(status: .ok)
        }

        if let error = monitor.lastError {
            menu.item(withTag: 100)?.title = "Fehler: \(error)"
            updateMenubarIcon(status: .error)
        }

        menu.item(withTag: 102)?.title = monitor.esp32Connected ? "ESP32: Verbunden" : "ESP32: Nicht erreichbar"

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        menu.item(withTag: 103)?.title = "Letztes Update: \(formatter.string(from: Date()))"
    }

    func formatCountdown(_ isoDate: String?) -> String {
        guard let dateStr = isoDate, !dateStr.isEmpty else { return "" }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let resetDate = formatter.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr) else { return "" }

        let diff = resetDate.timeIntervalSinceNow
        if diff <= 0 { return "jetzt" }

        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60

        if hours >= 24 {
            let days = hours / 24
            let remainHours = hours % 24
            return "in \(days)d \(remainHours)h"
        } else if hours > 0 {
            return "in \(hours)h \(minutes)m"
        } else {
            return "in \(minutes)m"
        }
    }

    // ---- Actions ----

    @objc func refreshNow() {
        monitor.poll()
    }

    @objc func openWebUI() {
        let host = monitor.esp32.host
        if let url = URL(string: "http://\(host)/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// ============================================================
// MARK: - App Entry Point
// ============================================================

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Hide from Dock (menubar only)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
