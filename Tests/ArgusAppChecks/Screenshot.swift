import AppKit
import SwiftUI
import ArgusCore

private struct DemoAdapter: HarnessAdapter {
    let name: String
    let sessions: [AgentSession]
    func scan() -> HarnessScan { .complete(sessions: sessions) }
}

private func session(_ harness: String, _ repo: String, _ branch: String, _ title: String, _ model: String,
                     _ state: SessionState, tool: String? = nil, question: String? = nil,
                     cost: Double, ago: TimeInterval) -> AgentSession {
    AgentSession(id: "\(harness)/\(repo)", machine: "This Mac", harness: harness, repo: repo,
                 worktreePath: "/Users/you/code/\(repo)", branch: branch, model: model, sessionName: title,
                 state: state, currentTool: tool, question: question,
                 inputTokens: Int(cost * 400_000), outputTokens: Int(cost * 20_000),
                 cost: cost, costToday: cost, lastActivity: Date().addingTimeInterval(-ago))
}

@main
struct ArgusScreenshot {
    @MainActor
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        Fonts.register()
        let adapters: [any HarnessAdapter] = [
            DemoAdapter(name: "Claude Code", sessions: [
                session("Claude Code", "payments", "webhook-retries", "Retry failed Stripe webhooks", "claude-opus-5-5",
                        .needsInput, tool: "AskUserQuestion",
                        question: "Should failed webhooks retry with exponential backoff, or go straight to the dead-letter queue?",
                        cost: 2.84, ago: 40),
                session("Claude Code", "web-dashboard", "fix/chart-tooltips", "Fix chart tooltips", "claude-sonnet-5-5",
                        .working, tool: "Bash", cost: 1.12, ago: 8),
                session("Claude Code", "docs-site", "main", "Rewrite the quickstart", "claude-sonnet-5-5",
                        .finished, cost: 0.63, ago: 6 * 60),
            ]),
            DemoAdapter(name: "Codex", sessions: [
                session("Codex", "api-gateway", "perf/connection-pool", "Load-test the pool", "gpt-5-codex",
                        .working, tool: "shell", cost: 0.91, ago: 15),
                session("Codex", "mobile-app", "chore/push-sdk", "Upgrade the push SDK", "gpt-5-codex",
                        .finished, cost: 0.38, ago: 22 * 60),
            ]),
            DemoAdapter(name: "OpenCode", sessions: [
                session("OpenCode", "data-pipeline", "feat/backfill-events", "Backfill events", "claude-sonnet-5-5",
                        .working, tool: "bash", cost: 0.27, ago: 50),
                session("OpenCode", "infra", "staging-vpc", "Plan staging VPC", "claude-sonnet-5-5",
                        .idle, cost: 0.17, ago: 48 * 60),
            ]),
        ]
        let defaults = UserDefaults(suiteName: "argus.screenshot.\(UUID().uuidString)")!
        let store = SessionStore(adapters: adapters, defaults: defaults,
                                 notifier: Notifier(resolveSystemCenter: false),
                                 automaticallyPoll: false, alertSink: { _ in })
        await store.refresh()
        await store.refresh()
        let host = NSHostingView(rootView: MenuContent().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        // The panel re-reads notification access when it appears; the
        // renderer has no notification center, so show the allowed state.
        store.notificationAccess = .authorized
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
        host.cacheDisplay(in: bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: output)
        print("wrote \(output.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
