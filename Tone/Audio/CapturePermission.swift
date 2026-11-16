import AppKit
import Observation

/// Audio capture (process tap) permission.
///
/// There is no public preflight API for kTCCServiceAudioCapture, so this looks
/// up the TCC SPI at runtime. If the SPI is missing the status stays `.unknown`
/// and the first tap triggers the system prompt instead.
@MainActor @Observable
final class CapturePermission {
    enum Status { case unknown, authorized, denied }

    private(set) var status: Status = .unknown

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: PreflightFn? = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: PreflightFn.self) }
    private static let requestFn: RequestFn? = handle.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: RequestFn.self) }

    init() { refresh() }

    func refresh() {
        guard let preflight = Self.preflight else { return }
        switch preflight(Self.service, nil) {
        case 0: status = .authorized
        case 1: status = .denied
        default: status = .unknown
        }
    }

    /// Shows the system prompt when the user hasn't decided yet.
    func request(_ completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard let requestFn = Self.requestFn else {
            completion(true) // Let the first tap prompt instead.
            return
        }
        requestFn(Self.service, nil, Self.callback { [weak self] granted in
            self?.status = granted ? .authorized : .denied
            completion(granted)
        })
    }

    /// TCC calls back on its own queue; hop to main from a nonisolated block.
    nonisolated private static func callback(_ body: @escaping @MainActor (Bool) -> Void) -> @convention(block) (Bool) -> Void {
        let box = SendableBox(body)
        return { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { box.value(granted) } }
        }
    }

    func markDenied() { status = .denied }

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
