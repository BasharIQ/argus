import AppKit
import Foundation
import UserNotifications
import ArgusCore

enum NotificationAccess: Equatable {
    case checking
    case notRequested
    case authorized
    case denied
    case unavailable

    var label: String {
        switch self {
        case .checking: "Checking notification access"
        case .notRequested: "Notifications are not enabled"
        case .authorized: "Notifications enabled"
        case .denied: "Notifications are blocked in System Settings"
        case .unavailable: "Notifications require the bundled Argus app"
        }
    }
}

/// Delivers `SessionAlert`s as native notifications. Alerts are computed by
/// `AlertTracker` (ArgusCore, tested); this type only authorizes and posts.
/// Thread-safe: UNUserNotificationCenter accepts calls from any queue.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter?

    init(center: UNUserNotificationCenter? = nil, resolveSystemCenter: Bool = true) {
        // UNUserNotificationCenter.current() raises an uncatchable ObjC
        // exception when the process has no bundle identity (the raw
        // `swift run` binary), so only resolve it for the bundled app.
        // Unbundled, this stays nil and delivery is a no-op.
        let bundled = Bundle.main.bundleIdentifier != nil
        self.center = center ?? (bundled && resolveSystemCenter ? .current() : nil)
        super.init()
        #if DEBUG
        if !bundled, center == nil {
            fputs("argus: no bundle identifier (raw binary?) — notifications need build/Argus.app, see scripts/make-app.sh\n", stderr)
        }
        #endif
        guard let center = self.center else { return }
        center.delegate = self
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-notification") {
            // Posts one sample banner a moment after launch so the full
            // system path (prompt → delivery → banner) can be verified
            // without waiting for a real session transition.
            Task { [center] in
                try? await Task.sleep(for: .seconds(2))
                self.post(SessionAlert(
                    sessionID: "test", state: .needsInput,
                    title: "Argus test", subtitle: "pi · playground (main)",
                    body: "Needs your input — if you can see this, notifications work",
                    harnessMark: "π", harnessColorHex: 0x7C_5CFF), via: center)
            }
        }
        #endif
    }

    func authorizationStatus() async -> NotificationAccess {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async -> NotificationAccess {
        guard let center else { return .unavailable }
        guard await authorizationStatus() == .notRequested else { return await authorizationStatus() }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            return await authorizationStatus()
        } catch {
            return .unavailable
        }
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func deliver(_ alerts: [SessionAlert]) {
        guard let center else { return }
        for alert in alerts {
            post(alert, via: center)
            #if DEBUG
            fputs("argus: notified \(alert.identifier) — \(alert.title)\n", stderr)
            #endif
        }
    }

    func clearResolvedPrompts(in sessions: [AgentSession]) {
        guard let center else { return }
        let identifiers = sessions.filter { $0.state != .needsInput }
            .map { "argus-\($0.id)-needsInput" }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func post(_ alert: SessionAlert, via center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.subtitle
        content.body = alert.body
        content.sound = .default
        // Follow-ups from the same session stack under one group.
        content.threadIdentifier = "argus-\(alert.sessionID)"
        if let badge = badgeAttachment(mark: alert.harnessMark, colorHex: alert.harnessColorHex) {
            content.attachments = [badge]
        }
        center.add(UNNotificationRequest(
            identifier: alert.identifier, content: content, trigger: nil))
    }

    /// Brand badge (harness color + letter, mirroring the menu mark) as the
    /// notification icon. Rendered once per harness and cached in tmp.
    private func badgeAttachment(mark: String, colorHex: UInt32) -> UNNotificationAttachment? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-badge-\(String(colorHex, radix: 16))-\(mark).png")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let png = onMain({ Self.renderBadge(mark: mark, colorHex: colorHex) }) else { return nil }
            try? png.write(to: file)
        }
        return try? UNNotificationAttachment(identifier: "badge", url: file, options: nil)
    }

    /// AppKit drawing must happen on the main thread; delivery usually
    /// arrives via the MainActor already, the debug test path doesn't.
    private func onMain<T>(_ work: @escaping () -> T?) -> T? {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    private static func renderBadge(mark: String, colorHex: UInt32) -> Data? {
        let side: CGFloat = 96
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        defer { image.unlockFocus() }
        // The ink (codex) mark inverts to a paper square so it stays
        // visible, same as the menu badge on the dark block.
        let isInk = colorHex == 0x1A_1A19
        (isInk ? NSColor.white : badgeColor(colorHex)).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 22, yRadius: 22).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 52, weight: .bold),
            .foregroundColor: isInk ? badgeColor(colorHex) : NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let textSize = mark.size(withAttributes: attrs)
        mark.draw(
            at: NSPoint(x: (side - textSize.width) / 2, y: (side - textSize.height) / 2),
            withAttributes: attrs)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }

    private static func badgeColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Show the banner even when Argus is frontmost (rare for a menu bar app,
    /// but cheap to guarantee).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
