import Accelerate
import CoreAudio
import Foundation
import Synchronization

/// Real-time DSP for one tapped app: preamp, 10-band peaking EQ (vDSP biquads),
/// smoothed gain and a peak limiter so overdrive past 100% doesn't clip.
///
/// Threading: `update` runs on the main thread and publishes parameters through a
/// seqlock. `process` runs on the HAL IO thread. It never allocates, locks or
/// blocks: if it catches the writer mid-update it keeps the previous parameters
/// and picks the new ones up on the next callback.
final class DSPKernel: @unchecked Sendable {
    static let bandCount = 10
    static let maxFrames = 4096
    private static let coefficientOffset = 3
    private static let paramCount = coefficientOffset + bandCount * 5
    private static let ceiling: Float = 0.98

    let sampleRate: Double

    // Shared with the main thread (seqlock-protected).
    private let sequence = Atomic<UInt32>(0)
    private let shared: UnsafeMutablePointer<Double>

    // Owned by the IO thread.
    private let scratch: UnsafeMutablePointer<Double>
    private var appliedSequence: UInt32 = .max
    private var targetGain: Float = 1
    private var currentGain: Float = 1
    private var preamp: Float = 1
    private var eqOn = false
    private var eqWasOn = false
    private var envelope: Float = 1
    private let release: Float
    private let setupL: vDSP_biquad_Setup
    private let setupR: vDSP_biquad_Setup
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>

