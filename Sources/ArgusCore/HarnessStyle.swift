import Foundation

/// Where a harness session lives: a terminal tab or a GUI app window.
///
/// The surface / target-app mapping belongs to the adapters — they know how
/// the harness runs. The registry below is the default; an adapter overrides
/// `surface` / `targetAppName` / `targetBundleID` once it knows better (the
/// prototype guessed codex/pi are apps).
public enum HarnessSurface: String, Sendable {
    case terminal
    case app
}

public struct HarnessStyle: Sendable, Hashable {
    public let key: String
    public let displayName: String
    public let colorHex: UInt32
    public let lightHex: UInt32
    public let faintHex: UInt32
    public let mark: String
    public let surface: HarnessSurface
    public let targetAppName: String
    public let targetBundleID: String?

    public init(
        key: String, displayName: String, colorHex: UInt32, lightHex: UInt32,
        faintHex: UInt32, mark: String, surface: HarnessSurface,
        targetAppName: String, targetBundleID: String?
    ) {
        self.key = key
        self.displayName = displayName
        self.colorHex = colorHex
        self.lightHex = lightHex
        self.faintHex = faintHex
        self.mark = mark
        self.surface = surface
        self.targetAppName = targetAppName
        self.targetBundleID = targetBundleID
    }

    public static let claude = HarnessStyle(
        key: "claude", displayName: "claude",
        colorHex: 0xD9_7757, lightHex: 0xF2_B39C, faintHex: 0xF0_CFC1, mark: "C",
        surface: .terminal, targetAppName: "Terminal", targetBundleID: "com.apple.Terminal")
    public static let codex = HarnessStyle(
        key: "codex", displayName: "codex",
        colorHex: 0x1A_1A19, lightHex: 0xD4_D4D0, faintHex: 0xC9_C9C4, mark: "X",
        surface: .app, targetAppName: "Codex", targetBundleID: nil)
    public static let opencode = HarnessStyle(
        key: "opencode", displayName: "opencode",
        colorHex: 0x3B_82F6, lightHex: 0xA9_C7FB, faintHex: 0xC8_DAF8, mark: "O",
        surface: .terminal, targetAppName: "Terminal", targetBundleID: "com.apple.Terminal")
    public static let pi = HarnessStyle(
        key: "pi", displayName: "pi",
        colorHex: 0x7C_5CFF, lightHex: 0xC4_B5FD, faintHex: 0xD9_D0F6, mark: "π",
        surface: .app, targetAppName: "Pi", targetBundleID: nil)

    /// Display order. Groups render in registry order, never sorted by urgency.
    public static let registry: [HarnessStyle] = [.claude, .codex, .opencode, .pi]

    /// Adapter harness names ("Claude Code", "Codex", …) map onto registry keys.
    public static func style(forHarness harness: String) -> HarnessStyle {
        let normalized = harness.lowercased().replacingOccurrences(of: " ", with: "")
        if let exact = registry.first(where: { $0.key == normalized }) { return exact }
        if normalized.contains("claude") { return .claude }
        if normalized.contains("codex") { return .codex }
        if normalized.contains("opencode") { return .opencode }
        if normalized == "pi" { return .pi }
        return HarnessStyle(
            key: normalized, displayName: harness.lowercased(),
            colorHex: 0x1A_1A19, lightHex: 0xD4_D4D0, faintHex: 0xC9_C9C4, mark: "?",
            surface: .terminal, targetAppName: "Terminal", targetBundleID: "com.apple.Terminal")
    }

    public static func key(forHarness harness: String) -> String {
        style(forHarness: harness).key
    }
}

extension HarnessAdapter {
    /// Defaults from the registry; override per adapter once the real
    /// surface / target is known.
    public var surface: HarnessSurface { HarnessStyle.style(forHarness: name).surface }
    public var targetAppName: String { HarnessStyle.style(forHarness: name).targetAppName }
    public var targetBundleID: String? { HarnessStyle.style(forHarness: name).targetBundleID }
}
