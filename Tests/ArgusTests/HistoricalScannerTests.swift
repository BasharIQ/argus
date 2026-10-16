import Foundation
@testable import ArgusCore

final class HistoricalScannerTests {
    private let root: URL
    private let file: URL
    private let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("argus-history-\(UUID().uuidString)")
        file = root.appendingPathComponent("history.jsonl")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func assistant(at date: Date, blocks: String, usage: Bool = false) -> String {
        let timestamp = ISO8601DateFormatter().string(from: date)
        let tokens = usage ? #","usage":{"input_tokens":100,"output_tokens":20}"# : ""
        return #"{"type":"assistant","timestamp":"\#(timestamp)","cwd":"/tmp/history-repo","message":{"model":"claude-sonnet-4-5"\#(tokens),"content":[\#(blocks)]}}"#
    }

    private func largePrefix(at date: Date) -> String {
        assistant(at: date, blocks: #"{"type":"text","text":"\#(String(repeating: "x", count: 80_000))"}"#, usage: true)
    }

    private func question(at date: Date) -> String {
        assistant(at: date, blocks: #"{"type":"tool_use","id":"q","name":"AskUserQuestion","input":{"questions":[{"question":"Choose a deployment."}]}}"#)
    }

    private func write(_ records: [String], mtime: Date) throws {
        try (records.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
    }

    func largeInactiveHistoryIsExcludedWhileCurrentSessionRemains() throws {
        let yesterday = now.addingTimeInterval(-26 * 60 * 60)
        try write([largePrefix(at: yesterday), assistant(at: yesterday, blocks: #"{"type":"text","text":"Finished."}"#)], mtime: yesterday)
        let current = root.appendingPathComponent("current.jsonl")
        try question(at: now).write(to: current, atomically: true, encoding: .utf8)
        let adapter = ClaudeCodeAdapter(root: root, clock: { [now] in now })
        guard case .complete(let sessions) = adapter.scan() else {
            throw TestFailure(message: "Readable history and current session must stay healthy", file: #fileID, line: #line)
        }
        try expectEqual(sessions.map(\.id), ["Claude Code/current"])
        try expectEqual(sessions.first?.state, .needsInput)
        try expectEqual(adapter.scan().sessions.map(\.id), ["Claude Code/current"])
    }

    func largeHistoricalQuestionGetsFullFieldsAndCost() throws {
        let yesterday = now.addingTimeInterval(-3 * 24 * 60 * 60)
        try write([largePrefix(at: yesterday), question(at: yesterday)], mtime: yesterday)
        let session = try required(ClaudeCodeAdapter(root: root, clock: { [now] in now }).scan().sessions.first)
        try expectEqual(session.state, .needsInput)
        try expectEqual(session.question, "Choose a deployment.")
        try expectEqual(session.worktreePath, "/tmp/history-repo")
        try expectApprox(session.cost, 0.0006)
        try expectApprox(session.costToday, 0)
    }

    func recentPreMidnightWorkGetsFullCost() throws {
        let midnight = Calendar.current.startOfDay(for: now)
        let activity = midnight.addingTimeInterval(-120)
        let scanTime = midnight.addingTimeInterval(300)
        try write([largePrefix(at: activity), assistant(at: activity, blocks: #"{"type":"tool_use","id":"bash","name":"Bash","input":{}}"#)], mtime: activity)
        let session = try required(ClaudeCodeAdapter(root: root, clock: { scanTime }).scan().sessions.first)
        try expectEqual(session.state, .working)
        try expectApprox(session.cost, 0.0006)
        try expectApprox(session.costToday, 0)
    }

    func activityUpdateInvalidatesHistoricalExclusion() throws {
        let yesterday = now.addingTimeInterval(-26 * 60 * 60)
        let prefix = largePrefix(at: yesterday)
        let finished = assistant(at: yesterday, blocks: #"{"type":"text","text":"Finished."}"#)
        try write([prefix, finished], mtime: yesterday)
        let adapter = ClaudeCodeAdapter(root: root, clock: { [now] in now })
        try expectEqual(adapter.scan(), .complete(sessions: []))
        try write([prefix, finished, question(at: now)], mtime: now)
        let session = try required(adapter.scan().sessions.first)
        try expectEqual(session.state, .needsInput)
        try expectEqual(session.question, "Choose a deployment.")
        try expectApprox(session.cost, 0.0006)
    }

    func giantMetadataTailCannotHideAnEarlierQuestion() throws {
        let yesterday = now.addingTimeInterval(-26 * 60 * 60)
        let metadata = #"{"type":"custom-title","customTitle":"\#(String(repeating: "x", count: 80_000))"}"#
        try write([question(at: yesterday), metadata], mtime: yesterday)
        let session = try required(ClaudeCodeAdapter(root: root, clock: { [now] in now }).scan().sessions.first)
        try expectEqual(session.state, .needsInput)
        try expectEqual(session.question, "Choose a deployment.")
    }

    func incompleteFinalRecordForcesFullRead() throws {
        let yesterday = now.addingTimeInterval(-26 * 60 * 60)
        let finished = assistant(at: yesterday, blocks: #"{"type":"text","text":"Finished."}"#)
        try write(["not-json", largePrefix(at: yesterday), finished], mtime: yesterday)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","message":{"content":"still writing"#.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: file.path)
        guard case .partial(let sessions, let issues) = ClaudeCodeAdapter(root: root, clock: { [now] in now }).scan() else {
            throw TestFailure(message: "An incomplete final record cannot certify inactive history", file: #fileID, line: #line)
        }
        try expectEqual(sessions.count, 0)
        try expectEqual(issues.first?.message, "Malformed transcript record on line 1.")
    }

    func malformedHistoricalTailReportsFullRecordLocation() throws {
        let yesterday = now.addingTimeInterval(-26 * 60 * 60)
        let finished = assistant(at: yesterday, blocks: #"{"type":"text","text":"Finished."}"#)
        try write([largePrefix(at: yesterday), finished, "not-json"], mtime: yesterday)
        guard case .partial(_, let issues) = ClaudeCodeAdapter(root: root, clock: { [now] in now }).scan() else {
            throw TestFailure(message: "Malformed historical tail must be read fully", file: #fileID, line: #line)
        }
        try expectEqual(issues.first?.message, "Malformed transcript record on line 3.")
    }
}
