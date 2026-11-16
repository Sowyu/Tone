import AppKit
import CoreAudio
import IOBluetooth
import Observation
import os

/// AirPods listening modes, numbered as IOBluetooth reports them.
enum ListeningMode: UInt8, CaseIterable, Identifiable {
    case off = 1, noiseCancellation = 2, transparency = 3, adaptive = 4
    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .noiseCancellation: "Noise Cancellation"
        case .transparency: "Transparency"
        case .adaptive: "Adaptive"
        }
    }

    /// Order used by the system Sound menu.
    static let menuOrder: [ListeningMode] = [.off, .transparency, .adaptive, .noiseCancellation]
}

struct BatteryLevel: Equatable, Sendable {
    var left: Int?
    var right: Int?
    var main: Int?

    /// Earbuds report per bud; the menu shows the lower one.
    var buds: Int? {
        switch (left, right) {
        case let (l?, r?): min(l, r)
        case let (l?, nil): l
        case let (nil, r?): r
        default: nil
        }
    }
}

/// What a connected Bluetooth audio device offers beyond Core Audio.
struct BluetoothDetails: Equatable {
    var battery: BatteryLevel?
    var listeningMode: ListeningMode?
    var modes: [ListeningMode] = []
}

/// Bluetooth audio devices: paired-but-disconnected ones to connect from the
/// Output list, and battery plus listening mode for connected ones.
///
/// Battery and listening mode come from IOBluetoothDevice methods that Apple
/// doesn't document (`batteryPercentLeft`, `listeningMode`, `setListeningMode:`).
/// They're looked up at runtime and every call is skipped if a method is missing.
@MainActor @Observable
final class BluetoothAudio {
    struct Paired: Identifiable, Equatable {
        let id: String       // normalized address
        let address: String  // as IOBluetooth formats it
        let name: String
        let symbol: String
    }

    private(set) var disconnected: [Paired] = []
    private(set) var connecting: Set<String> = []
    private(set) var details: [String: BluetoothDetails] = [:]

    /// "AA-BB-CC-DD-EE-FF:output" and "aa:bb:cc:dd:ee:ff" both become "AABBCCDDEEFF".
    nonisolated static func normalize(_ s: String) -> String {
        String(s.uppercased().filter(\.isHexDigit).prefix(12))
    }

    func details(for device: AudioDevice) -> BluetoothDetails? {
        guard device.isBluetooth else { return nil }
        return details[Self.normalize(device.uid)]
    }

