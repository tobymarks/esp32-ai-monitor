/**
 * CodexBarSource.swift — Liest AI-Provider-Usage-Daten über das CodexBar-CLI.
 *
 * Ab v1.24.0 nicht mehr über die Datei
 * `~/Library/Group Containers/…com.steipete.codexbar/widget-snapshot.json`,
 * sondern über `codexbar usage --provider <p> --json`.
 *
 * Warum der Wechsel:
 *  - Die Datei setzt voraus, dass die CodexBar-*App* läuft — zwei Menüleisten-
 *    Tools für denselben Zweck. Das CLI läuft eigenständig (verifiziert bei
 *    beendeter App).
 *  - Die Datei enthält nur die in CodexBar aktivierten Provider. Antigravity
 *    fehlte dort komplett, das CLI liefert es (schnellster Provider, ~0,8 s,
 *    weil lokaler Language-Server statt Netzwerk).
 *  - Der Security-Scoped-Bookmark auf einen fremden App-Container entfällt
 *    ersatzlos — damit auch der TCC-Prompt „Daten aus anderen Apps".
 *
 * Datenquelle:
 *  `codexbar usage --provider {claude|codex|antigravity} --json`
 *  → `[{ provider, source, usage: { primary, secondary, tertiary,
 *        updatedAt, loginMethod, extraRateWindows[] } }]`
 *  Fehlerfall: `[{ error: { code, message, kind }, provider, source }]`, Exit 1.
 *
 * Design:
 *  - Poll alle 3 min statt 30 s. Die Abfragen kosten echte Zeit (Claude ~1–2 s,
 *    Codex ~3,5 s) und laufen gegen Endpunkte, die drosseln (429). Für Fenster
 *    von 5 h bzw. 7 Tagen ist Sekundenaktualität ohnehin sinnlos.
 *  - Der Prozess läuft auf einer Hintergrund-Queue mit Timeout; State-Updates
 *    kehren auf den Main-Thread zurück.
 *  - Stale-Check über `usage.updatedAt` wie bisher.
 *  - Kein FileWatcher mehr (nichts zu beobachten).
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
    case notYet                          // Initialzustand vor dem ersten Lauf
    case cliMissing                      // codexbar-Binary nicht gefunden
    case providerUnavailable(String)     // CLI erreichbar, Provider liefert nicht
    case cliFailed(String)               // Aufruf fehlgeschlagen / Timeout
    case stale(ageSeconds: Int)
    case parseError(String)

    var shortLabel: String {
        switch self {
        case .ok: return "OK"
        case .notYet: return "…"
        case .cliMissing: return "CLI fehlt"
        case .providerUnavailable: return "Provider offline"
        case .cliFailed: return "Abruf fehlgeschlagen"
        case .stale(let ageSec): return "stale (\(ageSec / 60)m alt)"
        case .parseError: return "parse error"
        }
    }

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    /// Kurztext für das Display, wenn keine Daten vorliegen.
    ///
    /// WICHTIG: nur ASCII. Die LVGL-Montserrat-Fonts der Firmware enthalten
    /// keine Umlaute und kein „…“ — solche Zeichen erscheinen als Kästchen.
    /// Deshalb enthält auch localization.cpp durchgehend keine Umlaute.
    /// `sendNoticeToESP32` säubert zusätzlich, das hier ist die erste Instanz.
    var displayNotice: String? {
        switch self {
        case .ok: return nil
        case .notYet: return nil
        case .cliMissing: return "CodexBar-CLI fehlt"
        case .providerUnavailable: return "Bitte App starten"
        case .cliFailed: return "Abruf fehlgeschlagen"
        case .stale: return "Daten veraltet"
        case .parseError: return "Datenfehler"
        }
    }

    /// Hinweis waehrend eines laufenden Abrufs. Getrennt von `displayNotice`,
    /// weil hier nichts falsch ist — es dauert nur einen Moment.
    static let loadingNotice = "Lade Provider ..."
}

// MARK: - Datenmodelle

struct CodexBarWindow: Codable {
    let usedPercent: Double
    let resetsAt: String?
    let resetDescription: String?
    let windowMinutes: Int?
}

struct CodexBarUsageRow {
    let id: String?
    let title: String?
    let percentLeft: Double?
}

/// Zusatzfenster aus `extraRateWindows` — bei Antigravity die eigentlichen
/// Modell-Kontingente (Gemini 5h/weekly, Claude/GPT 5h/weekly).
struct CodexBarExtraWindow {
    let id: String
    let title: String
    let window: CodexBarWindow
}

struct CodexBarEntry {
    let provider: String?
    let updatedAt: String?
    let primary: CodexBarWindow?
    let secondary: CodexBarWindow?
    let tertiary: CodexBarWindow?
    let usageRows: [CodexBarUsageRow]?
    let extraWindows: [CodexBarExtraWindow]?
}

// MARK: - CLI-Antwortformat

private struct CLIExtraWindow: Codable {
    let id: String?
    let title: String?
    let window: CodexBarWindow?
}

private struct CLIUsage: Codable {
    let primary: CodexBarWindow?
    let secondary: CodexBarWindow?
    let tertiary: CodexBarWindow?
    let updatedAt: String?
    let extraRateWindows: [CLIExtraWindow]?
}

private struct CLIError: Codable {
    let code: Int?
    let message: String?
    let kind: String?
}

private struct CLIResult: Codable {
    let provider: String?
    let source: String?
    let usage: CLIUsage?
    let error: CLIError?
}

// MARK: - Source

final class CodexBarSource {

    /// Poll-Intervall. Bewusst gross: die CLI-Abfragen dauern real 1–4 s und
    /// laufen gegen drosselnde Endpunkte (429). Fenster von 5 h / 7 Tagen
    /// brauchen keine Sekundenaktualitaet.
    static let kPollInterval: TimeInterval = 180

    /// Stale-Schwelle — aelter als das heisst: nichts Neues mehr senden.
    static let kStaleThresholdSeconds: TimeInterval = 15 * 60

    /// Timeout je CLI-Aufruf. Codex braucht regulaer ~3,5 s; 30 s ist grosszuegig
    /// genug fuer einen langsamen Netzwerkpfad und faengt Haenger trotzdem ab.
    static let kCLITimeout: TimeInterval = 30

    /// Suchpfade fuer das Binary.
    ///
    /// Wichtig: Das CLI ist KEIN eigenstaendiges Homebrew-Formula, sondern liegt
    /// im App-Bundle (`CodexBar.app/Contents/Helpers/CodexBarCLI`, ~32 MB); das
    /// Cask legt in /opt/homebrew/bin nur einen Symlink dorthin. Deshalb steht
    /// der direkte Bundle-Pfad mit in der Liste — dann funktioniert es auch bei
    /// Nutzern ohne Homebrew, die die App per DMG installiert haben.
    static let cliSearchPaths = [
        "/opt/homebrew/bin/codexbar",
        "/usr/local/bin/codexbar",
        "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
        NSString("~/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI").expandingTildeInPath,
        "/usr/bin/codexbar",
    ]

    private(set) var provider: String
    private(set) var status: CodexBarStatus = .notYet
    private(set) var lastEntry: CodexBarEntry?
    private(set) var lastLoadedAt: Date?
    private(set) var lastSnapshotGeneratedAt: Date?
    /// Quelle, die das CLI benutzt hat („web", „oauth", „app", …) — nur Anzeige.
    private(set) var lastSource: String?

    var onChange: (() -> Void)?

    private var pollTimer: Timer?
    private let runQueue = DispatchQueue(label: "de.aimonitor.codexbar-cli")
    private var isRunning = false

    /// Waehrend eines laufenden Abrufs kam eine neue Anforderung (Provider-
    /// Wechsel oder Poll). Ohne dieses Merkmal ging sie verloren: `loadOnce()`
    /// stieg am `isRunning`-Guard aus, und das Ergebnis des laufenden Abrufs
    /// wurde anschliessend verworfen, weil der Provider inzwischen ein anderer
    /// war — die Anzeige blieb dann bis zum naechsten Poll auf „Lade Provider".
    private var pendingReload = false

    /// Letzter erfolgreicher Stand je Provider — fuer den sofortigen Wechsel,
    /// bevor der neue Abruf durch ist.
    private var cachedEntries: [String: (entry: CodexBarEntry, fetchedAt: Date)] = [:]

    /// `true`, solange fuer den aktiven Provider noch nie Daten vorlagen und ein
    /// Abruf laeuft — dann zeigt das Display den Lade-Hinweis statt fremder Werte.
    var isLoadingWithoutData: Bool { isRunning && lastEntry == nil }

    /// `true`, solange ein Abruf laeuft. Geht als `fetching` mit ins Envelope:
    /// das Display zeigt dann ein Refresh-Symbol im Kopf. Wichtig bei mehreren
    /// Geraeten — nach einem Wechsel sind die angezeigten Werte womoeglich vom
    /// vorherigen Abruf, und der Nutzer soll sehen, dass gerade nachgeladen wird.
    var isFetching: Bool { isRunning }

    deinit { stop() }

    init(provider: String = CodexBarProvider.defaultProvider.rawValue) {
        self.provider = Self.normalizeProvider(provider)
    }

    // MARK: - Lifecycle

    func start() {
        loadOnce()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.kPollInterval, repeats: true) { [weak self] _ in
            self?.loadOnce()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func setProvider(_ newProvider: String) {
        let norm = Self.normalizeProvider(newProvider)
        if norm == provider { return }
        provider = norm
        NSLog("[CodexBar] Provider switched to '%@'", norm)

        // Ein CLI-Abruf dauert 1–4 s. Ohne Zwischenspeicher waere das Display in
        // dieser Zeit entweder leer oder — schlimmer — zeigte weiter die Werte
        // des vorherigen Providers. Deshalb: zuletzt bekannten Stand dieses
        // Providers sofort anzeigen, sofern er nicht veraltet ist, und im
        // Hintergrund aktualisieren.
        if let cached = cachedEntries[norm],
           Date().timeIntervalSince(cached.fetchedAt) <= Self.kStaleThresholdSeconds {
            lastEntry = cached.entry
            status = .ok
        } else {
            lastEntry = nil
            status = .notYet
        }
        loadOnce()
        notify()
    }

    private static func normalizeProvider(_ raw: String) -> String {
        CodexBarProvider.normalized(raw).rawValue
    }

    // MARK: - CLI-Pfad

    /// Findet das codexbar-Binary; nil, wenn nicht installiert.
    static func resolveCLIPath() -> String? {
        let fm = FileManager.default
        for path in cliSearchPaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        // GUI-Apps erben den Login-PATH nicht zuverlaessig — deshalb erst die
        // festen Pfade oben, PATH nur als Ergaenzung.
        if let env = ProcessInfo.processInfo.environment["PATH"] {
            for dir in env.split(separator: ":") {
                let candidate = (String(dir) as NSString).appendingPathComponent("codexbar")
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static var isCLIAvailable: Bool { resolveCLIPath() != nil }

    // MARK: - Abruf

    @discardableResult
    func loadOnce() -> CodexBarStatus {
        // Ueberlappende Laeufe vermeiden: ein Codex-Abruf kann mehrere Sekunden
        // dauern, der Timer darf nicht danebenschiessen. Die Anforderung wird
        // aber gemerkt und direkt nach dem laufenden Abruf nachgeholt.
        guard !isRunning else {
            pendingReload = true
            return status
        }

        guard let cliPath = Self.resolveCLIPath() else {
            apply(status: .cliMissing, entry: nil, source: nil)
            return status
        }

        isRunning = true
        pendingReload = false
        let requestedProvider = provider
        lastLoadedAt = Date()
        // Sofort melden, dass ein Abruf laeuft — daraus entsteht ein Frame mit
        // `fetching: true`, und das Display zeigt sein Refresh-Symbol.
        notify()

        runQueue.async { [weak self] in
            guard let self = self else { return }
            let outcome = Self.runCLI(path: cliPath, provider: requestedProvider)

            DispatchQueue.main.async {
                self.isRunning = false

                // Provider koennte waehrend des Laufs gewechselt haben — das
                // Ergebnis gehoert dann zum falschen Provider.
                let providerChanged = (requestedProvider != self.provider)
                if !providerChanged {
                    self.handle(outcome: outcome)
                }

                // Verworfenes Ergebnis oder waehrenddessen angeforderter Abruf:
                // sofort nachholen. Fehlte das, blieb die Anzeige bis zum
                // naechsten Poll (3 min) auf „Lade Provider ..." stehen.
                if providerChanged || self.pendingReload {
                    self.pendingReload = false
                    self.loadOnce()
                }
            }
        }
        return status
    }

    private enum CLIOutcome {
        case success(CLIResult)
        case failure(CodexBarStatus)
    }

    private static func runCLI(path: String, provider: String) -> CLIOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["usage", "--provider", provider, "--json"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(.cliFailed("Start fehlgeschlagen: \(error.localizedDescription)"))
        }

        // Watchdog: nach kCLITimeout hart beenden, sonst haengt der Timer-Zyklus.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + kCLITimeout, execute: watchdog)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard !data.isEmpty else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(.cliFailed(msg.isEmpty ? "Keine Ausgabe (Exit \(process.terminationStatus))" : String(msg.prefix(160))))
        }

        do {
            let results = try JSONDecoder().decode([CLIResult].self, from: data)
            guard let first = results.first else {
                return .failure(.parseError("Leeres Ergebnis-Array"))
            }
            return .success(first)
        } catch {
            return .failure(.parseError(error.localizedDescription))
        }
    }

    private func handle(outcome: CLIOutcome) {
        switch outcome {
        case .failure(let failureStatus):
            NSLog("[CodexBar] %@ (%@)", failureStatus.shortLabel, provider)
            apply(status: failureStatus, entry: nil, source: nil)

        case .success(let result):
            if let err = result.error {
                let message = err.message ?? "Unbekannter Fehler"
                NSLog("[CodexBar] Provider '%@' unavailable: %@", provider, message)
                apply(status: .providerUnavailable(message), entry: nil, source: result.source)
                return
            }

            guard let usage = result.usage else {
                apply(status: .parseError("Antwort ohne usage-Objekt"), entry: nil, source: result.source)
                return
            }

            let extras: [CodexBarExtraWindow] = (usage.extraRateWindows ?? []).compactMap { raw in
                guard let id = raw.id, let window = raw.window else { return nil }
                return CodexBarExtraWindow(id: id, title: raw.title ?? id, window: window)
            }

            let entry = CodexBarEntry(
                provider: result.provider ?? provider,
                updatedAt: usage.updatedAt,
                primary: usage.primary,
                secondary: usage.secondary,
                tertiary: usage.tertiary,
                usageRows: nil,
                extraWindows: extras.isEmpty ? nil : extras
            )

            // Alle Fenster leer? Dann hat der Provider zwar geantwortet, aber
            // nichts Verwertbares — genauso behandeln wie „nicht verfuegbar",
            // damit das Display nicht stumm alte Werte weiterzeigt.
            if usage.primary == nil && usage.secondary == nil && usage.tertiary == nil && extras.isEmpty {
                apply(status: .providerUnavailable("Keine Kontingentdaten"), entry: nil, source: result.source)
                return
            }

            let updated = usage.updatedAt.flatMap { parseISO8601($0) }
            lastSnapshotGeneratedAt = updated
            if let ref = updated {
                let age = Date().timeIntervalSince(ref)
                if age > Self.kStaleThresholdSeconds {
                    NSLog("[CodexBar] Stale (%@): %.0f min", provider, age / 60)
                    apply(status: .stale(ageSeconds: Int(age)), entry: entry, source: result.source)
                    return
                }
            }

            apply(status: .ok, entry: entry, source: result.source)
        }
    }

    private func apply(status newStatus: CodexBarStatus,
                       entry: CodexBarEntry?,
                       source: String?) {
        status = newStatus
        if let entry, newStatus.isOK {
            cachedEntries[provider] = (entry: entry, fetchedAt: Date())
        }
        // Bei einem Fehler den Zwischenspeicher dieses Providers verwerfen —
        // sonst wuerde ein spaeterer Wechsel wieder veraltete Werte zeigen,
        // obwohl der Provider nachweislich nichts mehr liefert.
        if entry == nil, !newStatus.isOK {
            cachedEntries.removeValue(forKey: provider)
        }
        lastEntry = entry
        lastSource = source
        notify()
    }

    // MARK: - Helpers

    private func notify() {
        if Thread.isMainThread {
            onChange?()
        } else {
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
    }

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
        Self.isoFractional.date(from: s) ?? Self.isoPlain.date(from: s)
    }
}
