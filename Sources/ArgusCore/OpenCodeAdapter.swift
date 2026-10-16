import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

public final class OpenCodeAdapter: HarnessAdapter, @unchecked Sendable {
    private let databaseURL: URL
    private let clock: () -> Date

    public init(databaseURL: URL? = nil, clock: @escaping () -> Date = { Date() }) {
        self.databaseURL = databaseURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/opencode/opencode.db")
        self.clock = clock
    }

    public var name: String { "OpenCode" }

    public func scan() -> HarnessScan {
        do {
            _ = try databaseURL.resourceValues(forKeys: [.isRegularFileKey])
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return .unavailable(source: databaseURL.path)
            }
            return .failed(issues: [ScanIssue(source: databaseURL.path, message: error.localizedDescription)])
        }
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else {
            return .failed(issues: [ScanIssue(source: databaseURL.path, message: String(cString: sqlite3_errmsg(db)))])
        }
        do {
            return try scan(db: db)
        } catch {
            return .failed(issues: [ScanIssue(source: databaseURL.path, message: error.localizedDescription)])
        }
    }

    private func scan(db: OpaquePointer?) throws -> HarnessScan {
        let now = clock()
        let dayStart = Calendar.current.startOfDay(for: now)
        let dayStartMS = Int64(dayStart.timeIntervalSince1970 * 1000)
        _ = try query(db: db, sql: "SELECT id, session_id, time_created, data FROM message LIMIT 0")
        _ = try query(db: db, sql: "SELECT id, message_id, data FROM part LIMIT 0")
        let sql = """
        SELECT id, directory, title, model, time_updated FROM session_v2
          WHERE time_archived IS NULL AND parent_id IS NULL
        UNION ALL
        SELECT id, directory, title, model, time_updated FROM session
          WHERE time_archived IS NULL AND parent_id IS NULL
            AND id NOT IN (SELECT id FROM session_v2)
        """
        let rows = try query(db: db, sql: sql)
        var sessions: [AgentSession] = []
        var issues: [ScanIssue] = []
        for row in rows {
            let source = "\(databaseURL.path) session \(row[0] ?? "unknown")"
            do {
                guard let id = row[0], let directory = row[1], let updated = row[4],
                      let updatedMS = Double(updated), updatedMS.isFinite,
                      updatedMS >= Double(Int64.min), updatedMS <= Double(Int64.max) else {
                    throw DatabaseError(message: "Session has an invalid id, directory, or update time.")
                }
                let lastActivity = Date(timeIntervalSince1970: updatedMS / 1000)
                var parsed = ParsedTranscript(
                    cwd: directory, branch: nil, model: Self.model(from: row[3]),
                    lastActivity: lastActivity,
                    sessionName: row[2].flatMap { TranscriptParser.sessionName(customTitle: $0, firstUserText: nil) },
                    tail: .noConversation, inputTokens: 0, outputTokens: 0, costTotal: 0, costByDay: [:]
                )
                try parseActivity(db: db, sessionID: id, dayStartMS: dayStartMS, into: &parsed, now: now)
                guard parsed.tail != .noConversation else { continue }
                let state = SessionResolver.resolve(tail: parsed.tail, lastActivity: lastActivity, now: now)
                guard SessionResolver.isEligible(state: state, lastActivity: lastActivity, now: now) else { continue }
                var tool: String?
                var question: String?
                switch parsed.tail {
                case .pendingToolUse(let names), .runningToolUse(let names): tool = names.first
                case .waitingForInput(let names, let text):
                    tool = names.first
                    question = text
                default: break
                }
                sessions.append(AgentSession(
                    id: "\(name)/\(id)", machine: "This Mac", harness: name,
                    repo: URL(fileURLWithPath: directory).lastPathComponent,
                    worktreePath: directory, branch: nil, model: parsed.model,
                    sessionName: parsed.sessionName, state: state, currentTool: tool, question: question,
                    inputTokens: parsed.inputTokens, outputTokens: parsed.outputTokens,
                    cost: parsed.costTotal, costToday: parsed.costByDay[TranscriptParser.dayKey(now)] ?? 0,
                    lastActivity: lastActivity
                ))
            } catch {
                issues.append(ScanIssue(source: source, message: error.localizedDescription))
            }
        }
        sessions.sort {
            if $0.stateRank != $1.stateRank { return $0.stateRank < $1.stateRank }
            return $0.lastActivity > $1.lastActivity
        }
        return issues.isEmpty ? .complete(sessions: sessions) : .partial(sessions: sessions, issues: issues)
    }

    private func parseActivity(
        db: OpaquePointer?, sessionID: String, dayStartMS: Int64,
        into parsed: inout ParsedTranscript, now: Date
    ) throws {
        let usage = try aggregateUsage(db: db, sessionID: sessionID, sinceMS: nil)
        parsed.inputTokens = usage.inputTokens
        parsed.outputTokens = usage.outputTokens
        parsed.costTotal = usage.cost
        let todayUsage = try aggregateUsage(db: db, sessionID: sessionID, sinceMS: dayStartMS)
        parsed.costByDay[TranscriptParser.dayKey(now)] = todayUsage.cost
        let sql = "SELECT id, json_extract(data, '$.role') FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 1"
        guard let last = try query(db: db, sql: sql, bindings: [.text(sessionID)]).first else { return }
        switch last[1] {
        case "user": parsed.tail = .userMessage
        case "assistant":
            guard let messageID = last[0] else { throw DatabaseError(message: "Message id is missing.") }
            parsed.tail = try assistantTail(db: db, messageID: messageID)
        default: break
        }
    }

    private func assistantTail(db: OpaquePointer?, messageID: String) throws -> ParsedTranscript.Tail {
        let sql = "SELECT json_extract(data, '$.type'), json_extract(data, '$.tool'), json_extract(data, '$.state.status') FROM part WHERE message_id = ? ORDER BY id"
        let rows = try query(db: db, sql: sql, bindings: [.text(messageID)])
        var pending: [String] = []
        var running: [String] = []
        var hasCompletedTool = false
        var hasText = false
        for row in rows {
            switch row[0] {
            case "tool":
                if let tool = row[1] {
                    if row[2] == "pending" { pending.append(tool) }
                    else if row[2] == "running" { running.append(tool) }
                    else if row[2] == "completed" || row[2] == "error" { hasCompletedTool = true }
                }
            case "text": hasText = true
            default: break
            }
        }
        if !running.isEmpty { return .runningToolUse(names: running + pending) }
        if !pending.isEmpty { return .pendingToolUse(names: pending) }
        if hasText { return .assistantText(isError: false) }
        if hasCompletedTool { return .toolResultArrived }
        return .noConversation
    }

    private func aggregateUsage(db: OpaquePointer?, sessionID: String, sinceMS: Int64?) throws -> (inputTokens: Int, outputTokens: Int, cost: Double) {
        var sql = """
        SELECT
          COALESCE(SUM(COALESCE(json_extract(data, '$.tokens.input'), 0) + COALESCE(json_extract(data, '$.tokens.cache.read'), 0) + COALESCE(json_extract(data, '$.tokens.cache.write'), 0)), 0),
          COALESCE(SUM(COALESCE(json_extract(data, '$.tokens.output'), 0) + COALESCE(json_extract(data, '$.tokens.reasoning'), 0)), 0),
          COALESCE(SUM(json_extract(data, '$.cost')), 0)
        FROM message WHERE session_id = ? AND json_extract(data, '$.role') = 'assistant'
        """
        var bindings: [Binding] = [.text(sessionID)]
        if let sinceMS {
            sql += " AND time_created >= ?"
            bindings.append(.integer(sinceMS))
        }
        guard let row = try query(db: db, sql: sql, bindings: bindings).first else {
            throw DatabaseError(message: "Usage aggregate did not return a row.")
        }
        guard let input = Int(row[0] ?? ""), let output = Int(row[1] ?? ""),
              let cost = Double(row[2] ?? ""), cost.isFinite else {
            throw DatabaseError(message: "Usage contains invalid token counts or cost.")
        }
        return (input, output, cost)
    }

    private enum Binding {
        case text(String)
        case integer(Int64)
    }

    private struct DatabaseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func query(db: OpaquePointer?, sql: String, bindings: [Binding] = []) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            let status: Int32
            switch binding {
            case .text(let text): status = sqlite3_bind_text(statement, Int32(index + 1), text, -1, SQLITE_TRANSIENT)
            case .integer(let value): status = sqlite3_bind_int64(statement, Int32(index + 1), value)
            }
            guard status == SQLITE_OK else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
        }
        var rows: [[String?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw DatabaseError(message: String(cString: sqlite3_errmsg(db))) }
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
    }

    private static func model(from json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let id = value["id"]?.stringValue, !id.isEmpty else { return nil }
        return value["providerID"]?.stringValue.map { "\($0)/\(id)" } ?? id
    }
}
