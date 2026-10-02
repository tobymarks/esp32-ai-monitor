/**
 * Display plugins for the native Mac companion. Validation, HTTPS data access
 * and scene building run through the bundled aimonitor-plugin-host binary so
 * both desktop apps use the same public package contract.
 */

import AppKit
import Foundation

struct DisplayPluginRecord {
    let packageURL: URL
    var generation = UUID()
    var info: [String: Any]
    var settings: [String: Any]
    var scenes: [String: [String: Any]] = [:]
    var attention: [String: Bool] = [:]
    var hasAttentionBaseline = false
    var firedAttention = false
    var fetchedAt: Date?
    var lastAttempt: Date?
    var error: String?
    var sceneLocale: String?
    var sceneTheme: String?
}

final class DisplayPlugins {
    static let shared = DisplayPlugins()
    static let prefix = "plugin:"
    private(set) var records: [String: DisplayPluginRecord] = [:]
    var onChange: (() -> Void)?
    private var fetching = Set<String>()
    private var attentionResets = Set<String>()

    private let root: URL

    static func localized(_ source: String, info: [String: Any], locale: String? = nil) -> String {
        let locale = locale ?? (Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true ? "de" : "en")
        let dictionaries = info["localizations"] as? [String: [String: String]]
        return dictionaries?[locale]?[source] ?? source
    }

