import Foundation
import ArgusCore

private func makeSession(
    id: String = "s1",
    state: SessionState,
    question: String? = nil,
    tool: String? = nil
) -> AgentSession {
    AgentSession(
        id: id, machine: "This Mac", harness: "Claude Code", repo: "argus",
        worktreePath: "/tmp/argus", branch: "main", model: "claude-opus",
        sessionName: "Fix bug", state: state, currentTool: tool, question: question,
        inputTokens: 10, outputTokens: 20, cost: 0.01, costToday: 0.05,
        lastActivity: Date())
}

struct SessionNotificationsTests {
    func needsInputAlertsOnFirstSight() throws {
        var tracker = AlertTracker()
        let alerts = tracker.alerts(for: [makeSession(state: .needsInput, question: "Proceed?")])
        try expectEqual(alerts.count, 1)
        try expectEqual(alerts[0].state, .needsInput)
        try expectEqual(alerts[0].title, "Fix bug")
        try expectEqual(alerts[0].subtitle, "Claude Code · argus (main)")
        try expectEqual(alerts[0].body, "Needs your input — Proceed?")
        try expectEqual(alerts[0].harnessMark, "C")
        try expectEqual(alerts[0].harnessColorHex, 0xD9_7757)
    }

    func finishedAndErroredSeedSilentlyOnFirstSight() throws {
        var tracker = AlertTracker()
        let alerts = tracker.alerts(for: [
            makeSession(id: "f", state: .finished),
            makeSession(id: "e", state: .errored),
        ])
        try expectEqual(alerts.count, 0)
    }

    func transitionIntoFinishedOrErroredAlerts() throws {
        var tracker = AlertTracker()
        _ = tracker.alerts(for: [makeSession(id: "f", state: .working)])
        _ = tracker.alerts(for: [makeSession(id: "e", state: .working)])
        let alerts = tracker.alerts(for: [
            makeSession(id: "f", state: .finished),
            makeSession(id: "e", state: .errored),
        ])
        try expectEqual(alerts.count, 2)
        try expectEqual(alerts[0].title, "Fix bug")
        try expectEqual(alerts[0].body, "Finished — $0.05 today")
        try expectEqual(alerts[1].title, "Fix bug")
        try expectEqual(alerts[1].body, "Failed — something went wrong, check the session")
    }

    func sameStateDoesNotRepeat() throws {
        var tracker = AlertTracker()
        _ = tracker.alerts(for: [makeSession(state: .needsInput)])
        let again = tracker.alerts(for: [makeSession(state: .needsInput)])
        try expectEqual(again.count, 0)
    }

    func reentryAfterWorkingAlertsAgain() throws {
        var tracker = AlertTracker()
        _ = tracker.alerts(for: [makeSession(state: .needsInput)])
        _ = tracker.alerts(for: [makeSession(state: .working)])
        let again = tracker.alerts(for: [makeSession(state: .needsInput)])
        try expectEqual(again.count, 1)
    }

    func quietStatesNeverAlert() throws {
        var tracker = AlertTracker()
        let alerts = tracker.alerts(for: [
            makeSession(id: "w", state: .working),
            makeSession(id: "i", state: .idle),
        ])
        try expectEqual(alerts.count, 0)
        // …nor on transition between quiet states.
        let later = tracker.alerts(for: [
            makeSession(id: "w", state: .idle),
            makeSession(id: "i", state: .working),
        ])
        try expectEqual(later.count, 0)
    }

    func pendingToolBodyFallsBackToTool() throws {
        var tracker = AlertTracker()
        let alerts = tracker.alerts(for: [makeSession(state: .needsInput, tool: "Bash")])
        try expectEqual(alerts.count, 1)
        try expectEqual(alerts[0].body, "Needs your input — Check Bash")
        try expectEqual(alerts[0].subtitle, "Claude Code · argus (main)")
    }

    func identifierIsStablePerSessionAndState() throws {
        var tracker = AlertTracker()
        let alerts = tracker.alerts(for: [makeSession(id: "abc", state: .needsInput)])
        try expectEqual(alerts[0].identifier, "argus-abc-needsInput")
    }
}
