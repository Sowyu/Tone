import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (\(status))" }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw CoreAudioError(step: step, status: status) }
}

/// One app's process tap + private aggregate device + IOProc.
///
/// The tap mutes the app's original output while we run (`.mutedWhenTapped`)
/// and the aggregate plays our processed copy on the output device. If Tone
/// dies, the tap and private aggregate die with it and the app's audio returns.
@MainActor
final class AppTap {
    let key: String
    let outputUID: String
    let kernel: DSPKernel
    private(set) var processes: [AudioObjectID]

    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var overloadListener: PropertyListener?
    private(set) var overloads = 0
    private(set) var lastGain: Float
    private(set) var lastEQ: EQSettings?
    let createdAt = Date()

    init(key: String, processes: [AudioObjectID], outputUID: String, gain: Float, eq: EQSettings?) throws {
        self.key = key
        self.outputUID = outputUID
        self.processes = processes
        self.lastGain = gain
        self.lastEQ = eq

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Tone tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        self.description = description

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        let output = OutputComposition(uid: outputUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tone",
            kAudioAggregateDeviceUIDKey: AudioEngine.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output.main,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: output.stacked,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: output.subDevices.map { [kAudioSubDeviceUIDKey: $0] },
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        aggregateID = device
        let rate = CA.get(device, CA.address(kAudioDevicePropertyNominalSampleRate), as: Float64.self) ?? 48_000
        kernel = DSPKernel(sampleRate: rate)
        kernel.update(gain: gain, eq: eq)

        do {
            try check(status, "AudioHardwareCreateAggregateDevice")
            let kernel = self.kernel
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, Self.ioBlock(kernel)),
                      "AudioDeviceCreateIOProcIDWithBlock")
            procID = proc
            try check(AudioDeviceStart(device, proc), "AudioDeviceStart")
        } catch {
            invalidate()
            throw error
        }

        overloadListener = PropertyListener(device, CA.address(kAudioDeviceProcessorOverload)) { [weak self] in
            self?.overloads += 1
        }
    }

    /// Built outside the main actor: a closure formed in a @MainActor context
    /// inherits that isolation and Swift traps when the HAL thread calls it.
    nonisolated private static func ioBlock(_ kernel: DSPKernel) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in kernel.process(input: input, output: output) }
    }

    func apply(gain: Float, eq: EQSettings?) {
        guard gain != lastGain || eq != lastEQ else { return }
        lastGain = gain
        lastEQ = eq
        kernel.update(gain: gain, eq: eq)
    }

    /// Swaps the tapped process list in place (e.g. Chrome spawned a new renderer).
    func updateProcesses(_ newProcesses: [AudioObjectID]) throws {
        guard newProcesses != processes else { return }
        description.processes = newProcesses
        var address = CA.address(kAudioTapPropertyDescription)
        var ref = Unmanaged.passUnretained(description)
        try check(AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                             UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &ref),
                  "set kAudioTapPropertyDescription")
        processes = newProcesses
    }

    /// Stops IO and destroys the aggregate and the tap. Safe to call twice.
    func invalidate() {
        overloadListener?.cancel()
        overloadListener = nil
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

/// Aggregates can't contain aggregates. When the output is itself an aggregate
/// or Multi-Output Device, Tone's aggregate takes over its sub-devices instead.
struct OutputComposition {
    let main: String
    let subDevices: [String]
    let stacked: Bool

    init(uid: String) {
        guard let id = CA.deviceID(forUID: uid),
              CA.get(id, CA.address(kAudioDevicePropertyTransportType), as: UInt32.self) == kAudioDeviceTransportTypeAggregate,
              let subs = Self.array(id, kAudioAggregateDevicePropertyFullSubDeviceList), !subs.isEmpty else {
            main = uid
            subDevices = [uid]
            stacked = false
            return
        }
        subDevices = subs
        main = CA.getString(id, CA.address(kAudioAggregateDevicePropertyMainSubDevice)).flatMap { subs.contains($0) ? $0 : nil } ?? subs[0]
        let composition = Self.dictionary(id, kAudioAggregateDevicePropertyComposition)
        stacked = (composition?[kAudioAggregateDeviceIsStackedKey] as? NSNumber)?.boolValue ?? false
    }

    private static func array(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [String]? {
        var address = CA.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        var value: Unmanaged<CFArray>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? [String]
    }

    private static func dictionary(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [String: Any]? {
        var address = CA.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var value: Unmanaged<CFDictionary>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? [String: Any]
    }
}
