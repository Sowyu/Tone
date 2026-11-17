import AppKit
import CoreAudio
import IOBluetooth
import IOKit.ps
import Observation
import os

struct BatteryLevel: Equatable, Sendable {
    var left: Int?
    var right: Int?
    var main: Int?
    /// The AirPods case, while the system has a reading for it.
    var caseLevel: Int?

    /// Earbuds report per bud; the menu shows the lower one.
    var buds: Int? {
        switch (left, right) {
        case let (l?, r?): min(l, r)
        case let (l?, nil): l
        case let (nil, r?): r
        default: nil
        }
    }

    var shown: Int? { buds ?? main }
}

/// What a connected Bluetooth audio device offers beyond Core Audio.
struct BluetoothDetails: Equatable {
    var battery: BatteryLevel?
    /// Glyph by model, such as AirPods Pro by generation.
    var symbol: String?
    /// AirPods with noise control get the system menu's AirPods section.
    var isAirPods = false
    /// Every AirPods model with noise control except the first AirPods Pro has Adaptive.
    var hasAdaptive = false

    /// Prefers the stack copy that actually reports AirPods state.
    var score: Int { (isAirPods ? 10 : 0) + (battery == nil ? 0 : 1) }
}

/// Bluetooth audio devices: paired-but-disconnected ones to connect from the
/// Output list, battery for connected and nearby ones, and a control channel to
/// connected AirPods for listening mode and Conversation Awareness (AirPodsLink).
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
    /// Exact battery the system tracks per accessory name, connected or just nearby.
    private(set) var accessories: [String: BatteryLevel] = [:]
    /// Control channel per connected AirPods, by normalized address.
    private(set) var links: [String: AirPodsLink] = [:]
    @ObservationIgnored private var powerSource: CFRunLoopSource?

    /// "AA-BB-CC-DD-EE-FF:output" and "aa:bb:cc:dd:ee:ff" both become "AABBCCDDEEFF".
    nonisolated static func normalize(_ s: String) -> String {
        String(s.uppercased().filter(\.isHexDigit).prefix(12))
    }

    func details(for device: AudioDevice) -> BluetoothDetails? {
        guard device.isBluetooth else { return nil }
        return details[Self.normalize(device.uid)]
    }

    func link(for device: AudioDevice) -> AirPodsLink? {
        links[Self.normalize(device.uid)]
    }

    /// The system's exact level when it tracks the accessory, else what IOBluetooth reports.
    func battery(forName name: String, details: BluetoothDetails? = nil) -> BatteryLevel? {
        accessories[name] ?? details?.battery
    }

    /// Reads paired devices. Called when the menu opens, so the Bluetooth
    /// permission prompt only appears once someone looks at the Output list.
    ///
    /// macOS 27 lists dual-mode devices (AirPods, most headphones) twice, once per
    /// Bluetooth stack, and the copy that isn't carrying audio reports
    /// disconnected. Copies are merged by address, and a device counts as
    /// connected if any copy is connected or Core Audio has an output for it.
    func refresh(coreAudioIDs: Set<String> = []) {
        watchAccessories()
        let audio = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
            .filter { $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) }
        let byAddress = Dictionary(grouping: audio.filter { $0.addressString != nil }) { Self.normalize($0.addressString!) }
        var offline: [Paired] = []
        var online: [String: BluetoothDetails] = [:]
        for (id, copies) in byAddress {
            guard let first = copies.first, let address = first.addressString,
                  let name = copies.compactMap(\.name).first else { continue }
            if copies.contains(where: { $0.isConnected() }) || coreAudioIDs.contains(id) {
                // Read from whichever copy answers; the audio copy has the AirPods state.
                online[id] = copies.map(Self.readDetails).max { $0.score < $1.score }
            } else {
                offline.append(Paired(id: id, address: address, name: name, symbol: Self.symbol(first, name: name)))
            }
        }
        offline.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        if offline != disconnected { disconnected = offline }
        if online != details { details = online }

        for (id, link) in links where online[id]?.isAirPods != true {
            link.close()
            links[id] = nil
        }
        for (id, detail) in online where detail.isAirPods {
            if links[id] == nil, let address = byAddress[id]?.first?.addressString {
                links[id] = AirPodsLink(address: address.replacingOccurrences(of: "-", with: ":"))
            }
            links[id]?.open()
        }
    }

    private static func readDetails(_ device: IOBluetoothDevice) -> BluetoothDetails {
        func pct(_ selector: String) -> Int? {
            PrivateBT.uint8(device, selector).flatMap { $0 > 0 && $0 <= 100 ? Int($0) : nil }
        }
        let headset = PrivateBT.int(device, "headsetBattery").flatMap { $0 > 0 && $0 <= 100 ? $0 : nil }
        let battery = BatteryLevel(left: pct("batteryPercentLeft"), right: pct("batteryPercentRight"),
                                   main: pct("batteryPercentSingle") ?? pct("batteryPercentCombined") ?? headset,
                                   caseLevel: pct("batteryPercentCase"))
        let airPods = PrivateBT.bool(device, "isANCSupported") == true || PrivateBT.bool(device, "isTransparencySupported") == true
        let model = PrivateBT.uint16(device, "productID") ?? 0
        return BluetoothDetails(battery: battery.shown == nil ? nil : battery,
                                symbol: symbol(device, name: device.name ?? ""), isAirPods: airPods,
                                hasAdaptive: airPods && ![0x200E, 0x200A, 0x201F].contains(model))
    }

    /// AirPods Pro glyphs differ by generation, as in the system menu.
    private static func symbol(_ device: IOBluetoothDevice, name: String) -> String {
        let byModel: [UInt16: String] = [0x200E: "airpods.pro.gen1", 0x2027: "airpods.pro.gen3"]
        if let model = PrivateBT.uint16(device, "productID"), let symbol = byModel[model],
           NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
            return symbol
        }
        return AudioDevice.symbol(name: name, transport: kAudioDeviceTransportTypeBluetooth)
    }

    // MARK: Accessory battery

    /// The accessory power sources `pmset -g accps` lists. For AirPods in range the
    /// system fills them with the exact per-bud level it decrypts from their advert,
    /// so they're right even before connecting. `IOPSCopyPowerSourcesByType` is
    /// private and looked up at runtime; without it the IOBluetooth values remain.
    private func watchAccessories() {
        if powerSource == nil {
            powerSource = IOPSNotificationCreateRunLoopSource({ _ in
                MainActor.assumeIsolated { PowerSourceWatch.bluetooth?.readAccessories() }
            }, nil)?.takeRetainedValue()
            if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
            PowerSourceWatch.bluetooth = self
        }
        readAccessories()
    }

    fileprivate func readAccessories() {
        let read = Self.accessoryBatteries()
        if read != accessories { accessories = read }
    }

    nonisolated static func accessoryBatteries() -> [String: BatteryLevel] {
        typealias ByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType"),
              let info = unsafeBitCast(symbol, to: ByType.self)(0)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [:] }
        var result: [String: BatteryLevel] = [:]
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == "Accessory Source", d[kIOPSIsPresentKey] as? Bool != false,
                  var name = d[kIOPSNameKey] as? String,
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let pct = now * 100 / max
            // The case is listed as "<AirPods name> Case".
            if d["Part Identifier"] as? String == "Case", name.hasSuffix(" Case") { name.removeLast(5) }
            var level = result[name] ?? BatteryLevel()
            switch d["Part Identifier"] as? String {
            case "Left": level.left = pct
            case "Right": level.right = pct
            case "Case": level.caseLevel = pct
            default: level.main = pct
            }
            if level.shown != nil || level.caseLevel != nil { result[name] = level }
        }
        return result
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
            refresh(coreAudioIDs: [device.id])
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

/// The power source callback is a C function, so it reaches the instance through here.
@MainActor private enum PowerSourceWatch {
    static weak var bluetooth: BluetoothAudio?
}

/// Calls undocumented IOBluetoothDevice getters only if they exist.
private enum PrivateBT {
    static func uint8(_ object: NSObject, _ name: String) -> UInt8? {
        call(object, name) { (imp: IMP, sel) in
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> UInt8).self)(object, sel)
        }
    }

    static func uint16(_ object: NSObject, _ name: String) -> UInt16? {
        call(object, name) { (imp: IMP, sel) in
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> UInt16).self)(object, sel)
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

    private static func call<T>(_ object: NSObject, _ name: String, _ body: (IMP, Selector) -> T) -> T? {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel), let imp = object.method(for: sel) else { return nil }
        return body(imp, sel)
    }
}
