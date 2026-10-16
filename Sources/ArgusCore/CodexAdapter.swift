import Foundation

/// Reads Codex rollouts from ~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl.
/// Format: a "session_meta" line carrying cwd, then "response_item" lines
/// (message / custom_tool_call / *_call_output) that mirror the conversation,
/// plus "turn_context" lines carrying the model and "event_msg" token_count
/// lines carrying cumulative usage. Thread names live in a separate index at
/// ~/.codex/session_index.jsonl; the first user message stands in when absent.
public final class CodexAdapter: HarnessAdapter, @unchecked Sendable {
    private let root: URL
    private let indexURL: URL
    private let scanner: SessionScanner
    private let clock: () -> Date

    public init(root: URL? = nil, clock: @escaping () -> Date = { Date() }) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = root ?? home.appendingPathComponent(".codex")
        self.root = base.appendingPathComponent("sessions")
        self.indexURL = base.appendingPathComponent("session_index.jsonl")
        self.scanner = SessionScanner(root: self.root)
        self.clock = clock
    }

    public var name: String { "Codex" }

    public func scan() -> HarnessScan {
        let scan = scanner.scan(machine: "This Mac", harness: name, now: clock(), parse: CodexSessionParser.parse)
        switch scan {
        case .unavailable, .failed: return scan
        case .complete, .partial: break
        }
        let index = Self.threadNames(at: indexURL)
        let sessions = scan.sessions.map { session in
            guard let title = index.names[String(session.id.dropFirst(name.count + 1))] else { return session }
            return session.replacing(sessionName: title)
        }
        var issues = index.issues
        if case .partial(_, let sourceIssues) = scan { issues += sourceIssues }
        return issues.isEmpty ? .complete(sessions: sessions) : .partial(sessions: sessions, issues: issues)
    }

    private static func threadNames(at url: URL) -> (names: [String: String], issues: [ScanIssue]) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return ([:], [])
            }
            return ([:], [ScanIssue(source: url.path, message: error.localizedDescription)])
        }
        let decoded = JSONLines.decode(RawIndexEntry.self, data: data)
        var names: [String: String] = [:]
        for entry in decoded.records {
            if let id = entry.id, let name = entry.threadName, !name.isEmpty {
                names[id] = name
            }
        }
        return (names, decoded.malformedLines.map {
            ScanIssue(source: url.path, message: "Malformed session title record on line \($0).")
        })
    }
}

extension AgentSession {
    fileprivate func replacing(sessionName: String) -> AgentSession {
        AgentSession(
            id: id, machine: machine, harness: harness, repo: repo, worktreePath: worktreePath,
            branch: branch, model: model, sessionName: sessionName, state: state,
            currentTool: currentTool, question: question, inputTokens: inputTokens,
            outputTokens: outputTokens, cost: cost, costToday: costToday,
            lastActivity: lastActivity
        )
    }
}

