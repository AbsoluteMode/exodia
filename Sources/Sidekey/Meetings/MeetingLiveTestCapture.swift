import Foundation

/// Opt-in research capture, independent of the normal meeting processor.
/// WHY: .project-docs/decisions/2026-10-19-live-meeting-test-capture.md
enum MeetingLiveTestSettings {
    static let enabledKey = "sidekey.meetings.liveTestCapture"
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekey/meeting-assistant-tests", isDirectory: true)
    }

    @MainActor
    static func makeIfEnabled() -> MeetingLiveTestCapture? {
        guard UserDefaults.standard.bool(forKey: enabledKey),
              AIRoutingStore.shared.route(for: .meetings)?.account == .soniox else { return nil }
        return MeetingLiveTestCapture(root: root, keyProvider: {
            await Task.detached(priority: .utility) {
                ProviderKeyStore().read(account: BYOKKeyStore.account(for: .soniox))
            }.value
        }, stillEnabled: { UserDefaults.standard.bool(forKey: enabledKey) })
    }
}

struct MeetingSourceActivity: Codable, Equatable, Sendable {
    let startMS: Double
    let endMS: Double
    let micRMS: Double
    let systemRMS: Double

    /// Signal activity is evidence, not a speech detector or a voice identity.
    var exclusiveSource: String? {
        let mic = micRMS >= 0.003, system = systemRMS >= 0.003
        if mic && !system { return "local" }
        if system && !mic { return "remote" }
        return nil
    }
}

/// Causal mapping: uses only activity already submitted for the token's audio.
/// Both-active, silence and conflicting anchors remain unknown.
struct MeetingSpeakerSourceMapper {
    private var evidence: [String: (local: Double, remote: Double)] = [:]

    mutating func classify(speaker: String?, startMS: Double, endMS: Double,
                           activity: [MeetingSourceActivity]) -> String {
        var local = 0.0, remote = 0.0
        for frame in activity where frame.endMS > startMS && frame.startMS < endMS {
            let overlap = max(0, min(endMS, frame.endMS) - max(startMS, frame.startMS))
            if frame.exclusiveSource == "local" { local += overlap }
            if frame.exclusiveSource == "remote" { remote += overlap }
        }
        let duration = max(1, endMS - startMS)
        let immediate = local / duration >= 0.8 ? "local" : remote / duration >= 0.8 ? "remote" : "unknown"
        guard let speaker, !speaker.isEmpty else { return "unknown" }
        var total = evidence[speaker] ?? (0, 0)
        if immediate == "local" { total.local += min(local, 1000) }
        if immediate == "remote" { total.remote += min(remote, 1000) }
        evidence[speaker] = total
        // Require multiple useful word intervals; never label a speaker from
        // one tiny punctuation token, and withdraw a conflicting association.
        if total.local >= 500 && total.remote <= total.local * 0.1 { return "local" }
        if total.remote >= 500 && total.local <= total.remote * 0.1 { return "remote" }
        return "unknown"
    }
}

struct MeetingLiveTestPacket: Sendable {
    let mixed: Data
    let mic: Data
    let system: Data
    let activity: MeetingSourceActivity
    let emittedUptime: Double
}

/// Never awaits disk/network on the recorder's actor. A bounded queue fails
/// the diagnostic capture explicitly rather than dropping audio unnoticed.
final class MeetingLiveTestCapture: @unchecked Sendable {
    enum Event: Sendable {
        case audio(MeetingLiveTestPacket)
        case marker(String)
    }
    private let continuation: AsyncStream<Event>.Continuation
    private let worker: Task<Void, Never>
    private let stillEnabled: @Sendable () -> Bool
    private let lock = NSLock()
    private var failed = false
    private let runner: MeetingLiveTestWriter

    init(root: URL, keyProvider: @escaping @Sendable () async -> String?,
         stillEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.stillEnabled = stillEnabled
        let pair = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(100))
        continuation = pair.continuation
        let runner = MeetingLiveTestWriter(root: root, keyProvider: keyProvider)
        self.runner = runner
        worker = Task(priority: .utility) { await runner.consume(pair.stream) }
    }

    func submit(_ event: Event) {
        guard stillEnabled() else { finish(); return }
        lock.lock()
        guard !failed else { lock.unlock(); return }
        if case .dropped = continuation.yield(event) {
            failed = true
            continuation.finish()
            Task { await runner.markOverflow() }
        }
        lock.unlock()
    }

    func finish() { continuation.finish() }
    func waitUntilFinished() async { await worker.value }
    deinit { continuation.finish() }
}

