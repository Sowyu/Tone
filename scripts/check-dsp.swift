// Offline self-check for balance and crossfeed in the DSP kernel. Run: make check
import CoreAudio
import Foundation

@main
struct CheckDSP {
    /// Feeds a constant 0.5 into the left channel only and returns the settled output levels.
    static func render(_ mix: StereoMix) -> (l: Float, r: Float) {
        let kernel = DSPKernel(sampleRate: 48_000)
        kernel.update(gain: 1, eq: nil, mix: mix)
        let frames = 512
        var input = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { input[i * 2] = 0.5 }
        var output = [Float](repeating: 0, count: frames * 2)
        for _ in 0..<4 { // later buffers are past the parameter ramp and the 700 Hz low-pass settling
            input.withUnsafeMutableBytes { inBytes in
                output.withUnsafeMutableBytes { outBytes in
                    var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
                    var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                    kernel.process(input: &inList, output: &outList)
                }
            }
        }
        return (output[(frames - 1) * 2], output[(frames - 1) * 2 + 1])
    }

    static func expect(_ name: String, _ got: Float, _ want: Float) {
        guard abs(got - want) < 0.002 else { fatalError("\(name): expected \(want), got \(got)") }
    }

    static func main() {
        let neutral = render(StereoMix())
        expect("neutral left", neutral.l, 0.5)
        expect("neutral right", neutral.r, 0)

        expect("full right balance silences left", render(StereoMix(balance: 1)).l, 0)
        expect("half right balance halves left", render(StereoMix(balance: 0.5)).l, 0.25)
        expect("left balance keeps left", render(StereoMix(balance: -0.7)).l, 0.5)

        // Full crossfeed mixes the other side in at maxCrossfeed and normalises by 1 + feed.
        let feed = DSPKernel.maxCrossfeed
        let crossed = render(StereoMix(crossfeed: 1))
        expect("crossfeed left", crossed.l, 0.5 / (1 + feed))
        expect("crossfeed leaks into right", crossed.r, 0.5 * feed / (1 + feed))
        print("PASS: balance and crossfeed levels")
    }
}
