import Foundation
@testable import ArgusCore

final class CodexAdapterTests {
    private let root: URL
    /// Fixed to midday so the scanner's "used today" window never straddles
    /// midnight and the tests stay deterministic no matter when they run.
    private let now = Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: .now)!

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-codex-tests-\(UUID().uuidString)")
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
    private func writeRollout(uuid: String = "01a07979-04b1-7650-8f8c-406c5b3185a3", age: TimeInterval, lines: [String]) throws -> String {
        let day = Calendar.current.startOfDay(for: now)
        let dayNumber = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dir = root.appendingPathComponent("sessions/\(dayNumber.year!)/\(dayNumber.month!)/\(dayNumber.day!)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "rollout-2026-09-06T21-26-09-\(uuid).jsonl"
        let file = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)],
            ofItemAtPath: file.path
        )
        return name
    }

    private func writeIndex(_ entries: [String]) throws {
        try entries.joined(separator: "\n").write(
            to: root.appendingPathComponent("session_index.jsonl"),
            atomically: true, encoding: .utf8)
    }

    private func adapter() -> CodexAdapter {
        CodexAdapter(root: root, clock: { [now] in now })
    }

    private let threadID = "01a07979-04b1-7650-8f8c-406c5b3185a3"

    private func meta(age: TimeInterval, id: String? = nil, cwd: String = "/Users/me/work/myrepo", extra: String = "") -> String {
        #"{"timestamp":"\#(iso(now.addingTimeInterval(-age)))","type":"session_meta","payload":{"id":"\#(id ?? threadID)","cwd":"\#(cwd)"\#(extra)}}"#
    }

    private func event(_ age: TimeInterval, _ type: String) -> String {
        #"{"timestamp":"\#(iso(now.addingTimeInterval(-age)))","type":"event_msg","payload":{"type":"\#(type)"}}"#
    }

    private func responseItem(_ age: TimeInterval, _ payload: String) -> String {
        #"{"timestamp":"\#(iso(now.addingTimeInterval(-age)))","type":"response_item","payload":\#(payload)}"#
    }

    private func tokenCount(_ age: TimeInterval, usage: String) -> String {
        #"{"timestamp":"\#(iso(now.addingTimeInterval(-age)))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":\#(usage)}}}"#
    }

    private let sampleUsage = #"{"input_tokens":1000,"cached_input_tokens":200,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":24,"total_tokens":1100}"#

    // MARK: - State mapping

    func pendingToolCallWithinGraceIsWorking() throws {
        try writeRollout(age: 5, lines: [
            meta(age: 60),
            responseItem(5, #"{"type":"custom_tool_call","name":"shell","input":{}}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func longShellToolDoesNotNeedInput() throws {
        try writeRollout(age: 10 * 60, lines: [
            meta(age: 120),
            responseItem(10 * 60, #"{"type":"function_call","name":"shell","arguments":"{}"}"#),
        ])
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.first?.state, .working)
        var alerts = AlertTracker()
        try expectEqual(alerts.alerts(for: sessions).count, 0)
    }

    func toolOutputThenAssistantMeansWorking() throws {
        try writeRollout(age: 5, lines: [
            meta(age: 60),
            responseItem(20, #"{"type":"custom_tool_call","name":"shell"}"#),
            responseItem(10, #"{"type":"custom_tool_call_output","output":"ok"}"#),
            responseItem(5, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"thanks"}]}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func quietAssistantTextMeansFinished() throws {
        try writeRollout(age: 10 * 60, lines: [
            meta(age: 20 * 60),
            responseItem(10 * 60, #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"All done."}]}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .finished)
    }

    // MARK: - Session fields

    func capturesCwdModelTokensAndCost() throws {
        try writeRollout(age: 60, lines: [
            meta(age: 120),
            #"{"timestamp":"\#(iso(now.addingTimeInterval(-100)))","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#,
            tokenCount(100, usage: sampleUsage),
            responseItem(60, #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}"#),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.repo, "myrepo")
        try expectEqual(session.worktreePath, "/Users/me/work/myrepo")
        try expectEqual(session.model, "gpt-5.6-terra")
        try expectEqual(session.harness, "Codex")
        try expectEqual(session.inputTokens, 1000)
        try expectEqual(session.outputTokens, 100)
        // GPT-5 rates: (800*1.25 + 100*10 + 200*1.25*0.1) / 1M
        try expectApprox(session.cost, 0.002025)
        try expectApprox(session.costToday, 0.002025)
    }

    func idIsThreadIdFromSessionMeta() throws {
        try writeRollout(age: 60, lines: [
            meta(age: 120),
            responseItem(60, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}"#),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.id, "Codex/01a07979-04b1-7650-8f8c-406c5b3185a3")
    }

    func usesThreadNameFromIndexAsSessionName() throws {
        try writeRollout(age: 60, lines: [
            meta(age: 120),
            responseItem(90, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"the first prompt"}]}"#),
        ])
        try writeIndex([#"{"id":"01a07979-04b1-7650-8f8c-406c5b3185a3","thread_name":"Generate Tock project logo"}"#])
        try expectEqual(adapter().scan().sessions.first?.sessionName, "Generate Tock project logo")
    }

    func fallsBackToFirstUserMessageForSessionName() throws {
        try writeRollout(age: 60, lines: [
            meta(age: 120),
            responseItem(90, #"{"type":"message","role":"developer","content":[{"type":"input_text","text":"<app-context>nope"}]}"#),
            responseItem(80, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"the real prompt"}]}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.sessionName, "the real prompt")
    }

    func explicitQuestionSurvivesMidnight() throws {
        let age: TimeInterval = 13 * 60 * 60
        try writeRollout(age: age, lines: [
            meta(age: age),
            responseItem(age, #"{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"question\":\"Which region?\"}]}"}"#),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .needsInput)
        try expectEqual(session.question, "Which region?")
        try expectApprox(session.costToday, 0)
    }

    func explicitQuestionOutputClearsWait() throws {
        try writeRollout(age: 5, lines: [
            meta(age: 600),
            responseItem(600, #"{"type":"custom_tool_call","name":"functions.request_user_input","input":{"questions":[{"question":"Which region?"}]}}"#),
            responseItem(5, #"{"type":"custom_tool_call_output","output":"Toronto"}"#),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .working)
        try expectEqual(session.question, nil)
    }

    func emptyInputRequestIsNotQuestionEvidence() throws {
        try writeRollout(age: 600, lines: [meta(age: 1200), responseItem(600, #"{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[]}"}"#)])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func skipsSessionsNotUsedToday() throws {
        try writeRollout(age: 26 * 60 * 60, lines: [meta(age: 26 * 60 * 60)])
        try expect(adapter().scan().sessions.isEmpty, "yesterday's rollout should be excluded")
    }

    func asyncQuestionNeedsInputWhileAgentKeepsWorking() throws {
        try writeRollout(age: 5, lines: [
            meta(age: 600),
            responseItem(60, #"{"type":"function_call","name":"request_user_input_async","call_id":"q1","arguments":"{\"questions\":[{\"title\":\"Leave conflicts blank or use the most common value?\",\"options\":[\"Blank\",\"Common\"]}]}"}"#),
            responseItem(59, #"{"type":"function_call_output","call_id":"q1","output":"{\"accepted\":true}"}"#),
            responseItem(5, #"{"type":"custom_tool_call","name":"exec","call_id":"c1"}"#),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .needsInput)
        try expectEqual(session.question, "Leave conflicts blank or use the most common value?")
    }

    func asyncQuestionSurvivesMidnightBehindLongWork() throws {
        let age: TimeInterval = 13 * 60 * 60
        let output = String(repeating: "x", count: 1000)
        let work = (0..<100).flatMap { i in [
            responseItem(age, #"{"type":"custom_tool_call","name":"exec","call_id":"c\#(i)"}"#),
            responseItem(age, #"{"type":"custom_tool_call_output","call_id":"c\#(i)","output":"\#(output)"}"#),
        ] }
        try writeRollout(age: age, lines: [
            meta(age: age),
            responseItem(age, #"{"type":"function_call","name":"request_user_input_async","call_id":"q1","arguments":"{\"questions\":[{\"title\":\"Which region?\"}]}"}"#),
            responseItem(age, #"{"type":"function_call_output","call_id":"q1","output":"{\"accepted\":true}"}"#),
        ] + work + [event(age, "task_complete")])
        let session = try required(adapter().scan().sessions.first, "An open question far behind later work must survive midnight")
        try expectEqual(session.state, .needsInput)
        try expectEqual(session.question, "Which region?")
    }

    func userReplyClearsAsyncQuestion() throws {
        try writeRollout(age: 5, lines: [
            meta(age: 600),
            responseItem(60, #"{"type":"function_call","name":"request_user_input_async","call_id":"q1","arguments":"{\"questions\":[{\"title\":\"Which region?\"}]}"}"#),
            responseItem(59, #"{"type":"function_call_output","call_id":"q1","output":"{\"accepted\":true}"}"#),
            responseItem(5, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"<send_user_message_question_reply>Toronto</send_user_message_question_reply>"}]}"#),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .working)
        try expectEqual(session.question, nil)
    }

    func taskCompleteMeansFinishedWithoutQuietWait() throws {
        try writeRollout(age: 5, lines: [
            meta(age: 600),
            responseItem(6, #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}"#),
            event(5, "task_complete"),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .finished)
    }

    func turnAbortedMeansIdle() throws {
        try writeRollout(age: 5, lines: [
            meta(age: 600),
            responseItem(10, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"stop"}]}"#),
            event(5, "turn_aborted"),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .idle)
    }

    func capturesBranchFromSessionMeta() throws {
        try writeRollout(age: 60, lines: [
            meta(age: 120, extra: #","git":{"commit_hash":"abc","branch":"feature-x"}"#),
            responseItem(60, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.branch, "feature-x")
    }

    func foldsChildThreadsIntoParent() throws {
        let child = "01a13ba1-a606-7fc0-9745-0592545fcbca"
        try writeRollout(age: 60, lines: [
            meta(age: 120, extra: #","thread_source":"user""#),
            tokenCount(100, usage: sampleUsage),
            responseItem(60, #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hi"}]}"#),
        ])
        try writeRollout(uuid: child, age: 30, lines: [
            meta(age: 40, id: child, extra: #","parent_thread_id":"\#(threadID)","thread_source":"guardian_review""#),
            meta(age: 40, extra: #","thread_source":"user""#),
            tokenCount(35, usage: sampleUsage),
            responseItem(30, #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"approved"}]}"#),
        ])
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.map(\.id), ["Codex/\(threadID)"])
        try expectApprox(sessions[0].costToday, 2 * 0.002025)
        try expectEqual(sessions[0].inputTokens, 2000)
    }

    func mergesContinuationPagesOfOneThread() throws {
        try writeRollout(age: 3 * 60 * 60, lines: [
            meta(age: 4 * 60 * 60),
            responseItem(4 * 60 * 60, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"the first prompt"}]}"#),
            tokenCount(3 * 60 * 60, usage: sampleUsage),
        ])
        try writeRollout(uuid: "\(threadID)_01a13b83-e9a8-7bf0-80c1-71817f8cd47e", age: 60, lines: [
            meta(age: 120),
            responseItem(90, #"{"type":"message","role":"user","content":[{"type":"input_text","text":"a later prompt"}]}"#),
            tokenCount(70, usage: sampleUsage),
            responseItem(60, #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"working on it"}]}"#),
        ])
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.map(\.id), ["Codex/\(threadID)"])
        try expectEqual(sessions[0].state, .working)
        try expectEqual(sessions[0].sessionName, "the first prompt")
        try expectApprox(sessions[0].costToday, 2 * 0.002025)
    }
}