    // Diagnostics, read by the main thread.
    let callbackCount = Atomic<UInt64>(0)
    let sawSignal = Atomic<Bool>(false)
    private let peakInBits = Atomic<UInt32>(0)
    private let peakOutBits = Atomic<UInt32>(0)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        release = Float(exp(-1.0 / (0.15 * self.sampleRate)))
        shared = .allocate(capacity: Self.paramCount)
        scratch = .allocate(capacity: Self.paramCount)
        let identity = Self.identityCoefficients()
        setupL = identity.withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(Self.bandCount))! }
        setupR = identity.withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, vDSP_Length(Self.bandCount))! }
        let delayCount = 2 * Self.bandCount + 2
        delayL = .allocate(capacity: delayCount); delayL.initialize(repeating: 0, count: delayCount)
        delayR = .allocate(capacity: delayCount); delayR.initialize(repeating: 0, count: delayCount)
        left = .allocate(capacity: Self.maxFrames); left.initialize(repeating: 0, count: Self.maxFrames)
        right = .allocate(capacity: Self.maxFrames); right.initialize(repeating: 0, count: Self.maxFrames)
        shared.initialize(repeating: 0, count: Self.paramCount)
        scratch.initialize(repeating: 0, count: Self.paramCount)
    }

    deinit {
        vDSP_biquad_DestroySetup(setupL)
        vDSP_biquad_DestroySetup(setupR)
        [delayL, delayR, left, right].forEach { $0.deallocate() }
        shared.deallocate()
        scratch.deallocate()
    }

    // MARK: Main thread

    /// `gain` is linear amplitude (1 = unchanged). Pass `eq: nil` to bypass the EQ.
    func update(gain: Float, eq: EQSettings?) {
        var values = [Double](repeating: 0, count: Self.paramCount)
        values[0] = Double(gain)
        values[1] = eq == nil ? 0 : 1
        values[2] = eq.map { pow(10, $0.preamp / 20) } ?? 1
        let coefficients = eq.map { Self.coefficients(for: $0, sampleRate: sampleRate) } ?? Self.identityCoefficients()
        for i in coefficients.indices { values[Self.coefficientOffset + i] = coefficients[i] }

        let start = sequence.load(ordering: .relaxed)
        sequence.store(start &+ 1, ordering: .relaxed) // odd: write in progress
        atomicMemoryFence(ordering: .releasing)
        shared.update(from: values, count: Self.paramCount)
        sequence.store(start &+ 2, ordering: .releasing)
    }

    /// Returns and resets the peak levels seen since the last call.
    func takePeaks() -> (input: Float, output: Float) {
        (Float(bitPattern: peakInBits.exchange(0, ordering: .relaxed)),
         Float(bitPattern: peakOutBits.exchange(0, ordering: .relaxed)))
    }

    static func identityCoefficients() -> [Double] {
        (0..<bandCount).flatMap { _ in [1.0, 0, 0, 0, 0] }
    }

    /// RBJ cookbook peaking filters, one section per band: b0, b1, b2, a1, a2 (normalised by a0).
    static func coefficients(for eq: EQSettings, sampleRate: Double) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(bandCount * 5)
        let q = max(eq.q, 0.1)
        for (i, frequency) in EQSettings.frequencies.enumerated() {
            let gainDB = i < eq.bands.count ? eq.bands[i] : 0
            guard abs(gainDB) > 0.01, frequency < sampleRate * 0.45 else {
                out += [1, 0, 0, 0, 0]
                continue
            }
            let a = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let a0 = 1 + alpha / a
            out += [(1 + alpha * a) / a0, (-2 * cosw) / a0, (1 - alpha * a) / a0, (-2 * cosw) / a0, (1 - alpha / a) / a0]
        }
        return out
    }

    // MARK: IO thread

    private func syncParameters() {
        let seq = sequence.load(ordering: .acquiring)
        guard seq != appliedSequence, seq & 1 == 0 else { return }
        scratch.update(from: shared, count: Self.paramCount)
        atomicMemoryFence(ordering: .acquiring)
        guard sequence.load(ordering: .relaxed) == seq else { return } // torn read, retry next callback
        appliedSequence = seq
        targetGain = Float(scratch[0])
        eqOn = scratch[1] != 0
        preamp = Float(scratch[2])
        let coefficients = scratch + Self.coefficientOffset
        vDSP_biquad_SetCoefficientsDouble(setupL, coefficients, 0, vDSP_Length(Self.bandCount))
        vDSP_biquad_SetCoefficientsDouble(setupR, coefficients, 0, vDSP_Length(Self.bandCount))
    }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        callbackCount.add(1, ordering: .relaxed)
        syncParameters()

        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard outList.count > 0 else { return }
        for buffer in outList where buffer.mData != nil { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) }
        let firstChannels = max(1, Int(outList[0].mNumberChannels))
        let frames = Int(outList[0].mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)

        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var offset = 0
        while offset < frames {
            let count = min(Self.maxFrames, frames - offset)
            render(inList, outList, offset: offset, frames: count)
            offset += count
        }
    }

    private func render(_ inList: UnsafeMutableAudioBufferListPointer, _ outList: UnsafeMutableAudioBufferListPointer,
                        offset: Int, frames: Int) {
        // 1. Pull the tap's stereo mix. The aggregate lists the output device's own
        //    input streams first (if any), so the tap is the last stream.
        let available = readInput(inList, offset: offset, frames: frames)
        if available < frames {
            (left + available).update(repeating: 0, count: frames - available)
            (right + available).update(repeating: 0, count: frames - available)
        }
        var peakIn: Float = 0
        vDSP_maxmgv(left, 1, &peakIn, vDSP_Length(frames))
        var peakInR: Float = 0
        vDSP_maxmgv(right, 1, &peakInR, vDSP_Length(frames))
        peakIn = max(peakIn, peakInR)
        if peakIn > 0 && !sawSignal.load(ordering: .relaxed) { sawSignal.store(true, ordering: .relaxed) }

        // 2. Preamp + EQ.
        if eqOn {
            if !eqWasOn {
                delayL.update(repeating: 0, count: 2 * Self.bandCount + 2)
                delayR.update(repeating: 0, count: 2 * Self.bandCount + 2)
            }
            var pre = preamp
            vDSP_vsmul(left, 1, &pre, left, 1, vDSP_Length(frames))
            vDSP_vsmul(right, 1, &pre, right, 1, vDSP_Length(frames))
            vDSP_biquad(setupL, delayL, left, 1, left, 1, vDSP_Length(frames))
            vDSP_biquad(setupR, delayR, right, 1, right, 1, vDSP_Length(frames))
        }
        eqWasOn = eqOn

        // 3. Smoothed gain and a peak limiter (instant attack, 150 ms release).
        let step = (targetGain - currentGain) / Float(frames)
        var gain = currentGain
        var env = envelope
        var peakOut: Float = 0
        for i in 0..<frames {
            gain += step
            var l = left[i] * gain
            var r = right[i] * gain
            let peak = max(abs(l), abs(r))
            let needed = peak > Self.ceiling ? Self.ceiling / peak : 1
            env = needed < env ? needed : needed + (env - needed) * release
            l *= env
            r *= env
            left[i] = l
            right[i] = r
            peakOut = max(peakOut, max(abs(l), abs(r)))
        }
        currentGain = targetGain
        envelope = env.isFinite ? env : 1
        storeMax(peakInBits, peakIn)
        storeMax(peakOutBits, peakOut)

        // 4. Write to the output device's channels: L/R to the first two, silence elsewhere.
        writeOutput(outList, offset: offset, frames: frames)
    }

    private func readInput(_ list: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int) -> Int {
        guard let last = list.last, let data = last.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
        let channels = Int(last.mNumberChannels)
        if channels >= 2 {
            let total = Int(last.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let n = max(0, min(frames, total - offset))
            let base = data + offset * channels
            for i in 0..<n {
                left[i] = base[i * channels]
                right[i] = base[i * channels + 1]
            }
            return n
        }
        let total = Int(last.mDataByteSize) / MemoryLayout<Float>.size
        let n = max(0, min(frames, total - offset))
        // Non-interleaved stereo shows up as two mono buffers; a single mono buffer goes to both sides.
        let rightData = data
        let leftData: UnsafeMutablePointer<Float>
        if list.count >= 2, list[list.count - 2].mNumberChannels == 1, let l = list[list.count - 2].mData {
            leftData = l.assumingMemoryBound(to: Float.self)
        } else {
            leftData = data
        }
        left.update(from: leftData + offset, count: n)
        right.update(from: rightData + offset, count: n)
        return n
    }

    /// Writes L/R to every output stream: the first two channels of each
    /// interleaved stream, or alternating L/R across mono streams. Several streams
    /// show up when the output is a Multi-Output Device.
    private func writeOutput(_ list: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int) {
        var monoIndex = 0
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
            let n = max(0, min(frames, available - offset))
            if channels >= 2 {
                let base = data + offset * channels
                for i in 0..<n {
                    base[i * channels] = left[i]
                    base[i * channels + 1] = right[i]
                }
            } else if channels == 1 {
                let source = list.count == 1 ? nil : (monoIndex % 2 == 0 ? left : right)
                let base = data + offset
                if let source {
                    base.update(from: source, count: n)
                } else {
                    for i in 0..<n { base[i] = 0.5 * (left[i] + right[i]) }
                }
                monoIndex += 1
            }
        }
    }

    private func storeMax(_ atomic: borrowing Atomic<UInt32>, _ value: Float) {
        if value > Float(bitPattern: atomic.load(ordering: .relaxed)) {
            atomic.store(value.bitPattern, ordering: .relaxed)
        }
    }
}
