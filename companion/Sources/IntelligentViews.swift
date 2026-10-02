import Foundation

/// Host-only switch policy. The ESP receives ordinary manual set_views commands.
final class IntelligentViews {
    private struct UsageValue {
        let used: Double
        let reset: String?
    }
    private struct Candidate {
        let view: Int
        let priority: Int
        let date: Date
        let claudeWait: ClaudeWaitKey?
    }
    private var usage: [String: [String: UsageValue]] = [:]
    private var fetched: [String: Date] = [:]
    private struct ClaudeWaitKey: Hashable {
        let id: String
        let state: Int
        let since: Date
    }
    private var claudeCodeWaiting: Set<ClaudeWaitKey>?
    private var pending: [Candidate] = []
    private var shown: [Int: Date] = [:]
    private var lastChange = Date()
    private var manualUntil: Date?

    func reset() {
        usage.removeAll()
        fetched.removeAll()
        claudeCodeWaiting = nil
        pending.removeAll()
        shown.removeAll()
        lastChange = Date()
        manualUntil = nil
    }

    func touch() {
        let now = Date()
        lastChange = now
        manualUntil = now.addingTimeInterval(10 * 60)
        pending.removeAll()
    }

    func observe(_ source: CodexBarSource, views: [String]) {
        guard source.status == .ok, !source.isFetching, let entry = source.lastEntry,
              let loaded = source.lastSuccessfulAt, fetched[source.provider] != loaded else { return }
        fetched[source.provider] = loaded
        var values: [String: UsageValue] = [:]
        let extras = entry.extraWindows ?? []
        let modelExtras = CodexBarProvider.normalized(source.provider).usesModelRows && !extras.isEmpty
        if !modelExtras {
            for (key, window) in [("primary", entry.primary), ("secondary", entry.secondary),
                                  ("tertiary", entry.tertiary)] {
                if let window { values[key] = UsageValue(used: window.usedPercent, reset: window.resetsAt) }
            }
        }
        let extraSlots = modelExtras ? 3 : max(0, 3 - values.count)
        for row in extras.prefix(extraSlots) {
            values["extra:" + row.id] = UsageValue(used: row.window.usedPercent, reset: row.window.resetsAt)
        }
        guard var baseline = usage[source.provider] else {
            usage[source.provider] = values
            return
        }
        var priority = 0
        for (key, current) in values {
            guard let previous = baseline[key] else {
                baseline[key] = current
                continue
            }
            guard current.used.isFinite, (0...100).contains(current.used) else { continue }
            var rowPriority = 0
            if current.reset != previous.reset && current.used + 5 < previous.used {
                rowPriority = 2
            } else if current.used > previous.used {
                if [80.0, 90.0, 100.0].contains(where: { previous.used < $0 && current.used >= $0 }) {
                    rowPriority = 3
                } else if current.used - previous.used >= 5 {
                    rowPriority = 1
                }
            }
            priority = max(priority, rowPriority)
            // Keep the anchor through small increases, so they can accumulate.
            if rowPriority > 0 || current.used < previous.used {
                baseline[key] = current
            }
        }
        usage[source.provider] = baseline
        if priority > 0 {
            for (index, view) in views.enumerated() where view == source.provider {
                pending.append(Candidate(view: index, priority: priority, date: Date(), claudeWait: nil))
            }
        }
    }

    func observeClaudeCode(waiting: [ClaudeCodeWindow.Session], views: [String]) {
        let current = Set(waiting.compactMap { session -> ClaudeWaitKey? in
            guard let state = session.waiting else { return nil }
            return ClaudeWaitKey(id: session.id, state: state.rawValue, since: session.since)
        })
        let previous = claudeCodeWaiting
        claudeCodeWaiting = current
        pending.removeAll { candidate in
            candidate.claudeWait.map { !current.contains($0) } ?? false
        }
        if let previous {
            for key in current.subtracting(previous) {
                for (index, view) in views.enumerated() where view == ClaudeCodeWindow.view {
                    pending.append(Candidate(view: index, priority: 2, date: Date(), claudeWait: key))
                }
            }
        }
    }

    func resetPlugin(_ id: String, views: [String]) {
        for (index, view) in views.enumerated() where view == DisplayPlugins.prefix + id {
            pending.removeAll { $0.view == index }
        }
    }

    func pluginEvent(_ id: String, views: [String]) {
        for (index, view) in views.enumerated() where view == DisplayPlugins.prefix + id {
            pending.append(Candidate(view: index, priority: 2, date: Date(), claudeWait: nil))
        }
    }

    func choose(active: Int, now: Date = Date()) -> Int? {
        pending.removeAll { now.timeIntervalSince($0.date) > 5 * 60 }
        if let until = manualUntil, now < until { return nil }
        guard now.timeIntervalSince(lastChange) >= 2 * 60 else { return nil }
        let next = pending.filter {
            $0.view != active && (shown[$0.view].map { now.timeIntervalSince($0) >= 10 * 60 } ?? true)
        }.sorted {
            $0.priority == $1.priority ? $0.date < $1.date : $0.priority > $1.priority
        }.first?.view
        guard let next else { return nil }
        pending.removeAll()
        lastChange = now
        shown[next] = now
        return next
    }
}
