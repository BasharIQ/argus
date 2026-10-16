import SwiftUI
import ArgusCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        #if !ARGUS_PREVIEW
        NSApp.setActivationPolicy(.accessory)
        #endif
    }
}

@main
struct ArgusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()

    init() {
        Fonts.register()
    }

    var body: some Scene {
        #if ARGUS_PREVIEW
        WindowGroup("Argus Preview") {
            MenuContent()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        #else
        MenuBarExtra {
            Group {
                // windowResizeAnchor ships in the macOS 26 SDK (Swift 6.2);
                // older toolchains cannot resolve the symbol.
                #if compiler(>=6.2)
                if #available(macOS 26, *) {
                    MenuContent()
                        .environmentObject(store)
                        .windowResizeAnchor(.top)
                } else {
                    MenuContent()
                        .environmentObject(store)
                }
                #else
                MenuContent()
                    .environmentObject(store)
                #endif
            }
            .background(TrayWindowAnchor())
            // A window taller than the panel would otherwise center it.
            .frame(maxHeight: .infinity, alignment: .top)
        } label: {
            Image(nsImage: TrayIcon.image(waitingCount: store.waitingCount))
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
