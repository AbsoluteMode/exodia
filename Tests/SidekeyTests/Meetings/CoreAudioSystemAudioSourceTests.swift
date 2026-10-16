import CoreAudio
import XCTest
@testable import Sidekey

/// Aggregate-device description contract for the CoreAudio system-audio
/// process tap. The tap is wrapped in a private aggregate device; for the
/// aggregate's IOProc to actually pull the captured mix it needs a real
/// hardware sub-device to drive the IO clock. The canonical pattern (Apple
/// "Capturing system audio with Core Audio taps" / insidegui AudioCap) uses
/// the current default output device as the aggregate's *main* sub-device.
///
/// Regression guard: a previous shape created the aggregate with the tap
/// only (no sub-device). That aggregate has no clock-driving device, so the
/// IOProc never delivered the system mix — system audio was silent in
/// recordings and the system waveform stayed flat while the mic path
/// (separate AVAudioEngine) kept working.
final class CoreAudioSystemAudioSourceTests: XCTestCase {

    private let deviceName = "Whytap System Audio"
    private let aggregateUID = "com.rootwise.sidekey.system-audio.TEST-UID"
    private let tapUID = "TAP-UUID-1234"

    func test_aggregateDescription_bindsOutputDeviceAsMainSubDevice() {
        let outputUID = "BuiltInSpeakerDevice-UID"
        let description = CoreAudioSystemAudioSource.makeAggregateDescription(
            name: deviceName,
            aggregateUID: aggregateUID,
            outputDeviceUID: outputUID,
            tapUID: tapUID
        )

        XCTAssertEqual(
            description[kAudioAggregateDeviceMainSubDeviceKey] as? String,
            outputUID,
            "Aggregate must bind the default output device as its main sub-device so the IOProc has a clock to pull the tapped mix."
        )

        let subDeviceList = description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]]
        XCTAssertEqual(
            subDeviceList?.first?[kAudioSubDeviceUIDKey] as? String,
            outputUID,
            "Aggregate sub-device list must contain the output device UID."
        )

        XCTAssertEqual(
            description[kAudioAggregateDeviceIsStackedKey] as? Bool,
            false,
            "Aggregate must be non-stacked (multi-output) so the tap + output run as one clocked device."
        )
    }

    func test_aggregateDescription_alwaysContainsTapWithDriftCompensation() {
        let description = CoreAudioSystemAudioSource.makeAggregateDescription(
            name: deviceName,
            aggregateUID: aggregateUID,
            outputDeviceUID: "AnyOutput-UID",
            tapUID: tapUID
        )

        let tapList = description[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        XCTAssertEqual(
            tapList?.first?[kAudioSubTapUIDKey] as? String,
            tapUID,
            "Tap list must reference the created process tap by UID."
        )
        XCTAssertEqual(
            tapList?.first?[kAudioSubTapDriftCompensationKey] as? Bool,
            true,
            "Tap must drift-compensate against the output sub-device clock."
        )
        XCTAssertEqual(description[kAudioAggregateDeviceUIDKey] as? String, aggregateUID)
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool, true)
    }

    func test_aggregateDescription_withoutOutputDevice_omitsSubDeviceBinding() {
        let description = CoreAudioSystemAudioSource.makeAggregateDescription(
            name: deviceName,
            aggregateUID: aggregateUID,
            outputDeviceUID: nil,
            tapUID: tapUID
        )

        XCTAssertNil(
            description[kAudioAggregateDeviceMainSubDeviceKey],
            "With no resolvable output device there is nothing to bind; fall back to a tap-only aggregate rather than inventing a sub-device."
        )
        XCTAssertNil(description[kAudioAggregateDeviceSubDeviceListKey])
        // The tap itself must still be present so the best-effort fallback
        // at least attempts capture.
        XCTAssertNotNil(description[kAudioAggregateDeviceTapListKey])
    }

    func test_captureFormat_keepsTapLayoutAndAggregateClockSeparate() {
        let tapFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let format = SystemAudioCaptureFormat(
            decodeFormat: tapFormat,
            clockSampleRate: 16_000
        )

        XCTAssertEqual(format.decodeFormat.mSampleRate, 48_000)
        XCTAssertEqual(format.decodeFormat.mChannelsPerFrame, 1)
        XCTAssertEqual(format.clockSampleRate, 16_000)
    }

    func test_callbackRateMonitor_detectsBluetoothHFPClock() {
        var monitor = SystemAudioCallbackRateMonitor()
        let interval: UInt64 = 100_000_000

        var observed: Double?
        for callback in 0...20 {
            observed = monitor.observe(
                frameCount: 1_600,
                nowNanoseconds: UInt64(callback) * interval
            ) ?? observed
        }

        XCTAssertEqual(observed, 16_000)
    }

    func test_callbackRateMonitor_preservesFortyEightKilohertzClock() {
        var monitor = SystemAudioCallbackRateMonitor()
        let interval: UInt64 = 100_000_000

        var observed: Double?
        for callback in 0...20 {
            observed = monitor.observe(
                frameCount: 4_800,
                nowNanoseconds: UInt64(callback) * interval
            ) ?? observed
        }

        XCTAssertEqual(observed, 48_000)
    }

    func test_callbackRateMonitor_rejectsImplausibleCadence() {
        XCTAssertNil(SystemAudioCallbackRateMonitor.normalizedCommonRate(37_000))
        XCTAssertNil(SystemAudioCallbackRateMonitor.normalizedCommonRate(.nan))
        XCTAssertNil(SystemAudioCallbackRateMonitor.normalizedCommonRate(0))
    }

    // MARK: - Streaming resampler

    /// Regression guard: resampling each 512-frame 48 kHz callback from
    /// position zero produced 170 samples instead of 170.67, so an hour of
    /// system audio came out ~14 s short and drifted away from the mic track.
    func test_streamingResampler_keepsDurationAcrossCallbacks() {
        var resampler = SystemAudioStreamingResampler(targetSampleRate: 16_000)
        let callback = [Float](repeating: 0.25, count: 512)
        var produced = 0
        for _ in 0..<(60 * 48_000 / 512) {
            produced += resampler.process(callback, sourceSampleRate: 48_000).count
        }

        XCTAssertEqual(produced, 60 * 16_000, "60 s of 48 kHz input must yield 60 s at 16 kHz")
    }

    func test_streamingResampler_keepsDurationForUnevenCallbacksAt44k() {
        var resampler = SystemAudioStreamingResampler(targetSampleRate: 16_000)
        let sizes = [441, 512, 1_024, 300, 7, 999]
        var consumed = 0
        var produced = 0
        var index = 0
        while consumed < 30 * 44_100 {
            let size = min(sizes[index % sizes.count], 30 * 44_100 - consumed)
            produced += resampler.process([Float](repeating: 0, count: size), sourceSampleRate: 44_100).count
            consumed += size
            index += 1
        }

        XCTAssertEqual(Double(produced), 30 * 16_000, accuracy: 1)
    }

    func test_streamingResampler_matchesOneShotResampleOfWholeSignal() {
        // 44.1 kHz gives a fractional step, so callback boundaries land
        // between samples and exercise the carried-over neighbour.
        let rate = 44_100.0
        let signal = (0..<44_100).map { Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }
        var whole = SystemAudioStreamingResampler(targetSampleRate: 16_000)
        let expected = whole.process(signal, sourceSampleRate: rate)

        var streaming = SystemAudioStreamingResampler(targetSampleRate: 16_000)
        var actual: [Float] = []
        var offset = 0
        for size in [512, 1, 2, 511, 4_096, 13] where offset < signal.count {
            let end = min(offset + size, signal.count)
            actual += streaming.process(Array(signal[offset..<end]), sourceSampleRate: rate)
            offset = end
        }
        while offset < signal.count {
            let end = min(offset + 512, signal.count)
            actual += streaming.process(Array(signal[offset..<end]), sourceSampleRate: rate)
            offset = end
        }

        XCTAssertEqual(actual.count, expected.count)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: 1e-4)
        }
    }

    func test_streamingResampler_restartsPhaseWhenClockChanges() {
        var resampler = SystemAudioStreamingResampler(targetSampleRate: 16_000)
        _ = resampler.process([Float](repeating: 1, count: 512), sourceSampleRate: 48_000)

        // Bluetooth HFP: the callback clock drops to the target rate.
        let passThrough: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(resampler.process(passThrough, sourceSampleRate: 16_000), passThrough)

        let resumed = resampler.process([Float](repeating: 0.5, count: 48), sourceSampleRate: 48_000)
        XCTAssertEqual(resumed.count, 16)
        XCTAssertTrue(resumed.allSatisfy { $0 == 0.5 }, "No stale sample from before the clock change may leak in")
    }
}
