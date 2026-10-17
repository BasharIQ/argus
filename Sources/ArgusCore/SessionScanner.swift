import Foundation

final class SessionScanner: @unchecked Sendable {
    private let root: URL
    /// Raw bytes that start a question tool call in this harness's transcripts.
    private let questionCallMarkers: [Data]
    private let lock = NSLock()
    private var cache: [String: (mtime: Date, parsed: ParsedTranscript)] = [:]
    private var excludedHistory: [String: (mtime: Date, dayStart: Date, screenedAt: Date)] = [:]

    init(root: URL, questionCallMarkers: [String] = []) {
        self.root = root
        self.questionCallMarkers = questionCallMarkers.map { Data($0.utf8) }
    }

    func scan(
        machine: String,
        harness: String,
        now: Date,
        parse: (Data) -> ParsedTranscript?,
        ignoringFileNames: Set<String> = []
    ) -> HarnessScan {
        let dayStart = Calendar.current.startOfDay(for: now)
        let fm = FileManager.default
        do {
            _ = try root.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return .unavailable(source: root.path)
            }
            return .failed(issues: [ScanIssue(source: root.path, message: error.localizedDescription)])
        }
        var directories = [root]
        var issues: [ScanIssue] = []
        var result: [AgentSession] = []
        var children: [(parentID: String, session: AgentSession)] = []
        while let directory = directories.popLast() {
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [
                    .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey
                ])
            } catch {
                let issue = ScanIssue(source: directory.path, message: error.localizedDescription)
                if directory == root { return .failed(issues: [issue]) }
                issues.append(issue)
                continue
            }
            for item in items {
                do {
                    let values = try item.resourceValues(forKeys: [
                        .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey
                    ])
                    if values.isDirectory == true {
                        if values.isSymbolicLink != true {
                            directories.append(item)
                        }
                        continue
                    }
                    guard item.pathExtension == "jsonl", !ignoringFileNames.contains(item.lastPathComponent) else { continue }
                    guard let parsed = try load(
                        url: item, mtime: values.contentModificationDate ?? now,
                        now: now, dayStart: dayStart, parse: parse
                    ) else { continue }
                    issues.append(contentsOf: parsed.malformedLines.map {
                        ScanIssue(source: item.path, message: "Malformed transcript record on line \($0).")
                    })
                    guard !parsed.isChildSession, parsed.tail != .noConversation,
                          let last = parsed.lastActivity else { continue }
                    let state = SessionResolver.resolve(tail: parsed.tail, lastActivity: last, now: now)
                    guard SessionResolver.isEligible(state: state, lastActivity: last, now: now) else { continue }
                    var tool: String?
                    var question: String?
                    switch parsed.tail {
                    case .waitingForInput(let names, let text):
                        tool = names.first
                        question = text
                    case .pendingToolUse(let names), .runningToolUse(let names):
                        tool = names.first
                    default:
                        break
                    }
                    let session = AgentSession(
                        id: "\(harness)/\(parsed.threadID ?? item.deletingPathExtension().lastPathComponent)",
                        machine: machine,
                        harness: harness,
                        repo: parsed.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown",
                        worktreePath: parsed.cwd ?? "",
                        branch: parsed.branch,
                        model: parsed.model,
                        sessionName: parsed.sessionName,
                        state: state,
                        currentTool: tool,
                        question: question,
                        inputTokens: parsed.inputTokens,
                        outputTokens: parsed.outputTokens,
                        cost: parsed.costTotal,
                        costToday: parsed.costByDay[TranscriptParser.dayKey(now)] ?? 0,
                        lastActivity: last
                    )
                    if let parent = parsed.parentThreadID {
                        children.append(("\(harness)/\(parent)", session))
                    } else {
                        result.append(session)
                    }
                } catch {
                    issues.append(ScanIssue(source: item.path, message: error.localizedDescription))
                }
            }
        }
        result = Self.combine(pages: result, children: children)
        result.sort {
            if $0.stateRank != $1.stateRank { return $0.stateRank < $1.stateRank }
            return $0.lastActivity > $1.lastActivity
        }
        return issues.isEmpty ? .complete(sessions: result) : .partial(sessions: result, issues: issues)
    }

    /// Merges rollout pages that share a thread id (the newest page carries
    /// the live state, the earliest the original prompt) and folds child
    /// thread usage into its parent. A parent whose own transcript went
    /// quiet is still working while a child works.
    private static func combine(pages: [AgentSession], children: [(parentID: String, session: AgentSession)]) -> [AgentSession] {
        var threads: [String: AgentSession] = [:]
        var order: [String] = []
        for page in pages.sorted(by: { $0.lastActivity < $1.lastActivity }) {
            if let earlier = threads[page.id] {
                threads[page.id] = page.addingUsage(of: earlier, sessionName: earlier.sessionName ?? page.sessionName, state: page.state)
            } else {
                threads[page.id] = page
                order.append(page.id)
            }
        }
        for child in children {
            guard let parent = threads[child.parentID] else { continue }
            let quiet = parent.state == .finished || parent.state == .idle
            let state = quiet && child.session.state == .working ? .working : parent.state
            threads[child.parentID] = parent.addingUsage(of: child.session, sessionName: parent.sessionName, state: state)
        }
        return order.compactMap { threads[$0] }
    }

    private func load(
        url: URL, mtime: Date, now: Date, dayStart: Date,
        parse: (Data) -> ParsedTranscript?
    ) throws -> ParsedTranscript? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[url.path], cached.mtime == mtime { return cached.parsed }
        if let excluded = excludedHistory[url.path], excluded.mtime == mtime,
           excluded.dayStart == dayStart, now >= excluded.screenedAt { return nil }
        if mtime < dayStart,
           try isInactiveHistory(url: url, now: now, dayStart: dayStart, parse: parse) {
            excludedHistory[url.path] = (mtime, dayStart, now)
            cache.removeValue(forKey: url.path)
            return nil
        }
        let data = try Data(contentsOf: url)
        guard let parsed = parse(data) else {
            throw NSError(domain: "Argus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot parse transcript."])
        }
        cache[url.path] = (mtime, parsed)
        excludedHistory.removeValue(forKey: url.path)
        return parsed
    }

    private func isInactiveHistory(
        url: URL, now: Date, dayStart: Date,
        parse: (Data) -> ParsedTranscript?
    ) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let window: UInt64 = 64 * 1024
        let offset = length > window ? length - window : 0
        try handle.seek(toOffset: offset)
        guard var tail = try handle.read(upToCount: Int(window)), !tail.isEmpty else { return false }
        if offset > 0 {
            guard let newline = tail.firstIndex(of: UInt8(ascii: "\n")) else { return false }
            tail = Data(tail[tail.index(after: newline)...])
        }
        if tail.last != UInt8(ascii: "\n"),
           let finalRecord = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).last,
           !finalRecord.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }),
           (try? JSONSerialization.jsonObject(with: Data(finalRecord), options: [.fragmentsAllowed])) == nil {
            return false
        }
        guard let parsed = parse(tail), parsed.malformedLines.isEmpty,
              parsed.tail != .noConversation, let last = parsed.lastActivity,
              last < dayStart else { return false }
        let state = SessionResolver.resolve(tail: parsed.tail, lastActivity: last, now: now)
        guard !SessionResolver.isEligible(state: state, lastActivity: last, now: now) else { return false }
        guard parsed.mayInheritOpenQuestion else { return true }
        return try !containsQuestionCall(handle, before: length - UInt64(tail.count))
    }

    private func containsQuestionCall(_ handle: FileHandle, before end: UInt64) throws -> Bool {
        guard end > 0 else { return false }
        guard let longest = questionCallMarkers.map(\.count).max() else { return true }
        try handle.seek(toOffset: 0)
        var position: UInt64 = 0
        var carry = Data()
        while position < end {
            guard let chunk = try handle.read(upToCount: Int(min(4 << 20, end - position))), !chunk.isEmpty else { break }
            position += UInt64(chunk.count)
            let haystack = carry + chunk
            if questionCallMarkers.contains(where: { haystack.range(of: $0) != nil }) { return true }
            carry = haystack.suffix(longest - 1)
        }
        return false
    }
}

private extension AgentSession {
    func addingUsage(of other: AgentSession, sessionName: String?, state: SessionState) -> AgentSession {
        AgentSession(
            id: id, machine: machine, harness: harness, repo: repo, worktreePath: worktreePath,
            branch: branch, model: model, sessionName: sessionName, state: state,
            currentTool: currentTool, question: question,
            inputTokens: inputTokens + other.inputTokens, outputTokens: outputTokens + other.outputTokens,
            cost: cost + other.cost, costToday: costToday + other.costToday,
            lastActivity: lastActivity)
    }
}
