import Foundation
@testable import ArgusCore

final class ScanHealthTests {
    private let root: URL
    private let now = Date()

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("argus-health-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func validClaudeRecord() -> String {
        let timestamp = ISO8601DateFormatter().string(from: now)
        return #"{"type":"user","timestamp":"\#(timestamp)","cwd":"/tmp/health-repo","message":{"content":"Check source health"}}"#
    }

    private func write(_ text: String, file: String = "test.jsonl") throws {
        try text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func distinguishesMissingReadableEmptyAndFailedRoot() throws {
        let missing = root.appendingPathComponent("missing")
        try expectEqual(ClaudeCodeAdapter(root: missing).scan(), .unavailable(source: missing.path))
        try expectEqual(ClaudeCodeAdapter(root: root).scan(), .complete(sessions: []))
        let regularFile = root.appendingPathComponent("regular-file")
        try "data".write(to: regularFile, atomically: true, encoding: .utf8)
        guard case .failed(let issues) = ClaudeCodeAdapter(root: regularFile).scan() else {
            throw TestFailure(message: "A file used as a source directory must fail", file: #fileID, line: #line)
        }
        try expectEqual(issues.count, 1)
        try expectEqual(issues[0].source, regularFile.path)
    }

    func malformedCompleteRecordPreservesSessionAndIssueAcrossCache() throws {
        try write(validClaudeRecord() + "\nnot-json\n")
        let adapter = ClaudeCodeAdapter(root: root, clock: { [now] in now })
        guard case .partial(let sessions, let issues) = adapter.scan() else {
            throw TestFailure(message: "Malformed complete records must report partial scans", file: #fileID, line: #line)
        }
        try expectEqual(sessions.first?.sessionName, "Check source health")
        try expectEqual(issues.count, 1)
        try expectEqual(issues[0].message, "Malformed transcript record on line 2.")
        try expectEqual(adapter.scan(), .partial(sessions: sessions, issues: issues))
    }

    func incompleteStreamingTailDoesNotMakeSourceFail() throws {
        try write(validClaudeRecord() + "\n" + #"{"type":"assistant","message":{"content":"still writing"#)
        guard case .complete(let sessions) = ClaudeCodeAdapter(root: root, clock: { [now] in now }).scan() else {
            throw TestFailure(message: "A streaming tail must keep the source healthy", file: #fileID, line: #line)
        }
        try expectEqual(sessions.first?.sessionName, "Check source health")
    }

    func completedMalformedTailReportsIssueWithoutNewline() throws {
        try write(validClaudeRecord() + "\n{not-json}")
        guard case .partial(let sessions, let issues) = ClaudeCodeAdapter(root: root, clock: { [now] in now }).scan() else {
            throw TestFailure(message: "A complete bad final record must be visible", file: #fileID, line: #line)
        }
        try expectEqual(sessions.first?.sessionName, "Check source health")
        try expectEqual(issues.count, 1)
    }

    func brokenTranscriptPreservesOtherReadableSessions() throws {
        try write(validClaudeRecord())
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("broken.jsonl"),
            withDestinationURL: root.appendingPathComponent("does-not-exist"))
        guard case .partial(let sessions, let issues) = ClaudeCodeAdapter(root: root, clock: { [now] in now }).scan() else {
            throw TestFailure(message: "An unreadable transcript must report a partial scan", file: #fileID, line: #line)
        }
        try expectEqual(sessions.first?.sessionName, "Check source health")
        try expectEqual(issues.count, 1)
        try expectEqual(URL(fileURLWithPath: issues[0].source).lastPathComponent, "broken.jsonl")
    }

    func allTranscriptAdaptersReportMalformedRecords() throws {
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try "not-json\n".write(to: sessions.appendingPathComponent("bad.jsonl"), atomically: true, encoding: .utf8)
        try write("not-json\n")
        let adapters: [any HarnessAdapter] = [PiAdapter(root: root), CodexAdapter(root: root)]
        for adapter in adapters {
            guard case .partial(_, let issues) = adapter.scan() else {
                throw TestFailure(message: "\(adapter.name) must report corrupt records", file: #fileID, line: #line)
            }
            try expect(!issues.isEmpty, "Corrupt source must contain an issue")
            try expectEqual(issues.first?.message, "Malformed transcript record on line 1.")
        }
    }
}
