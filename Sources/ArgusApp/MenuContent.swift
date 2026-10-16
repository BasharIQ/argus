import SwiftUI
import AppKit
import ArgusCore

// MARK: - Design tokens (design_handoff_argus_tray 2, option 3a "roomy")

private enum Palette {
    static let ink = Color(hex: 0x1A1A19)
    static let paper = Color(hex: 0xF4F4F2)
    static let text2 = Color(hex: 0x5A5A56)
    static let text3 = Color(hex: 0x7A7A76)
    static let text4 = Color(hex: 0xA3A39E)
    static let hover = Color(hex: 0xE6E6E2)
    static let selected = Color(hex: 0xECECEA)
    static let hairline2 = Color(hex: 0xE6E6E2)
    static let controlLine = Color(hex: 0xB8B8B3)
    static let idle = Color(hex: 0xC9C9C4)
    static let coral = Color(hex: 0xFF5A48)
    static let statusWorking = Color(hex: 0xFFCC00)
    static let statusFinished = Color(hex: 0x34C759)
    static let statusErrored = Color(hex: 0xFF3B30)
    static let statusNeedsInput = Color(hex: 0x007AFF)

    /// Secondary text on the dark block.
    static func onInk(_ opacity: Double) -> Color { paper.opacity(opacity) }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// Section 3a "roomy" sizing. Every measurement reads from here so the
/// 2a compact sizes can be restored later with a one-spot flip.
private enum Metrics {
    static let panelWidth: CGFloat = 380
    static let panelRadius: CGFloat = 8
    static let gutter: CGFloat = 18          // panel horizontal padding
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 34
    static let rowIndent: CGFloat = 36
    static let detailIndent: CGFloat = 56
    static let chipHeight: CGFloat = 28
    static let pillHeight: CGFloat = 30      // ALLOW / DENY / SEND
    static let footerHeight: CGFloat = 36
    static let ui: CGFloat = 13              // grotesk body
    static let uiTitle: CGFloat = 15         // question / quiet headline
    static let mono: CGFloat = 12
    static let monoSmall: CGFloat = 11       // meta line, surface label
    static let eyebrow: CGFloat = 10
    static let badgeHeader: CGFloat = 22
    static let badgeCard: CGFloat = 16
    static let dot: CGFloat = 8
    static let radius: CGFloat = 5           // buttons / chips / badges
}

private struct CappedScroll<Content: View>: View {
    let limit: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content()
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                content()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: limit)
        }
        .frame(maxHeight: limit)
    }
}

// Bundled Space Grotesk + Space Mono (registered at launch by Fonts).
private func grotesk(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    let name: String
    switch weight {
    case .semibold, .bold: name = "SpaceGrotesk-SemiBold"
    case .medium: name = "SpaceGrotesk-Medium"
    default: name = "SpaceGrotesk-Regular"
    }
    return .custom(name, size: size)
}

private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .custom(weight == .bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size)
}

private extension SessionState {
    /// 8pt dot, 1.5pt ring; a nil fill is a hollow dot. Working flashes
    /// yellow, finished is green, errored is red, needs-input is blue.
    var dot: (fill: Color?, ring: Color) {
        switch self {
        case .needsInput: (Palette.statusNeedsInput, Palette.statusNeedsInput)
        case .working: (Palette.statusWorking, Palette.statusWorking)
        case .errored: (nil, Palette.statusErrored)
        case .finished: (nil, Palette.statusFinished)
        case .idle: (Palette.idle, Palette.idle)
        }
    }
}

/// `<60s → Ns`, `<1h → Nm`, else `Nh`. Re-renders on every scan.
private func ageText(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "\(Int(seconds))s" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    return "\(Int(seconds / 3600))h"
}

// MARK: - Temporarily hidden UI

