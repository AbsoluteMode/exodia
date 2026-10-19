import Foundation

/// Independent low-latency test clock. Never waits for the archival mixer's
/// five-second solo fallback. Missing input becomes silence after 150 ms.
/// Input APIs currently expose samples, not hardware host timestamps: source
/// placement is an arrival-time approximation, explicitly recorded as such.
@MainActor
final class MeetingLiveTestMixer {
    struct Frame {
        var mic = [Float](repeating: 0, count: 1600)
        var system = [Float](repeating: 0, count: 1600)
    }
    private let capture: MeetingLiveTestCapture
    private let clock: () -> Double
    private var epoch: Double
    private var epochSample = 0
    private var nextFrame = 0
    private var sourceNext: [MeetingAudioTrack: Int] = [:]
    private var frames: [Int: Frame] = [:]
    private var timer: Task<Void, Never>?
    private var paused = false
    private var stopped = false

    init(capture: MeetingLiveTestCapture, automaticTicks: Bool = true,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.capture = capture
        self.clock = clock
        epoch = clock()
        if automaticTicks {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.tick()
                }
            }
        }
    }

    func append(_ samples: [Float], source: MeetingAudioTrack) {
        guard !paused, !stopped, source == .mic || source == .system, !samples.isEmpty else { return }
        let arrivalEnd = epochSample + max(0, Int((clock() - epoch) * 16_000))
        let inferredStart = max(epochSample, arrivalEnd - samples.count)
        var start = sourceNext[source] ?? inferredStart
        // Discontinuous callbacks (mute/device stalls) keep their silence gap.
        if inferredStart > start + 3200 { start = inferredStart }
        sourceNext[source] = start + samples.count
        var late = 0
        // Never retain an unbounded callback/backlog or mutate sent frames.
        for (i, sample) in samples.enumerated() {
            let position = start + i, frame = position / 1600
            guard frame >= nextFrame, frame < nextFrame + 20 else { late += 1; continue }
            let finite = sample.isFinite ? max(-1, min(1, sample)) : 0
            if source == .mic { frames[frame, default: Frame()].mic[position % 1600] = finite }
            else { frames[frame, default: Frame()].system[position % 1600] = finite }
        }
        if late > 0 { capture.submit(.marker("late_or_out_of_range_\(source.rawValue)_samples:\(late)")) }
    }

    func tick() {
        guard !paused, !stopped else { return }
        let dueSamples = epochSample + max(0, Int((clock() - epoch - 0.15) * 16_000))
        flush(untilFrame: dueSamples / 1600)
    }

    func pause() {
        guard !paused, !stopped else { return }
        flushTail()
        paused = true
        capture.submit(.marker("paused"))
        frames.removeAll(); sourceNext.removeAll()
    }

    func resume() {
        guard paused, !stopped else { return }
        epoch = clock(); epochSample = nextFrame * 1600
        paused = false
        capture.submit(.marker("resumed"))
    }

    func finish() {
        guard !stopped else { return }
        if !paused { flushTail() }
        stopped = true
        timer?.cancel(); timer = nil
        capture.submit(.marker("stopped"))
        capture.finish()
        frames.removeAll()
    }

    private func flushTail() {
        let now = epochSample + max(0, Int((clock() - epoch) * 16_000))
        // Include already received audio even when a synthetic callback is
        // ahead of the injected clock. No speech is invented for absent input.
        let end = max((now + 1599) / 1600, (frames.keys.max().map { $0 + 1 }) ?? nextFrame)
        flush(untilFrame: end)
    }

    private func flush(untilFrame target: Int) {
        // Bound an unexpected scheduler/clock jump. A marker makes the gap
        // visible; it must never be mistaken for a fully captured meeting.
        guard target - nextFrame <= 50 else {
            capture.submit(.marker("capture_clock_gap"))
            finishAfterClockGap(); return
        }
        while nextFrame < target {
            let frame = frames.removeValue(forKey: nextFrame) ?? Frame()
            var mixed = [Int16](), mic = [Int16](), system = [Int16]()
            mixed.reserveCapacity(1600); mic.reserveCapacity(1600); system.reserveCapacity(1600)
            var mp = 0.0, sp = 0.0
            for i in 0..<1600 {
                let m = frame.mic[i], s = frame.system[i]
                mic.append(Int16(m * 32767)); system.append(Int16(s * 32767))
                mixed.append(Int16((m + s) * 0.5 * 32767))
                mp += Double(m) * Double(m); sp += Double(s) * Double(s)
            }
            func bytes(_ values: [Int16]) -> Data { values.withUnsafeBytes { Data($0) } }
            capture.submit(.audio(MeetingLiveTestPacket(mixed: bytes(mixed), mic: bytes(mic), system: bytes(system),
                activity: MeetingSourceActivity(startMS: Double(nextFrame * 100), endMS: Double((nextFrame + 1) * 100),
                    micRMS: sqrt(mp / 1600), systemRMS: sqrt(sp / 1600)), emittedUptime: clock())))
            nextFrame += 1
        }
    }

    private func finishAfterClockGap() {
        stopped = true
        timer?.cancel(); timer = nil
        frames.removeAll()
        capture.finish()
    }

    deinit { timer?.cancel(); capture.finish() }
}