enum CodexSessionParser {
    static func parse(data: Data) -> ParsedTranscript? {
        var result = ParsedTranscript(
            cwd: nil, branch: nil, model: nil, lastActivity: nil, sessionName: nil, tail: .noConversation,
            inputTokens: 0, outputTokens: 0, costTotal: 0, costByDay: [:]
        )
        var firstUserText: String?
        var sawMeta = false
        var openQuestion: OpenQuestion?
        let decoded = JSONLines.decode(RawEntry.self, data: data)
        result.malformedLines = decoded.malformedLines
        for raw in decoded.records {
            let payload: JSONValue = raw.payload ?? .object([:])
            if let ts = TranscriptParser.parseTimestamp(raw.timestamp) {
                result.lastActivity = ts
            }
            switch raw.type {
            case "session_meta":
                // Child threads replay their parent's meta after their own.
                guard !sawMeta else { break }
                sawMeta = true
                result.cwd = payload["cwd"]?.stringValue
                result.threadID = payload["id"]?.stringValue
                result.parentThreadID = payload["parent_thread_id"]?.stringValue
                result.branch = payload["git"]?["branch"]?.stringValue
            case "turn_context":
                if let model = payload["model"]?.stringValue { result.model = model }
            case "response_item":
                switch payload["type"]?.stringValue {
                case "message":
                    switch payload["role"]?.stringValue {
                    case "assistant":
                        let texts = text(from: payload["content"])
                        if !texts.isEmpty {
                            result.tail = .assistantText(isError: false)
                        }
                    case "user":
                        result.tail = .userMessage
                        openQuestion = nil
                        if firstUserText == nil, let text = text(from: payload["content"]).first,
                           !text.hasPrefix("<") {
                            firstUserText = text
                        }
                    default:
                        break
                    }
                case "custom_tool_call", "function_call":
                    if let tool = payload["name"]?.stringValue {
                        result.tail = .pendingToolUse(names: [tool])
                        let base = tool.hasPrefix("functions.") ? String(tool.dropFirst("functions.".count)) : tool
                        if base == "request_user_input" || base == "request_user_input_async",
                           let question = question(from: payload) {
                            openQuestion = OpenQuestion(
                                tool: tool, text: question, callID: payload["call_id"]?.stringValue,
                                // The async tool returns {"accepted":true} at once; the
                                // answer arrives later as a user message.
                                answeredByOutput: base == "request_user_input")
                        }
                    }
                case "custom_tool_call_output", "function_call_output":
                    result.tail = .toolResultArrived
                    if let question = openQuestion, question.answeredByOutput,
                       question.callID == payload["call_id"]?.stringValue {
                        openQuestion = nil
                    }
                default:
                    break
                }
            case "event_msg":
                switch payload["type"]?.stringValue {
                case "task_complete": result.tail = .turnEnded(aborted: false)
                case "turn_aborted": result.tail = .turnEnded(aborted: true)
                default: break
                }
                // token_count's total_token_usage is cumulative; last_token_usage
                // is per-turn, so accumulate that to keep the day split accurate.
                guard payload["type"]?.stringValue == "token_count",
                      let usage = payload["info"]?["last_token_usage"] else { break }
                let input = usage["input_tokens"]?.numberValue ?? 0
                let cached = usage["cached_input_tokens"]?.numberValue ?? 0
                let cacheWrite = usage["cache_write_input_tokens"]?.numberValue ?? 0
                let output = usage["output_tokens"]?.numberValue ?? 0
                result.inputTokens += Int(input)
                result.outputTokens += Int(output)
                if let ts = TranscriptParser.parseTimestamp(raw.timestamp) {
                    // input_tokens includes cached tokens; bill the remainder at
                    // the full rate and cached tokens at the cache-read rate.
                    let billedInput = max(0, Int(input) - Int(cached) - Int(cacheWrite))
                    let usage = TranscriptEntry.Usage(
                        input: billedInput,
                        output: Int(output),
                        cacheRead: Int(cached),
                        cacheWrite: Int(cacheWrite)
                    )
                    let cost = Pricing.estimate(model: result.model, usage: usage)
                    result.costTotal += cost
                    result.costByDay[TranscriptParser.dayKey(ts), default: 0] += cost
                }
            default:
                break
            }
        }
        if let openQuestion {
            result.tail = .waitingForInput(names: [openQuestion.tool], question: openQuestion.text)
        }
        result.sessionName = TranscriptParser.sessionName(customTitle: nil, firstUserText: firstUserText)
        return result
    }

    private struct OpenQuestion {
        let tool: String
        let text: String
        let callID: String?
        let answeredByOutput: Bool
    }

    private static func text(from content: JSONValue?) -> [String] {
        guard let items = content?.arrayValue else { return [] }
        return items.compactMap { $0["text"]?.stringValue }.filter { !$0.isEmpty }
    }

    private static func question(from payload: JSONValue) -> String? {
        let input: JSONValue?
        if let arguments = payload["arguments"]?.stringValue, let data = arguments.data(using: .utf8) {
            input = try? JSONDecoder().decode(JSONValue.self, from: data)
        } else {
            input = payload["arguments"] ?? payload["input"]
        }
        let first = input?["questions"]?.arrayValue?.first
        guard let text = first?["question"]?.stringValue ?? first?["title"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private struct RawEntry: Decodable {
        let type: String?
        let timestamp: String?
        let payload: JSONValue?
    }
}

extension CodexAdapter {
    struct RawIndexEntry: Decodable {
        let id: String?
        let threadName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }
}
