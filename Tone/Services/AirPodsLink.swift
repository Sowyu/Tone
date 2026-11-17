import IOBluetooth
import Observation
import os

/// AirPods listening modes, numbered as the AirPods report them.
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
}

/// Talks to connected AirPods over their accessory control channel (AACP, L2CAP
/// PSM 0x1001) with the packets LibrePods documents. After the handshake the
/// AirPods send every setting, then each change, whoever makes it. This is how Tone switches the
/// listening mode and Conversation Awareness: on macOS 27 the IOBluetooth setter
/// only stores a byte, and the system's own routes need Apple-only entitlements.
///
/// The channel only opens if this process's CoreBluetooth session has the AirPods
/// as a connected peer. When the system connected them, IOBluetooth skips that
/// step and the channel is closed the moment it opens, so the peer is connected
/// through IOBluetooth's coordinator first. Both calls are private and looked up
/// at runtime.
@MainActor @Observable
final class AirPodsLink: NSObject {
    let address: String
    /// What the AirPods last reported, or what Tone last set. nil until known.
    private(set) var listeningMode: ListeningMode?
    private(set) var conversationAwareness: Bool?
    @ObservationIgnored private var channel: IOBluetoothL2CAPChannel?
    @ObservationIgnored private var opening = false
    @ObservationIgnored private var pending: [[UInt8]] = []

    private static let log = Logger(subsystem: "com.sowyu.tone", category: "aacp")

    /// "F8:1E:49:9D:7D:55".
    init(address: String) {
        self.address = address
        super.init()
    }

    func open() {
        guard channel == nil, !opening, let device = IOBluetoothDevice(addressString: address) else { return }
        opening = true
        Self.connectPeerInThisProcess(address)
        // The peer connection completes asynchronously; the channel open waits for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                var opened: IOBluetoothL2CAPChannel?
                let status = device.openL2CAPChannelAsync(&opened, withPSM: 0x1001, delegate: self)
                Self.log.debug("open AACP \(UInt32(bitPattern: status), format: .hex)")
                if status == kIOReturnSuccess { self.channel = opened } else { self.opening = false }
            }
        }
    }

    func close() {
        channel?.close()
        reset()
    }

    func setListeningMode(_ mode: ListeningMode) {
        listeningMode = mode
        send(Self.control(0x0D, mode.rawValue))
    }

    func setConversationAwareness(_ on: Bool) {
        conversationAwareness = on
        send(Self.control(0x28, on ? 1 : 2))
    }

    private func send(_ packet: [UInt8]) {
        guard let channel, !opening else {
            pending.append(packet)
            open()
            return
        }
        write(packet, on: channel)
    }

    /// A channel can end without a close callback, for example when another app's
    /// channel to the same AirPods closes. A failed write reopens and resends.
    private func write(_ packet: [UInt8], on channel: IOBluetoothL2CAPChannel) {
        var bytes = packet
        let status = channel.writeSync(&bytes, length: UInt16(bytes.count))
        guard status != kIOReturnSuccess else { return }
        Self.log.error("AACP write failed \(UInt32(bitPattern: status), format: .hex), reopening")
        let mode = listeningMode, aware = conversationAwareness
        reset()
        listeningMode = mode
        conversationAwareness = aware
        if ![Self.handshake, Self.features, Self.notifications].contains(packet) { pending.append(packet) }
        open()
    }

    private func reset() {
        channel = nil
        opening = false
        listeningMode = nil
        conversationAwareness = nil
    }

    // MARK: Packets

    private static let handshake: [UInt8] = [0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    private static let features: [UInt8] = [0x04, 0x00, 0x04, 0x00, 0x4D, 0x00, 0xD7, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    private static let notifications: [UInt8] = [0x04, 0x00, 0x04, 0x00, 0x0F, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]

    nonisolated static func control(_ id: UInt8, _ value: UInt8) -> [UInt8] {
        [0x04, 0x00, 0x04, 0x00, 0x09, 0x00, id, value, 0x00, 0x00, 0x00]
    }

    /// A control setting the AirPods report: (id, value), else nil.
    nonisolated static func parseControl(_ b: [UInt8]) -> (id: UInt8, value: UInt8)? {
        guard b.count >= 8, b[0] == 0x04, b[1] == 0x00, b[2] == 0x04, b[3] == 0x00, b[4] == 0x09, b[5] == 0x00 else { return nil }
        return (b[6], b[7])
    }

    fileprivate func received(_ bytes: [UInt8]) {
        guard let (id, value) = Self.parseControl(bytes) else { return }
        Self.log.debug("AACP control \(id, format: .hex) = \(value)")
        switch id {
        case 0x0D: listeningMode = ListeningMode(rawValue: value)
        case 0x28: conversationAwareness = value == 1
        default: break
        }
    }

    fileprivate func opened(_ channel: IOBluetoothL2CAPChannel, status: IOReturn) {
        opening = false
        guard status == kIOReturnSuccess else {
            Self.log.error("AACP open failed \(UInt32(bitPattern: status), format: .hex)")
            reset()
            return
        }
        self.channel = channel
        write(Self.handshake, on: channel)
        write(Self.features, on: channel)
        write(Self.notifications, on: channel)
        pending.forEach { write($0, on: channel) }
        pending = []
    }

    /// Makes the AirPods a connected peer of this process's CoreBluetooth session.
    private static func connectPeerInThisProcess(_ address: String) {
        guard let type = NSClassFromString("IOBluetoothCoreBluetoothCoordinator") as? NSObject.Type,
              type.responds(to: NSSelectorFromString("sharedInstance")),
              let coordinator = type.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject,
              coordinator.responds(to: NSSelectorFromString("peerForAddressString:")),
              let peer = coordinator.perform(NSSelectorFromString("peerForAddressString:"), with: address.uppercased())?.takeUnretainedValue(),
              let manager = coordinator.value(forKey: "classicManager") as? NSObject,
              manager.responds(to: NSSelectorFromString("connectPeer:options:"))
        else {
            log.error("IOBluetooth coordinator unavailable")
            return
        }
        _ = manager.perform(NSSelectorFromString("connectPeer:options:"), with: peer, with: NSDictionary())
    }

    #if DEBUG
    nonisolated static func selfCheck() {
        assert(parseControl([0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0D, 0x03, 0x00, 0x00, 0x00])! == (0x0D, 0x03),
               "listening mode notification must parse")
        assert(parseControl([0x04, 0x00, 0x04, 0x00, 0x4B, 0x00, 0x02, 0x00, 0x01, 0x09]) == nil, "other opcodes must be ignored")
        assert(control(0x0D, 2) == [0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x0D, 0x02, 0x00, 0x00, 0x00], "set packet layout")
    }
    #endif
}

extension AirPodsLink: IOBluetoothL2CAPChannelDelegate {
    nonisolated func l2capChannelOpenComplete(_ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn) {
        nonisolated(unsafe) let channel = l2capChannel
        MainActor.assumeIsolated { if let channel { opened(channel, status: error) } }
    }

    nonisolated func l2capChannelData(_ l2capChannel: IOBluetoothL2CAPChannel!, data dataPointer: UnsafeMutableRawPointer!,
                                      length dataLength: Int) {
        let bytes = [UInt8](UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { received(bytes) }
    }

    nonisolated func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        MainActor.assumeIsolated { reset() }
    }
}
