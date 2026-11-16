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
        if ProcessInfo.processInfo.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.panel.show() } }
        }
        if Diagnostics.shared.enabled {
            DistributedNotificationCenter.default().addObserver(forName: .init("com.gooober.tone.debug.panel"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel.toggleFromDebug() }
            }
            DistributedNotificationCenter.default().addObserver(forName: .init("com.gooober.tone.debug.expand"), object: nil, queue: .main) { [weak self] note in
                let key = note.userInfo?["key"] as? String ?? ""
                let eq = (note.userInfo?["eq"] as? NSNumber)?.boolValue ?? false
                MainActor.assumeIsolated { self?.panel.expandFromDebug(key: key, eq: eq) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func showSettings() {
        panel.close()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(model)))
            window.title = "Tone Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
