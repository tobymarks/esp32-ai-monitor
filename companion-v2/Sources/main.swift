/**
 * AI Monitor v1.0.0 — macOS Menubar App for ESP32 AI Usage Monitor Display
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

let kAppVersion = "1.0.0"
let kKeychainService = "Claude Code-credentials"
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
let kPollInterval: TimeInterval = 60
let kMinPollInterval: TimeInterval = 60
let kSerialBaudRate: speed_t = 115200
let kSerialScanInterval: TimeInterval = 3
let kUserDefaultsSuite = "de.aimonitor.app"

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
    /// Read Claude Code OAuth access token from macOS Keychain
    static func readAccessToken() -> String? {
        // Primary: Keychain
        if let token = readFromKeychain() {
            return token
        }
        // Fallback: credentials file
        NSLog("[Keychain] Trying fallback credentials file")
        return readFromFile()
    }

    private static func readFromKeychain() -> String? {
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

        return extractToken(from: data)
    }

    private static func readFromFile() -> String? {
        guard let data = FileManager.default.contents(atPath: kCredentialsFilePath) else {
            NSLog("[Keychain] No credentials file at %@", kCredentialsFilePath)
            return nil
        }
        return extractToken(from: data)
    }

    private static func extractToken(from data: Data) -> String? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[Keychain] Top-level JSON is not a dictionary")
                return nil
            }

            // Try nested format: { "claudeAiOauth": { "accessToken": "..." } }
            if let oauth = json["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String, !token.isEmpty {
                return token
            }

            // Try flat format: { "accessToken": "..." }
            if let token = json["accessToken"] as? String, !token.isEmpty {
                return token
            }

            NSLog("[Keychain] Could not extract accessToken from JSON")
            return nil
        } catch {
            NSLog("[Keychain] JSON parse error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Attempt token refresh by calling claude CLI
    static func refreshToken() -> Bool {
        NSLog("[Keychain] Attempting token refresh via claude CLI")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        process.arguments = ["--print-access-token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("[Keychain] Token refresh failed: %@", error.localizedDescription)
            return false
        }
    }
}

// ============================================================
// MARK: - Claude Usage API
// ============================================================

class ClaudeAPI {
    /// Retry-After until date from last 429 response
    static var retryAfterUntil: Date?
    /// Whether a token refresh has been attempted for this cycle
    static var tokenRefreshAttempted = false

    static var rateLimitRemaining: Int {
        guard let until = retryAfterUntil else { return 0 }
        let remaining = Int(until.timeIntervalSinceNow)
        return max(0, remaining)
    }

    static var isRateLimited: Bool {
        guard let until = retryAfterUntil else { return false }
        return Date() < until
    }

    static func fetchUsage(token: String, completion: @escaping (UsageResponse?, Int?, Error?) -> Void) {
        // Respect Retry-After from previous 429
        if let until = retryAfterUntil, Date() < until {
            let remaining = Int(until.timeIntervalSinceNow)
            NSLog("[API] Rate-limit cooldown: %d sec remaining", remaining)
            completion(nil, 429, NSError(domain: "API", code: 429,
                userInfo: [NSLocalizedDescriptionKey: "Rate-limited (\(remaining)s)"]))
            return
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
                let headerVal = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Int($0) } ?? 120
                let retryAfter = max(headerVal, 60)  // minimum 60s backoff
                retryAfterUntil = Date().addingTimeInterval(TimeInterval(retryAfter))
                NSLog("[API] 429 Rate Limited - backing off %d sec (header: %d)", retryAfter, headerVal)
                completion(nil, 429, NSError(domain: "API", code: 429,
                    userInfo: [NSLocalizedDescriptionKey: "Rate limited (\(retryAfter)s)"]))
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
        usleep(100_000)  // 100ms settle time

        // Notify listener so an immediate poll can be triggered
        DispatchQueue.main.async { [weak self] in
            self?.onConnect?()
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
        // When a USB serial device connects, immediately fetch & send fresh data
        serialPort.onConnect = { [weak self] in
            NSLog("[Monitor] Serial connected — triggering immediate poll")
            self?.poll()
        }
        serialPort.startScanning()
        poll()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        serialPort.stopScanning()
    }

    func scheduleTimer() {
        timer?.invalidate()

        // Align to next full minute so displayTime updates on the dot
        let now = Date()
        let calendar = Calendar.current
        let seconds = calendar.component(.second, from: now)
        let fireDate = now.addingTimeInterval(TimeInterval(60 - seconds))

        timer = Timer(fire: fireDate, interval: kPollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    /// Manual refresh with minimum interval enforcement
    func manualRefresh() {
        if let lastPoll = lastPollDate {
            let elapsed = Date().timeIntervalSince(lastPoll)
            if elapsed < kMinPollInterval {
                let remaining = Int(kMinPollInterval - elapsed)
                NSLog("[Monitor] Manual refresh blocked - %d sec cooldown remaining", remaining)
                lastError = "Bitte \(remaining)s warten"
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }
        }
        poll()
    }

    func poll() {
        lastPollDate = Date()

        // 1. Read token
        guard let token = KeychainReader.readAccessToken() else {
            lastError = "Kein Token im Keychain"
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
                                    self.lastError = "Token abgelaufen - Claude Code oeffnen"
                                    self.status = .tokenExpired
                                    DispatchQueue.main.async { self.onUpdate?() }
                                }
                            }
                            return
                        }
                    }
                    self.lastError = "Token abgelaufen - Claude Code oeffnen"
                    self.status = .tokenExpired
                    DispatchQueue.main.async { self.onUpdate?() }
                    return
                } else {
                    self.lastError = "Token abgelaufen - Claude Code oeffnen"
                    self.status = .tokenExpired
                    DispatchQueue.main.async { self.onUpdate?() }
                    return
                }
            }

            if let statusCode = statusCode, statusCode == 429 {
                self.status = .rateLimited
                self.lastError = "Rate-limited (\(ClaudeAPI.rateLimitRemaining)s)"
                // Still send cached data with current time to keep display clock alive
                self.resendCachedData()
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }

            if let error = error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain {
                    self.status = .offline
                    self.lastError = "Offline"
                } else if let statusCode = statusCode, statusCode >= 500 {
                    self.status = .error
                    self.lastError = "Server-Fehler (\(statusCode))"
                } else {
                    self.status = .error
                    self.lastError = error.localizedDescription
                }
                DispatchQueue.main.async { self.onUpdate?() }
                return
            }

            guard let usage = usage else {
                self.lastError = "Keine Daten"
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

    private func sendToESP32(usage: UsageResponse) {
        guard serialPort.isConnected else { return }

        // API returns utilization as percentage (0-100), not fraction (0-1)
        let primaryPercent = Int(round(usage.five_hour?.utilization ?? 0))
        let secondaryPercent = Int(round(usage.seven_day?.utilization ?? 0))
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

    // Menu item tags
    let kTagTitle = 10
    let kTagSession = 100
    let kTagWeekly = 101
    let kTagPlan = 102
    let kTagDisplay = 103
    let kTagLastUpdate = 104
    let kTagRefresh = 105

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

        NSLog("[App] AI Monitor v%@ started - polling every %.0fs", kAppVersion, kPollInterval)
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

        if let usage = usage, status == .ok {
            let sp = Int(round(usage.five_hour?.utilization ?? 0))
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

        // Title
        let titleItem = NSMenuItem(title: "AI Monitor v\(kAppVersion)", action: nil, keyEquivalent: "")
        titleItem.tag = kTagTitle
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Session
        let sessionItem = NSMenuItem(title: "Session: --", action: nil, keyEquivalent: "")
        sessionItem.tag = kTagSession
        sessionItem.isEnabled = false
        menu.addItem(sessionItem)

        // Weekly
        let weeklyItem = NSMenuItem(title: "Weekly:  --", action: nil, keyEquivalent: "")
        weeklyItem.tag = kTagWeekly
        weeklyItem.isEnabled = false
        menu.addItem(weeklyItem)

        // Plan
        let planItem = NSMenuItem(title: "Plan:    --", action: nil, keyEquivalent: "")
        planItem.tag = kTagPlan
        planItem.isEnabled = false
        menu.addItem(planItem)

        menu.addItem(NSMenuItem.separator())

        // Display status
        let displayItem = NSMenuItem(title: "Display: -- Nicht verbunden", action: nil, keyEquivalent: "")
        displayItem.tag = kTagDisplay
        displayItem.isEnabled = false
        menu.addItem(displayItem)

        // Last update
        let updateItem = NSMenuItem(title: "Letztes Update: --", action: nil, keyEquivalent: "")
        updateItem.tag = kTagLastUpdate
        updateItem.isEnabled = false
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        // Refresh
        let refreshItem = NSMenuItem(title: "Jetzt aktualisieren", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.tag = kTagRefresh
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        // Launch at login
        let loginItem = NSMenuItem(title: "Bei Login starten", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.state = Settings.shared.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // About
        menu.addItem(withTitle: "Ueber AI Monitor", action: #selector(showAbout), keyEquivalent: "")

        // Quit
        menu.addItem(withTitle: "Beenden", action: #selector(quit), keyEquivalent: "q")

        statusItem.menu = menu
    }

    // ---- Menu Update ----

    func updateMenu() {
        guard let menu = statusItem.menu else { return }

        updateMenubarTitle(status: monitor.status, usage: monitor.lastUsage)

        if let usage = monitor.lastUsage {
            let sp = Int(round(usage.five_hour?.utilization ?? 0))
            let wp = Int(round(usage.seven_day?.utilization ?? 0))

            let sessionReset = formatCountdown(usage.five_hour?.resets_at)
            let weeklyReset = formatCountdown(usage.seven_day?.resets_at)

            let sessionText = sessionReset.isEmpty ? "Session: \(sp)%" : "Session: \(sp)%  (Reset \(sessionReset))"
            let weeklyText = weeklyReset.isEmpty ? "Weekly:  \(wp)%" : "Weekly:  \(wp)%  (Reset \(weeklyReset))"

            menu.item(withTag: kTagSession)?.title = sessionText
            menu.item(withTag: kTagWeekly)?.title = weeklyText

            // Plan info
            if let extra = usage.extra_usage {
                // API returns costs in cents
                let used = (extra.used_credits ?? 0) / 100.0
                let limit = (extra.monthly_limit ?? 0) / 100.0
                menu.item(withTag: kTagPlan)?.title = "Plan:    Claude Max ($\(formatCurrency(used))/$\(formatCurrency(limit)))"
            } else {
                menu.item(withTag: kTagPlan)?.title = "Plan:    Claude Pro"
            }
        }

        if let error = monitor.lastError {
            if monitor.status == .rateLimited {
                let remaining = ClaudeAPI.rateLimitRemaining
                let minutes = remaining / 60
                menu.item(withTag: kTagSession)?.title = "Rate-limited (\(minutes)m verbleibend)"
            } else if monitor.lastUsage == nil {
                menu.item(withTag: kTagSession)?.title = "Fehler: \(error)"
            }
        }

        // Display status
        if monitor.serialPort.isConnected, let port = monitor.serialPort.connectedPort {
            let shortPort = (port as NSString).lastPathComponent
            menu.item(withTag: kTagDisplay)?.title = "Display: \u{25CF} Verbunden (\(shortPort))"
        } else {
            menu.item(withTag: kTagDisplay)?.title = "Display: \u{25CB} Nicht verbunden"
        }

        // Last update
        if let lastUpdate = monitor.lastUpdateDate {
            let elapsed = Int(Date().timeIntervalSince(lastUpdate))
            let text: String
            if elapsed < 60 {
                text = "vor \(elapsed)s"
            } else {
                text = "vor \(elapsed / 60)m"
            }
            menu.item(withTag: kTagLastUpdate)?.title = "Letztes Update: \(text)"
        }

        // Update launch at login checkmark
        if let loginItem = menu.items.first(where: { $0.title == "Bei Login starten" }) {
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

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "AI Monitor v\(kAppVersion)"
        alert.informativeText = "macOS Menubar App fuer ESP32 AI Usage Monitor Display.\n\nLiest Claude OAuth Usage und sendet Daten per USB-Serial an das ESP32 Display."
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
