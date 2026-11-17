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
    private var panel: PanelController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        panel = PanelController(model: model) { [weak self] in self?.showSettings() }
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

    /// Lets scripts open the UI: post "com.gooober.tone.debug.<name>" as a distributed
    /// notification. "expand" and "keys" take their argument as the notification's object.
    private func addDebugHooks() {
        // DebugAppearance "light" or "dark" overrides the system appearance.
        if let name = UserDefaults.standard.string(forKey: "DebugAppearance") {
            NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        }
        let hooks: [String: @MainActor (AppDelegate, String?) -> Void] = [
            "panel": { delegate, _ in delegate.panel.toggle() },
            "settings": { delegate, _ in delegate.showSettings() },
            "equalizer": { delegate, _ in delegate.panel.debugExpand(row: "app", equalizer: true) },
            "expand": { delegate, row in delegate.panel.debugExpand(row: row ?? "app", equalizer: false) },
            "keys": { delegate, keys in delegate.panel.debugKeys(keys ?? "") },
        ]
        for (name, hook) in hooks {
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.gooober.tone.debug.\(name)"), object: nil, queue: .main) { [weak self] note in
                let argument = note.object as? String
                MainActor.assumeIsolated { if let self { hook(self, argument) } }
            }
        }
    }
}
