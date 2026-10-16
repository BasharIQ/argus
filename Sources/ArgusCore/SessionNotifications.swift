import Foundation

/// A notification-worthy session transition: needs input, finished, or
/// errored. Pure value — delivery lives in ArgusApp's `Notifier`.
public struct SessionAlert: Equatable, Sendable {
    public init(sessionID: String, state: SessionState, title: String, subtitle: String, body: String, harnessMark: String, harnessColorHex: UInt32) {
        self.sessionID = sessionID
        self.state = state
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.harnessMark = harnessMark
        self.harnessColorHex = harnessColorHex
    }

    public let sessionID: String
    public let state: SessionState
    public let title: String
    public let subtitle: String
    public let body: String
    /// Brand badge for the notification icon, rendered by ArgusApp.
    public let harnessMark: String
    public let harnessColorHex: UInt32

    /// Stable per session + state so the system replaces rather than stacks
    /// repeats.
    public var identifier: String { "argus-\(sessionID)-\(state.rawValue)" }
}

/// Tracks last-seen state per session and emits an alert once per entry into
/// a notifiable state (working/idle never alert).
///
/// First-sight rule: a session already finished/errored when first seen is
/// stale history, not a transition, so it seeds silently. A session already
/// waiting on first sight still needs you now, so it alerts.
public struct AlertTracker: Sendable {
    private var lastSeen: [String: SessionState] = [:]

    public init() {}

    public static func isNotifiable(_ state: SessionState) -> Bool {
        switch state {
        case .needsInput, .finished, .errored: true
        case .working, .idle: false
        }
    }

    public mutating func alerts(for sessions: [AgentSession]) -> [SessionAlert] {
        var out: [SessionAlert] = []
        for session in sessions {
            defer { lastSeen[session.id] = session.state }
            guard Self.isNotifiable(session.state), lastSeen[session.id] != session.state else { continue }
            if lastSeen[session.id] == nil, session.state != .needsInput { continue }
            let content = Self.content(for: session)
            out.append(SessionAlert(
                sessionID: session.id, state: session.state,
                title: content.title, subtitle: content.subtitle, body: content.body,
                harnessMark: content.harnessMark, harnessColorHex: content.harnessColorHex))
        }
        return out
    }

    /// Title/subtitle/body for a session in a notifiable state. The title is
    /// the session name, the subtitle carries harness + repo, and the body
    /// always opens with the status — the reason the banner fired.
    public static func content(for session: AgentSession) -> (title: String, subtitle: String, body: String, harnessMark: String, harnessColorHex: UInt32) {
        let display = session.sessionName ?? session.repo
        let style = HarnessStyle.style(forHarness: session.harness)
        var context = "\(session.harness) · \(session.repo)"
        if let branch = session.branch, !branch.isEmpty {
            context += " (\(branch))"
        }
        switch session.state {
        case .needsInput:
            let prompt: String
            if let question = session.question {
                prompt = question
            } else if let tool = session.currentTool {
                prompt = "Check \(tool)"
            } else {
                prompt = "Waiting for you"
            }
            return (display, context, "Needs your input — \(prompt)", style.mark, style.colorHex)
        case .finished:
            return (display, context, String(format: "Finished — $%.2f today", session.costToday), style.mark, style.colorHex)
        case .errored:
            return (display, context, "Failed — something went wrong, check the session", style.mark, style.colorHex)
        case .working, .idle:
            return (display, context, "", style.mark, style.colorHex)
        }
    }
}
