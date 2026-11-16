import AppKit
import CoreAudio
import IOBluetooth
import Observation

/// Paired Bluetooth audio devices that aren't connected, so they can be listed
/// under Output and connected with a click, like the system Sound menu.
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

    /// Reads the paired list. Called when the Output section is visible, so the
    /// Bluetooth permission prompt only appears once someone looks at it.
    func refresh() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let list = paired
            .filter { $0.deviceClassMajor == UInt32(kBluetoothDeviceClassMajorAudio) && !$0.isConnected() }
            .compactMap { device -> Paired? in
                guard let address = device.addressString, let name = device.name else { return nil }
                return Paired(id: BluetoothBattery.normalize(address), address: address, name: name,
                              symbol: AudioDevice.symbol(name: name, transport: kAudioDeviceTransportTypeBluetooth))
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        if list != disconnected { disconnected = list }
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
        if let match = devices.outputDevices.first(where: { BluetoothBattery.normalize($0.uid) == device.id || $0.name == device.name }) {
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
