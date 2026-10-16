import Foundation
import Combine
import ArgusCore

struct SourceStatus: Identifiable {
    enum Health {
        case checking
        case healthy
        case unavailable(String)
        case partial([ScanIssue])
        case failed([ScanIssue])
    }

    let harness: String
    var health: Health = .checking
    var lastAttempt: Date?
    var lastSuccess: Date?
    var id: String { harness }

    var hasProblem: Bool {
        switch health {
        case .partial, .failed: true
        case .checking, .healthy, .unavailable: false
        }
    }

    var label: String {
        switch health {
        case .checking: "Checking"
        case .healthy: "Up to date"
        case .unavailable: "Source not found"
        case .partial: "Incomplete scan"
        case .failed: "Scan failed"
        }
    }

    var details: [String] {
        switch health {
        case .partial(let issues), .failed(let issues):
            return issues.map { "\($0.message) · \($0.source)" }
        case .unavailable(let source):
            return [source]
        case .checking, .healthy:
            return []
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    static let pollInterval: Duration = .seconds(5)
    private static let dismissedKey = "dismissedSessions"

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var hiddenSessions: [AgentSession] = []
    @Published private(set) var staleSessionIDs: Set<String> = []
    @Published private(set) var sourceStatuses: [SourceStatus]
    @Published private(set) var totalCostToday: Double = 0
    @Published private(set) var lastScan: Date?
    @Published private(set) var isRefreshing = false
    @Published var notificationAccess: NotificationAccess = .checking
    @Published private(set) var dismissed: [String: Date]

    private struct StoredSession {
        let session: AgentSession
        let scannedAt: Date
        var isStale: Bool
    }

    private let adapters: [any HarnessAdapter]
    private let defaults: UserDefaults
    private let notifier: Notifier
    private let clock: () -> Date
    private let alertSink: (([SessionAlert]) -> Void)?
    private var snapshots: [String: [StoredSession]] = [:]
    private var alerts = AlertTracker()
    private var pollingTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    init(adapters: [any HarnessAdapter] = [ClaudeCodeAdapter(), PiAdapter(), CodexAdapter(), OpenCodeAdapter()],
         defaults: UserDefaults = .standard,
         notifier: Notifier = Notifier(),
         automaticallyPoll: Bool = true,
         clock: @escaping () -> Date = Date.init,
         alertSink: (([SessionAlert]) -> Void)? = nil) {
        self.adapters = adapters
        self.defaults = defaults
        self.notifier = notifier
        self.clock = clock
        self.alertSink = alertSink
        self.sourceStatuses = adapters.map { SourceStatus(harness: $0.name) }
        self.dismissed = Self.loadDismissed(from: defaults)
        if automaticallyPoll {
            // Prompts only while the user has not decided; afterwards it
            // just reads the current status.
            Task { [weak self] in await self?.enableNotifications() }
            pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(for: Self.pollInterval) }
                    catch { return }
                }
            }
        }
    }

    deinit {
        pollingTask?.cancel()
        scanTask?.cancel()
    }

    var waitingCount: Int {
        sessions.filter { $0.state == .needsInput && !isStale($0) }.count
    }

    var hasSourceProblems: Bool { sourceStatuses.contains(where: \.hasProblem) }
    var hasStaleSessions: Bool { !staleSessionIDs.isEmpty }

    func isStale(_ session: AgentSession) -> Bool {
        staleSessionIDs.contains(session.id)
    }

    func refresh() async {
        if let scanTask {
            await scanTask.value
            return
        }
        isRefreshing = true
        let task = Task { [self, adapters] in
            let startedAt = clock()
            let reports = await Task.detached {
                adapters.map { ($0.name, $0.scan()) }
            }.value
            guard !Task.isCancelled else { return }
            apply(reports, startedAt: startedAt, finishedAt: clock())
            notificationAccess = await notifier.authorizationStatus()
        }
        scanTask = task
        await task.value
        scanTask = nil
        isRefreshing = false
    }

    func refreshNotificationAccess() async {
        notificationAccess = await notifier.authorizationStatus()
    }

    func enableNotifications() async {
        notificationAccess = await notifier.requestAuthorization()
    }

    func answer(_ session: AgentSession, _ response: PromptResponse) async -> Bool {
        guard let adapter = adapters.first(where: { $0.name == session.harness }) as? any AnsweringAdapter,
              await adapter.answer(session, response) else { return false }
        if let index = snapshots[session.harness]?.firstIndex(where: { $0.session.id == session.id }) {
            snapshots[session.harness]?[index] = StoredSession(
                session: session.markingWorking(), scannedAt: clock(), isStale: false)
            rebuild(at: clock())
        }
        return true
    }

    func dismiss(_ session: AgentSession) {
        guard session.canDismiss else { return }
        dismissed[session.id] = clock()
        saveDismissed()
        rebuild(at: clock())
    }

    func restore(_ id: String) {
        dismissed.removeValue(forKey: id)
        saveDismissed()
        rebuild(at: clock())
    }

    func restoreAll() {
        dismissed.removeAll()
        saveDismissed()
        rebuild(at: clock())
    }

    private func apply(_ reports: [(String, HarnessScan)], startedAt: Date, finishedAt now: Date) {
        var fresh: [AgentSession] = []
        for (harness, report) in reports {
            guard let index = sourceStatuses.firstIndex(where: { $0.harness == harness }) else { continue }
            sourceStatuses[index].lastAttempt = startedAt
            switch report {
            case .complete(let found):
                snapshots[harness] = found.map { StoredSession(session: $0, scannedAt: startedAt, isStale: false) }
                sourceStatuses[index].health = .healthy
                sourceStatuses[index].lastSuccess = now
                fresh.append(contentsOf: found)
            case .partial(let found, let issues):
                let foundIDs = Set(found.map(\.id))
                let retained = (snapshots[harness] ?? []).filter { !foundIDs.contains($0.session.id) }
                    .map { StoredSession(session: $0.session, scannedAt: $0.scannedAt, isStale: true) }
                snapshots[harness] = found.map { StoredSession(session: $0, scannedAt: startedAt, isStale: false) } + retained
                sourceStatuses[index].health = .partial(issues)
                fresh.append(contentsOf: found)
            case .failed(let issues):
                snapshots[harness] = (snapshots[harness] ?? []).map {
                    StoredSession(session: $0.session, scannedAt: $0.scannedAt, isStale: true)
                }
                sourceStatuses[index].health = .failed(issues)
            case .unavailable(let source):
                snapshots[harness] = (snapshots[harness] ?? []).map {
                    StoredSession(session: $0.session, scannedAt: $0.scannedAt, isStale: true)
                }
                sourceStatuses[index].health = .unavailable(source)
            }
        }
        if !Calendar.current.isDate(startedAt, inSameDayAs: now) {
            fresh = fresh.map { $0.withDailyCost(0) }
        }
        notifier.clearResolvedPrompts(in: fresh)
        let emitted = alerts.alerts(for: fresh)
        if let alertSink { alertSink(emitted) }
        else { notifier.deliver(emitted) }
        lastScan = now
        rebuild(at: now)
    }

    private func rebuild(at now: Date) {
        let records = snapshots.values.flatMap { $0 }
        let all = records.map { record in
            Calendar.current.isDate(record.scannedAt, inSameDayAs: now)
                ? record.session : record.session.withDailyCost(0)
        }.sorted {
            if $0.stateRank != $1.stateRank { return $0.stateRank < $1.stateRank }
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.id < $1.id
        }
        var changed = false
        for session in all {
            if let at = dismissed[session.id], !session.canDismiss || session.lastActivity > at {
                dismissed.removeValue(forKey: session.id)
                changed = true
            }
        }
        if changed { saveDismissed() }
        sessions = all.filter { dismissed[$0.id] == nil }
        hiddenSessions = all.filter { dismissed[$0.id] != nil }
        staleSessionIDs = Set(records.filter(\.isStale).map { $0.session.id })
        totalCostToday = all.reduce(0) { $0 + $1.costToday }
    }

    private func saveDismissed() {
        if let data = try? JSONEncoder().encode(dismissed) {
            defaults.set(data, forKey: Self.dismissedKey)
        }
    }

    private static func loadDismissed(from defaults: UserDefaults) -> [String: Date] {
        guard let data = defaults.data(forKey: dismissedKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return decoded
    }
}

private extension AgentSession {
    func withDailyCost(_ dailyCost: Double) -> AgentSession {
        AgentSession(id: id, machine: machine, harness: harness, repo: repo,
                     worktreePath: worktreePath, branch: branch, model: model,
                     sessionName: sessionName, state: state, currentTool: currentTool,
                     question: question, inputTokens: inputTokens, outputTokens: outputTokens,
                     cost: cost, costToday: dailyCost, lastActivity: lastActivity,
                     worktreeDirty: worktreeDirty, branchMerged: branchMerged)
    }
}
