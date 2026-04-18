/**
 * CodexBarSource.swift — Liest Claude-Usage-Daten aus der lokalen CodexBar-App.
 *
 * Datenquelle: ~/Library/Group Containers/group.com.steipete.codexbar/widget-snapshot.json
 * Das ist der aktuelle Momentan-Snapshot, den CodexBar fuer sein Widget schreibt —
 * strukturell identisch mit dem alten Anthropic-Envelope (primary/secondary/tertiary),
 * d.h. ideal als Drop-in-Ersatz fuer unser ESP32-JSON.
 *
 * Zusaetzlich: ~/Library/Application Support/com.steipete.codexbar/history/claude.json
 * enthaelt ein "version"-Feld (aktuell 1). Bei Mismatch wird ein Fehlerzustand
 * gesetzt, damit die App sich nicht blind auf ein geaendertes Schema verlaesst.
 *
 * Design:
 *  - Pull-Strategie: alle 30 s laden. Zusaetzlich ueber DispatchSource-FileMonitor
 *    reagieren, wenn CodexBar schreibt (sub-sekuendliche Latenz).
 *  - Stale-Check: wenn `updatedAt` (bzw. `generatedAt`) > 15 min alt -> Fehler,
 *    ESP32 bekommt nichts Neues, UI zeigt "stale" im Settings-Fenster.
 *  - Schema-Check: wenn claude.json `version` != kExpectedClaudeHistoryVersion ->
 *    Fehler "wrong version".
 */

import Foundation

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

    /// Erwartete Schema-Version der claude.json. Wenn CodexBar auf 2 wechselt,
    /// hier ebenfalls anpassen — bis dahin: Fehlermeldung im Settings-Fenster.
    static let kExpectedClaudeHistoryVersion = 1

    /// Stale-Schwelle — > 15 min Alter heisst: App sendet nichts Neues mehr.
    static let kStaleThresholdSeconds: TimeInterval = 15 * 60

    /// Poll-Intervall fuers zyklische Neueinlesen.
    static let kPollInterval: TimeInterval = 30

    // Pfade
    static let widgetSnapshotPath = NSString("~/Library/Group Containers/group.com.steipete.codexbar/widget-snapshot.json").expandingTildeInPath
    static let claudeHistoryPath = NSString("~/Library/Application Support/com.steipete.codexbar/history/claude.json").expandingTildeInPath

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

    // MARK: - Lifecycle

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

        // 1. Schema-Version aus history/claude.json pruefen
        if let header = readHistoryHeader() {
            if let v = header.version, v != Self.kExpectedClaudeHistoryVersion {
                status = .wrongVersion(found: v, expected: Self.kExpectedClaudeHistoryVersion)
                NSLog("[CodexBar] Wrong schema version in claude.json: %d (expected %d)", v, Self.kExpectedClaudeHistoryVersion)
                notify()
                return status
            }
        }
        // kein else: wenn die History-Datei noch nicht existiert (frischer Install),
        // ist das nicht zwingend ein Fehler. Widget-Snapshot entscheidet.

        // 2. widget-snapshot.json laden
        guard let data = FileManager.default.contents(atPath: Self.widgetSnapshotPath) else {
            status = .missing
            lastEntry = nil
            NSLog("[CodexBar] widget-snapshot.json not found at %@", Self.widgetSnapshotPath)
            notify()
            return status
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

        // generatedAt -> Date (fuer stale-check)
        let genDate = snapshot.generatedAt.flatMap { parseISO8601($0) }
        lastSnapshotGeneratedAt = genDate

        // Claude-Entry suchen (provider == "claude")
        let claudeEntry = snapshot.entries?.first(where: { ($0.provider ?? "").lowercased() == "claude" })
            ?? snapshot.entries?.first
        lastEntry = claudeEntry

        // Alter bestimmen — bevorzugt updatedAt des Entries, sonst generatedAt
        let ageRef: Date? = {
            if let s = claudeEntry?.updatedAt, let d = parseISO8601(s) { return d }
            return genDate
        }()

        if let ref = ageRef {
            let age = Date().timeIntervalSince(ref)
            if age > Self.kStaleThresholdSeconds {
                status = .stale(ageSeconds: Int(age))
                NSLog("[CodexBar] Stale snapshot: %.0f min old", age / 60)
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

        if claudeEntry == nil {
            status = .missing
            NSLog("[CodexBar] No claude entry in snapshot")
            notify()
            return status
        }

        status = .ok
        notify()
        return status
    }

    private func readHistoryHeader() -> CodexBarHistoryHeader? {
        guard let data = FileManager.default.contents(atPath: Self.claudeHistoryPath) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(CodexBarHistoryHeader.self, from: data)
        } catch {
            NSLog("[CodexBar] Could not parse claude.json header: %@", error.localizedDescription)
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

        let path = Self.widgetSnapshotPath
        let fd = open(path, O_EVTONLY)
        if fd < 0 {
            // Datei existiert nicht — wir probieren beim naechsten Poll erneut.
            return
        }
        watchedFD = fd

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
        }
        src.resume()
        fileWatcher = src
    }

    private func stopFileWatch() {
        fileWatcher?.cancel()
        fileWatcher = nil
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
