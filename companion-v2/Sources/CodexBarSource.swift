/**
 * CodexBarSource.swift — Liest AI-Provider-Usage-Daten aus der lokalen CodexBar-App.
 *
 * Ab v1.10.0 provider-parametrisiert: unterstützt Claude, Codex und Antigravity. Der
 * aktive Provider wird über `provider` im Init/setProvider gesetzt (UserDefaults
 * „selectedProvider"). Das Schema ist strukturell identisch zwischen den Providern
 * im widget-snapshot.json (primary/secondary mit usedPercent/resetsAt/
 * windowMinutes). In der history/-Ablage können Provider abweichen: Daten liegen teils unter
 * `accounts[<key>]` statt `unscoped[]` — für den Schema-Versions-Check reicht
 * uns aber das `version`-Feld der entsprechenden History-Datei.
 *
 * Datenquelle (beide Provider):
 *  ~/Library/Group Containers/<container>.com.steipete.codexbar/widget-snapshot.json
 *  → entries[] mit `provider`-Feld („claude" / „codex" / „antigravity")
 *  (ab CodexBar 0.22 kann der Container Team-ID-präfixiert sein, z.B.
 *   Y5PE65HELJ.com.steipete.codexbar)
 *
 * Schema-Check:
 *  ~/Library/Application Support/com.steipete.codexbar/history/{claude,codex,antigravity}.json
 *  → `version`-Feld (aktuell 1).
 *
 * Design:
 *  - Pull-Strategie: alle 30 s laden. Zusätzlich über DispatchSource-FileMonitor
 *    reagieren, wenn CodexBar schreibt (sub-sekündliche Latenz).
 *  - Stale-Check: wenn `updatedAt` (bzw. `generatedAt`) > 15 min alt -> Fehler,
 *    ESP32 bekommt nichts Neues, UI zeigt „stale" im Settings-Fenster.
 *  - Schema-Check: wenn history-Datei `version` != kExpectedHistoryVersion ->
 *    Fehler „wrong version".
 */

import Foundation

enum CodexBarProvider: String, CaseIterable {
    case claude
    case codex
    case antigravity

    static let defaultProvider: CodexBarProvider = .claude

    static func normalized(_ raw: String) -> CodexBarProvider {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CodexBarProvider(rawValue: cleaned) ?? defaultProvider
    }

    static func fromSegment(index: Int) -> CodexBarProvider {
        guard index >= 0 && index < allCases.count else { return defaultProvider }
        return allCases[index]
    }

    var segmentIndex: Int {
        CodexBarProvider.allCases.firstIndex(of: self) ?? 0
    }

    var displayLabel: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .antigravity:
            return "Antigravity"
        }
    }

    var loginLabel: String {
        switch self {
        case .claude:
            return "Claude Max"
        case .codex:
            return "Codex"
        case .antigravity:
            return "Antigravity"
        }
    }
}

// MARK: - Status-Enum

enum CodexBarStatus: Equatable {
    case ok
    case stale(ageSeconds: Int)
    case missing                // Datei existiert nicht (CodexBar nicht installiert / nie gelaufen)
    case wrongVersion(found: Int, expected: Int)
    case parseError(String)
    case notYet                 // Initialzustand vor dem ersten Laden

    var shortLabel: String {
        switch self {
        case .ok: return "OK"
        case .stale(let ageSec):
            let m = ageSec / 60
            return "stale (\(m)m alt)"
        case .missing: return "missing"
        case .wrongVersion(let f, let e): return "wrong version (\(f) != \(e))"
        case .parseError: return "parse error"
        case .notYet: return "…"
        }
    }

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

// MARK: - Datenmodelle (widget-snapshot.json)

struct CodexBarWindow: Codable {
    let usedPercent: Double
    let resetsAt: String?
    let resetDescription: String?
    let windowMinutes: Int?
}

struct CodexBarEntry: Codable {
    let provider: String?
    let updatedAt: String?
    let primary: CodexBarWindow?
    let secondary: CodexBarWindow?
    let tertiary: CodexBarWindow?
}

struct CodexBarSnapshot: Codable {
    let generatedAt: String?
    let enabledProviders: [String]?
    let entries: [CodexBarEntry]?
}

struct CodexBarHistoryHeader: Codable {
    let version: Int?
}

// MARK: - Source

final class CodexBarSource {

