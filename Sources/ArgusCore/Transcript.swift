import Foundation

/// Tolerant JSON value, used for `message.content` and tool inputs whose shape
/// we only need to reach into occasionally (e.g. question text).
enum JSONValue: Equatable, Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .null
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var numberValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

enum TranscriptBlock: Equatable, Sendable {
    case text(String)
    case thinking
    case toolUse(id: String?, name: String, input: [String: JSONValue])
    case toolResult(id: String?)
    case other
}

struct TranscriptEntry: Equatable, Sendable {
    struct Usage: Equatable, Sendable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        var cacheWrite1h: Int = 0
    }

    let type: String
    let messageID: String?
    let timestamp: Date?
    let cwd: String?
    let gitBranch: String?
    let isApiErrorMessage: Bool
    let model: String?
    let customTitle: String?
    let costUSD: Double?
    let usage: Usage?
    let blocks: [TranscriptBlock]

    var toolUseNames: [String] {
        blocks.compactMap {
            if case .toolUse(_, let name, _) = $0 { return name }
            return nil
        }
    }

    var hasToolResult: Bool {
        blocks.contains {
            if case .toolResult = $0 { return true }
            return false
        }
    }
}

/// Everything Argus needs from one transcript file. State resolution happens
/// later against a clock, so a parse result is cacheable until the file changes.
struct ParsedTranscript: Equatable, Sendable {
    enum Tail: Equatable, Sendable {
        case assistantText(isError: Bool)
        case pendingToolUse(names: [String])
        case waitingForInput(names: [String], question: String?)
        case runningToolUse(names: [String])
        case toolResultArrived
        case userMessage
        case turnEnded(aborted: Bool)
        case noConversation
    }

    var cwd: String?
    var branch: String?
    var model: String?
    var lastActivity: Date?
    var sessionName: String?
    /// Lineage marker: pi writes the parent file path into forked/subagent
    /// session headers (`parentSession`). Argus lists main sessions only,
    /// so the scanner skips transcripts with this set.
    var isChildSession = false
    /// Codex keys a thread by `session_meta.id` and may split it across
    /// several rollout files. Child threads (Codex subagents and guardian
    /// reviews, Claude Code sidechains) name their parent; their usage and
    /// activity fold into it instead of listing.
    var threadID: String?
    var parentThreadID: String?
    var tail: Tail
    var inputTokens: Int
    var outputTokens: Int
    var costTotal: Double
    var costByDay: [String: Double]
    var malformedLines: [Int] = []
}

enum TranscriptParser {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter = ISO8601DateFormatter()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func parse(data: Data) -> [TranscriptEntry] {
        entries(from: JSONLines.decode(RawEntry.self, data: data).records)
    }

    static func summarize(data: Data) -> ParsedTranscript {
        let decoded = JSONLines.decode(RawEntry.self, data: data)
        var result = summarize(entries: entries(from: decoded.records))
        result.malformedLines = decoded.malformedLines
        result.parentThreadID = decoded.records.first { $0.isSidechain == true }?.sessionId
        return result
    }

    private static func entries(from rawEntries: [RawEntry]) -> [TranscriptEntry] {
        var entries: [TranscriptEntry] = []
        for raw in rawEntries {
            let usage = raw.message?.usage.map {
                TranscriptEntry.Usage(
                    input: $0.input_tokens ?? 0,
                    output: $0.output_tokens ?? 0,
                    cacheRead: $0.cache_read_input_tokens ?? 0,
                    cacheWrite: $0.cache_creation_input_tokens ?? 0,
                    cacheWrite1h: $0.cache_creation?.ephemeral_1h_input_tokens ?? 0
                )
            }
            entries.append(TranscriptEntry(
                type: raw.type ?? "",
                messageID: raw.message?.id,
                timestamp: parseTimestamp(raw.timestamp),
                cwd: raw.cwd,
                gitBranch: raw.gitBranch,
                isApiErrorMessage: raw.isApiErrorMessage ?? false,
                model: raw.message?.model,
                customTitle: raw.customTitle,
                costUSD: raw.costUSD,
                usage: usage,
                blocks: blocks(from: raw.message?.content)
            ))
        }
        return entries
    }

