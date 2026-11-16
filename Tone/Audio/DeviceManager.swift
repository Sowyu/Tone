import AppKit
import AudioToolbox
import IOKit.ps
import CoreAudio
import Foundation
import Observation

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    /// Resolved once, not on every render.
    let symbol: String

    init(id: AudioObjectID, uid: String, name: String, transport: UInt32) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        symbol = Self.symbol(name: name, transport: transport)
    }

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The same glyphs the system Sound menu uses: what the device is, not its role.
    static func symbol(name: String, transport: UInt32) -> String {
        let n = name.lowercased()
        let candidates: [String]
        if n.contains("airpods pro") { candidates = ["airpods.pro", "airpodspro", "headphones"] }
        else if n.contains("airpods max") { candidates = ["airpods.max", "airpodsmax", "headphones"] }
        else if n.contains("airpods") { candidates = ["airpods", "headphones"] }
        else if n.contains("beats") { candidates = ["beats.headphones", "headphones"] }
        else if n.contains("homepod") { candidates = ["homepod.fill", "hifispeaker.fill"] }
        else {
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn:
                candidates = [MacModel.isLaptop ? "laptopcomputer" : "desktopcomputer"]
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                candidates = ["headphones"]
            case kAudioDeviceTransportTypeAirPlay:
                candidates = ["airplayaudio"]
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
                candidates = ["display"]
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
                candidates = ["waveform"]
            default:
                candidates = n.contains("mic") ? ["mic.fill"] : (n.contains("head") ? ["headphones"] : ["hifispeaker.fill"])
            }
        }
        return candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? "speaker.wave.2.fill"
    }
}

enum MacModel {
    /// A Mac with an internal battery is a laptop.
    static let isLaptop: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return d?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
}

/// Lists output/input devices, tracks the system defaults and the master volume.
@MainActor @Observable
final class DeviceManager {
    private(set) var outputDevices: [AudioDevice] = []
    private(set) var inputDevices: [AudioDevice] = []
    private(set) var defaultOutputID: AudioObjectID = 0
    private(set) var defaultInputID: AudioObjectID = 0
    /// 0...1 scalar of the default output device.
    private(set) var masterVolume: Float = 0.5
    private(set) var isMuted = false
    private(set) var canSetVolume = true

    /// Called after the default output device changes.
    @ObservationIgnored var onDefaultOutputChanged: ((AudioObjectID) -> Void)?

    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var volumeListeners: [PropertyListener] = []

    var defaultOutput: AudioDevice? { outputDevices.first { $0.id == defaultOutputID } }

    init() {
        refreshDevices()
        refreshDefaults(notify: false)
        let sys = CA.system
        systemListeners = [
            PropertyListener(sys, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in self?.refreshDevices() },
            PropertyListener(sys, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.refreshDefaults(notify: true) },
            PropertyListener(sys, CA.address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in self?.refreshDefaults(notify: false) },
        ]
    }

    // MARK: Devices

    func refreshDevices() {
        let ids = CA.getArray(CA.system, CA.address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
        var outputs: [AudioDevice] = []
        var inputs: [AudioDevice] = []
        for id in ids {
            guard let uid = CA.getString(id, CA.address(kAudioDevicePropertyDeviceUID)),
                  !uid.hasPrefix(AudioEngine.aggregateUIDPrefix) else { continue }
            let name = CA.getString(id, CA.address(kAudioObjectPropertyName)) ?? "Unknown Device"
            let transport = CA.get(id, CA.address(kAudioDevicePropertyTransportType), as: UInt32.self) ?? 0
            let device = AudioDevice(id: id, uid: uid, name: name, transport: transport)
            let hidden = CA.get(id, CA.address(kAudioDevicePropertyIsHidden), as: UInt32.self) ?? 0
            if hidden != 0 { continue }
            if CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 { outputs.append(device) }
            if CA.channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0 { inputs.append(device) }
        }
        outputDevices = outputs
        inputDevices = inputs
    }

    private func refreshDefaults(notify: Bool) {
        let out = CA.get(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), as: AudioObjectID.self) ?? 0
        defaultInputID = CA.get(CA.system, CA.address(kAudioHardwarePropertyDefaultInputDevice), as: AudioObjectID.self) ?? 0
        let changed = out != defaultOutputID
        defaultOutputID = out
        if changed {
            observeVolume(of: out)
            if notify { onDefaultOutputChanged?(out) }
        }
    }

    func setDefaultOutput(_ device: AudioDevice) {
        CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), device.id)
        // Keep alerts and sound effects on the same device, like System Settings does.
        CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultSystemOutputDevice), device.id)
    }

    func setDefaultInput(_ device: AudioDevice) {
        CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultInputDevice), device.id)
    }

    // MARK: Master volume

    private static let virtualMain = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    private static let mute = CA.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)

    private func scalarAddresses(for device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        if CA.has(device, Self.virtualMain) { return [Self.virtualMain] }
        let main = CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput)
        if CA.has(device, main) { return [main] }
        return [1, 2].map { CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: $0) }
            .filter { CA.has(device, $0) }
    }

    private func observeVolume(of device: AudioObjectID) {
        volumeListeners.forEach { $0.cancel() }
        volumeListeners = (scalarAddresses(for: device) + [Self.mute]).filter { CA.has(device, $0) }.map {
            PropertyListener(device, $0) { [weak self] in self?.readVolume() }
        }
        readVolume()
    }

    private func readVolume() {
        let device = defaultOutputID
        let addresses = scalarAddresses(for: device)
        canSetVolume = addresses.contains { CA.isSettable(device, $0) }
        let values = addresses.compactMap { CA.get(device, $0, as: Float32.self) }
        masterVolume = values.isEmpty ? 1 : values.reduce(0, +) / Float(values.count)
        isMuted = (CA.get(device, Self.mute, as: UInt32.self) ?? 0) != 0
    }

    func setMasterVolume(_ value: Float) {
        let value = min(max(value, 0), 1)
        masterVolume = value
        let device = defaultOutputID
        for address in scalarAddresses(for: device) { CA.set(device, address, Float32(value)) }
        if isMuted, value > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        CA.set(defaultOutputID, Self.mute, UInt32(muted ? 1 : 0))
    }
}
