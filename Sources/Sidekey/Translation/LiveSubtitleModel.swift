import Foundation

struct SubtitleLine: Identifiable, Equatable {
    let id: UUID
    let source: String
    var translation: String?
    init(source: String) { id = UUID(); self.source = source }
}

enum SubtitlePhase: Equatable {
    case idle, connecting, listening, finishing, failed
    var isActive: Bool { self == .connecting || self == .listening || self == .finishing }
}

/// A bounded handoff prevents a slow socket from retaining unlimited system audio.
/// Overflow ends the session visibly; it never silently drops captured speech.
final class SubtitleAudioRelay: @unchecked Sendable {
    let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var task: Task<Void, Never>?
    struct Overflow: Error {}

    init(
        source: SystemAudioSourceStreaming,
        convert: @escaping @Sendable ([Float]) -> Data = { SubtitleSegmenter.pcm16($0) },
        onOverflow: @escaping @Sendable () -> Void
    ) {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        stream = pair.stream
        continuation = pair.continuation
        let input = source.audioBufferStream()
        task = Task.detached {
            for await samples in input {
                guard !Task.isCancelled else { break }
                if case .dropped = pair.continuation.yield(convert(samples)) {
                    onOverflow()
                    pair.continuation.finish(throwing: Overflow())
                    return
                }
            }
            pair.continuation.finish()
        }
    }

    func cancel() { task?.cancel(); task = nil; continuation.finish() }
    deinit { task?.cancel(); continuation.finish() }
}

// WHY: .project-docs/decisions/2026-10-20-translation-tools.md
@MainActor
final class LiveSubtitleModel: ObservableObject {
    @Published var targetCode = "ru"
    @Published var sourceCode = "auto"
    @Published var showsOriginal = true
    @Published private(set) var phase: SubtitlePhase = .idle
    @Published private(set) var lines: [SubtitleLine] = []
    @Published private(set) var partial = ""
    @Published private(set) var issue: TranslationIssue?
    @Published private(set) var hasAudio = false
    var onActivityChange: (() -> Void)?

    private let connectionTimeout: Duration
    private var connectionWatchdog: Task<Void, Never>?
    private let flushInterval: Duration
    private let makeAudio: () -> TerminalSystemAudioSourceStreaming
    private let open: (String?) async throws -> BYOKUpstreamSession
    private let makeService: () async throws -> TextTranslating
    private var generation = UUID()
    private var cleanupTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var stopWatchdog: Task<Void, Never>?
    private var source: TerminalSystemAudioSourceStreaming?
    private var upstream: BYOKUpstreamSession?
    private var relay: SubtitleAudioRelay?
    private var segmenter = SubtitleSegmenter()
    private var queue: [UUID] = []
    private var service: TextTranslating?
    private var target: TranslationTarget = .language("ru")
    private var sawFinal = false

    init(
        flushInterval: Duration = .milliseconds(250),
        connectionTimeout: Duration = .seconds(15),
        makeAudio: @escaping () -> TerminalSystemAudioSourceStreaming = { CoreAudioSystemAudioSource() },
        open: @escaping (String?) async throws -> BYOKUpstreamSession = { language in
            let resolver = FeatureRouteResolver()
            guard let route = resolver.route(for: .subtitlesAudio) else { throw FeatureRouteError.notSet(.subtitlesAudio) }
            if route.account == .deepgram,
               let error = DeepgramLanguagePolicy.configurationError(model: route.model, language: language) {
                throw FeatureRouteError.invalidLanguageConfiguration(.subtitlesAudio, error)
            }
            let adapter = try RealtimeAdapterFactory.makeMetered(resolver.resolve(route, for: .subtitlesAudio))
            return try await adapter.open(language: language, terms: [])
        },
        makeService: @escaping () async throws -> TextTranslating = { try await TranslationService.live(for: .subtitlesTranslation) }
    ) {
        self.connectionTimeout = connectionTimeout
        self.flushInterval = flushInterval
        self.makeAudio = makeAudio
        self.open = open
        self.makeService = makeService
    }