    static func summarize(entries: [TranscriptEntry]) -> ParsedTranscript {
        var result = ParsedTranscript(
            cwd: nil, branch: nil, model: nil, lastActivity: nil, sessionName: nil, tail: .noConversation,
            inputTokens: 0, outputTokens: 0, costTotal: 0, costByDay: [:]
        )
        var customTitle: String?
        var firstUserText: String?
        // Claude Code writes one entry per content block, each repeating the
        // message's usage, so bill each message id once.
        var billedMessages: Set<String> = []
        // Parallel tool calls and their results are separate entries too, so
        // a question stays open while a sibling call's result is the tail.
        var openQuestions: [(id: String?, text: String)] = []
        for entry in entries {
            if entry.type == "custom-title", let title = entry.customTitle {
                customTitle = title
                continue
            }
            guard entry.type == "user" || entry.type == "assistant" else { continue }
            if let cwd = entry.cwd { result.cwd = cwd }
            if let branch = entry.gitBranch { result.branch = branch }
            if entry.type == "assistant", let model = entry.model { result.model = model }
            if let date = entry.timestamp { result.lastActivity = date }
            if let usage = entry.usage, entry.messageID.map({ billedMessages.insert($0).inserted }) ?? true {
                result.inputTokens += usage.input + usage.cacheWrite + usage.cacheRead
                result.outputTokens += usage.output
                let cost = entry.costUSD ?? Pricing.estimate(model: entry.model, usage: usage)
                result.costTotal += cost
                if let date = entry.timestamp {
                    result.costByDay[dayKey(date), default: 0] += cost
                }
            }
            if entry.type == "assistant" {
                if entry.toolUseNames.isEmpty {
                    result.tail = .assistantText(isError: entry.isApiErrorMessage)
                } else {
                    result.tail = .pendingToolUse(names: entry.toolUseNames)
                    openQuestions += questions(in: entry.blocks)
                }
            } else {
                for case .toolResult(let id) in entry.blocks {
                    openQuestions.removeAll { $0.id == id }
                }
                result.tail = entry.hasToolResult ? .toolResultArrived : .userMessage
                if firstUserText == nil, let text = firstText(in: entry.blocks) {
                    if let args = commandArgs(in: text) {
                        firstUserText = args
                    } else if !text.hasPrefix("<"), !text.hasPrefix("Base directory for this skill:") {
                        firstUserText = text
                    }
                }
            }
        }
        if let open = openQuestions.first {
            result.tail = .waitingForInput(names: ["AskUserQuestion"], question: open.text)
        }
        result.sessionName = sessionName(customTitle: customTitle, firstUserText: firstUserText)
        return result
    }

    /// A display name for the session: the harness's explicit title when it
    /// has one, otherwise a tidy first user message. Callers already skip
    /// command entries and tool results when picking `firstUserText`.
    static func sessionName(customTitle: String?, firstUserText: String?) -> String? {
        if let customTitle { return tidy(customTitle, limit: 80) }
        guard let firstUserText else { return nil }
        return tidy(firstUserText, limit: 80)
    }

    private static func tidy(_ text: String, limit: Int) -> String? {
        var collapsed = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > limit {
            collapsed = String(collapsed.prefix(limit - 1)) + "…"
        }
        return collapsed
    }

