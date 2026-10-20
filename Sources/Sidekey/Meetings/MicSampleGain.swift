import Foundation

enum MicSampleGain {
    /// Matches the production microphone boost that fed the meeting recording
    /// indicator before the audio-only capture rewrite.
    static let defaultMultiplier: Float = 4.0

    static func applyDefault(to samples: [Float]) -> [Float] {
        apply(to: samples, gain: defaultMultiplier)
    }

    static func apply(to samples: [Float], gain: Float) -> [Float] {
        guard gain != 1 else { return samples }
        return samples.map { sample in
            max(-1.0, min(1.0, sample * gain))
        }
    }
}

/// Keep the existing quiet-microphone boost, but reduce it before a loud
/// buffer can clip. Immediate attack and a 500ms release avoid amplifying
/// already loud speech or jumping straight back to full gain between words.
/// WHY: .project-docs/decisions/2026-10-20-meeting-source-noise-floor.md
struct MicSampleGainProcessor {
    private(set) var currentGain = MicSampleGain.defaultMultiplier

    mutating func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let clean = samples.map { $0.isFinite ? $0 : 0 }
        let peak = clean.reduce(Float(0)) { max($0, abs($1)) }
        let target = peak > 0 ? min(MicSampleGain.defaultMultiplier, 0.95 / peak) : MicSampleGain.defaultMultiplier
        if target < currentGain { currentGain = target }
        else {
            let release = Float(1 - exp(-Double(samples.count) / 16_000 / 0.5))
            currentGain += (target - currentGain) * release
        }
        return clean.map { max(-0.95, min(0.95, $0 * currentGain)) }
    }
}