private actor MeetingLiveTestWriter {
    private let root: URL
    private let keyProvider: @Sendable () async -> String?
    private let started = ProcessInfo.processInfo.systemUptime
    private let createdAt = Date()
    private var directory: URL?
    private var handles: [String: FileHandle] = [:]
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var activity: [MeetingSourceActivity] = []
    private var mapper = MeetingSpeakerSourceMapper()
    private var errorCode: String?
    private var finished = false
    private var overflow = false
    private var samples = 0
    private var tokenCount = 0
    private var timingWarnings = 0

    init(root: URL, keyProvider: @escaping @Sendable () async -> String?) {
        self.root = root
        self.keyProvider = keyProvider
    }

    func markOverflow() {
        overflow = true
        try? writeManifest(state: "queue_overflow")
    }

    func consume(_ stream: AsyncStream<MeetingLiveTestCapture.Event>) async {
        do {
            try prepareFiles()
            // Keychain I/O and socket setup are outside the capture callback.
            if let key = await keyProvider(), !key.isEmpty {
                do { try await connect(key: key) }
                catch { errorCode = "connect_failed"; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
            } else { errorCode = "missing_key" }
            for await event in stream {
                switch event {
                case .marker(let name):
                    if name.contains("clock_gap") || name.hasPrefix("late_or_out_of_range") { timingWarnings += 1 }
                    try appendJSON(["event": name, "audio_ms": Double(samples) / 16,
                                    "received_elapsed_ms": elapsedMS], file: "events.jsonl")
                case .audio(let packet):
                    guard samples < 16_000 * 60 * 120 else { errorCode = "two_hour_limit"; break }
                    try handles["mixed.pcm"]?.write(contentsOf: packet.mixed)
                    try handles["mic.pcm"]?.write(contentsOf: packet.mic)
                    try handles["system.pcm"]?.write(contentsOf: packet.system)
                    samples += packet.mixed.count / 2
                    activity.append(packet.activity)
                    // Keep only recent activity: Soniox final tokens can lag,
                    // but never map an older token against unrelated audio.
                    let cutoff = packet.activity.endMS - 120_000
                    if let first = activity.firstIndex(where: { $0.endMS >= cutoff }), first > 0 {
                        activity.removeFirst(first)
                    }
                    try appendJSON(["start_ms": packet.activity.startMS, "end_ms": packet.activity.endMS,
                                    "mic_rms": packet.activity.micRMS, "system_rms": packet.activity.systemRMS,
                                    "emitted_elapsed_ms": (packet.emittedUptime - started) * 1000,
                                    "written_elapsed_ms": elapsedMS], file: "activity.jsonl")
                    if let socket {
                        do { try await socket.send(.data(packet.mixed)) }
                        catch { errorCode = "audio_send_failed"; self.socket = nil; socket.cancel(with: .goingAway, reason: nil) }
                    }
                }
                if samples >= 16_000 * 60 * 120 { errorCode = "two_hour_limit"; break }
            }
            if let socket {
                do { try await socket.send(.string("")) }
                catch { errorCode = "end_send_failed" }
                // Bound final draining; do not hold the normal Stop/notes flow.
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                while !finished && ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if !finished && errorCode == nil { errorCode = "final_timeout" }
            }
        } catch { errorCode = "local_write_failed" }
        keepaliveTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        try? writeManifest(state: overflow ? "queue_overflow" : errorCode ?? (timingWarnings > 0 ? "complete_with_timing_warnings" : "complete"))
        for handle in handles.values { try? handle.close() }
        handles.removeAll()
    }

    private var elapsedMS: Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }

    private func prepareFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        directory = dir
        for file in ["mixed.pcm", "mic.pcm", "system.pcm", "activity.jsonl", "tokens.jsonl", "events.jsonl"] {
            let url = dir.appendingPathComponent(file)
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handles[file] = try FileHandle(forWritingTo: url)
        }
        try writeManifest(state: "recording")
    }

    private func writeManifest(state: String) throws {
        guard let directory else { return }
        let value: [String: Any] = ["schema_version": 1, "state": state,
            "sample_rate": 16_000, "audio_format": "pcm_s16le", "channels_per_file": 1,
            "samples": samples, "final_tokens": tokenCount, "timing_warnings": timingWarnings, "model": "stt-rt-v5",
            "speaker_mapping": "experimental_signal_activity_not_voice_identity",
            "clock": "exact_test_mixed_audio_samples; source placement approximated from callback arrival; pause removed; prerecord excluded",
            "capture_latency": "independent 100ms frames with 150ms jitter buffer; emitted/written/token receipt times saved",
            "created_at": ISO8601DateFormatter().string(from: createdAt)]
        let url = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func appendJSON(_ value: [String: Any], file: String) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        data.append(0x0a)
        try handles[file]?.write(contentsOf: data)
    }

    private func connect(key: String) async throws {
        var request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        let config: [String: Any] = ["model": "stt-rt-v5", "audio_format": "pcm_s16le",
            "sample_rate": 16_000, "num_channels": 1, "enable_speaker_diarization": true,
            "enable_endpoint_detection": false]
        let data = try JSONSerialization.data(withJSONObject: config)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        receiveTask = Task { await receive(task) }
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                try? await task.send(.string(#"{"type":"keepalive"}"#))
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: continue
                }
                guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errorCode = "invalid_response"; return
                }
                if response["error_code"] != nil { errorCode = "provider_error"; finished = true; return }
                for token in response["tokens"] as? [[String: Any]] ?? [] {
                    guard let text = token["text"] as? String, !text.hasPrefix("<"),
                          token["is_final"] as? Bool == true,
                          let start = token["start_ms"] as? Double, let end = token["end_ms"] as? Double,
                          start.isFinite, end.isFinite, start >= 0, end >= start else { continue }
                    let speaker = token["speaker"] as? String
                    let role = mapper.classify(speaker: speaker, startMS: start, endMS: end, activity: activity)
                    try appendJSON(["text": text, "start_ms": start, "end_ms": end,
                                    "speaker": speaker ?? "unknown", "role": role,
                                    "received_elapsed_ms": elapsedMS, "is_final": true], file: "tokens.jsonl")
                    tokenCount += 1
                }
                if response["finished"] as? Bool == true { finished = true; return }
            }
        } catch { if !Task.isCancelled { errorCode = "receive_failed"; finished = true } }
    }
}