    private static func firstText(in blocks: [TranscriptBlock]) -> String? {
        for block in blocks {
            if case .text(let text) = block, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func commandArgs(in text: String) -> String? {
        guard let start = text.range(of: "<command-args>"),
              let end = text.range(of: "</command-args>", range: start.upperBound..<text.endIndex)
        else { return nil }
        let args = text[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return args.isEmpty ? nil : args
    }

    private static func questions(in blocks: [TranscriptBlock]) -> [(id: String?, text: String)] {
        blocks.compactMap { block in
            guard case .toolUse(let id, "AskUserQuestion", let input) = block,
                  let text = input["questions"]?.arrayValue?.first?["question"]?.stringValue,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (id, text)
        }
    }

    static func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        return fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }

    private static func blocks(from content: JSONValue?) -> [TranscriptBlock] {
        switch content {
        case .string(let string):
            return [.text(string)]
        case .array(let items):
            return items.map { item in
                switch item["type"]?.stringValue {
                case "text":
                    return .text(item["text"]?.stringValue ?? "")
                case "thinking":
                    return .thinking
                case "tool_use":
                    return .toolUse(
                        id: item["id"]?.stringValue,
                        name: item["name"]?.stringValue ?? "",
                        input: item["input"]?.objectValue ?? [:]
                    )
                case "tool_result":
                    return .toolResult(id: item["tool_use_id"]?.stringValue)
                default:
                    return .other
                }
            }
        default:
            return []
        }
    }

    private struct RawEntry: Decodable {
        let type: String?
        let timestamp: String?
        let cwd: String?
        let gitBranch: String?
        let isApiErrorMessage: Bool?
        let customTitle: String?
        let costUSD: Double?
        let message: RawMessage?
        let sessionId: String?
        let isSidechain: Bool?
    }

    private struct RawMessage: Decodable {
        let id: String?
        let model: String?
        let usage: RawUsage?
        let content: JSONValue?
    }

    private struct RawUsage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_read_input_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_creation: RawCacheCreation?
    }

    private struct RawCacheCreation: Decodable {
        let ephemeral_1h_input_tokens: Int?
    }
}

/// costUSD is null in current Claude Code transcripts, so cost is estimated
/// from token counts using public list prices ($/MTok). Cache writes bill at
/// 1.25x input for the 5-minute TTL and 2x for the 1-hour TTL; cache-read
/// rates differ by model.
enum Pricing {
    struct Rates {
        let input: Double
        let output: Double
        let cacheRead: Double
    }

    /// First substring match wins, so versions precede their family fallback.
    private static let claude: [(match: String, rates: Rates)] = [
        ("fable-5-1", Rates(input: 10, output: 50, cacheRead: 0.25)),
        ("fable", Rates(input: 10, output: 50, cacheRead: 1)),
        ("opus-5-5", Rates(input: 4, output: 20, cacheRead: 0.2)),
        ("opus-5", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4-8", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4-7", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4-6", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("opus-4-5", Rates(input: 5, output: 25, cacheRead: 0.5)),
        ("opus", Rates(input: 15, output: 75, cacheRead: 1.5)),
        ("sonnet-5", Rates(input: 2, output: 10, cacheRead: 0.2)),
        ("sonnet", Rates(input: 3, output: 15, cacheRead: 0.3)),
        ("haiku-5", Rates(input: 0.1, output: 0.5, cacheRead: 0.01)),
        ("haiku", Rates(input: 1, output: 5, cacheRead: 0.1)),
    ]

    /// Codex models get GPT-5 class list pricing.
    private static let gpt = Rates(input: 1.25, output: 10, cacheRead: 0.125)

    static func estimate(model: String?, usage: TranscriptEntry.Usage) -> Double {
        let name = model?.lowercased() ?? ""
        let rates = claude.first { name.contains($0.match) }?.rates ?? gpt
        let input = Double(usage.input) * rates.input
        let shortWrites = Double(usage.cacheWrite - usage.cacheWrite1h) * rates.input * 1.25
        let longWrites = Double(usage.cacheWrite1h) * rates.input * 2
        let cacheRead = Double(usage.cacheRead) * rates.cacheRead
        let output = Double(usage.output) * rates.output
        return (input + shortWrites + longWrites + cacheRead + output) / 1_000_000
    }
}
