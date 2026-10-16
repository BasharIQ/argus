import Foundation

/// Reads Pi (pi-mono) sessions from ~/.pi/agent/sessions/<encoded-cwd>/*.jsonl.
/// Format: a "session" header line carrying cwd and id, then "message" lines
/// with roles user / assistant / toolResult. Assistant messages carry real
/// cost totals in usage.cost — no estimation needed. Pi stores no session
/// title, so the first user message stands in as the session name.
/// Forked/subagent sessions carry `parentSession` in the header and are
/// skipped — only the main session lists. The pi-subagents extension also
/// spawns children into a fixed `session.jsonl` (no parent marker), which
/// is excluded by filename; pi itself only ever writes timestamped names.
public final class PiAdapter: HarnessAdapter, @unchecked Sendable {
    private let scanner: SessionScanner
    private let clock: () -> Date

    public init(root: URL? = nil, clock: @escaping () -> Date = { Date() }) {
        self.scanner = SessionScanner(
            root: root ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/sessions")
        )
        self.clock = clock
    }

    public var name: String { "Pi" }

    public func scan() -> HarnessScan {
        scanner.scan(
            machine: "This Mac", harness: name, now: clock(),
            parse: PiSessionParser.parse,
            ignoringFileNames: ["session.jsonl"]
        )
    }
}

enum PiSessionParser {
    static func parse(data: Data) -> ParsedTranscript? {
        var result = ParsedTranscript(
            cwd: nil, branch: nil, model: nil, lastActivity: nil, sessionName: nil, tail: .noConversation,
            inputTokens: 0, outputTokens: 0, costTotal: 0, costByDay: [:]
        )
        var firstUserText: String?
        let decoded = JSONLines.decode(RawEntry.self, data: data)
        result.malformedLines = decoded.malformedLines
        for raw in decoded.records {
            switch raw.type {
            case "session":
                if let parent = raw.parentSession, !parent.isEmpty {
                    result.isChildSession = true
                }
                if let cwd = raw.cwd, !cwd.isEmpty { result.cwd = cwd }
                if result.lastActivity == nil { result.lastActivity = date(raw.timestamp) ?? result.lastActivity }
            case "model_change":
                if let model = raw.modelId, !model.isEmpty {
                    result.model = raw.provider.map { "\($0)/\(model)" } ?? model
                }
            case "message":
                guard let message = raw.message else { continue }
                if let ts = date(raw.timestamp) { result.lastActivity = ts }
                let blocks = message.content?.arrayValue ?? []
                let toolNames = blocks.compactMap { block in
                    block["type"]?.stringValue == "toolCall" ? block["name"]?.stringValue : nil
                }
                switch message.role {
                case "assistant":
                    if toolNames.isEmpty {
                        result.tail = .assistantText(isError: false)
                    } else {
                        result.tail = .pendingToolUse(names: toolNames)
                    }
                    if let model = message.model {
                        result.model = message.provider.map { "\($0)/\(model)" } ?? model
                    }
                    if let usage = message.usage {
                        result.inputTokens += (usage.input ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0)
                        result.outputTokens += (usage.output ?? 0) + (usage.reasoning ?? 0)
                        let cost = usage.cost?.total ?? 0
                        result.costTotal += cost
                        if let ts = date(raw.timestamp) {
                            result.costByDay[TranscriptParser.dayKey(ts), default: 0] += cost
                        }
                    }
                case "toolResult":
                    result.tail = .toolResultArrived
                case "user":
                    result.tail = .userMessage
                    if firstUserText == nil, let text = firstText(in: message.content) {
                        firstUserText = text
                    }
                default:
                    break
                }
            default:
                break
            }
        }
        result.sessionName = TranscriptParser.sessionName(customTitle: nil, firstUserText: firstUserText)
        return result
    }

    private static func firstText(in content: JSONValue?) -> String? {
        switch content {
        case .string(let string):
            return string.isEmpty ? nil : string
        case .array(let blocks):
            for block in blocks {
                if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue, !text.isEmpty {
                    return text
                }
            }
            return nil
        default:
            return nil
        }
    }

    private static func date(_ string: String?) -> Date? {
        TranscriptParser.parseTimestamp(string)
    }

    private struct RawEntry: Decodable {
        let type: String?
        let timestamp: String?
        let cwd: String?
        let parentSession: String?
        let provider: String?
        let modelId: String?
        let message: RawMessage?
    }

    private struct RawMessage: Decodable {
        let role: String?
        let provider: String?
        let model: String?
        let content: JSONValue?
        let usage: RawUsage?
    }

    private struct RawUsage: Decodable {
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let reasoning: Int?
        let cost: RawCost?
    }

    private struct RawCost: Decodable {
        let total: Double?
    }
}
