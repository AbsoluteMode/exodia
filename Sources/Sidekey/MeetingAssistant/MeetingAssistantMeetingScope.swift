import Foundation

/// A listening choice belongs to this session, never a saved auto-join policy.
/// The existing metadata-only meeting probe is independent of Meeting Notes.
// WHY: docs/decisions/2026-10-24-meeting-assistant-session-switch.md
@MainActor
final class MeetingAssistantMeetingScope {
    private let makeProbe: @MainActor () -> MicInUseProbing
    private let endGrace: Duration
    private var probe: MicInUseProbing?
    private var consumer: Task<Void, Never>?
    private var ending: Task<Void, Never>?
    private var generation = UUID()
    private var sawMeeting = false
    var onEnd: (() -> Void)?

    init(endGrace: Duration = .seconds(15), makeProbe: @escaping @MainActor () -> MicInUseProbing = { MeetingContextActiveProbe() }) {
        self.endGrace = endGrace; self.makeProbe = makeProbe
    }

    func begin() {
        guard probe == nil else { return }
        generation = UUID(); let token = generation
        sawMeeting = false
        let probe = makeProbe(); self.probe = probe
        let events = probe.subscribe()
        consumer = Task { [weak self] in
            for await active in events {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.contextChanged(active, token: token)
            }
        }
    }

    private func contextChanged(_ active: Bool, token: UUID) {
        ending?.cancel(); ending = nil
        if active { sawMeeting = true; return }
        // Explicit manual use also works before an app has opened its mic.
        // Without a recognized context, only an explicit stop/close ends it.
        guard sawMeeting else { return }
        ending = Task { [weak self, endGrace] in
            try? await Task.sleep(for: endGrace)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.stop()
            self.onEnd?()
        }
    }

    func stop() {
        generation = UUID()
        consumer?.cancel(); consumer = nil; ending?.cancel(); ending = nil
        probe?.stop(); probe = nil; sawMeeting = false
    }
}

struct MeetingAssistantHoverState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case off, connecting, listening, stopping }
    var available = false
    var phase: Phase = .off
    var visible: Bool { available || phase != .off }
    var isOn: Bool { phase == .connecting || phase == .listening }
    var canToggle: Bool { phase != .stopping }
    var subtitle: String {
        switch phase {
        case .off: return "Только эта встреча"
        case .connecting: return "Подключение…"
        case .listening: return "Слушает эту встречу"
        case .stopping: return "Останавливаю…"
        }
    }
}
