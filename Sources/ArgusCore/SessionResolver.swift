import Foundation

/// Shared state semantics for all harnesses: the same quiet-period rules map
/// a parsed transcript tail to a session state.
enum SessionResolver {
    /// Assistant output with no follow-up for this long means the turn is over.
    static let finishedQuiet: TimeInterval = 2 * 60
    /// Anything quiet for this long is idle.
    static let idleQuiet: TimeInterval = 30 * 60

    static func isEligible(state: SessionState, lastActivity: Date, now: Date) -> Bool {
        if lastActivity >= Calendar.current.startOfDay(for: now) || state == .needsInput { return true }
        return state == .working && lastActivity >= now.addingTimeInterval(-24 * 60 * 60)
    }

    static func resolve(tail: ParsedTranscript.Tail, lastActivity: Date, now: Date) -> SessionState {
        let quiet = now.timeIntervalSince(lastActivity)
        switch tail {
        case .assistantText(isError: true):
            return .errored
        case .waitingForInput:
            return .needsInput
        case .pendingToolUse:
            return quiet > idleQuiet ? .idle : .working
        case .runningToolUse:
            return .working
        case .assistantText(isError: false):
            if quiet > idleQuiet { return .idle }
            if quiet > finishedQuiet { return .finished }
            return .working
        case .toolResultArrived:
            // The tool ran and its result landed, but no assistant follow-up
            // arrived: the turn is over once it goes quiet, exactly like a
            // trailing assistant message. Without the finished window the
            // session reads working for 30 minutes and then goes idle —
            // finished (and its notification) never fires.
            if quiet > idleQuiet { return .idle }
            if quiet > finishedQuiet { return .finished }
            return .working
        case .userMessage:
            return quiet > idleQuiet ? .idle : .working
        case .turnEnded(let aborted):
            // The harness recorded the turn boundary, so no quiet period is
            // needed. An abort is the user stopping the turn themselves.
            if aborted || quiet > idleQuiet { return .idle }
            return .finished
        case .noConversation:
            return .idle
        }
    }
}