/// Jump-to-window affordances (header ↗, inbox + row terminal/window chips)
/// and the editor chip are hidden for now. The logic stays wired behind
/// these flags so restoring them is a one-line flip.
/// The inbox ALLOW / DENY / SEND buttons are gone entirely, not hidden:
/// no adapter implements AnsweringAdapter yet, so they were clickable
/// no-ops. They come back once an adapter can deliver answers.
private let jumpActionsVisible = false
private let editorActionVisible = false

/// Forces a cursor while hovered. A pushed cursor overrides both the hand
/// SwiftUI buttons show and the I-beam over text; each instance balances
/// its own push with a pop on leave/disappear so the stack can't stick.
private struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, !pushed {
                    cursor.push()
                    pushed = true
                } else if !hovering, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

private extension View {
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursor(cursor: cursor))
    }
}

/// Local sessions carry nothing; remote sessions get `@<host>`.
private func hostSuffix(_ machine: String) -> String {
    machine == "This Mac" ? "" : "@\(machine)"
}

/// One collapsible group per harness. Waiting sessions count toward the group
/// even though they render in the inbox, never in the rows.
private struct HarnessGroup {
    let style: HarnessStyle
    let rows: [AgentSession]
    let waitingCount: Int
    let workingCount: Int
    let costSubtotal: Double
    var key: String { style.key }
    /// Total including waiting, for the header summary.
    let total: Int
}

// MARK: - Panel

struct MenuContent: View {
    @EnvironmentObject var store: SessionStore
    /// Persisted as a comma-separated string; harness keys never contain commas.
    @AppStorage("collapsedHarnesses") private var collapsedRaw = ""
    /// Prototype tweak `rowCost`: header summaries show the harness cost
    /// subtotal instead of the working/total counts.
    @AppStorage("showRowCost") private var showRowCost = false
    @State private var expandedSessionID: String?
    @State private var jumpingHarness: String?
    @State private var sourcesExpanded = false
    @State private var hiddenExpanded = false

