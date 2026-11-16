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
        if ProcessInfo.processInfo.arguments.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { self.menu.open() } }
        }
        if Diagnostics.shared.enabled {
            DistributedNotificationCenter.default().addObserver(forName: .init("com.gooober.tone.debug.panel"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menu.open() }
            }
            DistributedNotificationCenter.default().addObserver(forName: .init("com.gooober.tone.debug.close"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menu.close() }
            }
            DistributedNotificationCenter.default().addObserver(forName: .init("com.gooober.tone.debug.expand"), object: nil, queue: .main) { [weak self] note in
                let row = note.userInfo?["row"] as? String ?? ""
                let eq = (note.userInfo?["eq"] as? NSNumber)?.boolValue ?? false
                MainActor.assumeIsolated { _ = (row, eq); self?.menu.open() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func showSettings() {
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