    /// Reads paired devices. Called while the Output section is visible, so the
    /// Bluetooth permission prompt only appears once someone looks at it.
    func refresh() {
        let audio = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .filter { $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) }
        var offline: [Paired] = []
        var online: [String: BluetoothDetails] = [:]
        for device in audio {
            guard let address = device.addressString, let name = device.name else { continue }
            let id = Self.normalize(address)
            if device.isConnected() {
                online[id] = Self.readDetails(device)
            } else {
                offline.append(Paired(id: id, address: address, name: name,
                                      symbol: AudioDevice.symbol(name: name, transport: kAudioDeviceTransportTypeBluetooth)))
            }
        }
        offline.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        if offline != disconnected { disconnected = offline }
        if online != details { details = online }
    }

    func setListeningMode(_ mode: ListeningMode, for device: AudioDevice) {
        let id = Self.normalize(device.uid)
        guard let bt = IOBluetoothDevice(addressString: String(device.uid.prefix(17))) ?? Self.paired(id) else { return }
        PrivateBT.set(bt, "setListeningMode:", mode.rawValue)
        details[id]?.listeningMode = mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { self.refresh() } }
    }

    private static func paired(_ id: String) -> IOBluetoothDevice? {
        ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .first { $0.addressString.map(normalize) == id }
    }

    private static func readDetails(_ device: IOBluetoothDevice) -> BluetoothDetails {
        func pct(_ selector: String) -> Int? {
            PrivateBT.uint8(device, selector).flatMap { $0 > 0 && $0 <= 100 ? Int($0) : nil }
        }
        let headset = PrivateBT.int(device, "headsetBattery").flatMap { $0 > 0 && $0 <= 100 ? $0 : nil }
        let battery = BatteryLevel(left: pct("batteryPercentLeft"), right: pct("batteryPercentRight"),
                                   main: pct("batteryPercentSingle") ?? pct("batteryPercentCombined") ?? headset)

        var modes: [ListeningMode] = []
        let anc = PrivateBT.bool(device, "isANCSupported") ?? false
        let transparency = PrivateBT.bool(device, "isTransparencySupported") ?? false
        let configs = PrivateBT.uint32(device, "listeningModeConfigs") ?? 0
        let current = PrivateBT.uint8(device, "listeningMode").flatMap(ListeningMode.init(rawValue:))
        if anc || transparency {
            // listeningModeConfigs is a bitmask of the modes the user enabled for the stem press:
            // bit (mode - 1). With no mask, offer what the hardware supports.
            modes = ListeningMode.menuOrder.filter { mode in
                if configs != 0 { return configs & (1 << UInt32(mode.rawValue - 1)) != 0 || mode == current }
                switch mode {
                case .off: return false
                case .transparency: return transparency
                case .noiseCancellation: return anc
                case .adaptive: return current == .adaptive
                }
            }
        }
        AudioEngine.log.info("""
            BT \(device.name ?? "?", privacy: .public) mode=\(current?.rawValue ?? 0) configs=\(configs) \
            anc=\(anc) transparency=\(transparency) L=\(battery.left ?? -1) R=\(battery.right ?? -1) main=\(battery.main ?? -1)
            """)
        return BluetoothDetails(battery: battery.buds == nil && battery.main == nil ? nil : battery,
                                listeningMode: modes.isEmpty ? nil : current, modes: modes)
    }

    /// Connects, waits for the Core Audio device to appear, then makes it the output.
    func connect(_ device: Paired, devices: DeviceManager) {
        guard !connecting.contains(device.id) else { return }
        connecting.insert(device.id)
        let address = device.address
        Task.detached(priority: .userInitiated) {
            // openConnection() blocks until the link is up or fails.
            let status = IOBluetoothDevice(addressString: address)?.openConnection() ?? kIOReturnError
            await MainActor.run {
                guard status == kIOReturnSuccess else {
                    self.connecting.remove(device.id)
                    NSSound.beep()
                    return
                }
                self.waitForAudioDevice(device, devices: devices, attempts: 40)
            }
        }
    }

    private func waitForAudioDevice(_ device: Paired, devices: DeviceManager, attempts: Int) {
        devices.refreshDevices()
        if let match = devices.outputDevices.first(where: { Self.normalize($0.uid) == device.id || $0.name == device.name }) {
            devices.setDefaultOutput(match)
            connecting.remove(device.id)
            refresh()
            return
        }
        guard attempts > 0 else {
            connecting.remove(device.id)
            refresh()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated { self.waitForAudioDevice(device, devices: devices, attempts: attempts - 1) }
        }
    }
}

/// Calls undocumented IOBluetoothDevice getters/setters only if they exist.
private enum PrivateBT {
    static func uint8(_ object: NSObject, _ name: String) -> UInt8? {
        call(object, name) { (imp: IMP, sel) in
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> UInt8).self)(object, sel)
        }
    }

    static func uint32(_ object: NSObject, _ name: String) -> UInt32? {
        call(object, name) { (imp: IMP, sel) in
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> UInt32).self)(object, sel)
        }
    }

    static func int(_ object: NSObject, _ name: String) -> Int? {
        call(object, name) { (imp: IMP, sel) in
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> Int).self)(object, sel)
        }
    }

    static func bool(_ object: NSObject, _ name: String) -> Bool? {
        call(object, name) { (imp: IMP, sel) in
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(object, sel)
        }
    }

    static func set(_ object: NSObject, _ name: String, _ value: UInt8) {
        _ = call(object, name) { (imp: IMP, sel) in
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, UInt8) -> Void).self)(object, sel, value)
        }
    }

    private static func call<T>(_ object: NSObject, _ name: String, _ body: (IMP, Selector) -> T) -> T? {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel), let imp = object.method(for: sel) else { return nil }
        return body(imp, sel)
    }
}