    /// Needs-input sessions live in the dark block, never in the groups.
    private var waiting: [AgentSession] {
        store.sessions
            .filter { $0.state == .needsInput }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private var waitingIDs: [String] { waiting.map(\.id) }

    /// Registry order — never sorted by urgency.
    private var groups: [HarnessGroup] {
        HarnessStyle.registry.compactMap { style in
            let all = store.sessions.filter {
                HarnessStyle.key(forHarness: $0.harness) == style.key
            }
            guard !all.isEmpty else { return nil }
            let rows = all
                .filter { $0.state != .needsInput }
                .sorted { a, b in
                    if a.stateRank != b.stateRank { return a.stateRank < b.stateRank }
                    return a.lastActivity > b.lastActivity
                }
            return HarnessGroup(
                style: style,
                rows: rows,
                waitingCount: all.filter { $0.state == .needsInput && !store.isStale($0) }.count,
                workingCount: rows.filter { $0.state == .working && !store.isStale($0) }.count,
                costSubtotal: all.reduce(0) { $0 + $1.costToday },
                total: all.count)
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    private func isCollapsed(_ key: String) -> Bool {
        collapsed.contains(key)
    }

    private func setCollapsed(_ key: String, _ collapsed: Bool) {
        var keys = self.collapsed
        if collapsed { keys.insert(key) } else { keys.remove(key) }
        collapsedRaw = keys.sorted().joined(separator: ",")
    }

    private func toggleRow(_ session: AgentSession) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            expandedSessionID = expandedSessionID == session.id ? nil : session.id
        }
    }

    private func jump(style: HarnessStyle, worktreePath: String?) {
        OpenIn.bringForward(style: style, worktreePath: worktreePath)
        let key = style.key
        jumpingHarness = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if jumpingHarness == key { jumpingHarness = nil }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            CappedScroll(limit: (NSScreen.main?.visibleFrame.height ?? 800) - 80) {
                VStack(spacing: 0) {
                    inboxBlock
                    if store.sessions.isEmpty {
                        emptyState
                    } else {
                        groupsView
                    }
                    hiddenControls
                    if sourcesExpanded {
                        sourceDetails
                    }
                }
            }
            footer
        }
        .frame(width: Metrics.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.paper)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .strokeBorder(Palette.ink, lineWidth: 1)
        )
        // Answering a prompt moves the card into its group; animate that hop.
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: waitingIDs)
        // Arrow cursor everywhere on the panel — never the hand or I-beam,
        // including over text.
        .hoverCursor(.arrow)
        .onDisappear {
            expandedSessionID = nil
            jumpingHarness = nil
        }
        .task { await store.refreshNotificationAccess() }
    }

    // MARK: Dark block

    private var inboxBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
            if waiting.isEmpty {
                quietCard
            } else {
                VStack(spacing: 0) {
                    ForEach(waiting) { session in
                        InboxCard(
                            session: session,
                            style: HarnessStyle.style(forHarness: session.harness),
                            isStale: store.isStale(session),
                            onJump: {
                                jump(style: HarnessStyle.style(forHarness: session.harness),
                                     worktreePath: session.worktreePath)
                            })
                    }
                }
            }
        }
        .background(Palette.ink)
    }

    /// Compact status above the harness lists. Session details live in their
    /// harness containers, so the status does not repeat those rows.
    private var quietCard: some View {
        let workingCount = store.sessions.filter { $0.state == .working && !store.isStale($0) }.count
        let lastFinished = store.sessions
            .filter { $0.state == .finished && !store.isStale($0) }
            .max { $0.lastActivity < $1.lastActivity }
        return VStack(alignment: .leading, spacing: 4) {
            Text(store.lastScan == nil
                 ? "Checking sessions"
                 : (store.hasSourceProblems || store.hasStaleSessions
                    ? "Monitoring needs attention"
                    : (workingCount == 0 ? "Nothing running" : "\(workingCount) running, nothing needs you")))
                .font(grotesk(Metrics.uiTitle, .medium))
                .foregroundStyle(Palette.paper)
            if workingCount == 0, let lastFinished {
                Text("Last finished \(ageText(lastFinished.lastActivity, now: Date())) ago")
                    .font(mono(Metrics.mono))
                    .foregroundStyle(Palette.onInk(0.55))
            }
        }
        .padding(EdgeInsets(top: 10, leading: Metrics.gutter, bottom: 14, trailing: Metrics.gutter))
    }

    private var eyebrow: some View {
        let working = store.sessions.filter { $0.state == .working && !store.isStale($0) }.count
        let quiet = store.sessions.count - waiting.count - working
        let stale = store.sessions.filter { store.isStale($0) }.count
        return HStack(spacing: 7) {
            Circle()
                .fill(store.waitingCount == 0 ? Palette.text3 : Palette.coral)
                .frame(width: 6, height: 6)
            Text(store.lastScan == nil
                 ? "CHECKING"
                 : (store.waitingCount == 0
                    ? (store.hasSourceProblems || store.hasStaleSessions ? "CHECK SOURCES" : "ALL QUIET")
                    : "\(store.waitingCount) NEED YOU"))
            Spacer()
            Text(stale > 0 ? "\(working) working · \(stale) stale" : "\(working) working · \(quiet) quiet")
                .monospacedDigit()
        }
        .font(mono(Metrics.eyebrow))
        .tracking(1.2)
        .foregroundStyle(Palette.onInk(0.55))
        .padding(EdgeInsets(top: 14, leading: Metrics.gutter, bottom: 0, trailing: Metrics.gutter))
    }

    // MARK: Harness groups

    private var groupsView: some View {
        VStack(spacing: 0) {
            ForEach(groups, id: \.key) { group in
                GroupSection(
                    group: group,
                    isOpen: !isCollapsed(group.key),
                    isJumping: jumpingHarness == group.key,
                    showCost: showRowCost,
                    expandedSessionID: expandedSessionID,
                    onToggle: { setCollapsed(group.key, isCollapsed(group.key) ? false : true) },
                    onJump: { jump(style: group.style, worktreePath: group.rows.first?.worktreePath) },
                    onToggleRow: toggleRow,
                    onDismiss: { store.dismiss($0) },
                    onJumpSession: {
                        jump(
                            style: HarnessStyle.style(forHarness: $0.harness),
                            worktreePath: $0.worktreePath)
                    },
                    staleSessionIDs: store.staleSessionIDs)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 0, bottom: 4, trailing: 0))
    }

    private var monitoringProblem: Bool { store.hasSourceProblems || store.hasStaleSessions }
    private var alertsOff: Bool { store.notificationAccess != .authorized && store.notificationAccess != .checking }

    private var sourceDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.sourceStatuses) { status in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(status.harness)
                            Spacer()
                            Text(status.label)
                                .foregroundStyle(status.hasProblem ? Palette.coral : Palette.text3)
                        }
                        if let attempted = status.lastAttempt {
                            Text("Attempted \(ageText(attempted, now: Date())) ago · success \(status.lastSuccess.map { ageText($0, now: Date()) + " ago" } ?? "not yet")")
                                .foregroundStyle(Palette.text3)
                        }
                        ForEach(status.details.indices, id: \.self) { index in
                            Text(status.details[index])
                                .foregroundStyle(Palette.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if monitoringProblem {
                    Text("Rows marked stale show the last known state. Today's cost total may be incomplete.")
                        .foregroundStyle(Palette.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.notificationAccess == .authorized {
                    Text(store.notificationAccess.label).foregroundStyle(Palette.text3)
                }
            }
            if store.notificationAccess != .authorized {
                HStack(alignment: .top, spacing: 8) {
                    Text(store.notificationAccess.label)
                        .foregroundStyle(Palette.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if store.notificationAccess == .notRequested {
                        Button("enable") { Task { await store.enableNotifications() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.ink)
                    } else if store.notificationAccess == .denied {
                        Button("settings") { Notifier.openSettings() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.ink)
                    }
                }
            }
        }
        .font(mono(Metrics.monoSmall))
        .foregroundStyle(Palette.text2)
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline2).frame(height: 1)
        }
    }

    @ViewBuilder
    private var hiddenControls: some View {
        if !store.hiddenSessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        hiddenExpanded.toggle()
                    } label: {
                        HStack {
                            Text(hiddenExpanded ? "▾" : "▸")
                            Text("\(store.hiddenSessions.count) hidden")
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("restore all") { store.restoreAll() }
                        .buttonStyle(.plain)
                }
                if hiddenExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.hiddenSessions) { session in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.sessionName ?? session.repo)
                                        .lineLimit(2)
                                    Text("\(session.harness) · \(session.repo)")
                                        .foregroundStyle(Palette.text3)
                                    if store.isStale(session) {
                                        Text("stale").foregroundStyle(Palette.coral)
                                    }
                                }
                                .help(session.worktreePath)
                                Spacer()
                                Button("restore") { store.restore(session.id) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Restore \(session.sessionName ?? session.repo)")
                            }
                        }
                    }
                }
            }
            .font(mono(Metrics.monoSmall))
            .foregroundStyle(Palette.text2)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 10)
        }
    }

    private var emptyState: some View {
        Text(store.hasSourceProblems ? "Session data could not be fully read" : "No visible sessions")
            .font(mono(Metrics.mono))
            .foregroundStyle(Palette.text4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }

    /// No top hairline: the last group's divider serves as the separator.
    private var footer: some View {
        HStack {
            Text("\(String(format: "$%.2f", store.totalCostToday)) today")
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(monitoringProblem ? Palette.coral : Palette.text3)
                .help(monitoringProblem
                      ? "Incomplete total. Some sources could not be read. Retained costs reset at midnight."
                      : "Includes hidden sessions")
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help(store.lastScan.map { "Retry sources. Last attempt \(ageText($0, now: Date())) ago" } ?? "Refresh sources")
            .accessibilityLabel("Refresh sources")
            Spacer()
            Button {
                sourcesExpanded.toggle()
            } label: {
                Text(monitoringProblem ? "check sources" : (alertsOff ? "alerts off" : "sources"))
                    .foregroundStyle(monitoringProblem || alertsOff ? Palette.coral : Palette.text3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sourcesExpanded ? "Hide source status" : "Show source status and notification access")
            .padding(.trailing, 10)
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 8) {
                    Text("quit")
                    Text("⌘Q").foregroundStyle(Palette.text4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
        .font(mono(Metrics.mono))
        .foregroundStyle(Palette.text3)
        .frame(height: Metrics.footerHeight)
        .padding(.horizontal, Metrics.gutter)
    }
}

// MARK: - Mark badge

/// Filled square in the harness color, paper glyph. Two sizes: 22×22 in
/// group headers and 16×16 in inbox card meta lines.
/// A real logo asset renders on the same square in place of the letter when
/// one exists. On the dark block the ink mark (#1A1A19 on #1A1A19) inverts
/// to a paper square with an ink glyph so Codex stays visible.
private struct MarkBadge: View {
    let mark: String
    let color: Color
    let colorHex: UInt32
    let size: CGFloat
    let radius: CGFloat
    let fontSize: CGFloat
    var onInk = false

    private var isInk: Bool { colorHex == 0x1A_1A19 }
    private var fill: Color { onInk && isInk ? Palette.paper : color }
    private var glyph: Color { onInk && isInk ? Palette.ink : Palette.paper }

    var body: some View {
        Text(mark)
            .font(mono(fontSize, .bold))
            .foregroundStyle(glyph)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .fixedSize()
    }
}

/// 8×8 dot that breathes while its session is live. The animation is scoped
/// to this dot: an unscoped repeatForever transaction (the old
/// withAnimation-in-onAppear pattern) leaks onto the panel's layout and
/// makes the whole window wobble.
private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Metrics.dot, height: Metrics.dot)
            .opacity(pulsing ? 0.3 : 1)
            .animation(
                .easeInOut(duration: 1).repeatForever(autoreverses: true),
                value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - Inbox card

private struct SessionIdentity: View {
    let session: AgentSession
    var onInk = false

    private var textColor: Color { onInk ? Palette.onInk(0.65) : Palette.text3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.sessionName ?? session.repo)
                .font(grotesk(Metrics.ui, .medium))
                .foregroundStyle(onInk ? Palette.paper : Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(session.repo)\(hostSuffix(session.machine))\(session.branch.map { " · " + $0 } ?? "")")
                .fixedSize(horizontal: false, vertical: true)
            if !session.worktreePath.isEmpty {
                Text(session.worktreePath)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Working directory \(session.worktreePath)")
                Button("copy path") {
                    SessionClipboard.copyPath(session.worktreePath)
                }
                .buttonStyle(.plain)
                .foregroundStyle(onInk ? Palette.paper : Palette.text2)
                .padding(.vertical, 3)
                .accessibilityLabel("Copy path for \(session.sessionName ?? session.repo)")
            } else {
                Text("Working directory unavailable")
            }
        }
        .font(mono(Metrics.monoSmall))
        .foregroundStyle(textColor)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SessionClipboard {
    @MainActor
    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

private struct InboxCard: View {
    let session: AgentSession
    let style: HarnessStyle
    let isStale: Bool
    let onJump: () -> Void

    private var color: Color { Color(hex: style.colorHex) }
    private var light: Color { Color(hex: style.lightHex) }

    /// `terminal` for terminal harnesses, `window` for app harnesses.
    private var surfaceLabel: String {
        style.surface == .app ? "window" : "terminal"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                MarkBadge(
                    mark: style.mark, color: color, colorHex: style.colorHex,
                    size: Metrics.badgeCard, radius: 4, fontSize: 9, onInk: true)
                Text(style.displayName)
                    .foregroundStyle(light)
                Text("· \(context)")
                    .foregroundStyle(Palette.onInk(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(context)
                Spacer()
                Text(ageText(session.lastActivity, now: Date()))
                    .foregroundStyle(Palette.onInk(0.6))
            }
            .font(mono(Metrics.monoSmall))
            Text(session.sessionName ?? session.repo)
                .font(grotesk(Metrics.ui, .medium))
                .foregroundStyle(Palette.onInk(0.75))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if isStale {
                Text("Stale · last known prompt")
                    .font(mono(Metrics.monoSmall))
                    .foregroundStyle(Palette.coral)
                    .padding(.top, 6)
            }
            Text(questionText)
                .font(grotesk(Metrics.uiTitle, .medium))
                .lineSpacing(3)
                .foregroundStyle(Palette.paper)
                .padding(.top, 6)
            if !session.worktreePath.isEmpty {
                Button("copy path") {
                    SessionClipboard.copyPath(session.worktreePath)
                }
                .buttonStyle(.plain)
                .font(mono(Metrics.monoSmall))
                .foregroundStyle(Palette.onInk(0.55))
                .help(session.worktreePath)
                .accessibilityLabel("Copy path for \(session.sessionName ?? session.repo)")
                .padding(.top, 10)
            }
            if jumpActionsVisible {
                HStack(spacing: 8) {
                    jumpChip
                }
                .padding(.top, 14)
            }
        }
        .padding(EdgeInsets(top: 14, leading: Metrics.gutter, bottom: 16, trailing: Metrics.gutter))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.onInk(0.1)).frame(height: 1)
        }
    }

    private var context: String {
        "\(session.repo)\(hostSuffix(session.machine))\(session.branch.map { " · " + $0 } ?? "")"
    }

    private var questionText: String {
        if let question = session.question { return question }
        if let tool = session.currentTool { return "Check \(tool)" }
        return "Waiting for you"
    }

    /// Outline chip bordered in the harness color: brings that harness's
    /// target window forward.
    private var jumpChip: some View {
        Button(action: onJump) {
            HStack(spacing: 6) {
                Text(surfaceLabel)
                Text("↗").opacity(0.6)
            }
            .font(mono(11))
            .foregroundStyle(light)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(color, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Bring \(OpenIn.jumpTargetName(for: style)) forward")
    }
}

// MARK: - Harness group section

private struct GroupSection: View {
    let group: HarnessGroup
    let isOpen: Bool
    let isJumping: Bool
    let showCost: Bool
    let expandedSessionID: String?
    let onToggle: () -> Void
    let onJump: () -> Void
    let onToggleRow: (AgentSession) -> Void
    let onDismiss: (AgentSession) -> Void
    let onJumpSession: (AgentSession) -> Void
    let staleSessionIDs: Set<String>

    @State private var hovered = false
    @State private var jumpHovered = false
    private var color: Color { Color(hex: group.style.colorHex) }

    /// `N working · T sessions` when anything is working, else `T sessions`.
    /// Cost subtotal when the row-cost preference is on.
    private var summary: String {
        if showCost { return String(format: "$%.2f", group.costSubtotal) }
        let sessions = group.total == 1 ? "1 session" : "\(group.total) sessions"
        if group.workingCount > 0 { return "\(group.workingCount) working · \(sessions)" }
        return sessions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isOpen, !group.rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(group.rows) { session in
                        SessionRow(
                            session: session,
                            style: HarnessStyle.style(forHarness: session.harness),
                            isExpanded: expandedSessionID == session.id,
                            isStale: staleSessionIDs.contains(session.id),
                            onToggle: { onToggleRow(session) },
                            onJumpSession: { onJumpSession(session) },
                            onDismiss: session.canDismiss ? { onDismiss(session) } : nil)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hairline2).frame(height: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Text("▸")
                        .font(mono(Metrics.monoSmall))
                        .foregroundStyle(Palette.text3)
                        .frame(width: 10)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isOpen)
                    MarkBadge(
                        mark: group.style.mark, color: color,
                        colorHex: group.style.colorHex,
                        size: Metrics.badgeHeader, radius: Metrics.radius, fontSize: 11)
                    Text(group.style.displayName)
                        .font(grotesk(Metrics.ui, .semibold))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    // Waiting can never be hidden: the collapsed header keeps
                    // a coral count even though the card stays in the inbox.
                    if !isOpen, group.waitingCount > 0 {
                        Text("\(group.waitingCount)")
                            .font(mono(Metrics.monoSmall))
                            .foregroundStyle(Palette.paper)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.coral))
                    }
                    Text(summary)
                        .font(mono(Metrics.mono))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if jumpActionsVisible {
                jumpButton
            }
        }
        .frame(height: Metrics.headerHeight)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .background(hovered ? Palette.selected : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(color).frame(width: 3)
        }
        .onHover { hovered = $0 }
    }

    /// Never toggles collapse. While the jump is in flight it inverts.
    private var jumpButton: some View {
        Button(action: onJump) {
            Text("↗")
                .font(mono(Metrics.mono))
                .foregroundStyle(isJumping ? Palette.paper : color)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: Metrics.radius).fill(isJumping ? color : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radius)
                        .strokeBorder(color, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .brightness(jumpHovered && !isJumping ? -0.1 : 0)
        .onHover { jumpHovered = $0 }
        .help("Bring \(OpenIn.jumpTargetName(for: group.style)) forward")
    }
}

// MARK: - Session row

struct SessionRow: View {
    let session: AgentSession
    let style: HarnessStyle
    let isExpanded: Bool
    let isStale: Bool
    let onToggle: () -> Void
    let onJumpSession: () -> Void
    var onDismiss: (() -> Void)? = nil

    @State private var hovered = false

    private var faint: Color { Color(hex: style.faintHex) }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                header
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hide session details" : "Show session details")
            if isExpanded {
                detail
            }
        }
        .background(isExpanded ? Palette.selected : .clear)
    }

    /// Indented under the chevron; the faint edge continues the header edge.
    /// No harness tag — the group carries it.
    private var header: some View {
        HStack(spacing: 12) {
            stateDot
            Text(session.sessionName ?? session.repo)
                .font(grotesk(Metrics.ui, .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .help(session.sessionName ?? session.repo)
            if isStale {
                Text("stale")
                    .font(mono(10))
                    .foregroundStyle(Palette.coral)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // Names are usually the first prompt, so the repo tells rows apart.
            if session.sessionName != nil {
                Text(shortRepo)
                    .font(mono(Metrics.monoSmall))
                    .foregroundStyle(Palette.text4)
                    .fixedSize()
                    .help(session.repo)
            }
            Text(ageText(session.lastActivity, now: Date()))
                .font(mono(Metrics.mono))
                .monospacedDigit()
                .foregroundStyle(Palette.text2)
                .frame(width: 32, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.text3)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.leading, Metrics.rowIndent)
        .padding(.trailing, Metrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.rowHeight)
        .background(hovered ? Palette.hover : .clear)
        .overlay(alignment: .leading) {
            Rectangle().fill(faint).frame(width: 3)
        }
        .onHover { hovered = $0 }
    }

    private var shortRepo: String {
        let repo = session.repo
        return repo.count > 16 ? "\(repo.prefix(7))…\(repo.suffix(8))" : repo
    }

    /// The dot breathes while the agent is live, so working reads at a glance.
    @ViewBuilder
    private var stateDot: some View {
        let spec = session.state.dot
        if session.state == .working, !isStale {
            PulsingDot(color: spec.fill ?? spec.ring)
        } else {
            Circle()
                .fill(spec.fill ?? .clear)
                .overlay(Circle().strokeBorder(spec.ring, lineWidth: 1.5))
                .frame(width: Metrics.dot, height: Metrics.dot)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionIdentity(session: session)
            if isStale {
                Text("Stale · last known state. Retry sources to update.")
                    .foregroundStyle(Palette.coral)
            }
            detailLine
            metaLine
            actionChips
                .padding(.top, 4)
        }
        .font(mono(Metrics.mono))
        .lineSpacing(2)
        .padding(EdgeInsets(top: 2, leading: Metrics.detailIndent, bottom: 16, trailing: Metrics.gutter))
    }

    @ViewBuilder
    private var detailLine: some View {
        switch session.state {
        case .working:
            Text(session.currentTool.map { "Running \($0)" } ?? "Working")
                .foregroundStyle(Palette.text2)
                .lineLimit(2).truncationMode(.tail)
                .help(session.currentTool.map { "Running \($0)" } ?? "Working")
        case .errored:
            Text("Errored · last activity \(ageText(session.lastActivity, now: Date())) ago")
                .foregroundStyle(Palette.coral)
                .lineLimit(2).truncationMode(.tail)
        case .finished:
            Text("Finished").foregroundStyle(Palette.text2)
        case .idle:
            Text("Idle").foregroundStyle(Palette.text2)
        case .needsInput:
            EmptyView()
        }
    }

    private var metaLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let model = session.model {
                Text(model)
            }
            if let dirty = session.worktreeDirty {
                Text(dirty ? "worktree dirty" : "worktree clean")
            }
            if session.branchMerged == true {
                Text("merged into main")
            }
            Text(String(format: "$%.2f today", session.costToday))
        }
        .foregroundStyle(Palette.text3)
    }

    @ViewBuilder
    private var actionChips: some View {
        HStack(spacing: 8) {
            if jumpActionsVisible {
                chip(style.surface == .app ? "window" : "terminal", shortcut: "⌘↵", action: onJumpSession)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            if editorActionVisible {
                chip("editor", shortcut: "⌘E") {
                    OpenIn.editor(session.worktreePath)
                }
                .keyboardShortcut("e", modifiers: .command)
            }
            if session.branchMerged == true {
                chip("remove worktree", shortcut: nil) {
                    confirmRemoveWorktree()
                }
            }
            Spacer(minLength: 0)
            if session.canDismiss, let onDismiss {
                Button(action: onDismiss) {
                    Text("hide")
                        .foregroundStyle(Palette.text4)
                        .padding(.horizontal, 6)
                        .frame(height: Metrics.chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chip(
        _ label: String, shortcut: String?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(label)
                if let shortcut {
                    Text(shortcut).foregroundStyle(Palette.text4)
                }
            }
            .font(mono(11))
            .foregroundStyle(Palette.text2)
            .padding(.horizontal, 10)
            .frame(height: Metrics.chipHeight)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius)
                    .strokeBorder(Palette.controlLine, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func confirmRemoveWorktree() {
        let alert = NSAlert()
        alert.messageText = "Remove worktree?"
        alert.informativeText = session.worktreePath
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            OpenIn.removeWorktree(session.worktreePath)
        }
    }
}

// MARK: - Open actions

private enum OpenIn {
    static func terminal(_ path: String) {
        open(["-a", "Terminal", path])
    }

    static func editor(_ path: String) {
        let app = UserDefaults.standard.string(forKey: "editorApp") ?? "Visual Studio Code"
        open(["-a", app, path])
    }

    static func removeWorktree(_ path: String) {
        run("/usr/bin/git", ["worktree", "remove", path])
    }

    /// Bring the harness's destination forward: any tab of that harness for
    /// terminal surfaces (front-most is fine), the target app otherwise.
    /// The panel closes and the window comes forward; no toast.
    static func bringForward(style: HarnessStyle, worktreePath: String?) {
        switch style.surface {
        case .terminal:
            if let path = worktreePath, !path.isEmpty {
                terminal(path)
            } else {
                open(["-a", style.targetAppName])
            }
        case .app:
            open(["-a", style.targetAppName])
        }
    }

    static func jumpTargetName(for style: HarnessStyle) -> String {
        style.surface == .terminal ? style.targetAppName : "\(style.targetAppName).app"
    }

    private static func open(_ arguments: [String]) {
        run("/usr/bin/open", arguments)
    }

    private static func run(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try? process.run()
    }
}
