import AppKit
import Observation

/// Checks GitHub at most once a day and installs a release only when asked.
/// Ported from VectorScroll's settings window code.
@MainActor
@Observable
final class UpdateController {
    private(set) var status = ""
    private(set) var busy = false
    private(set) var available: AppUpdate?
    @ObservationIgnored var showSettings: () -> Void = {}
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private let defaults = UserDefaults.standard

    func start() {
        if let error = defaults.string(forKey: "updateInstallError"), !error.isEmpty {
            defaults.set("", forKey: "updateInstallError")
            showSettings()
            showError(error)
        }
        let checkAutomatically: @MainActor () -> Void = { [weak self] in
            guard let self, self.installTask == nil, self.updateTask == nil,
                  AppUpdate.beginAutomaticCheck(defaults: self.defaults) else { return }
            self.check(manual: false)
        }
        checkAutomatically()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + AppUpdate.automaticCheckDelay(defaults: defaults),
                       repeating: .seconds(86400), leeway: .seconds(60))
        // The timer fires on the main queue. Handing Dispatch the @MainActor closure itself crashes release builds.
        timer.setEventHandler { MainActor.assumeIsolated { checkAutomatically() } }
        self.timer = timer
        timer.resume()
    }

    func check(manual: Bool) {
        guard installTask == nil, updateTask == nil else { return }
        setStatus("Checking for updates…", busy: true)
        updateTask = Task { [weak self] in
            do {
                let update = try await AppUpdate.check()
                guard let self, !Task.isCancelled else { return }
                self.available = update
                self.setStatus(update.map { "Tone \($0.version) is available." }
                    ?? "Tone \(AppUpdate.installedVersion) is up to date.", busy: false)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setStatus(manual ? "Couldn't check for updates. \(error.localizedDescription)" : "", busy: false)
            }
            if let self, manual {
                NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: self.status,
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            self?.updateTask = nil
        }
    }

    func install() {
        guard let update = available, installTask == nil, updateTask == nil else { return }
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard let helper = Bundle.main.executableURL else { return }
        do { _ = try UpdateInstaller.validateDestination(destination) }
        catch { showError(error.localizedDescription); return }
        showSettings()
        defaults.set("", forKey: "updateInstallError")
        setStatus("Downloading Tone \(update.version)…", busy: true)
        installTask = Task { [weak self] in
            do {
                let image = try await UpdateInstaller.download(update)
                guard let self, !Task.isCancelled else { return }
                self.setStatus("Verifying the update…", busy: true)
                let pid = ProcessInfo.processInfo.processIdentifier
                let plan = try await Task.detached {
                    try UpdateInstaller.prepare(update, image: image, destination: destination,
                                                helperSource: helper, parentPID: pid)
                }.value
                guard !Task.isCancelled else { return }
                self.setStatus("Restarting Tone…", busy: true)
                try await Task.detached { try UpdateInstaller.launchHelper(plan) }.value
                self.installTask = nil
                NSApp.terminate(nil)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.installTask = nil
                self.setStatus("Update failed.", busy: false)
                self.showError(error.localizedDescription)
            }
        }
    }

    private func setStatus(_ text: String, busy: Bool) {
        status = text
        self.busy = busy
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update could not be completed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
