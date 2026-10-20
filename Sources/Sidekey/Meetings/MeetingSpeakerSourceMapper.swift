import Foundation

struct MeetingSourceActivity: Codable, Equatable, Sendable {
    let startMS: Double
    let endMS: Double
    let micRMS: Double
    let systemRMS: Double
    var micThreshold: Double = 0.003
    var systemThreshold: Double = 0.003
    var calibrated = true

    var exclusiveSource: String? {
        guard calibrated, micRMS.isFinite, systemRMS.isFinite else { return nil }
        let mic = micRMS >= micThreshold, system = systemRMS >= systemThreshold
        if mic && !system { return "local" }
        if system && !mic { return "remote" }
        return nil
    }

    var simultaneousActivity: Bool {
        calibrated && micRMS >= micThreshold && systemRMS >= systemThreshold
    }
}

/// Estimate each source's own background instead of comparing unrelated gains.
/// Runs once per captured 100ms frame, before any ASR tokens arrive.
/// WHY: .project-docs/decisions/2026-10-20-meeting-source-noise-floor.md
struct MeetingSourceActivityDetector {
    private var mic = NoiseFloor()
    private var system = NoiseFloor()

    mutating func observe(_ frame: MeetingSourceActivity) -> MeetingSourceActivity {
        var result = frame
        result.micThreshold = mic.observe(frame.micRMS)
        result.systemThreshold = system.observe(frame.systemRMS)
        result.calibrated = mic.ready && system.ready
        return result
    }

    private struct NoiseFloor {
        private var levels: [Double] = []
        private var next = 0
        private var threshold = 0.003
        var ready: Bool { levels.count >= 20 }

        mutating func observe(_ rms: Double) -> Double {
            let value = rms.isFinite ? max(0, min(1, rms)) : 0
            // Do not teach a long uninterrupted utterance to become silence.
            if ready && value >= threshold { return threshold }
            if levels.count < 100 { levels.append(value) }
            else { levels[next] = value; next = (next + 1) % 100 }
            let sorted = levels.sorted()
            // Up to 100 background frames, lower quintile, ~9.5dB above it. This
            // deliberately remains a signal heuristic, not speech recognition.
            threshold = max(0.003, sorted[(sorted.count - 1) / 5] * 3)
            return threshold
        }
    }
}

struct MeetingSpeakerSourceMapper {
    private struct Evidence {
        var local = 0.0
        var remote = 0.0
        var lastEnd = 0.0
    }
    private var evidence: [String: Evidence] = [:]

    mutating func classify(speaker: String?, startMS: Double, endMS: Double,
                           activity: [MeetingSourceActivity]) -> String {
        guard let speaker, !speaker.isEmpty, startMS.isFinite, endMS.isFinite,
              startMS >= 0, endMS > startMS else { return "unknown" }
        // Callback timing is approximate. A tiny token in a source's brief
        // inter-word gap must not establish the opposite speaker identity.
        let start = max(0, startMS - 100), end = endMS + 100
        var local = 0.0, remote = 0.0, simultaneous = 0.0, covered = 0.0
        for frame in activity where frame.endMS > start && frame.startMS < end {
            let overlap = max(0, min(end, frame.endMS) - max(start, frame.startMS))
            if frame.calibrated && frame.micRMS.isFinite && frame.systemRMS.isFinite { covered += overlap }
            if frame.exclusiveSource == "local" { local += overlap }
            if frame.exclusiveSource == "remote" { remote += overlap }
            if frame.simultaneousActivity { simultaneous += overlap }
        }
        let duration = end - start
        guard covered / duration >= 0.8 else { return "unknown" }
        let immediate = local / duration >= 0.8 ? "local" : remote / duration >= 0.8 ? "remote" : "unknown"
        var total = evidence[speaker] ?? Evidence()
        // Repeated/overlapping subword timestamps count only once.
        let uniqueDuration = min(1000, max(0, endMS - max(startMS, total.lastEnd)))
        if immediate == "local" { total.local += uniqueDuration }
        if immediate == "remote" { total.remote += uniqueDuration }
        if immediate != "unknown" { total.lastEnd = max(total.lastEnd, endMS) }
        evidence[speaker] = total
        let anchored: String
        if total.local >= 500 && total.remote <= total.local * 0.1 { anchored = "local" }
        else if total.remote >= 500 && total.local <= total.remote * 0.1 { anchored = "remote" }
        else { return "unknown" }
        // A remembered speaker must not override current overlap or an
        // opposing source (the provider may reuse/switch speaker IDs).
        if simultaneous / duration > 0.2 { return "unknown" }
        if anchored == "local" && remote / duration > 0.2 { return "unknown" }
        if anchored == "remote" && local / duration > 0.2 { return "unknown" }
        return anchored
    }
}
