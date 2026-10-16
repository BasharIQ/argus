import Foundation

public enum SessionState: String, Sendable {
    case working
    case needsInput
    case idle
    case finished
    case errored
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public init(id: String, machine: String, harness: String, repo: String, worktreePath: String, branch: String?, model: String?, sessionName: String?, state: SessionState, currentTool: String?, question: String?, inputTokens: Int, outputTokens: Int, cost: Double, costToday: Double, lastActivity: Date, worktreeDirty: Bool? = nil, branchMerged: Bool? = nil) {
        self.id = id
        self.machine = machine
        self.harness = harness
        self.repo = repo
        self.worktreePath = worktreePath
        self.branch = branch
        self.model = model
        self.sessionName = sessionName
        self.state = state
        self.currentTool = currentTool
        self.question = question
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cost = cost
        self.costToday = costToday
        self.lastActivity = lastActivity
        self.worktreeDirty = worktreeDirty
        self.branchMerged = branchMerged
    }

    public let id: String
    public let machine: String
    public let harness: String
    public let repo: String
    public let worktreePath: String
    public let branch: String?
    public let model: String?
    public let sessionName: String?
    public let state: SessionState
    public let currentTool: String?
    public let question: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cost: Double
    public let costToday: Double
    public let lastActivity: Date
    /// Worktree status for planned git detection. Nil until that lands; the
    /// panel only shows what it knows.
    public var worktreeDirty: Bool? = nil
    public var branchMerged: Bool? = nil
}

/// A harness is one source of sessions. Everything else in Argus treats
/// adapters identically; adding a harness means adding a conforming type.
public protocol HarnessAdapter: Sendable {
    var name: String { get }
    func scan() -> HarnessScan
}

public struct ScanIssue: Equatable, Sendable {
    public init(source: String, message: String) {
        self.source = source
        self.message = message
    }

    public let source: String
    public let message: String
}

public enum HarnessScan: Equatable, Sendable {
    case unavailable(source: String)
    case complete(sessions: [AgentSession])
    case partial(sessions: [AgentSession], issues: [ScanIssue])
    case failed(issues: [ScanIssue])

    public var sessions: [AgentSession] {
        switch self {
        case .complete(let sessions), .partial(let sessions, _): sessions
        case .unavailable, .failed: []
        }
    }
}

/// How the user answered a needs-input prompt.
public enum PromptResponse: Sendable {
    case allow
    case deny
    case reply(String)
}

/// Answering prompts has no public API for most harnesses; the mechanism is
/// a per-harness investigation. Adapters conform once they can
/// deliver answers; the panel stays read-only for the rest.
public protocol AnsweringAdapter: HarnessAdapter {
    func answer(_ session: AgentSession, _ response: PromptResponse) async -> Bool
}

extension AgentSession {
    /// A copy marked working — used after an answer is delivered, before the
    /// next scan confirms the session is mid-turn again.
    public func markingWorking() -> AgentSession {
        AgentSession(
            id: id, machine: machine, harness: harness, repo: repo, worktreePath: worktreePath,
            branch: branch, model: model, sessionName: sessionName, state: .working,
            currentTool: currentTool, question: question, inputTokens: inputTokens,
            outputTokens: outputTokens, cost: cost, costToday: costToday,
            lastActivity: lastActivity, worktreeDirty: worktreeDirty, branchMerged: branchMerged)
    }

    /// Sort priority so sessions that need attention float to the top.
    public var stateRank: Int {
        switch state {
        case .needsInput: 0
        case .working: 1
        case .errored: 2
        case .finished: 3
        case .idle: 4
        }
    }

    /// Working and needs-input sessions are mid-turn; hiding one would hide
    /// live state or a pending question, so only quiet states can be dismissed.
    public var canDismiss: Bool {
        switch state {
        case .working, .needsInput: false
        case .idle, .finished, .errored: true
        }
    }
}
