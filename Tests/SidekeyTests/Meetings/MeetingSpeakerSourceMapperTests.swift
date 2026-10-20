import XCTest
@testable import Sidekey

final class MeetingSpeakerSourceMapperTests: XCTestCase {
    func testBackgroundMicDoesNotLabelTheRemoteSpeakerAsLocal() {
        var detector = MeetingSourceActivityDetector()
        var frames: [MeetingSourceActivity] = []
        for i in 0..<40 {
            frames.append(detector.observe(.init(startMS: Double(i * 100), endMS: Double((i + 1) * 100),
                micRMS: 0.012, systemRMS: i < 20 ? 0 : 0.1)))
        }
        XCTAssertNil(frames[10].exclusiveSource, "Warmup must not establish an identity")
        XCTAssertEqual(frames[25].exclusiveSource, "remote")
        var mapper = MeetingSpeakerSourceMapper()
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 2200, endMS: 2800, activity: frames), "remote")
        // A gap in remote speech still has microphone noise, not local speech.
        let gap = detector.observe(.init(startMS: 4000, endMS: 4100, micRMS: 0.012, systemRMS: 0))
        XCTAssertNil(gap.exclusiveSource)
    }

    func testOwnSpeechSurvivesNoiseCalibrationAndLongUtterances() {
        var detector = MeetingSourceActivityDetector()
        for i in 0..<100 {
            _ = detector.observe(.init(startMS: Double(i * 100), endMS: Double((i + 1) * 100),
                micRMS: 0.02, systemRMS: 0))
        }
        for i in 100..<400 {
            let frame = detector.observe(.init(startMS: Double(i * 100), endMS: Double((i + 1) * 100),
                micRMS: 0.15, systemRMS: 0))
            XCTAssertEqual(frame.exclusiveSource, "local", "Continuous speech must not raise the noise floor")
        }
    }

    func testQuietMicrophoneSpeechRemainsDetectableAboveItsOwnBackground() {
        var detector = MeetingSourceActivityDetector()
        for i in 0..<20 {
            _ = detector.observe(.init(startMS: Double(i * 100), endMS: Double((i + 1) * 100),
                micRMS: 0.001, systemRMS: 0))
        }
        let frame = detector.observe(.init(startMS: 2000, endMS: 2100, micRMS: 0.006, systemRMS: 0))
        XCTAssertEqual(frame.exclusiveSource, "local")
    }

    func testOverlappingAndRepeatedTokenTimesCannotManufactureAnchors() {
        var mapper = MeetingSpeakerSourceMapper()
        let frames = [MeetingSourceActivity(startMS: 0, endMS: 1000, micRMS: 0, systemRMS: 0.1)]
        for _ in 0..<20 {
            XCTAssertEqual(mapper.classify(speaker: "1", startMS: 200, endMS: 260, activity: frames), "unknown")
        }
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 260, endMS: 800, activity: frames), "remote")
    }

    func testShortInterWordGapCannotOverrideSurroundingRemoteSpeech() {
        var mapper = MeetingSpeakerSourceMapper()
        let frames = [
            MeetingSourceActivity(startMS: 0, endMS: 100, micRMS: 0, systemRMS: 0.1),
            MeetingSourceActivity(startMS: 100, endMS: 200, micRMS: 0.1, systemRMS: 0),
            MeetingSourceActivity(startMS: 200, endMS: 1000, micRMS: 0, systemRMS: 0.1)
        ]
        for _ in 0..<20 {
            XCTAssertEqual(mapper.classify(speaker: "1", startMS: 120, endMS: 180, activity: frames), "unknown")
        }
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 300, endMS: 900, activity: frames), "remote")
    }

    func testKnownSpeakerDoesNotOverrideOverlapOrOpposingSource() {
        var mapper = MeetingSpeakerSourceMapper()
        let remote = [MeetingSourceActivity(startMS: 0, endMS: 1000, micRMS: 0, systemRMS: 0.1)]
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 100, endMS: 700, activity: remote), "remote")
        let overlap = [MeetingSourceActivity(startMS: 1000, endMS: 2000, micRMS: 0.1, systemRMS: 0.1)]
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 1100, endMS: 1700, activity: overlap), "unknown")
        let local = [MeetingSourceActivity(startMS: 2000, endMS: 3000, micRMS: 0.1, systemRMS: 0)]
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 2100, endMS: 2160, activity: local), "unknown")
    }

    func testMissingTimingAndNonfiniteLevelsStayUnknown() {
        var mapper = MeetingSpeakerSourceMapper()
        let invalid = [MeetingSourceActivity(startMS: 0, endMS: 1000, micRMS: .nan, systemRMS: 0.1)]
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 100, endMS: 800, activity: invalid), "unknown")
        XCTAssertEqual(mapper.classify(speaker: nil, startMS: 100, endMS: 800, activity: []), "unknown")
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: .nan, endMS: 800, activity: []), "unknown")
    }

    func testKnownSpeakerDoesNotFillMissingOrUncalibratedAudio() {
        var mapper = MeetingSpeakerSourceMapper()
        let remote = [MeetingSourceActivity(startMS: 0, endMS: 1000, micRMS: 0, systemRMS: 0.1)]
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 100, endMS: 700, activity: remote), "remote")
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 2000, endMS: 2700, activity: []), "unknown")
        var warmup = MeetingSourceActivity(startMS: 2000, endMS: 3000, micRMS: 0, systemRMS: 0.1)
        warmup.calibrated = false
        XCTAssertEqual(mapper.classify(speaker: "1", startMS: 2100, endMS: 2700, activity: [warmup]), "unknown")
    }
}
