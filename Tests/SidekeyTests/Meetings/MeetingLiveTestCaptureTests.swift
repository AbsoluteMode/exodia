import XCTest
@testable import Sidekey

@MainActor
final class MeetingLiveTestCaptureTests: XCTestCase {
    func testUntimedFinalTextSurvivesWhileInterimsAndControlTokensDoNot() {
        let value = MeetingLiveTestToken(["text": "?", "is_final": true])
        XCTAssertEqual(value?.text, "?")
        XCTAssertNil(value?.startMS)
        XCTAssertNil(MeetingLiveTestToken(["text": "partial", "is_final": false]))
        XCTAssertNil(MeetingLiveTestToken(["text": "<fin>", "is_final": true]))
        XCTAssertEqual(MeetingLiveTestToken(["text": "<example", "is_final": true])?.text, "<example")
        let invalid = MeetingLiveTestToken(["text": "word", "is_final": true, "start_ms": 200.0, "end_ms": 100.0])
        XCTAssertEqual(invalid?.text, "word")
        XCTAssertNil(invalid?.endMS)
    }

    func testRecorderFeedsLiveCaptureBeforeArchivalSoloFallback() async throws {
        let root = temporaryRoot(), staging = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: staging) }
        let capture = MeetingLiveTestCapture(root: root, keyProvider: { nil })
        let mic = MeetingRecorderTests.StubMicSource()
        let recorder = MeetingRecorder(micSource: mic, systemSource: MeetingRecorderTests.StubSystemSource(),
            micInUseProbe: MeetingRecorderTests.StubMicInUse(), stagingRoot: staging, testCapture: capture)
        let id = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: id)
        mic.feed([Float](repeating: 0.2, count: 1600))
        let deadline = Date().addingTimeInterval(2)
        var liveAudioSeen = false
        while Date() < deadline {
            if let dir = try? onlyDirectory(root),
               let rows = try? jsonLines(dir.appendingPathComponent("activity.jsonl")),
               rows.contains(where: { (($0["mic_rms"] as? Double) ?? 0) > 0.1 }) {
                liveAudioSeen = true; break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(liveAudioSeen, "Test audio must flow before the five-second archival fallback")
        let event = await recorder.stop(reason: .user)
        XCTAssertFalse(event.chunkURLs.isEmpty)
        await capture.waitUntilFinished()
        let events = try jsonLines(onlyDirectory(root).appendingPathComponent("events.jsonl"))
        XCTAssertTrue(events.contains { ($0["event"] as? String) == "meeting:\(id.uuidString)" })
        XCTAssertTrue(events.contains { ($0["event"] as? String) == "stopped" })
    }

    func testMapperWaitsForAnchorsAndDoesNotGuessDuringOverlap() {
        var mapper = MeetingSpeakerSourceMapper()
        let local = [MeetingSourceActivity(startMS: 0, endMS: 600, micRMS: 0.1, systemRMS: 0)]
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 0, endMS: 200, activity: local), "unknown")
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 200, endMS: 600, activity: local), "local")
        let overlap = [MeetingSourceActivity(startMS: 600, endMS: 1000, micRMS: 0.1, systemRMS: 0.2)]
        XCTAssertEqual(mapper.classify(speaker: "2", startMS: 600, endMS: 1000, activity: overlap), "unknown")
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 600, endMS: 1000, activity: overlap), "unknown")
        let conflict = [MeetingSourceActivity(startMS: 1000, endMS: 1600, micRMS: 0, systemRMS: 0.1)]
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 1000, endMS: 1600, activity: conflict), "unknown")
        var newSession = MeetingSpeakerSourceMapper()
        XCTAssertEqual(newSession.classify(speaker: "1", startMS: 600, endMS: 1000, activity: overlap), "unknown")
    }

    func testSingleSourceFlowsWithoutWaitingForTheOtherChannel() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = MeetingLiveTestCapture(root: root, keyProvider: { nil })
        var now = 100.0
        let mixer = MeetingLiveTestMixer(capture: capture, automaticTicks: false, clock: { now })
        now += 0.1
        mixer.append([Float](repeating: 0.25, count: 1600), source: .mic)
        now += 0.16
        mixer.tick()
        mixer.finish()
        await capture.waitUntilFinished()
        let dir = try onlyDirectory(root)
        let mic = try Data(contentsOf: dir.appendingPathComponent("mic.pcm"))
        let system = try Data(contentsOf: dir.appendingPathComponent("system.pcm"))
        XCTAssertGreaterThanOrEqual(mic.count, 3200)
        XCTAssertEqual(mic.count, system.count)
        XCTAssertTrue(system.allSatisfy { $0 == 0 })
        XCTAssertFalse(mic.allSatisfy { $0 == 0 })
        let rows = try jsonLines(dir.appendingPathComponent("activity.jsonl"))
        XCTAssertEqual(rows[0]["start_ms"] as? Double, 0)
        XCTAssertEqual(rows[0]["end_ms"] as? Double, 100)
        XCTAssertEqual(rows[0]["mic_rms"] as? Double, 0.25)
        let manifest = try json(dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest["state"] as? String, "missing_key")
        XCTAssertEqual(manifest["sample_rate"] as? Int, 16_000)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testPauseDropsAudioAndKeepsTheTranscriptionClockContinuous() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = MeetingLiveTestCapture(root: root, keyProvider: { nil })
        var now = 100.0
        let mixer = MeetingLiveTestMixer(capture: capture, automaticTicks: false, clock: { now })
        now += 0.1
        mixer.append([Float](repeating: 0.2, count: 1600), source: .mic)
        mixer.pause()
        now += 60
        mixer.append([Float](repeating: 0.9, count: 1600), source: .mic)
        mixer.tick()
        mixer.resume()
        now += 0.1
        mixer.append([Float](repeating: 0.4, count: 1600), source: .system)
        mixer.finish()
        await capture.waitUntilFinished()
        let dir = try onlyDirectory(root)
        let rows = try jsonLines(dir.appendingPathComponent("activity.jsonl"))
        XCTAssertLessThanOrEqual(rows.count, 4) // ceil padding, never sixty seconds of pause
        XCTAssertFalse(rows.contains { (($0["mic_rms"] as? Double) ?? 0) > 0.8 })
        XCTAssertTrue(rows.contains { abs((($0["system_rms"] as? Double) ?? 0) - 0.4) < 0.001 })
        for (index, row) in rows.enumerated() { XCTAssertEqual(row["start_ms"] as? Double, Double(index * 100)) }
    }

    func testSyntheticConversationCapturesDifferentSourcesAndSimultaneousSpeech() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = MeetingLiveTestCapture(root: root, keyProvider: { nil })
        var now = 0.0
        let mixer = MeetingLiveTestMixer(capture: capture, automaticTicks: false, clock: { now })
        for i in 0..<30 {
            now = Double(i + 1) * 0.1
            mixer.append([Float](repeating: i < 20 ? 0.2 : 0, count: 1600), source: .mic)
            mixer.append([Float](repeating: i >= 10 ? 0.3 : 0, count: 1600), source: .system)
            mixer.tick()
        }
        mixer.finish()
        await capture.waitUntilFinished()
        let dir = try onlyDirectory(root)
        let rows = try jsonLines(dir.appendingPathComponent("activity.jsonl"))
        XCTAssertTrue(rows.contains { (($0["mic_rms"] as? Double) ?? 0) > 0.1 && (($0["system_rms"] as? Double) ?? 0) < 0.001 })
        XCTAssertTrue(rows.contains { (($0["mic_rms"] as? Double) ?? 0) > 0.1 && (($0["system_rms"] as? Double) ?? 0) > 0.1 })
        XCTAssertTrue(rows.contains { (($0["mic_rms"] as? Double) ?? 0) < 0.001 && (($0["system_rms"] as? Double) ?? 0) > 0.1 })
        let sizes = try ["mixed.pcm", "mic.pcm", "system.pcm"].map { try Data(contentsOf: dir.appendingPathComponent($0)).count }
        XCTAssertEqual(Set(sizes).count, 1)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("meeting-live-test-\(UUID().uuidString)")
    }
    private func onlyDirectory(_ root: URL) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
    }
    private func json(_ path: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    }
    private func jsonLines(_ path: URL) throws -> [[String: Any]] {
        try String(contentsOf: path).split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
}
