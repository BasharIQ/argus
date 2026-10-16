import Foundation
import ArgusCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected { throw CheckFailure(description: "\(message). Expected \(expected), got \(actual)") }
}

private final class FakeAdapter: HarnessAdapter, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var report: HarnessScan
    private var count = 0
    private var active = 0
    private var maximumActive = 0
    let delay: TimeInterval

    init(name: String = "Claude Code", report: HarnessScan, delay: TimeInterval = 0) {
        self.name = name
        self.report = report
        self.delay = delay
    }

    func set(_ report: HarnessScan) {
        lock.lock()
        self.report = report
        lock.unlock()
    }

    var scanCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var concurrentScans: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActive
    }

    func scan() -> HarnessScan {
        lock.lock()
        count += 1
        active += 1
        maximumActive = max(maximumActive, active)
        let current = report
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.lock()
        active -= 1
        lock.unlock()
        return current
    }
}

@main
private struct AppChecks {
    private static let today = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!

    private static func session(_ id: String, state: SessionState = .finished,
                                at: Date = today, cost: Double = 2) -> AgentSession {
        AgentSession(id: id, machine: "This Mac", harness: "Claude Code", repo: "argus",
                     worktreePath: "/tmp/argus-\(id)", branch: "feature/\(id)", model: nil,
                     sessionName: "Task \(id)", state: state, currentTool: nil,
                     question: state == .needsInput ? "Which option?" : nil,
                     inputTokens: 10, outputTokens: 20, cost: cost, costToday: cost, lastActivity: at)
    }