    static func resolvedTheme() -> String {
        switch Settings.shared.themeMode {
        case "dark": return "dark"
        case "light": return "light"
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? "dark" : "light"
        }
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        root = support.appendingPathComponent("de.aimonitor.companion/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        loadInstalled()
    }

    static func id(from view: String) -> String? {
        guard view.hasPrefix(prefix) else { return nil }
        let id = String(view.dropFirst(prefix.count))
        guard !id.isEmpty, id.utf8.count <= 40,
              id.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
                                   || $0 == 46 || $0 == 45 || $0 == 95 }) else { return nil }
        return id
    }

    func label(for view: String) -> String {
        guard let id = Self.id(from: view) else { return view }
        if id == ClaudeCodeWindow.viewID { return ClaudeCodeWindow.label }
        guard let info = records[id]?.info else { return id }
        return Self.localized(info["viewLabel"] as? String ?? id, info: info)
    }

    private func packagePath(_ id: String) -> URL {
        root.appendingPathComponent("\(id).aimplugin")
    }

    private func settingsPath(_ id: String) -> URL {
        root.appendingPathComponent("\(id).settings.json")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DisplayPlugins", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// The helper is first-party code signed together with the app. Every
    /// package is checked before activation; this never executes plugin code.
    static func helper(_ arguments: [String], environment: [String: String] = [:]) throws -> [String: Any] {
        guard let binary = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("aimonitor-plugin-host"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw failure("Plugin helper is missing from the application bundle")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let output = Pipe()
        // Drain both streams while the helper runs. A separate stderr pipe
        // can fill up on a malformed package and deadlock before stdout EOF.
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let detail = String(decoding: bytes.prefix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw failure(detail.isEmpty ? "Plugin helper failed" : String(detail.prefix(200)))
        }
        guard bytes.count <= 64 * 1024,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw failure("Invalid plugin helper response")
        }
        return object
    }

    private func loadInstalled() {
        let previous = (try? FileManager.default.contentsOfDirectory(at: root,
                           includingPropertiesForKeys: nil)) ?? []
        for backup in previous where backup.lastPathComponent.hasPrefix(".")
            && backup.lastPathComponent.hasSuffix(".previous") {
            let name = String(backup.lastPathComponent.dropFirst().dropLast(".previous".count))
            guard Self.id(from: Self.prefix + name) != nil else { continue }
            let target = packagePath(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: backup, to: target)
            }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: root,
                          includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "aimplugin" {
            guard let info = try? Self.helper(["inspect", file.path]),
                  let id = info["id"] as? String,
                  file.deletingPathExtension().lastPathComponent == id else { continue }
            let defaults = info["settings"] as? [String: Any] ?? [:]
            let saved = (try? Data(contentsOf: settingsPath(id))).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? defaults
            var settings = defaults
            for key in defaults.keys { if let value = saved[key] { settings[key] = value } }
            let check = root.appendingPathComponent(".settings-check-\(UUID().uuidString)")
            if let bytes = try? JSONSerialization.data(withJSONObject: settings) {
                try? bytes.write(to: check)
                if (try? Self.helper(["validate-settings", file.path, check.path])) == nil {
                    settings = defaults
                }
            }
            try? FileManager.default.removeItem(at: check)
            if let bytes = try? JSONSerialization.data(withJSONObject: settings) {
                try? bytes.write(to: settingsPath(id), options: .atomic)
            }
            records[id] = DisplayPluginRecord(packageURL: file, info: info, settings: settings)
        }
    }

    /// Inspect a local file or an HTTPS release asset without activating it.
    func inspect(source: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if source.lowercased().hasPrefix("https://") {
                    let temp = root.appendingPathComponent(".preview-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temp) }
                    let info = try Self.helper(["download", source, temp.path])
                    DispatchQueue.main.async { completion(.success(info)) }
                } else if source.contains("://") {
                    throw Self.failure("Only HTTPS plugin links are supported")
                } else {
                    let info = try Self.helper(["inspect", source])
                    DispatchQueue.main.async { completion(.success(info)) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func install(source: String, expectedSHA256: String,
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let root = self.root
        let installedIDs = Set(records.keys)
        DispatchQueue.global(qos: .userInitiated).async {
            let staged = root.appendingPathComponent(".install-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staged) }
            do {
                if source.lowercased().hasPrefix("https://") {
                    _ = try Self.helper(["download", source, staged.path])
                } else if source.contains("://") {
                    throw Self.failure("Only HTTPS plugin links are supported")
                } else {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: staged)
                }
                let info = try Self.helper(["inspect", staged.path])
                guard let hash = info["sha256"] as? String, hash == expectedSHA256,
                      let id = info["id"] as? String, Self.id(from: Self.prefix + id) != nil else {
                    throw Self.failure("Plugin changed since inspection")
                }
                if !installedIDs.contains(id) && installedIDs.count >= 20 {
                    throw Self.failure("Plugin limit reached")
                }
                let target = root.appendingPathComponent("\(id).aimplugin")
                let backup = root.appendingPathComponent(".\(id).previous")
                let defaults = info["settings"] as? [String: Any] ?? [:]
                let settingsFile = root.appendingPathComponent("\(id).settings.json")
                let saved = (try? Data(contentsOf: settingsFile)).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? defaults
                var settings = defaults
                for key in defaults.keys { if let value = saved[key] { settings[key] = value } }
                let serialized = try JSONSerialization.data(withJSONObject: settings)
                let check = root.appendingPathComponent(".settings-check-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: check) }
                try serialized.write(to: check)
                do {
                    _ = try Self.helper(["validate-settings", staged.path, check.path])
                } catch {
                    settings = defaults
                }
                let settingsData = try JSONSerialization.data(withJSONObject: settings)
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: backup)
                    try FileManager.default.moveItem(at: target, to: backup)
                }
                do {
                    try FileManager.default.moveItem(at: staged, to: target)
                    try settingsData.write(to: settingsFile, options: .atomic)
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    if FileManager.default.fileExists(atPath: backup.path) {
                        try? FileManager.default.moveItem(at: backup, to: target)
                    }
                    throw error
                }
                try? FileManager.default.removeItem(at: backup)
                DispatchQueue.main.async {
                    self.records[id] = DisplayPluginRecord(packageURL: target, info: info,
                                                           settings: settings)
                    self.attentionResets.insert(id)
                    self.onChange?()
                    completion(.success(info))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func saveSettings(id: String, values: [String: Any]) throws {
        guard var record = records[id] else { throw Self.failure("Plugin is not installed") }
        let target = settingsPath(id)
        let staged = root.appendingPathComponent(".settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        let bytes = try JSONSerialization.data(withJSONObject: values)
        try bytes.write(to: staged)
        _ = try Self.helper(["validate-settings", record.packageURL.path, staged.path])
        try bytes.write(to: target, options: .atomic)
        record.settings = values
        record.generation = UUID()
        record.scenes.removeAll()
        record.attention.removeAll()
        record.hasAttentionBaseline = false
        record.firedAttention = false
        record.lastAttempt = nil
        record.fetchedAt = nil
        record.error = nil
        records[id] = record
        attentionResets.insert(id)
        onChange?()
    }

    func remove(id: String) throws {
        guard let record = records[id] else { throw Self.failure("Plugin is not installed") }
        try FileManager.default.removeItem(at: record.packageURL)
        try? FileManager.default.removeItem(at: settingsPath(id))
        records.removeValue(forKey: id)
        attentionResets.insert(id)
        onChange?()
    }

    func refresh(views: [String]) {
        let locale = Settings.shared.language == "en" ? "en" : "de"
        let theme = Self.resolvedTheme()
        for id in Set(views.compactMap(Self.id(from:))) {
            guard var record = records[id] else { continue }
            guard !fetching.contains(id) else { continue }
            let interval = TimeInterval(record.info["intervalSeconds"] as? Int ?? 900)
            let now = Date()
            let retryAfter = record.error == nil ? interval : min(interval, 60)
            // Nur fertige Szenen ohne Fehler sofort neu rendern. Nach Fehlern
            // gilt die Wartezeit, sonst kann onChange eine Abrufschleife auslösen.
            let sceneChanged = record.error == nil && record.fetchedAt != nil &&
                record.sceneLocale != nil && record.sceneTheme != nil &&
                (record.sceneLocale != locale || record.sceneTheme != theme)
            if !sceneChanged,
               let attempt = record.lastAttempt, now.timeIntervalSince(attempt) < retryAfter { continue }
            record.lastAttempt = now
            records[id] = record
            fetching.insert(id)
            let package = record.packageURL.path
            let settings = settingsPath(id).path
            let generation = record.generation
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try Self.helper(["render", package, settings, "all",
                                                        "--theme=\(theme)", "--locale=\(locale)"]) }
                DispatchQueue.main.async {
                    self.fetching.remove(id)
                    guard var current = self.records[id], current.packageURL.path == package,
                          current.generation == generation else { return }
                    switch result {
                    case .success(let response):
                        if let scenes = response["scenes"] as? [String: [String: Any]],
                           scenes["portrait"] != nil, scenes["landscape"] != nil,
                           scenes["square"] != nil {
                            let attention = response["attention"] as? [String: Bool] ?? [:]
                            let previousAttention = current.attention
                            let interval = TimeInterval(current.info["intervalSeconds"] as? Int ?? 900)
                            let recentBaseline = current.fetchedAt.map {
                                Date().timeIntervalSince($0) <= 3 * interval
                            } ?? false
                            current.firedAttention = current.hasAttentionBaseline && recentBaseline &&
                                attention.contains { $0.value && previousAttention[$0.key] != true }
                            current.attention = attention
                            current.hasAttentionBaseline = true
                            current.scenes = scenes
                            current.sceneLocale = locale
                            current.sceneTheme = theme
                            current.fetchedAt = Date()
                            current.error = nil
                        } else {
                            current.error = "Invalid plugin scenes"
                        }
                    case .failure(let error):
                        current.error = String(error.localizedDescription.prefix(60))
                    }
                    self.records[id] = current
                    self.onChange?()
                    if Self.resolvedTheme() != theme ||
                       (Settings.shared.language == "en" ? "en" : "de") != locale {
                        self.refresh(views: Settings.shared.displayViews)
                    }
                }
            }
        }
    }

    func resetAttentionBaseline(for ids: Set<String>) {
        for id in ids {
            guard var record = records[id] else { continue }
            record.attention.removeAll()
            record.hasAttentionBaseline = false
            record.firedAttention = false
            record.lastAttempt = nil
            records[id] = record
        }
    }

    func takeAttentionResets() -> Set<String> {
        let ids = attentionResets
        attentionResets.removeAll()
        return ids
    }

    func takeAttentionEvents() -> Set<String> {
        var fired = Set<String>()
        for id in Array(records.keys) {
            guard var record = records[id], record.firedAttention else { continue }
            fired.insert(id)
            record.firedAttention = false
            records[id] = record
        }
        return fired
    }

    func scene(for id: String, layout: String, language: String) -> [String: Any] {
        let theme = Self.resolvedTheme()
        let text = { (key: String) in Self.statusText(key, language: language) }
        guard let record = records[id] else {
            return Self.statusScene(text("missing"), text("missing.hint"), theme: theme)
        }
        let title = Self.localized(record.info["viewLabel"] as? String ?? "Plugin", info: record.info, locale: language)
        if record.error != nil { return Self.statusScene(title, text("unavailable"), theme: theme) }
        // Bei einem Theme- oder Sprachwechsel die vorhandene Szene bis zur neuen Antwort stehen lassen.
        guard let scene = record.scenes[layout], let fetched = record.fetchedAt else {
            return Self.statusScene(title, text("loading"), theme: theme)
        }
        let interval = TimeInterval(record.info["intervalSeconds"] as? Int ?? 900)
        if Date().timeIntervalSince(fetched) > interval * 3 {
            return Self.statusScene(title, text("stale"), theme: theme)
        }
        return scene
    }

    /// Statustexte in der Sprache des Displays. Die Firmware nimmt in Szenen
    /// nur druckbares ASCII an, deshalb stehen die deutschen Texte ohne Umlaute.
    static func statusText(_ key: String, language: String) -> String {
        let de = language == "de"
        switch key {
        case "missing":      return de ? "Plugin fehlt" : "Plugin missing"
        case "missing.hint": return de ? "Plugin in den Einstellungen installieren" : "Install this plugin in Settings"
        case "unavailable":  return de ? "Daten nicht abrufbar" : "Data unavailable"
        case "loading":      return de ? "Lade Daten ..." : "Loading data..."
        case "stale":        return de ? "Daten veraltet - warte auf Update" : "Data stale - waiting for update"
        default:             return ""
        }
    }

    static func statusScene(_ title: String, _ message: String, theme: String) -> [String: Any] {
        let light = theme == "light"
        return ["background": light ? 0xF5F7FA : 1580575, "nodes": [
            ["type": "text", "x": 50, "y": 75, "w": 900, "h": 120,
             "color": light ? 0x17212F : 16777215, "font": 24, "text": String(title.prefix(40))],
            ["type": "rect", "x": 50, "y": 210, "w": 900, "h": 3,
             "color": light ? 0xD4DDE7 : 3717119],
            ["type": "text", "x": 50, "y": 300, "w": 900, "h": 180,
             "color": light ? 0x45566A : 11250603, "font": 16, "text": String(message.prefix(60))]
        ]]
    }
}
