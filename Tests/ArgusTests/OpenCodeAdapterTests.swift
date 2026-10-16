import Foundation
import SQLite3
@testable import ArgusCore

final class OpenCodeAdapterTests {
    private let dbURL: URL
    /// Fixed to midday so the scanner's "used today" window never straddles
    /// midnight and the tests stay deterministic no matter when they run.
    private let now = Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: .now)!

    private var db: OpaquePointer?

    init() {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-opencode-\(UUID().uuidString).db")
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            fatalError("could not create test database")
        }
        self.db = db
        exec("""
        CREATE TABLE session_v2 (
          id text PRIMARY KEY, directory text NOT NULL, title text, model text,
          time_updated integer NOT NULL, time_archived integer, parent_id text);
        CREATE TABLE session (
          id text PRIMARY KEY, directory text NOT NULL, title text, model text,
          time_updated integer NOT NULL, time_archived integer, parent_id text);
        CREATE TABLE message (
          id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, data text NOT NULL);
        CREATE TABLE part (
          id text PRIMARY KEY, message_id text NOT NULL, data text NOT NULL);
        """)
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: dbURL)
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            fatalError("test db exec failed: \(error.map { String(cString: $0) } ?? "?")")
        }
    }

    /// Millisecond epoch, matching OpenCode's time columns.
    private func ms(_ age: TimeInterval) -> Int64 {
        Int64((now - age).timeIntervalSince1970 * 1000)
    }

    private func insertSession(id: String, title: String = "My session", directory: String = "/Users/me/work/myrepo",
                               model: String? = #"{"id":"claude-sonnet-4-5","providerID":"anthropic"}"#,
                               age: TimeInterval, parent: String? = nil, archived: Bool = false, table: String = "session_v2") {
        exec("""
        INSERT INTO \(table) (id, directory, title, model, time_updated, time_archived, parent_id)
        VALUES ('\(id)', '\(directory)', '\(title)', \(model.map { "'\($0)'" } ?? "NULL"), \(ms(age)), \(archived ? "\(ms(age))" : "NULL"), \(parent.map { "'\($0)'" } ?? "NULL"));
        """)
    }

    private func insertMessage(id: String, session: String, role: String, age: TimeInterval,
                               cost: Double = 0, input: Int = 0, output: Int = 0,
                               reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        exec("""
        INSERT INTO message (id, session_id, time_created, data) VALUES (
          '\(id)', '\(session)', \(ms(age)),
          '{"role":"\(role)","cost":\(cost),"tokens":{"input":\(input),"output":\(output),"reasoning":\(reasoning),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}}}');
        """)
    }

    private func insertPart(id: String, message: String, data: String) {
        exec("INSERT INTO part (id, message_id, data) VALUES ('\(id)', '\(message)', '\(data)');")
    }

    private func adapter() -> OpenCodeAdapter {
        OpenCodeAdapter(databaseURL: dbURL, clock: { [now] in now })
    }

    // MARK: - State mapping

    func userMessageMeansWorking() throws {
        insertSession(id: "ses_a", age: 60)
        insertMessage(id: "msg_a1", session: "ses_a", role: "assistant", age: 120)
        insertMessage(id: "msg_a2", session: "ses_a", role: "user", age: 60)
        try expectEqual(adapter().scan().sessions.first?.state, .working)
    }

    func longPendingToolDoesNotNeedInput() throws {
        insertSession(id: "ses_b", age: 10 * 60)
        insertMessage(id: "msg_b1", session: "ses_b", role: "user", age: 20 * 60)
        insertMessage(id: "msg_b2", session: "ses_b", role: "assistant", age: 10 * 60)
        insertPart(id: "part_b2a", message: "msg_b2", data: #"{"type":"step-start"}"#)
        insertPart(id: "part_b2b", message: "msg_b2", data: #"{"type":"tool","tool":"bash","state":{"status":"pending"}}"#)
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .working)
        try expectEqual(session.currentTool, "bash")
        var alerts = AlertTracker()
        try expectEqual(alerts.alerts(for: [session]).count, 0)
    }

    func assistantTextPartsMeanFinishedWhenQuiet() throws {
        insertSession(id: "ses_c", age: 10 * 60)
        insertMessage(id: "msg_c1", session: "ses_c", role: "assistant", age: 10 * 60)
        insertPart(id: "part_c1a", message: "msg_c1", data: #"{"type":"text","text":"All done."}"#)
        try expectEqual(adapter().scan().sessions.first?.state, .finished)
    }

    func completedToolFollowedByTextMeansFinished() throws {
        insertSession(id: "ses_complete", age: 10 * 60)
        insertMessage(id: "msg_complete", session: "ses_complete", role: "assistant", age: 10 * 60)
        insertPart(id: "part_complete_a", message: "msg_complete", data: #"{"type":"tool","tool":"bash","state":{"status":"completed"}}"#)
        insertPart(id: "part_complete_b", message: "msg_complete", data: #"{"type":"text","text":"Done."}"#)
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .finished)
        try expectEqual(session.currentTool, nil)
    }

    func runningToolStaysWorking() throws {
        insertSession(id: "ses_running", age: 40 * 60)
        insertMessage(id: "msg_running", session: "ses_running", role: "assistant", age: 40 * 60)
        insertPart(id: "part_running", message: "msg_running", data: #"{"type":"tool","tool":"bash","state":{"status":"running"}}"#)
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .working)
        try expectEqual(session.currentTool, "bash")
    }

    // MARK: - Session fields

    func capturesTitleModelTokensCostAndCostToday() throws {
        insertSession(id: "ses_d", title: "Fix the tray icon", age: 60)
        insertMessage(id: "msg_d1", session: "ses_d", role: "assistant", age: 26 * 60 * 60,
                      cost: 0.05, input: 100, output: 50, reasoning: 10, cacheRead: 200, cacheWrite: 30)
        insertMessage(id: "msg_d2", session: "ses_d", role: "assistant", age: 60,
                      cost: 0.07, input: 20, output: 5, reasoning: 0, cacheRead: 0, cacheWrite: 0)
        insertPart(id: "part_d2a", message: "msg_d2", data: #"{"type":"text","text":"done"}"#)
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.id, "OpenCode/ses_d")
        try expectEqual(session.harness, "OpenCode")
        try expectEqual(session.repo, "myrepo")
        try expectEqual(session.worktreePath, "/Users/me/work/myrepo")
        try expectEqual(session.sessionName, "Fix the tray icon")
        try expectEqual(session.model, "anthropic/claude-sonnet-4-5")
        // input includes cache tokens; output includes reasoning
        try expectEqual(session.inputTokens, 350)
        try expectEqual(session.outputTokens, 65)
        try expectApprox(session.cost, 0.12)
        try expectApprox(session.costToday, 0.07)
    }

    func countsTokensWithMissingOptionalFields() throws {
        insertSession(id: "ses_sparse", age: 60)
        exec("""
        INSERT INTO message (id, session_id, time_created, data) VALUES (
          'msg_sparse', 'ses_sparse', \(ms(60)),
          '{"role":"assistant","cost":0.03,"tokens":{"input":11,"output":7}}');
        """)
        insertPart(id: "part_sparse", message: "msg_sparse", data: #"{"type":"text","text":"Done."}"#)
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.inputTokens, 11)
        try expectEqual(session.outputTokens, 7)
        try expectApprox(session.costToday, 0.03)
    }

    func skipsSubagentAndArchivedSessions() throws {
        insertSession(id: "ses_child", age: 60, parent: "ses_d")
        insertSession(id: "ses_old", age: 60, archived: true)
        try expect(adapter().scan().sessions.isEmpty, "child and archived sessions should be excluded")
    }

    func skipsSessionsNotUsedToday() throws {
        insertSession(id: "ses_yesterday", age: 26 * 60 * 60)
        try expect(adapter().scan().sessions.isEmpty, "yesterday's session should be excluded")
    }

    func unionsLegacyRowsMissingFromV2() throws {
        insertSession(id: "ses_legacy", title: "Legacy run", age: 60, table: "session")
        insertMessage(id: "msg_l1", session: "ses_legacy", role: "user", age: 60)
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.sessionName, "Legacy run")
    }

    func overnightRunningToolRemainsVisibleWithTodayCostOnly() throws {
        insertSession(id: "overnight", age: 13 * 60 * 60)
        insertMessage(id: "overnight-message", session: "overnight", role: "assistant", age: 13 * 60 * 60, cost: 0.2)
        insertPart(id: "overnight-part", message: "overnight-message", data: #"{"type":"tool","tool":"bash","state":{"status":"running"}}"#)
        let session = try required(adapter().scan().sessions.first)
        try expectEqual(session.state, .working)
        try expectApprox(session.costToday, 0)
        try expectApprox(session.cost, 0.2)
    }

    func ancientRunningMarkersDoNotReturnAsCurrentSessions() throws {
        insertSession(id: "ancient-running", age: 3 * 24 * 60 * 60)
        insertMessage(id: "ancient-message", session: "ancient-running", role: "assistant", age: 3 * 24 * 60 * 60)
        insertPart(id: "ancient-part", message: "ancient-message", data: #"{"type":"tool","tool":"bash","state":{"status":"running"}}"#)
        insertSession(id: "recent-overnight", age: 13 * 60 * 60)
        insertMessage(id: "recent-message", session: "recent-overnight", role: "assistant", age: 13 * 60 * 60)
        insertPart(id: "recent-part", message: "recent-message", data: #"{"type":"tool","tool":"bash","state":{"status":"running"}}"#)
        let sessions = adapter().scan().sessions
        try expectEqual(sessions.map(\.id), ["OpenCode/recent-overnight"])
        try expectEqual(sessions.first?.state, .working)
    }

    func invalidSchemaReportsFailure() throws {
        exec("DROP TABLE session_v2;")
        guard case .failed(let issues) = adapter().scan() else {
            throw TestFailure(message: "Unsupported schemas must fail visibly", file: #fileID, line: #line)
        }
        try expectEqual(issues.count, 1)
        try expect(issues[0].message.contains("session_v2"), "Schema error must identify the missing table")
    }

    func malformedSessionPreservesReadableSession() throws {
        insertSession(id: "bad", age: 60)
        exec("INSERT INTO message (id, session_id, time_created, data) VALUES ('bad-message', 'bad', \(ms(60)), 'not-json');")
        insertSession(id: "good", age: 60)
        insertMessage(id: "good-message", session: "good", role: "user", age: 60)
        guard case .partial(let sessions, let issues) = adapter().scan() else {
            throw TestFailure(message: "Bad message JSON must report partial scan", file: #fileID, line: #line)
        }
        try expectEqual(sessions.map(\.id), ["OpenCode/good"])
        try expectEqual(issues.count, 1)
        try expect(issues[0].message.contains("malformed JSON"), "Malformed JSON issue must explain the bad message")
    }

    func emptyDatabaseWithMissingActivitySchemaFails() throws {
        exec("DROP TABLE part;")
        guard case .failed(let issues) = adapter().scan() else {
            throw TestFailure(message: "Missing activity tables must fail even without sessions", file: #fileID, line: #line)
        }
        try expectEqual(issues.count, 1)
        try expect(issues[0].message.contains("part"), "Schema error must identify the missing activity table")
    }

    func readableEmptyDatabaseIsHealthy() throws {
        try expectEqual(adapter().scan(), .complete(sessions: []))
    }

    func invalidUpdateTimePreservesReadableSession() throws {
        insertSession(id: "invalid-time", age: 60)
        insertMessage(id: "invalid-time-message", session: "invalid-time", role: "assistant", age: 60)
        insertPart(id: "invalid-time-part", message: "invalid-time-message", data: #"{"type":"tool","tool":"bash","state":{"status":"running"}}"#)
        insertSession(id: "valid-time", age: 60)
        insertMessage(id: "valid-time-message", session: "valid-time", role: "user", age: 60)
        for invalidTime in ["-1e999", "1e999", "-1e100", "1e100"] {
            exec("UPDATE session_v2 SET time_updated = \(invalidTime) WHERE id = 'invalid-time';")
            guard case .partial(let sessions, let issues) = adapter().scan() else {
                throw TestFailure(message: "Invalid update times must report a partial scan", file: #fileID, line: #line)
            }
            try expectEqual(sessions.map(\.id), ["OpenCode/valid-time"])
            try expectEqual(issues.count, 1)
            try expectEqual(issues[0].message, "Session has an invalid id, directory, or update time.")
        }
    }

    func invalidUsageReportsIssueInsteadOfCrashing() throws {
        insertSession(id: "invalid-usage", age: 60)
        exec("INSERT INTO message (id, session_id, time_created, data) VALUES ('invalid-usage-message', 'invalid-usage', \(ms(60)), '{\"role\":\"assistant\",\"tokens\":{\"input\":1e309}}');")
        guard case .partial(_, let issues) = adapter().scan() else {
            throw TestFailure(message: "Invalid numeric usage must report an issue", file: #fileID, line: #line)
        }
        try expectEqual(issues.first?.message, "Usage contains invalid token counts or cost.")
    }

    func handlesMissingDatabase() throws {
        let path = dbURL.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString).db")
        let missing = adapter(databaseURL: path)
        try expectEqual(missing.scan(), .unavailable(source: path.path))
    }

    private func adapter(databaseURL: URL?) -> OpenCodeAdapter {
        OpenCodeAdapter(databaseURL: databaseURL, clock: { [now] in now })
    }
}