    @MainActor
    private static func fixture(_ adapters: [any HarnessAdapter],
                                clock: @escaping () -> Date = { today },
                                sink: (([SessionAlert]) -> Void)? = nil) -> (SessionStore, UserDefaults, String) {
        let suite = "argus.app-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SessionStore(adapters: adapters, defaults: defaults,
                                 notifier: Notifier(resolveSystemCenter: false),
                                 automaticallyPoll: false, clock: clock, alertSink: sink)
        return (store, defaults, suite)
    }

    @MainActor
    static func main() async {
        var failures: [String] = []
        let checks: [(String, @MainActor () async throws -> Void)] = [
            ("hide and restore preserve total cost", hideAndRestore),
            ("dismissals persist and activity restores", persistenceAndActivity),
            ("active sessions cannot stay hidden", activeRowsStayVisible),
            ("source outcomes stay distinct", sourceOutcomes),
            ("partial and failed scans preserve stale rows", staleRowsAndDayRollover),
            ("fresh results recover and emit transitions", recoveryAlerts),
            ("concurrent retries share one scan", refreshOwnership),
            ("disabled notification service remains unavailable", notificationAccess),
        ]
        for (name, check) in checks {
            do {
                try await check()
                print("PASS \(name)")
            } catch {
                failures.append("\(name). \(error)")
                print("FAIL \(name). \(error)")
            }
        }
        print("\(checks.count - failures.count) passed, \(failures.count) failed")
        exit(failures.isEmpty ? 0 : 1)
    }

    @MainActor
    private static func hideAndRestore() async throws {
        let adapter = FakeAdapter(report: .complete(sessions: [session("a"), session("b", cost: 3)]))
        let (store, defaults, suite) = fixture([adapter])
        defer { defaults.removePersistentDomain(forName: suite) }
        await store.refresh()
        store.dismiss(session("a"))
        try expect(store.sessions.map(\.id), ["b"], "Dismissed row leaves visible list")
        try expect(store.hiddenSessions.map(\.id), ["a"], "Hidden row remains recoverable")
        try expect(store.totalCostToday, 5, "Hidden spending remains in total")
        store.restore("a")
        try expect(store.sessions.map(\.id), ["a", "b"], "Individual restore returns row")
        store.dismiss(session("a"))
        store.dismiss(session("b", cost: 3))
        store.restoreAll()
        try expect(store.sessions.map(\.id), ["a", "b"], "Restore all returns both rows")
        try expect(store.dismissed.count, 0, "Restore all clears persisted dismissals")
    }

    @MainActor
    private static func persistenceAndActivity() async throws {
        let adapter = FakeAdapter(report: .complete(sessions: [session("a")]))
        let (first, defaults, suite) = fixture([adapter])
        defer { defaults.removePersistentDomain(forName: suite) }
        await first.refresh()
        first.dismiss(session("a"))
        let next = SessionStore(adapters: [adapter], defaults: defaults,
                                notifier: Notifier(resolveSystemCenter: false),
                                automaticallyPoll: false, clock: { today })
        await next.refresh()
        try expect(next.hiddenSessions.map(\.id), ["a"], "Dismissal survives a new store")
        adapter.set(.complete(sessions: [session("a", at: today.addingTimeInterval(1))]))
        await next.refresh()
        try expect(next.sessions.map(\.id), ["a"], "New activity restores the hidden session")
        try expect(next.dismissed.count, 0, "New activity removes stored dismissal")
        next.dismiss(session("a", at: today))
        next.restore("a")
        let restored = SessionStore(adapters: [adapter], defaults: defaults,
                                    notifier: Notifier(resolveSystemCenter: false),
                                    automaticallyPoll: false, clock: { today })
        await restored.refresh()
        try expect(restored.sessions.map(\.id), ["a"], "Restore survives a new store")
    }

    @MainActor
    private static func activeRowsStayVisible() async throws {
        let adapter = FakeAdapter(report: .complete(sessions: [session("a")]))
        let (store, defaults, suite) = fixture([adapter])
        defer { defaults.removePersistentDomain(forName: suite) }
        await store.refresh()
        store.dismiss(session("a"))
        adapter.set(.complete(sessions: [session("a", state: .needsInput)]))
        await store.refresh()
        try expect(store.sessions.map(\.id), ["a"], "Question overrides prior dismissal even at same timestamp")
        try expect(store.waitingCount, 1, "Fresh question counts toward tray alert")
        store.dismiss(session("a", state: .needsInput))
        try expect(store.hiddenSessions.count, 0, "A waiting row refuses dismissal")
        adapter.set(.complete(sessions: [session("a", state: .working)]))
        await store.refresh()
        store.dismiss(session("a", state: .working))
        try expect(store.sessions.map(\.id), ["a"], "A working row refuses dismissal")
    }

    @MainActor
    private static func sourceOutcomes() async throws {
        let issue = ScanIssue(source: "/tmp/broken.jsonl", message: "Cannot read transcript")
        let adapters: [any HarnessAdapter] = [
            FakeAdapter(name: "empty", report: .complete(sessions: [])),
            FakeAdapter(name: "missing", report: .unavailable(source: "/tmp/missing")),
            FakeAdapter(name: "failed", report: .failed(issues: [issue])),
            FakeAdapter(name: "partial", report: .partial(sessions: [session("a")], issues: [issue])),
        ]
        let (store, defaults, suite) = fixture(adapters)
        defer { defaults.removePersistentDomain(forName: suite) }
        await store.refresh()
        try expect(store.sourceStatuses.map(\.label), ["Up to date", "Source not found", "Scan failed", "Incomplete scan"], "Source states remain distinct")
        try expect(store.sourceStatuses[0].lastSuccess, today, "Complete empty scan succeeds")
        try expect(store.sourceStatuses[2].lastSuccess, nil, "Failed scan never claims success")
        try expect(store.sourceStatuses[2].details, ["Cannot read transcript · /tmp/broken.jsonl"], "Issue carries recovery context")
        try expect(store.sessions.map(\.id), ["a"], "Partial scan contributes its valid row")
    }

    @MainActor
    private static func staleRowsAndDayRollover() async throws {
        var now = today
        var emitted: [SessionAlert] = []
        let issue = ScanIssue(source: "/tmp/b.jsonl", message: "Access denied")
        let adapter = FakeAdapter(report: .complete(sessions: [session("a", state: .working), session("b", state: .needsInput)]))
        let (store, defaults, suite) = fixture([adapter], clock: { now }, sink: { emitted += $0 })
        defer { defaults.removePersistentDomain(forName: suite) }
        await store.refresh()
        try expect(emitted.map(\.sessionID), ["b"], "Fresh question alerts")
        adapter.set(.partial(sessions: [session("a", state: .working)], issues: [issue]))
        now = today.addingTimeInterval(5)
        await store.refresh()
        try expect(store.sessions.map(\.id), ["b", "a"], "Partial scan retains missing rows")
        try expect(store.staleSessionIDs, Set(["b"]), "Only absent partial rows become stale")
        try expect(store.waitingCount, 0, "Stale question does not claim fresh input needed")
        try expect(store.sourceStatuses[0].lastSuccess, today, "Partial attempt keeps last complete success")
        adapter.set(.failed(issues: [issue]))
        now = today.addingTimeInterval(10)
        await store.refresh()
        try expect(store.staleSessionIDs, Set(["a", "b"]), "Failed scan retains all rows as stale")
        try expect(emitted.map(\.sessionID), ["b"], "Stale rows do not generate repeated alerts")
        try expect(store.totalCostToday, 4, "Same-day retained costs remain visible")
        now = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        await store.refresh()
        try expect(store.totalCostToday, 0, "Failed source cannot carry yesterday's spending into today")
        try expect(store.sessions.map(\.costToday), [0, 0], "Individual stale costs reset too")
        adapter.set(.unavailable(source: "/tmp/missing"))
        await store.refresh()
        try expect(store.hasStaleSessions, true, "Source disappearance preserves incomplete-data warning")
        try expect(store.sessions.map(\.id), ["b", "a"], "Source disappearance preserves last-known rows")
    }

    @MainActor
    private static func recoveryAlerts() async throws {
        var emitted: [SessionAlert] = []
        let issue = ScanIssue(source: "/tmp/a.jsonl", message: "Read failed")
        let adapter = FakeAdapter(report: .complete(sessions: [session("a", state: .working)]))
        let (store, defaults, suite) = fixture([adapter], sink: { emitted += $0 })
        defer { defaults.removePersistentDomain(forName: suite) }
        await store.refresh()
        adapter.set(.failed(issues: [issue]))
        await store.refresh()
        adapter.set(.complete(sessions: [session("a", state: .finished, cost: 3)]))
        await store.refresh()
        try expect(store.hasStaleSessions, false, "A successful retry clears stale flags")
        try expect(store.sourceStatuses[0].label, "Up to date", "A successful retry clears source problem")
        try expect(emitted.map(\.state), [.finished], "Fresh recovered completion emits its transition")
        try expect(store.totalCostToday, 3, "Retry replaces retained daily costs")
        adapter.set(.complete(sessions: []))
        await store.refresh()
        try expect(store.sessions.count, 0, "Confirmed empty scan clears last-known rows")
    }

    @MainActor
    private static func refreshOwnership() async throws {
        let adapter = FakeAdapter(report: .complete(sessions: [session("a")]), delay: 0.1)
        let (store, defaults, suite) = fixture([adapter])
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = Task { await store.refresh() }
        let second = Task { await store.refresh() }
        await first.value
        await second.value
        try expect(adapter.scanCount, 1, "Simultaneous retry callers await one scan")
        try expect(adapter.concurrentScans, 1, "An adapter never scans concurrently")
        try expect(store.isRefreshing, false, "Refresh completes its visible busy state")
        await store.refresh()
        try expect(adapter.scanCount, 2, "A later retry performs a new scan")
    }

    @MainActor
    private static func notificationAccess() async throws {
        let adapter = FakeAdapter(report: .complete(sessions: []))
        let (store, defaults, suite) = fixture([adapter])
        defer { defaults.removePersistentDomain(forName: suite) }
        await store.refresh()
        try expect(store.notificationAccess, .unavailable, "Test service cannot request system access")
        await store.enableNotifications()
        try expect(store.notificationAccess, .unavailable, "Unavailable service remains unavailable after explicit enable")
    }
}
