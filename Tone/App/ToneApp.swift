import AppKit
import SwiftUI

@main
@MainActor
enum ToneMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var menu: MenuController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        menu = MenuController(model: model) { [weak self] in self?.showSettings() }
        if Diagnostics.shared.enabled { addDebugHooks() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    private func showSettings() {
        let window = settingsWindow ?? {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(model)))
            window.title = "Tone Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
            return window
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Lets scripts open the UI: post "com.gooober.tone.debug.<name>" as a distributed notification.
    private func addDebugHooks() {
        // DebugAppearance "light" or "dark" overrides the system appearance.
        if let name = UserDefaults.standard.string(forKey: "DebugAppearance") {
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        let hooks: [String: @MainActor (AppDelegate) -> Void] = [
            "panel": { $0.menu.debugOpen() },
            "settings": { $0.showSettings() },
            "equalizer": { delegate in
                if let key = delegate.model.applicationKeys.first { delegate.menu.showEqualizer(key) }
            },
        ]
        for (name, hook) in hooks {
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.gooober.tone.debug.\(name)"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self.map(hook) }
            }
        }
    }
}
