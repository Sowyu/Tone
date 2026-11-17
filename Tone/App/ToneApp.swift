import AppKit
import SwiftUI

@main
@MainActor
enum ToneMain {
    static func main() {
        // The updater runs a copy of this binary as its install helper.
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "--install-update" {
            exit(UpdateInstaller.runHelper(URL(fileURLWithPath: arguments[2])))
        }
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
    private let updates = UpdateController()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Alerts show NSApp's icon, which comes back blank for this menu bar app; read it from the bundle.
        NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        model = AppModel()
        panel = PanelController(model: model) { [weak self] in self?.showSettings() }
        if Diagnostics.shared.enabled { addDebugHooks() }
        // Confirms a healthy start to the update helper, or rolls back an interrupted update.
        _ = try? UpdateInstaller.acknowledgeLaunch()
        updates.showSettings = { [weak self] in self?.showSettings() }
        updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    private func showSettings() {
        let window = settingsWindow ?? {
            let root = SettingsView().environment(model).environment(updates)
            let window = SettingsWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Tone Settings"
            window.styleMask = [.titled, .closable]
            SettingsStyle.prepareWindow(window)
            window.isReleasedWhenClosed = false
            // Size to the SwiftUI content first, or center() centers an empty window.
            if let content = window.contentViewController?.view { window.setContentSize(content.fittingSize) }
            window.center()
            settingsWindow = window
            return window
        }()
        SettingsStyle.present(window)
    }

    /// Lets scripts open the UI: post "com.sowyu.tone.debug.<name>" as a distributed
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
                forName: .init("com.sowyu.tone.debug.\(name)"), object: nil, queue: .main) { [weak self] note in
                let argument = note.object as? String
                MainActor.assumeIsolated { if let self { hook(self, argument) } }
            }
        }
    }
}
