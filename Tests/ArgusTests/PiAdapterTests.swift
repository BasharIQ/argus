import Foundation
@testable import ArgusCore

final class PiAdapterTests {
    private let root: URL
    /// Fixed to midday so the scanner's "used today" window never straddles
    /// midnight and the tests stay deterministic no matter when they run.
    private let now = Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: .now)!

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-pi-tests-\(UUID().uuidString)")
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
    private func writeSession(project: String = "pirepo", age: TimeInterval, lines: [String], filename: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent("--Users-me-work-\(project)--")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(filename ?? "\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)],
            ofItemAtPath: file.path
        )
        return file
    }

    private func sessionHeader(age: TimeInterval = 3600) -> String {
        #"{"type":"session","id":"s1","version":2,"timestamp":"\#(iso(now.addingTimeInterval(-age)))","cwd":"/Users/me/work/pirepo"}"#
    }

    private func assistant(age: TimeInterval, blocks: String, usage: String? = nil, model: String? = nil, provider: String? = nil) -> String {
        var message = #"{"role":"assistant","content":[\#(blocks)]"#
        if let model {
            message += #","model":"\#(model)""#
        }
        if let provider {
            message += #","provider":"\#(provider)""#
        }
        if let usage {
            message += #","usage":\#(usage)"#
        }
        return #"{"type":"message","id":"m1","parentId":null,"timestamp":"\#(iso(now.addingTimeInterval(-age)))","message":\#(message)}}"#
    }

    private func user(age: TimeInterval) -> String {
        #"{"type":"message","id":"m2","parentId":null,"timestamp":"\#(iso(now.addingTimeInterval(-age)))","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]}}"#
    }

    private func toolResult(age: TimeInterval) -> String {
        #"{"type":"message","id":"m3","parentId":null,"timestamp":"\#(iso(now.addingTimeInterval(-age)))","message":{"role":"toolResult","content":[{"type":"text","text":"ok"}]}}"#
    }

    private func adapter() -> PiAdapter {
        PiAdapter(root: root, clock: { [now] in now })
    }

    private var sampleUsage: String {
        #"{"input":3267,"output":365,"cacheRead":39424,"cacheWrite":0,"reasoning":239,"totalTokens":43056,"cost":{"input":0.006534,"output":0.00438,"cacheRead":0.0078848,"cacheWrite":0,"total":0.0187988}}"#
    }

    // MARK: - State mapping

    func recentUserMessageMeansWorking() throws {
        try writeSession(age: 5, lines: [sessionHeader(), user(age: 5)])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func toolResultArrivedMeansWorking() throws {
        try writeSession(age: 5, lines: [
            sessionHeader(),
            assistant(age: 20, blocks: #"{"type":"toolCall","id":"c1","name":"grep","arguments":{}}"#),
            toolResult(age: 5),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func longBashToolDoesNotNeedInput() throws {
        try writeSession(age: 10 * 60, lines: [
            sessionHeader(),
            assistant(age: 10 * 60, blocks: #"{"type":"toolCall","id":"c1","name":"bash","arguments":{}}"#),
        ])
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.first?.state, .working)
        var alerts = AlertTracker()
        try expectEqual(alerts.alerts(for: sessions).count, 0)
    }

    func pendingToolCallWithinGraceIsWorking() throws {
        try writeSession(age: 5, lines: [
            sessionHeader(),
            assistant(age: 5, blocks: #"{"type":"toolCall","id":"c1","name":"bash","arguments":{}}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func quietAssistantTextMeansFinished() throws {
        try writeSession(age: 10 * 60, lines: [
            sessionHeader(),
            assistant(age: 10 * 60, blocks: #"{"type":"text","text":"All done."}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .finished)
    }

    func veryQuietUserMessageMeansIdle() throws {
        try writeSession(age: 40 * 60, lines: [sessionHeader(), user(age: 40 * 60)])
        try expectEqual(adapter().scan().sessions.first?.state, .idle)
    }

    func quietToolResultMeansFinished() throws {
        try writeSession(age: 10 * 60, lines: [
            sessionHeader(),
            assistant(age: 10 * 60, blocks: #"{"type":"toolCall","id":"c1","name":"bash","arguments":{}}"#),
            toolResult(age: 10 * 60),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .finished)
    }

    func veryQuietToolResultMeansIdle() throws {
        try writeSession(age: 40 * 60, lines: [
            sessionHeader(),
            assistant(age: 40 * 60, blocks: #"{"type":"toolCall","id":"c1","name":"bash","arguments":{}}"#),
            toolResult(age: 40 * 60),
        ])
        try expectEqual(adapter().scan().sessions.first?.state, .idle)
    }

    // MARK: - Session fields

    func usesRealCostFromUsageAndCountsReasoningAsOutput() throws {
        let secondUsage = #"{"input":584,"output":339,"cacheRead":42496,"cacheWrite":0,"reasoning":0,"totalTokens":43419,"cost":{"total":0.0137352}}"#
        try writeSession(age: 60, lines: [
            sessionHeader(),
            assistant(age: 120, blocks: #"{"type":"text","text":"step one"}"#, usage: sampleUsage),
            assistant(age: 60, blocks: #"{"type":"text","text":"step two"}"#, usage: secondUsage),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.harness, "Pi")
        try expectEqual(session.machine, "This Mac")
        try expectEqual(session.repo, "pirepo")
        try expectEqual(session.worktreePath, "/Users/me/work/pirepo")
        // input = 3267+39424+0 + 584+42496+0
        try expectEqual(session.inputTokens, 42691 + 43080)
        // output = 365+239 + 339+0 (reasoning counts as output)
        try expectEqual(session.outputTokens, 604 + 339)
        try expectApprox(session.cost, 0.0187988 + 0.0137352)
        try expectApprox(session.costToday, 0.0187988 + 0.0137352)
        try expect(session.branch == nil, "Pi transcripts carry no branch")
    }

    func capturesModelFromAssistantAndModelChangeEntries() throws {
        let modelChange = #"{"type":"model_change","id":"c0","parentId":null,"timestamp":"\#(iso(now.addingTimeInterval(-120)))","provider":"openai-codex","modelId":"gpt-5.6-terra"}"#
        try writeSession(age: 60, lines: [
            sessionHeader(),
            modelChange,
            assistant(age: 60, blocks: #"{"type":"text","text":"hi"}"#, model: "gpt-5.6-terra", provider: "openai-codex"),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.model, "openai-codex/gpt-5.6-terra")
    }

    func derivesSessionNameFromFirstUserMessage() throws {
        try writeSession(age: 60, lines: [
            sessionHeader(),
            user(age: 120),
            assistant(age: 60, blocks: #"{"type":"text","text":"On it."}"#),
        ])
        try expectEqual(adapter().scan().sessions.first?.sessionName, "do the thing")
    }

    func skipsSessionsNotUsedToday() throws {
        try writeSession(age: 26 * 60 * 60, lines: [
            sessionHeader(age: 26 * 60 * 60),
            user(age: 26 * 60 * 60),
        ])
        try expect(adapter().scan().sessions.isEmpty, "yesterday's session should be excluded")
    }

    func showsSessionsUsedTodayEvenAfterHoursIdle() throws {
        try writeSession(age: 3 * 60 * 60, lines: [
            sessionHeader(),
            assistant(age: 3 * 60 * 60, blocks: #"{"type":"text","text":"done"}"#),
        ])
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .idle)
    }

    func skipsChildSessionsPointingAtAParent() throws {
        // Forked/subagent files carry parentSession in the header (pi ≥0.85
        // writes version 3 with the parent file path). Only the main
        // session should list.
        let childHeader = #"{"type":"session","id":"s2","version":3,"timestamp":"\#(iso(now.addingTimeInterval(-300)))","cwd":"/Users/me/work/pirepo","parentSession":"2026-09-08T10-00-00-000Z_s1.jsonl"}"#
        try writeSession(age: 300, lines: [childHeader, user(age: 300)])
        try writeSession(age: 300, lines: [sessionHeader(), user(age: 300)])
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions.first?.sessionName, "do the thing")
    }

    func skipsExtensionChildSessionFile() throws {
        // pi-subagents spawns children into a fixed session.jsonl with no
        // parentSession marker; pi itself only writes timestamped names.
        try writeSession(age: 60, lines: [sessionHeader(), user(age: 60)], filename: "session.jsonl")
        try writeSession(age: 60, lines: [sessionHeader(), user(age: 60)])
        try expectEqual(adapter().scan().sessions.count, 1)
    }

    func skipsHeaderOnlyFiles() throws {
        try writeSession(age: 10, lines: [sessionHeader()])
        try expect(adapter().scan().sessions.isEmpty, "session without messages should be excluded")
    }

    func sessionsAreStableAcrossScansViaCache() throws {
        try writeSession(age: 10, lines: [sessionHeader(), user(age: 10)])
        try expectEqual(adapter().scan().sessions, adapter().scan().sessions)
    }
}
