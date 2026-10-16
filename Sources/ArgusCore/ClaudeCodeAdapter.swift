import Foundation

public final class ClaudeCodeAdapter: HarnessAdapter, @unchecked Sendable {
    private let scanner: SessionScanner
    private let clock: () -> Date

    public init(root: URL? = nil, clock: @escaping () -> Date = { Date() }) {
        self.scanner = SessionScanner(
            root: root ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
        )
        self.clock = clock
    }

    public var name: String { "Claude Code" }

    public func scan() -> HarnessScan {
        scanner.scan(machine: "This Mac", harness: name, now: clock()) { data in
            TranscriptParser.summarize(data: data)
        }
    }
}
