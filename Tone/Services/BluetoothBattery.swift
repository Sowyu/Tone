import Foundation
import Observation

/// Battery levels of connected Bluetooth audio devices, as the system Sound menu shows them.
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

/// Reads `system_profiler SPBluetoothDataType -json` off the main thread when the
/// panel opens (at most every 30 s). There is no public API for these levels;
/// if the output changes shape the rows simply show no battery.
@MainActor @Observable
final class BluetoothBattery {
    private(set) var levels: [String: BatteryLevel] = [:]
    @ObservationIgnored private var lastFetch = Date.distantPast
    @ObservationIgnored private var fetching = false

    func refreshIfStale() {
        guard !fetching, Date().timeIntervalSince(lastFetch) > 30 else { return }
        fetching = true
        Task.detached(priority: .utility) {
            let result = Self.fetch()
            await MainActor.run {
                self.fetching = false
                self.lastFetch = Date()
                if result != self.levels { self.levels = result }
            }
        }
    }

    func level(for device: AudioDevice) -> BatteryLevel? {
        guard device.isBluetooth else { return nil }
        return levels[Self.normalize(device.uid)] ?? levels[device.name]
    }

    /// "AA-BB-CC-DD-EE-FF:output" and "aa:bb:cc:dd:ee:ff" both become "AABBCCDDEEFF".
    nonisolated static func normalize(_ s: String) -> String {
        String(s.uppercased().filter(\.isHexDigit).prefix(12))
    }

    nonisolated private static func fetch() -> [String: BatteryLevel] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: BatteryLevel] = [:]
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    func percent(_ key: String) -> Int? {
                        (info[key] as? String).flatMap { Int($0.filter(\.isNumber)) }
                    }
                    let level = BatteryLevel(left: percent("device_batteryLevelLeft"),
                                             right: percent("device_batteryLevelRight"),
                                             main: percent("device_batteryLevelMain"))
                    guard level.buds != nil || level.main != nil else { continue }
                    result[name] = level
                    if let address = info["device_address"] as? String { result[normalize(address)] = level }
                }
            }
        }
        return result
    }
}
