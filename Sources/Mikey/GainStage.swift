import Accelerate
import AVFoundation
import Foundation

/// Boosts microphone PCM and soft-limits it so boosted loud audio saturates
/// smoothly at ±1 instead of hard-clipping (SPEC §3 — a professor across a
/// lecture hall stays intelligible to Whisper).
///
/// `y = tanh(x · g)` where `g = 10^(gainDB/20)`: quiet input (|x·g| ≪ 1) gets
/// essentially the full boost, loud input compresses toward full scale without
/// ever reaching it, so the limiter adds no audible edge.
///
/// The `gainDB` value is a constructor parameter so the sibling config ticket
/// can feed `config.json`'s `gainDB` straight in — until then the single
/// source is `defaultGainDB` (used as `MicRecordingEngine.init`'s default).
public struct GainStage: Sendable {
    /// Default capture boost in dB. Swap for the configured `gainDB` once
    /// `config.json` lands (SPEC §5).
    public static let defaultGainDB: Double = 12

    /// `gainDB` as a linear amplitude multiplier.
    public let linearGain: Float

    public init(gainDB: Double = GainStage.defaultGainDB) {
        linearGain = Float(pow(10, gainDB / 20))
    }

    /// Boost + soft-limit one sample.
    public func process(_ sample: Float) -> Float {
        tanhf(sample * linearGain)
    }

    /// Boost + soft-limit every channel of a float PCM buffer in place.
    /// Non-float buffers are passed through untouched (the input tap is
    /// float32; anything else degrades to unboosted rather than crashing).
    public func process(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return }
        var gain = linearGain
        var count = Int32(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let data = channelData[channel]
            vDSP_vsmul(data, 1, &gain, data, 1, frames)
            vvtanhf(data, data, &count) // in-place soft limit per channel
        }
    }
}
