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

    /// `true`, wenn der Provider drei feste Modell-Zeilen (IDs primary/secondary/
    /// tertiary) statt der generischen Session/Weekly/Tertiary-Fenster nutzt.
    /// Steuert den Row-Aufbau im Envelope. Neuer Provider dieser Art: hier ergänzen.
    var usesModelRows: Bool {
        switch self {
        case .antigravity: return true
        case .claude, .codex: return false
        }
    }

    /// Default-Titel je Zeilenindex; ein neuer Provider definiert seine Titel
    /// ausschliesslich hier statt in verstreuten switch-Bloecken.
    var defaultRowTitles: [String] {
        switch self {
        case .antigravity: return ["Claude", "Gemini Pro", "Gemini Flash"]
        case .claude, .codex: return ["Session", "Weekly", "Tertiary"]
        }
    }

    /// Titel fuer Zeilen jenseits von `defaultRowTitles`.
    var fallbackRowTitle: String {
        switch self {
        case .antigravity: return "Model"
        case .claude, .codex: return "Window"
        }
    }

    /// Default-Titel fuer einen konkreten Zeilenindex (mit Fallback).
    func defaultRowTitle(at index: Int) -> String {
        index >= 0 && index < defaultRowTitles.count ? defaultRowTitles[index] : fallbackRowTitle
    }
}

// MARK: - Status-Enum

enum CodexBarStatus: Equatable {
    case ok
    case accessNotConfigured    // User hat noch keine CodexBar-Snapshot-Datei ausgewaehlt
    case stale(ageSeconds: Int)
    case missing                // Datei existiert nicht (CodexBar nicht installiert / nie gelaufen)
    case wrongVersion(found: Int, expected: Int)
    case parseError(String)
    case notYet                 // Initialzustand vor dem ersten Laden

    var shortLabel: String {
        switch self {
        case .ok: return "OK"
        case .accessNotConfigured: return "Zugriff einrichten"
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

struct CodexBarUsageRow: Codable {
    let id: String?
    let title: String?
    let percentLeft: Double?
}

struct CodexBarEntry: Codable {
    let provider: String?
    let updatedAt: String?
    let primary: CodexBarWindow?
    let secondary: CodexBarWindow?
    let tertiary: CodexBarWindow?
    let usageRows: [CodexBarUsageRow]?
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
    private var securityScopedSnapshotURL: URL?
    private var isAccessingSecurityScopedSnapshot = false

    deinit {
        stop()
        stopSecurityScopedSnapshotAccess()
    }

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

        // Kein Bookmark-Guard mehr: Da die App nicht sandboxed ist, findet
        // resolveWidgetSnapshotPath() die aktuelle Datei per Auto-Discovery
        // (Bookmark/Legacy nur als Fallback). Wird gar nichts gefunden, ist
        // CodexBar nicht installiert/aktiv -> .missing.
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

    /// Durchsucht ~/Library/Group Containers nach allen CodexBar-Containern und
    /// gibt die NEUESTE widget-snapshot.json zurueck. CodexBar hat den Container
    /// schon einmal gewechselt (group.com.steipete.codexbar ->
    /// Y5PE65HELJ.com.steipete.codexbar); ein einmal gewaehlter Bookmark zeigt
    /// dann auf eine veraltete Datei. Da die App NICHT sandboxed ist, darf sie
    /// die Container direkt lesen und die aktuell beschriebene Datei selbst finden.
    private func discoverLatestSnapshotPath() -> String? {
        let fm = FileManager.default
        let root = Self.groupContainersRootPath
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        var best: (path: String, mtime: Date)?
        for entry in entries where entry.contains("com.steipete.codexbar") {
            let candidate = (root as NSString).appendingPathComponent(entry)
                .appending("/widget-snapshot.json")
            guard fm.fileExists(atPath: candidate),
                  let attrs = try? fm.attributesOfItem(atPath: candidate),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime {
                best = (candidate, mtime)
            }
        }
        return best?.path
    }

    private func resolveWidgetSnapshotPath() -> String? {
        // 1. Auto-Discovery (bevorzugt): aktuell beschriebene Datei selbst finden.
        if let discovered = discoverLatestSnapshotPath() {
            return discovered
        }

        // 2. Fallback: vom Nutzer einmalig gewaehlter Security-Scoped Bookmark.
        if let bookmarkData = Settings.shared.codexBarSnapshotBookmarkData {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                if isStale,
                   let refreshed = try? url.bookmarkData(options: [.withSecurityScope],
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil) {
                    Settings.shared.codexBarSnapshotBookmarkData = refreshed
                }
                startSecurityScopedSnapshotAccess(url)
                Settings.shared.codexBarSnapshotPath = url.path
                return url.path
            } catch {
                NSLog("[CodexBar] Could not resolve snapshot bookmark: %@", error.localizedDescription)
                Settings.shared.codexBarSnapshotBookmarkData = nil
            }
        }

        // 3. Letzter Fallback: bekannter Legacy-Pfad.
        if FileManager.default.fileExists(atPath: Self.legacyWidgetSnapshotPath) {
            return Self.legacyWidgetSnapshotPath
        }
        return nil
    }

    private func startSecurityScopedSnapshotAccess(_ url: URL) {
        if securityScopedSnapshotURL == url { return }
        stopSecurityScopedSnapshotAccess()
        securityScopedSnapshotURL = url
        isAccessingSecurityScopedSnapshot = url.startAccessingSecurityScopedResource()
    }

    private func stopSecurityScopedSnapshotAccess() {
        if isAccessingSecurityScopedSnapshot {
            securityScopedSnapshotURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedSnapshotURL = nil
        isAccessingSecurityScopedSnapshot = false
    }

    // MARK: - Helpers

    private func notify() {
        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }

    // Gecachte Formatter — Erzeugung ist teuer und die Konfiguration ist
    // konstant; ISO8601DateFormatter ist fuer reines Parsen thread-safe.
    // Gecachte Formatter — Erzeugung ist teuer und die Konfiguration ist
    // konstant; ISO8601DateFormatter ist fuer reines Parsen thread-safe.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func parseISO8601(_ s: String) -> Date? {
        if let d = Self.isoFractional.date(from: s) { return d }
        return Self.isoPlain.date(from: s)
    }
}