    /// Erwartete Schema-Version der history/{provider}.json. Wenn CodexBar auf 2
    /// wechselt, hier ebenfalls anpassen — bis dahin: Fehlermeldung im Settings-
    /// Fenster.
    static let kExpectedHistoryVersion = 1

    /// Stale-Schwelle — > 15 min Alter heisst: App sendet nichts Neues mehr.
    static let kStaleThresholdSeconds: TimeInterval = 15 * 60

    /// Poll-Intervall fürs zyklische Neueinlesen.
    static let kPollInterval: TimeInterval = 30

    // Pfade
    static let groupContainersRootPath = NSString("~/Library/Group Containers").expandingTildeInPath
    static let legacyWidgetSnapshotPath = NSString("~/Library/Group Containers/group.com.steipete.codexbar/widget-snapshot.json").expandingTildeInPath
    static let historyDirectoryPath = NSString("~/Library/Application Support/com.steipete.codexbar/history").expandingTildeInPath

    /// Aktiver Provider („claude" | „codex" | „antigravity"). Darf zur Laufzeit über
    /// `setProvider(_:)` gewechselt werden — anschliessend `loadOnce()` aufrufen
    /// (macht `setProvider` automatisch).
    private(set) var provider: String

    // State
    private(set) var status: CodexBarStatus = .notYet
    private(set) var lastEntry: CodexBarEntry?
    private(set) var lastLoadedAt: Date?
    private(set) var lastSnapshotGeneratedAt: Date?

    /// Wird aufgerufen, sobald neue Daten geladen wurden (status + lastEntry aktualisiert).
    var onChange: (() -> Void)?

    private var pollTimer: Timer?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var watchedSnapshotPath: String?

    // MARK: - Init / Lifecycle

    init(provider: String = CodexBarProvider.defaultProvider.rawValue) {
        self.provider = Self.normalizeProvider(provider)
    }

    /// Provider zur Laufzeit wechseln. Triggert ein sofortiges Re-Load, damit
    /// der nächste `onChange`-Tick schon den neuen Provider liefert.
    func setProvider(_ newProvider: String) {
        let norm = Self.normalizeProvider(newProvider)
        if norm == provider { return }
        provider = norm
        NSLog("[CodexBar] Provider switched to '%@'", norm)
        loadOnce()
    }

    private static func normalizeProvider(_ raw: String) -> String {
        return CodexBarProvider.normalized(raw).rawValue
    }

    /// Pfad der History-Datei für den aktiven Provider (Schema-Version).
    private func historyFilePath() -> String {
        return (Self.historyDirectoryPath as NSString).appendingPathComponent("\(provider).json")
    }

    func start() {
        loadOnce()
        schedulePoll()
        startFileWatch()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopFileWatch()
    }

    // MARK: - Pull

    @discardableResult
    func loadOnce() -> CodexBarStatus {
        lastLoadedAt = Date()

        // 1. Schema-Version aus history/{provider}.json prüfen
        if let header = readHistoryHeader() {
            if let v = header.version, v != Self.kExpectedHistoryVersion {
                status = .wrongVersion(found: v, expected: Self.kExpectedHistoryVersion)
                NSLog("[CodexBar] Wrong schema version in %@.json: %d (expected %d)", provider, v, Self.kExpectedHistoryVersion)
                notify()
                return status
            }
        }
        // kein else: wenn die History-Datei noch nicht existiert (frischer Install /
        // Provider noch nie genutzt), ist das nicht zwingend ein Fehler. Widget-
        // Snapshot entscheidet.

        // 2. widget-snapshot.json laden
        guard let snapshotPath = resolveWidgetSnapshotPath(),
              let data = FileManager.default.contents(atPath: snapshotPath) else {
            status = .missing
            lastEntry = nil
            NSLog("[CodexBar] widget-snapshot.json not found in Group Containers")
            notify()
            return status
        }
        if watchedSnapshotPath != snapshotPath {
            startFileWatch()
        }

        let snapshot: CodexBarSnapshot
        do {
            snapshot = try JSONDecoder().decode(CodexBarSnapshot.self, from: data)
        } catch {
            status = .parseError(error.localizedDescription)
            NSLog("[CodexBar] Parse error: %@", error.localizedDescription)
            notify()
            return status
        }

        // generatedAt -> Date (für stale-check)
        let genDate = snapshot.generatedAt.flatMap { parseISO8601($0) }
        lastSnapshotGeneratedAt = genDate

        // Entry für aktiven Provider suchen
        let providerEntry = snapshot.entries?.first(where: { ($0.provider ?? "").lowercased() == provider })
        if providerEntry == nil {
            // Provider nicht im Snapshot — explizit missing (CodexBar schreibt ihn
            // erst, wenn der Provider dort aktiv ist).
            lastEntry = nil
            status = .missing
            NSLog("[CodexBar] No entry for provider '%@' in snapshot", provider)
            notify()
            return status
        }
        lastEntry = providerEntry

        // Alter bestimmen — bevorzugt updatedAt des Entries, sonst generatedAt
        let ageRef: Date? = {
            if let s = providerEntry?.updatedAt, let d = parseISO8601(s) { return d }
            return genDate
        }()

        if let ref = ageRef {
            let age = Date().timeIntervalSince(ref)
            if age > Self.kStaleThresholdSeconds {
                status = .stale(ageSeconds: Int(age))
                NSLog("[CodexBar] Stale snapshot (%@): %.0f min old", provider, age / 60)
                notify()
                return status
            }
        } else {
            // Kein Zeitstempel - behandeln wir defensiv als stale, damit wir nicht blindlings senden.
            status = .stale(ageSeconds: Int.max)
            NSLog("[CodexBar] Snapshot has no updatedAt/generatedAt — treating as stale")
            notify()
            return status
        }

        status = .ok
        notify()
        return status
    }

