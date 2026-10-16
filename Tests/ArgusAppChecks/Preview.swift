import SwiftUI
import ArgusCore

private final class PreviewAdapter: HarnessAdapter, @unchecked Sendable {
    let name: String
    private let reports: [HarnessScan]
    private let lock = NSLock()
    private var index = 0

    init(_ name: String, reports: [HarnessScan]) {
        self.name = name
        self.reports = reports
    }

    func scan() -> HarnessScan {
        lock.lock()
        defer { lock.unlock() }
        let report = reports[min(index, reports.count - 1)]
        index += 1
        return report
    }
}

@main
struct ArgusChecksPreview: App {
    @StateObject private var store: SessionStore

    init() {
        Fonts.register()
        let now = Date()
        let directory = "/Users/example/projects/argus/worktrees/a-long-directory-for-identifying-parallel-agent-sessions"
        let questions = (1...7).map { index in
            AgentSession(id: "Claude Code/wait-\(index)", machine: "This Mac", harness: "Claude Code",
                         repo: "argus", worktreePath: "\(directory)/review-\(index)",
                         branch: "feature/parallel-review-\(index)", model: "claude-sonnet",
                         sessionName: "Review \(index). A distinct title in the same repository",
                         state: .needsInput, currentTool: "AskUserQuestion",
                         question: "For review \(index), should this change keep the existing behavior or use the proposed workflow? This is a long explicit question so the waiting inbox must scroll while the footer stays reachable.",
                         inputTokens: 1000, outputTokens: 200, cost: 0.02, costToday: 0.02,
                         lastActivity: now.addingTimeInterval(Double(-index)))
        }
        let finished = AgentSession(
            id: "Codex/finished", machine: "This Mac", harness: "Codex", repo: "argus",
            worktreePath: "\(directory)/finished-work", branch: "fix/completed-task", model: "gpt-6",
            sessionName: "Completed task. Hide and restore this row", state: .finished,
            currentTool: nil, question: nil, inputTokens: 2000, outputTokens: 400,
            cost: 0.04, costToday: 0.04, lastActivity: now.addingTimeInterval(-180))
        let working = AgentSession(
            id: "Codex/working", machine: "This Mac", harness: "Codex", repo: "argus",
            worktreePath: "\(directory)/running-work", branch: "feature/long-build", model: "gpt-6",
            sessionName: "Build still running", state: .working, currentTool: "Build",
            question: nil, inputTokens: 3000, outputTokens: 500, cost: 0.05, costToday: 0.05,
            lastActivity: now.addingTimeInterval(-30))
        let stale = AgentSession(
            id: "OpenCode/stale", machine: "This Mac", harness: "OpenCode", repo: "argus",
            worktreePath: "\(directory)/stale-source", branch: "feature/last-known", model: "test-model",
            sessionName: "Last known task. Source failed", state: .working,
            currentTool: "Read", question: nil, inputTokens: 100, outputTokens: 20,
            cost: 0.01, costToday: 0.01, lastActivity: now.addingTimeInterval(-60))
        let adapters: [any HarnessAdapter] = [
            PreviewAdapter("Claude Code", reports: [.complete(sessions: questions)]),
            PreviewAdapter("Codex", reports: [.complete(sessions: [working, finished])]),
            PreviewAdapter("OpenCode", reports: [
                .complete(sessions: [stale]),
                .failed(issues: [ScanIssue(source: "/fixture/opencode.db", message: "Cannot read database. Fixture source is unavailable")]),
            ]),
            PreviewAdapter("Pi", reports: [.unavailable(source: "/fixture/pi/sessions")]),
        ]
        let defaults = UserDefaults(suiteName: "argus.ui-fixture.\(UUID().uuidString)")!
        _store = StateObject(wrappedValue: SessionStore(
            adapters: adapters, defaults: defaults, notifier: Notifier(resolveSystemCenter: false),
            automaticallyPoll: false, alertSink: { _ in }))
    }

    var body: some Scene {
        WindowGroup("Argus checks") {
            MenuContent()
                .environmentObject(store)
                .task {
                    await store.refresh()
                    await store.refresh()
                }
        }
        .windowResizability(.contentSize)
    }
}