    @discardableResult func start() -> Task<Void, Never>? {
        guard !phase.isActive else { return nil }
        cleanupTask = nil
        generation = UUID()
        let token = generation
        let language = sourceCode == "auto" ? nil : sourceCode
        target = .language(targetCode)
        lines = []; partial = ""; issue = nil; queue = []
        segmenter = SubtitleSegmenter(); sawFinal = false; hasAudio = false
        setPhase(.connecting)
        connectionWatchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.connectionTimeout ?? .seconds(15))
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .connecting else { return }
            self.fail(.init(message: "Connecting took too long. Check your providers and network, then start again."), token: token)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                // Resolve both routes before touching system audio. Never borrow a
                // Drop/Agent key and never switch the model after a failure.
                let service = try await self.makeService()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.service = service
                let upstream = try await self.open(language)
                guard self.generation == token, !Task.isCancelled else { await upstream.close(); return }
                self.upstream = upstream
                let source = self.makeAudio()
                self.source = source
                let relay = SubtitleAudioRelay(source: source) { [weak self] in
                    Task { @MainActor in
                        self?.fail(.init(message: "Audio is arriving faster than it can be sent. Check your connection and start again."), token: token)
                    }
                }
                self.relay = relay
                try await source.start()
                guard self.generation == token, !Task.isCancelled else { await source.stop(); return }
                self.connectionWatchdog?.cancel(); self.connectionWatchdog = nil
                self.setPhase(.listening)
                self.audioTask = Task { [weak self] in
                    do {
                        for try await pcm in relay.stream {
                            guard !Task.isCancelled else { return }
                            // RMS-independent: distinguish true digital silence from
                            // received audio without logging or persisting samples.
                            if pcm.contains(where: { $0 != 0 }), self?.hasAudio == false { self?.hasAudio = true }
                            await upstream.sendAudio(pcm)
                        }
                        guard !Task.isCancelled else { return }
                        await upstream.endInput()
                    } catch {
                        self?.fail(.init(message: "Audio is arriving faster than it can be sent. Check your connection and start again."), token: token)
                    }
                }
                self.timer = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: self?.flushInterval ?? .milliseconds(250))
                        guard !Task.isCancelled, let self, self.generation == token else { return }
                        self.flush(token: token)
                    }
                }
                for await event in upstream.events {
                    guard self.generation == token, !Task.isCancelled else { return }
                    switch event {
                    case .partial(let text): self.partial = String(text.suffix(800))
                    case .final(let text):
                        self.sawFinal = true
                        self.segmenter.append(text, join: upstream.finalsJoin, now: ProcessInfo.processInfo.systemUptime)
                        self.partial = ""
                        if self.segmenter.pending.count > 4_000 {
                            self.fail(.init(message: "The speech stream is too far behind. Choose a faster model and start again."), token: token)
                            return
                        }
                    case .done(let text):
                        if !self.sawFinal { self.segmenter.append(text, join: upstream.finalsJoin, now: ProcessInfo.processInfo.systemUptime) }
                        guard self.phase == .finishing else {
                            self.fail(.init(message: "The audio connection ended. Start again to continue subtitles."), token: token)
                            return
                        }
                    case .error:
                        self.fail(.init(message: "The speech provider stopped responding. Check the Subtitles audio route and try again.", feature: .subtitlesAudio), token: token)
                        return
                    }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                guard self.phase == .finishing else {
                    self.fail(.init(message: "The audio connection ended. Start again to continue subtitles."), token: token)
                    return
                }
                self.stopWatchdog?.cancel(); self.stopWatchdog = nil
                self.timer?.cancel(); self.timer = nil
                self.flush(token: token, force: true)
                await self.translationTask?.value
                guard self.generation == token else { return }
                await self.releaseCapture()
                guard self.generation == token else { return }
                self.partial = ""; self.service = nil; self.runTask = nil
                self.setPhase(.idle)
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail(.from(error, feature: self.service == nil ? .subtitlesTranslation : .subtitlesAudio), token: token)
            }
        }
        runTask = task
        return task
    }

    func stop() {
        guard phase == .listening else { cancel(); return }
        setPhase(.finishing)
        // Stop capture, then drain the bounded relay, then provider finals.
        // The source's terminal EOF lets the producer finish naturally: cancelling
        // it here would discard buffered and in-flight captured PCM.
        let source = self.source
        Task { await source?.stopAndFinishStreams() }
        let token = generation
        stopWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.fail(.init(message: "The speech provider did not finish in time. The completed subtitles are still here."), token: token)
        }
    }

    /// Closing/sleep cancels immediately, including pending paid requests.
    /// Keep a finishing state until old capture has actually been released.
    @discardableResult func cancel() -> Task<Void, Never> {
        if let cleanupTask { return cleanupTask }
        generation = UUID()
        let token = generation
        runTask?.cancel(); runTask = nil
        translationTask?.cancel(); translationTask = nil
        timer?.cancel(); timer = nil
        stopWatchdog?.cancel(); stopWatchdog = nil
        connectionWatchdog?.cancel(); connectionWatchdog = nil
        queue = []; service = nil; partial = ""
        setPhase(.finishing)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.releaseCapture()
            guard self.generation == token else { return }
            self.setPhase(self.issue == nil ? .idle : .failed)
            self.cleanupTask = nil
        }
        cleanupTask = task
        return task
    }

    func clear() { guard !phase.isActive else { return }; lines = []; issue = nil; setPhase(.idle) }

    private func fail(_ issue: TranslationIssue, token: UUID) {
        guard generation == token else { return }
        self.issue = issue
        cancel()
    }

    private func setPhase(_ value: SubtitlePhase) { phase = value; onActivityChange?() }

    private func releaseCapture() async {
        audioTask?.cancel(); audioTask = nil
        relay?.cancel(); relay = nil
        let source = self.source; self.source = nil
        let upstream = self.upstream; self.upstream = nil
        await source?.stop()
        await upstream?.close()
    }

    private func flush(token: UUID, force: Bool = false) {
        while let text = segmenter.take(now: ProcessInfo.processInfo.systemUptime, force: force) {
            guard queue.count < 8 else {
                fail(.init(message: "Translation cannot keep up with speech. Choose a faster Subtitles LLM model, then start again.", feature: .subtitlesTranslation), token: token)
                return
            }
            let line = SubtitleLine(source: text)
            lines.append(line); queue.append(line.id)
            // Do not evict any queued/in-flight line. The queue itself is bounded.
            if lines.count > 40, !queue.contains(lines[0].id), lines[0].translation != nil { lines.removeFirst() }
            startTranslationWorker(token: token)
            if !force { break }
        }
    }

    private func startTranslationWorker(token: UUID) {
        guard translationTask == nil, let service else { return }
        let target = self.target
        translationTask = Task { [weak self] in
            guard let self else { return }
            while self.generation == token, !Task.isCancelled, !self.queue.isEmpty {
                let id = self.queue.removeFirst()
                guard let line = self.lines.first(where: { $0.id == id }) else { continue }
                do {
                    let value = try await service.translate(line.source, target: target)
                    guard self.generation == token, !Task.isCancelled else { return }
                    if let index = self.lines.firstIndex(where: { $0.id == id }) { self.lines[index].translation = value }
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.fail(.from(error, feature: .subtitlesTranslation), token: token)
                    return
                }
            }
            guard self.generation == token else { return }
            self.translationTask = nil
        }
    }
}
