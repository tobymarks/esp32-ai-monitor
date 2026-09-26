/**
 * Display plugins for the native Mac companion. Validation, HTTPS data access
 * and scene building run through the bundled aimonitor-plugin-host binary so
 * both desktop apps use the same public package contract.
 */

import Foundation

struct DisplayPluginRecord {
    let packageURL: URL
    var generation = UUID()
    var info: [String: Any]
    var settings: [String: Any]
    var scenes: [String: [String: Any]] = [:]
    var fetchedAt: Date?
    var lastAttempt: Date?
    var error: String?
}

final class DisplayPlugins {
    static let shared = DisplayPlugins()
    static let prefix = "plugin:"
    private(set) var records: [String: DisplayPluginRecord] = [:]
    var onChange: (() -> Void)?
    private var fetching = Set<String>()

    private let root: URL

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
        return records[id]?.info["viewLabel"] as? String ?? id
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
    static func helper(_ arguments: [String]) throws -> [String: Any] {
        guard let binary = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("aimonitor-plugin-host"),
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw failure("Plugin helper is missing from the application bundle")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
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
        record.lastAttempt = nil
        record.fetchedAt = nil
        record.error = nil
        records[id] = record
        onChange?()
    }

    func remove(id: String) throws {
        guard let record = records[id] else { throw Self.failure("Plugin is not installed") }
        try FileManager.default.removeItem(at: record.packageURL)
        try? FileManager.default.removeItem(at: settingsPath(id))
        records.removeValue(forKey: id)
        onChange?()
    }

    func refresh(views: [String]) {
        for id in Set(views.compactMap(Self.id(from:))) {
            guard var record = records[id] else { continue }
            guard !fetching.contains(id) else { continue }
            let interval = TimeInterval(record.info["intervalSeconds"] as? Int ?? 900)
            let now = Date()
            let retryAfter = record.error == nil ? interval : min(interval, 60)
            if let attempt = record.lastAttempt, now.timeIntervalSince(attempt) < retryAfter { continue }
            record.lastAttempt = now
            records[id] = record
            fetching.insert(id)
            let package = record.packageURL.path
            let settings = settingsPath(id).path
            let generation = record.generation
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try Self.helper(["render", package, settings, "all"]) }
                DispatchQueue.main.async {
                    self.fetching.remove(id)
                    guard var current = self.records[id], current.packageURL.path == package,
                          current.generation == generation else { return }
                    switch result {
                    case .success(let response):
                        if let scenes = response["scenes"] as? [String: [String: Any]],
                           scenes["portrait"] != nil, scenes["landscape"] != nil,
                           scenes["square"] != nil {
                            current.scenes = scenes
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
                }
            }
        }
    }

    func scene(for id: String, layout: String) -> [String: Any] {
        guard let record = records[id] else {
            return Self.statusScene("Plugin missing", "Install this plugin in Settings")
        }
        let title = record.info["viewLabel"] as? String ?? "Plugin"
        if record.error != nil { return Self.statusScene(title, "Data unavailable") }
        guard let scene = record.scenes[layout], let fetched = record.fetchedAt else {
            return Self.statusScene(title, "Loading data...")
        }
        let interval = TimeInterval(record.info["intervalSeconds"] as? Int ?? 900)
        if Date().timeIntervalSince(fetched) > interval * 3 {
            return Self.statusScene(title, "Data stale - waiting for update")
        }
        return scene
    }

    static func statusScene(_ title: String, _ message: String) -> [String: Any] {
        ["background": 1580575, "nodes": [
            ["type": "text", "x": 50, "y": 75, "w": 900, "h": 120,
             "color": 16777215, "font": 24, "text": String(title.prefix(40))],
            ["type": "rect", "x": 50, "y": 210, "w": 900, "h": 3,
             "color": 3717119],
            ["type": "text", "x": 50, "y": 300, "w": 900, "h": 180,
             "color": 11250603, "font": 16, "text": String(message.prefix(60))]
        ]]
    }
}
