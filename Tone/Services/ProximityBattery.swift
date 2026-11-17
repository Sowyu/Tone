import CoreBluetooth
import Observation

/// Battery of nearby AirPods that aren't connected, read from the "proximity
/// pairing" BLE advertisement they send while the case is open or the buds are out.
///
/// The battery nibbles are in the clear and come in 10% steps. The exact percentage
/// the system shows is in an encrypted part keyed to the user's iCloud account.
/// Byte layout follows OpenPods and AirBattery.
@MainActor @Observable
final class ProximityBattery: NSObject {
    struct Advert: Equatable {
        var model: UInt16
        var battery: BatteryLevel
        var rssi: Int
        var seen: Date
    }

    /// Newest advert per model ID, strongest signal wins while both are fresh.
    private(set) var adverts: [UInt16: Advert] = [:]
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var wanted = false

    nonisolated static let maxAge: TimeInterval = 10
    nonisolated static let minRSSI = -70

    /// Called when the panel opens. The first call may show the Bluetooth prompt.
    func start() {
        wanted = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) } else { scan() }
    }

    func stop() {
        wanted = false
        central?.stopScan()
    }

    /// The freshest nearby advert whose model fits a paired device's name.
    func battery(forName name: String, now: Date = .now) -> BatteryLevel? {
        let family = Self.family(name: name)
        return adverts.values
            .filter { now.timeIntervalSince($0.seen) < Self.maxAge && Self.family(model: $0.model) == family }
            .max { $0.rssi < $1.rssi }?.battery
    }

    private func scan() {
        guard wanted, let central, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    fileprivate func received(_ data: Data, rssi: Int) {
        guard rssi >= Self.minRSSI, rssi < 0, let parsed = Self.parse(data) else { return }
        let now = Date.now
        if let old = adverts[parsed.model], now.timeIntervalSince(old.seen) < 2, old.rssi > rssi { return }
        if adverts[parsed.model].map({ $0.battery != parsed.battery || $0.rssi != rssi }) ?? true {
            AudioEngine.log.debug("proximity model=\(parsed.model, format: .hex) rssi=\(rssi) L=\(parsed.battery.left ?? -1) R=\(parsed.battery.right ?? -1) case=\(parsed.battery.main ?? -1)")
        }
        adverts[parsed.model] = Advert(model: parsed.model, battery: parsed.battery, rssi: rssi, seen: now)
    }

    // MARK: Parsing

    /// Manufacturer data as CoreBluetooth hands it over: 4C 00, then type 07, length 19,
    /// prefix 01, model (little endian), status, buds nibbles, charge flags and case nibble.
    nonisolated static func parse(_ d: Data) -> (model: UInt16, battery: BatteryLevel)? {
        let b = [UInt8](d)
        guard b.count >= 11, b[0] == 0x4C, b[1] == 0x00, b[2] == 0x07, b[3] == 0x19, b[4] == 0x01 else { return nil }
        let model = UInt16(b[5]) | UInt16(b[6]) << 8
        // Bit 1 of the status high nibble says which bud is broadcasting, and so
        // which nibble belongs to which bud.
        let flipped = (b[7] >> 4) & 0x02 == 0
        func pct(_ nibble: UInt8) -> Int? { nibble <= 10 ? Int(nibble) * 10 : nil }
        let hi = pct(b[8] >> 4), lo = pct(b[8] & 0x0F)
        let battery = BatteryLevel(left: flipped ? hi : lo, right: flipped ? lo : hi, main: pct(b[9] & 0x0F))
        guard battery.buds != nil || battery.main != nil else { return nil }
        return (model, battery)
    }

    private enum Family { case pro, max, plain, beats }

    private static func family(model: UInt16) -> Family {
        switch model {
        case 0x200E, 0x2014, 0x2024, 0x2027: .pro
        case 0x200A, 0x201F: .max
        case 0x2002, 0x200F, 0x2013, 0x2019, 0x201B: .plain
        default: .beats
        }
    }

    private static func family(name: String) -> Family {
        let n = name.lowercased()
        if n.contains("airpods pro") { return .pro }
        if n.contains("airpods max") { return .max }
        if n.contains("airpods") { return .plain }
        return .beats
    }

    #if DEBUG
    nonisolated static func selfCheck() {
        // AirPods Pro, left bud 80%, right 90%, case 50%, case charging.
        let sample = Data([0x4C, 0x00, 0x07, 0x19, 0x01, 0x0E, 0x20, 0x2B, 0x98, 0x45, 0x00] + [UInt8](repeating: 0, count: 18))
        let parsed = parse(sample)
        assert(parsed?.model == 0x200E, "model ID must read little endian")
        assert(parsed?.battery == BatteryLevel(left: 80, right: 90, main: 50), "battery nibbles misread: \(String(describing: parsed?.battery))")
        assert(parse(Data([0x4C, 0x00, 0x10, 0x05])) == nil, "other Continuity messages must be ignored")
    }
    #endif
}

extension ProximityBattery: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { scan() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count > 4, data[data.startIndex + 2] == 0x07 else { return }
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { received(data, rssi: rssi) }
    }
}
