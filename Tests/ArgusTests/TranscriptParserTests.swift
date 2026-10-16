import Foundation
@testable import ArgusCore

struct TranscriptParserTests {
    private let jsonl = """
    {"type":"summary","summary":"x","leafUuid":"a"}
    {"type":"assistant","timestamp":"2026-09-05T10:00:00.123Z","cwd":"/tmp/repo","gitBranch":"main","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":5},"content":[{"type":"thinking","thinking":"hm"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]}}
    {"type":"user","timestamp":"2026-09-05T10:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}
    {"type":"user","timestamp":"2026-09-05T10:01:00.000Z","message":{"role":"user","content":"please fix the tests"}}
    {"type":"attachment","timestamp":"2026-09-05T10:01:01.000Z"}
    """

    private var entries: [TranscriptEntry] {
        TranscriptParser.parse(data: Data(jsonl.utf8))
    }

    func parsesEveryDecodableLine() throws {
        try expectEqual(entries.count, 5)
    }

    func assistantEntryFields() throws {
        let assistant = try required(entries.first { $0.type == "assistant" })
        try expectEqual(assistant.toolUseNames, ["Bash"])
        try expectEqual(assistant.model, "claude-sonnet-4-5")
        try expectEqual(assistant.usage?.input, 10, "input tokens")
        try expectEqual(assistant.usage?.output, 20, "output tokens")
        try expectEqual(assistant.usage?.cacheRead, 30, "cache read")
        try expectEqual(assistant.usage?.cacheWrite, 5, "cache write")
        try expectEqual(assistant.cwd, "/tmp/repo")
        try expectEqual(assistant.gitBranch, "main")
        try expect(assistant.timestamp != nil, "timestamp should parse")
    }

    func userEntries() throws {
        let users = entries.filter { $0.type == "user" }
        try expectEqual(users.count, 2)
        try expect(users[0].hasToolResult, "first user entry is a tool result")
        try expectEqual(users[1].blocks, [.text("please fix the tests")])
    }

    func summarizeCapturesCwdBranchTokensAndCost() throws {
        let parsed = TranscriptParser.summarize(entries: entries)
        try expectEqual(parsed.cwd, "/tmp/repo")
        try expectEqual(parsed.branch, "main")
        try expectEqual(parsed.model, "claude-sonnet-4-5")
        try expectEqual(parsed.tail, .userMessage)
        try expectEqual(parsed.inputTokens, 10 + 5 + 30)
        try expectEqual(parsed.outputTokens, 20)
        // Sonnet 4.5 rates per MTok: 10 input*3 + 5 cacheWrite*3*1.25 + 30 cacheRead*0.3 + 20*15.
        try expectApprox(parsed.costTotal, (30 + 18.75 + 9 + 300) / 1_000_000)
        try expect(!parsed.costByDay.isEmpty, "cost should be bucketed by day")
        try expectApprox(parsed.costTotal, parsed.costByDay.values.reduce(0, +))
    }

    func summarizeTracksCurrentModelAcrossEntries() throws {
        let first = #"{"type":"assistant","timestamp":"2026-09-05T10:00:00.000Z","message":{"model":"claude-opus-4","content":[{"type":"text","text":"one"}]}}"#
        let second = #"{"type":"assistant","timestamp":"2026-09-05T10:01:00.000Z","message":{"model":"claude-haiku-4","content":[{"type":"text","text":"two"}]}}"#
        let parsed = TranscriptParser.summarize(entries: TranscriptParser.parse(data: Data("\(first)\n\(second)".utf8)))
        try expectEqual(parsed.model, "claude-haiku-4", "the most recent assistant model wins")
    }

    func summarizePrefersCostUSDWhenPresent() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-05T10:00:00.000Z","cwd":"/tmp/r","message":{"model":"claude-opus-4","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"tool_use","id":"t","name":"Read","input":{}}]},"costUSD":0.5}"#
        let parsed = TranscriptParser.summarize(entries: TranscriptParser.parse(data: Data(line.utf8)))
        try expectApprox(parsed.costTotal, 0.5)
        try expectEqual(parsed.tail, .pendingToolUse(names: ["Read"]))
    }

    func summarizeExtractsAskUserQuestionText() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-05T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t","name":"AskUserQuestion","input":{"questions":[{"question":"Ship it now or later?","header":"Timing"}]}}]}}"#
        let parsed = TranscriptParser.summarize(entries: TranscriptParser.parse(data: Data(line.utf8)))
        try expectEqual(parsed.tail, .waitingForInput(names: ["AskUserQuestion"], question: "Ship it now or later?"))
    }

    func estimatesCurrentModelRatesAndCacheDurations() throws {
        let usage = TranscriptEntry.Usage(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 2_000_000, cacheWrite1h: 1_000_000)
        try expectApprox(Pricing.estimate(model: "claude-opus-5-5", usage: usage), 4 + 20 + 0.2 + 5 + 8)
        try expectApprox(Pricing.estimate(model: "claude-opus-4-8", usage: usage), 5 + 25 + 0.5 + 6.25 + 10)
        try expectApprox(Pricing.estimate(model: "claude-opus-4-1-20250805", usage: usage), 15 + 75 + 1.5 + 18.75 + 30)
        try expectApprox(Pricing.estimate(model: "claude-sonnet-5-5", usage: usage), 2 + 10 + 0.2 + 2.5 + 4)
        try expectApprox(Pricing.estimate(model: "claude-haiku-5-5", usage: usage), 0.1 + 0.5 + 0.01 + 0.125 + 0.2)
        try expectApprox(Pricing.estimate(model: "claude-fable-5-1", usage: usage), 10 + 50 + 0.25 + 12.5 + 20)
    }

    func summarizeBillsOneHourCacheWritesAtDoubleInput() throws {
        let line = #"{"type":"assistant","timestamp":"2026-09-05T10:00:00.000Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}},"content":[{"type":"text","text":"hi"}]}}"#
        let parsed = TranscriptParser.summarize(entries: TranscriptParser.parse(data: Data(line.utf8)))
        try expectApprox(parsed.costTotal, 8)
    }

    func countsUsageOncePerMessageAcrossContentBlockEntries() throws {
        let usage = #""usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#
        let thinking = #"{"type":"assistant","timestamp":"2026-09-05T10:00:00.000Z","message":{"id":"msg_1","model":"claude-opus-5-5",\#(usage),"content":[{"type":"thinking","thinking":""}]}}"#
        let text = #"{"type":"assistant","timestamp":"2026-09-05T10:00:01.000Z","message":{"id":"msg_1","model":"claude-opus-5-5",\#(usage),"content":[{"type":"text","text":"hi"}]}}"#
        let parsed = TranscriptParser.summarize(entries: TranscriptParser.parse(data: Data("\(thinking)\n\(text)".utf8)))
        try expectEqual(parsed.inputTokens, 1_000_000)
        try expectApprox(parsed.costTotal, 4)
    }

    func ignoresMalformedLines() throws {
        let entries = TranscriptParser.parse(data: Data("not json\n{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n".utf8))
        try expectEqual(entries.count, 1)
    }

    func dayKeyIsLocalCalendarDay() throws {
        let expected = DateFormatter()
        expected.dateFormat = "yyyy-MM-dd"
        try expectEqual(
            TranscriptParser.dayKey(Date(timeIntervalSince1970: 0)),
            expected.string(from: Date(timeIntervalSince1970: 0))
        )
    }
}
