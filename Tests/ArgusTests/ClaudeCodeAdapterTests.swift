import Foundation
@testable import ArgusCore

final class ClaudeCodeAdapterTests {
    private let root: URL
    /// Fixed to midday so the scanner's "used today" window never straddles
    /// midnight and the tests stay deterministic no matter when they run.
    private let now = Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: .now)!

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @discardableResult
    private func writeTranscript(project: String = "myrepo", age: TimeInterval, lines: [String]) throws -> URL {
        let dir = root.appendingPathComponent("-Users-me-\(project)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)],
            ofItemAtPath: file.path
        )
        return file
    }

    private func adapter() -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(root: root, clock: { [now] in now })
    }

    private func assistant(age: TimeInterval, blocks: String, model: String = "claude-sonnet-4-5", usage: String? = nil, cwd: String = "/Users/me/work/myrepo") -> String {
        var message = #"{"model":"\#(model)""#
        if let usage {
            message += #","usage":\#(usage)"#
        }
        message += #","content":[\#(blocks)]}"#
        return #"{"type":"assistant","timestamp":"\#(iso(now.addingTimeInterval(-age)))","cwd":"\#(cwd)","gitBranch":"main","message":\#(message)}"#
    }

    private func user(age: TimeInterval, content: String, cwd: String = "/Users/me/work/myrepo") -> String {
        #"{"type":"user","timestamp":"\#(iso(now.addingTimeInterval(-age)))","cwd":"\#(cwd)","message":{"role":"user","content":\#(content)}}"#
    }

    // MARK: - State mapping

    func recentUserMessageMeansWorking() throws {
        try writeTranscript(age: 5, lines: [user(age: 5, content: #""go ahead""#)])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func justArrivedToolResultMeansWorking() throws {
        let toolUse = assistant(age: 20, blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{}}"#)
        let result = user(age: 5, content: #"[{"type":"tool_result","tool_use_id":"t1","content":"done"}]"#)
        try writeTranscript(age: 5, lines: [toolUse, result])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func longBashToolDoesNotNeedInput() throws {
        try writeTranscript(age: 10 * 60, lines: [assistant(age: 10 * 60, blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{}}"#)])
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.first?.state, .working)
        var alerts = AlertTracker()
        try expectEqual(alerts.alerts(for: sessions).count, 0)
    }

    func pendingToolCallWithinGraceIsWorking() throws {
        try writeTranscript(age: 5, lines: [assistant(age: 5, blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{}}"#)])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func askUserQuestionIsImmediatelyNeedsInputWithQuestionText() throws {
        let blocks = #"{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Deploy now?","header":"Deploy"}]}}"#
        try writeTranscript(age: 1, lines: [assistant(age: 1, blocks: blocks)])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .needsInput)
        try expectEqual(session.question, "Deploy now?")
    }


    func unansweredQuestionSurvivesMidnightWithTodayCostOnly() throws {
        let age: TimeInterval = 13 * 60 * 60
        let blocks = #"{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Which deployment?"}]}}"#
        try writeTranscript(age: age, lines: [assistant(age: age, blocks: blocks, usage: #"{"input_tokens":100,"output_tokens":20}"#)])
        let session = try required(adapter().scan().sessions.first, "An unanswered question must survive midnight and restart")
        try expectEqual(session.state, .needsInput)
        try expectEqual(session.question, "Which deployment?")
        try expectApprox(session.costToday, 0)
        try expectApprox(session.cost, 0.0006)
    }

    func exitPlanModeDoesNotClaimPermissionWait() throws {
        try writeTranscript(age: 600, lines: [assistant(age: 600, blocks: #"{"type":"tool_use","id":"plan","name":"ExitPlanMode","input":{}}"#)])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func emptyQuestionIsNotInputEvidence() throws {
        try writeTranscript(age: 600, lines: [assistant(age: 600, blocks: #"{"type":"tool_use","id":"q","name":"AskUserQuestion","input":{"questions":[]}}"#)])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func questionResultClearsWait() throws {
        let blocks = #"{"type":"tool_use","id":"q","name":"AskUserQuestion","input":{"questions":[{"question":"Deploy?"}]}}"#
        try writeTranscript(age: 5, lines: [assistant(age: 600, blocks: blocks), user(age: 5, content: #"[{"type":"tool_result","tool_use_id":"q","content":"Later"}]"#)])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .working)
        try expectEqual(session.question, nil)
    }

    func abandonedGenericToolBecomesIdle() throws {
        try writeTranscript(age: 40 * 60, lines: [assistant(age: 40 * 60, blocks: #"{"type":"tool_use","id":"bash","name":"Bash","input":{}}"#)])
        try expectEqual(adapter().scan().sessions.first?.state, .idle)
    }

    func quietAssistantTextMeansFinished() throws {
        try writeTranscript(age: 10 * 60, lines: [assistant(age: 10 * 60, blocks: #"{"type":"text","text":"All done."}"#)])
        try expectEqual(adapter().scan().sessions.first?.state, .finished)
    }

    func quietToolResultMeansFinished() throws {
        let toolUse = assistant(age: 10 * 60, blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{}}"#)
        let result = user(age: 10 * 60, content: #"[{"type":"tool_result","tool_use_id":"t1","content":"done"}]"#)
        try writeTranscript(age: 10 * 60, lines: [toolUse, result])
        try expectEqual(adapter().scan().sessions.first?.state, .finished)
    }

    func veryQuietToolResultMeansIdle() throws {
        let toolUse = assistant(age: 40 * 60, blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{}}"#)
        let result = user(age: 40 * 60, content: #"[{"type":"tool_result","tool_use_id":"t1","content":"done"}]"#)
        try writeTranscript(age: 40 * 60, lines: [toolUse, result])
        try expectEqual(adapter().scan().sessions.first?.state, .idle)
    }

    func veryQuietUserMessageMeansIdle() throws {
        try writeTranscript(age: 40 * 60, lines: [user(age: 40 * 60, content: #""hello""#)])
        try expectEqual(adapter().scan().sessions.first?.state, .idle)
    }

    func apiErrorMessageMeansErrored() throws {
        let line = #"{"type":"assistant","timestamp":"\#(iso(now.addingTimeInterval(-30)))","cwd":"/Users/me/work/myrepo","gitBranch":"main","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 500"}]}}"#
        try writeTranscript(age: 30, lines: [line])
        try expectEqual(adapter().scan().sessions.first?.state, .errored)
    }

    // MARK: - Session fields

    func capturesRepoBranchCostAndTokens() throws {
        let usage = #"{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#
        try writeTranscript(age: 60, lines: [
            assistant(age: 60, blocks: #"{"type":"text","text":"hi"}"#, model: "claude-sonnet-4-5", usage: usage),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.repo, "myrepo")
        try expectEqual(session.worktreePath, "/Users/me/work/myrepo")
        try expectEqual(session.branch, "main")
        try expectEqual(session.machine, "This Mac")
        try expectEqual(session.model, "claude-sonnet-4-5")
        try expectEqual(session.harness, "Claude Code")
        try expectEqual(session.inputTokens, 1000)
        try expectEqual(session.outputTokens, 500)
        // Sonnet: (1000*3 + 500*15) / 1M
        try expectApprox(session.cost, 0.0105)
        try expectApprox(session.costToday, 0.0105)
    }

    func capturesCustomTitleAsSessionName() throws {
        let title = #"{"type":"custom-title","customTitle":"Proxy Builder tile copy"}"#
        try writeTranscript(age: 60, lines: [
            user(age: 120, content: #""build the proxy""#),
            title,
        ])
        try expectEqual(adapter().scan().sessions.first?.sessionName, "Proxy Builder tile copy")
    }

    func fallsBackToFirstUserMessageForSessionName() throws {
        try writeTranscript(age: 60, lines: [
            user(age: 120, content: #""Add the session name\nacross two lines""#),
            assistant(age: 60, blocks: #"{"type":"text","text":"On it."}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.sessionName, "Add the session name across two lines")
    }

    func ignoresCommandEntriesForSessionName() throws {
        try writeTranscript(age: 60, lines: [
            user(age: 120, content: #""<command-name>/clear</command-name>""#),
            user(age: 100, content: #""the real prompt""#),
        ])
        try expectEqual(adapter().scan().sessions.first?.sessionName, "the real prompt")
    }

    func usesSlashCommandArgumentsInsteadOfSkillInstructionsForSessionName() throws {
        try writeTranscript(age: 60, lines: [
            user(age: 120, content: #""<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>Fix the tray layout</command-args>""#),
            user(age: 100, content: #""Base directory for this skill: /tmp/review\n\n## Local compatibility""#),
        ])
        try expectEqual(adapter().scan().sessions.first?.sessionName, "Fix the tray layout")
    }

    func sortsNeedsInputFirst() throws {
        let quietCwd = "/Users/me/work/quiet"
        try writeTranscript(project: "quiet", age: 10 * 60, lines: [
            assistant(age: 10 * 60, blocks: #"{"type":"text","text":"done"}"#, cwd: quietCwd),
        ])
        try writeTranscript(project: "blocked", age: 60, lines: [
            assistant(age: 60, blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{}}"#, cwd: "/Users/me/work/blocked"),
        ])
        try expectEqual(adapter().scan().sessions.map(\.repo), ["blocked", "quiet"])
    }

    func skipsSessionsNotUsedToday() throws {
        try writeTranscript(age: 26 * 60 * 60, lines: [user(age: 26 * 60 * 60, content: #""hi""#)])
        try expect(adapter().scan().sessions.isEmpty, "yesterday's session should be excluded")
    }

    func showsSessionsUsedTodayEvenAfterHoursIdle() throws {
        try writeTranscript(age: 3 * 60 * 60, lines: [
            assistant(age: 3 * 60 * 60, blocks: #"{"type":"text","text":"done"}"#),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .idle)
    }

    func skipsFilesWithoutConversation() throws {
        try writeTranscript(age: 10, lines: [
            #"{"type":"attachment","timestamp":"2026-09-05T10:00:00.000Z"}"#,
        ])
        try expect(adapter().scan().sessions.isEmpty, "file without conversation entries should be excluded")
    }

    /// Claude Code writes each subagent to `<session>/subagents/agent-<id>.jsonl`
    /// with `isSidechain` and the parent's `sessionId` on every record.
    private func writeSubagent(of parent: URL, age: TimeInterval, lines: [String]) throws {
        let sessionID = parent.deletingPathExtension().lastPathComponent
        let dir = parent.deletingPathExtension().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("agent-\(UUID().uuidString).jsonl")
        let sidechain = lines.map { "{\"isSidechain\":true,\"sessionId\":\"\(sessionID)\"," + $0.dropFirst() }
        try sidechain.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    func runningSubagentKeepsQuietParentWorking() throws {
        let usage = #"{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#
        let parent = try writeTranscript(age: 5 * 60, lines: [
            user(age: 6 * 60, content: #""Parent task""#),
            assistant(age: 5 * 60, blocks: #"{"type":"text","text":"Waiting for the subagent."}"#, usage: usage),
        ])
        try writeSubagent(of: parent, age: 60, lines: [
            assistant(age: 60, blocks: #"{"type":"tool_use","id":"t1","name":"Bash","input":{}}"#, usage: usage),
        ])
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions.first?.sessionName, "Parent task")
        try expectEqual(sessions.first?.state, .working)
        // Two Sonnet messages: 2 * (1000*3 + 500*15) / 1M
        try expectApprox(sessions.first?.cost ?? 0, 0.021)
    }

    func finishedSubagentLetsQuietParentFinish() throws {
        let parent = try writeTranscript(age: 5 * 60, lines: [
            user(age: 6 * 60, content: #""Parent task""#),
            assistant(age: 5 * 60, blocks: #"{"type":"text","text":"All done."}"#),
        ])
        try writeSubagent(of: parent, age: 5 * 60, lines: [
            assistant(age: 5 * 60, blocks: #"{"type":"text","text":"Child done."}"#),
        ])
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions.first?.state, .finished)
    }

    func sessionsAreStableAcrossScansViaCache() throws {
        try writeTranscript(age: 10, lines: [user(age: 10, content: #""hi""#)])
        try expectEqual(adapter().scan().sessions, adapter().scan().sessions)
    }
}
