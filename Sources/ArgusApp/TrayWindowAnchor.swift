import AppKit
import SwiftUI

struct TrayWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> TrayAnchorView { TrayAnchorView() }

    func updateNSView(_ nsView: TrayAnchorView, context: Context) {
        nsView.scheduleAlignment()
    }
}

final class TrayAnchorView: NSView {
    private var alignmentScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowGeometryChanged), name: name, object: window)
        }
        scheduleAlignment()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        // Resize in the same layout pass: a deferred resize lets one frame
        // draw the new panel inside the old window size.
        if oldSize != newSize { alignWindow() }
    }

    override func layout() {
        super.layout()
        scheduleAlignment()
    }

    @objc private func windowGeometryChanged(_ notification: Notification) {
        scheduleAlignment()
    }

    func scheduleAlignment() {
        guard !alignmentScheduled else { return }
        alignmentScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.alignmentScheduled = false
            self.alignWindow()
        }
    }

    private func alignWindow() {
        guard let window, let screen = window.screen,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return }
        let top = screen.visibleFrame.maxY
        let left = window.frame.minX
        let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: bounds.size)).size
        let target = NSRect(x: left, y: top - frameSize.height,
                            width: frameSize.width, height: frameSize.height)
        // MenuBarExtra can keep its expanded window after the content shrinks.
        if abs(window.frame.width - target.width) > 0.5 || abs(window.frame.height - target.height) > 0.5
            || abs(window.frame.maxY - top) > 0.5 {
            window.setFrame(target, display: true, animate: false)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