    private func readHistoryHeader() -> CodexBarHistoryHeader? {
        let path = historyFilePath()
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(CodexBarHistoryHeader.self, from: data)
        } catch {
            NSLog("[CodexBar] Could not parse %@ header: %@", path, error.localizedDescription)
            return nil
        }
    }

    // MARK: - Poll-Timer

    private func schedulePoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.kPollInterval, repeats: true) { [weak self] _ in
            self?.loadOnce()
        }
    }

    // MARK: - FileSystem-Watch

    private func startFileWatch() {
        stopFileWatch()

        guard let path = resolveWidgetSnapshotPath() else {
            // Datei existiert nicht — wir probieren beim nächsten Poll erneut.
            return
        }
        let fd = open(path, O_EVTONLY)
        if fd < 0 {
            // Datei existiert nicht — wir probieren beim nächsten Poll erneut.
            return
        }
        watchedFD = fd
        watchedSnapshotPath = path

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Wenn die Datei ersetzt wurde (rename/delete), Watch neu anlegen.
            let data = src.data
            if data.contains(.delete) || data.contains(.rename) {
                self.stopFileWatch()
                // Kurz verzoegert neu aufsetzen, CodexBar schreibt meist per rename-swap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.loadOnce()
                    self.startFileWatch()
                }
                return
            }
            self.loadOnce()
        }
        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.watchedFD >= 0 {
                close(self.watchedFD)
                self.watchedFD = -1
            }
            self.watchedSnapshotPath = nil
        }
        src.resume()
        fileWatcher = src
    }

    private func stopFileWatch() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    /// Sucht den aktuellsten vorhandenen widget-snapshot.json-Pfad in allen
    /// CodexBar-Group-Containern (legacy + Team-ID-präfixierte Varianten).
    private func resolveWidgetSnapshotPath() -> String? {
        var candidates = [String]()
        candidates.append(Self.legacyWidgetSnapshotPath)

        let fm = FileManager.default
        if let containerNames = try? fm.contentsOfDirectory(atPath: Self.groupContainersRootPath) {
            for name in containerNames where name.hasSuffix(".com.steipete.codexbar") {
                let path = (Self.groupContainersRootPath as NSString)
                    .appendingPathComponent(name)
                let snapshot = (path as NSString).appendingPathComponent("widget-snapshot.json")
                candidates.append(snapshot)
            }
        }

        let existing = Array(Set(candidates)).filter { fm.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }

        var newestPath: String?
        var newestDate = Date.distantPast
        for path in existing {
            let attrs = try? fm.attributesOfItem(atPath: path)
            let mtime = attrs?[.modificationDate] as? Date ?? Date.distantPast
            if mtime >= newestDate {
                newestDate = mtime
                newestPath = path
            }
        }
        return newestPath
    }

    // MARK: - Helpers

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    private func parseISO8601(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
