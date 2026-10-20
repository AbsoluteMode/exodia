import AppKit
import Combine
import SwiftUI

/// The Case Approve prompt: one compact black card attached under the island, at
/// the island's width. App, project with key names, the command on one line, and
/// three answers with their physical keys.
struct CaseApprovalView: View {
    let request: CaseApprovalRequest
    let width: CGFloat
    let pendingCount: Int
    let isArmed: Bool
    let onChoose: (CaseApprovalOutcome) -> Void
    var timedMinutes: Int? = nil
    var onTimedMinutesChange: (Int) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let bottomCornerRadius: CGFloat = 18
    static let accent = Color(red: 0.18, green: 0.43, blue: 0.96)

    // MARK: Copy (pure, tested)

    static func titleText(_ r: CaseApprovalRequest) -> String {
        "\(r.appName) хочет запустить команду"
    }

    static func keysText(_ r: CaseApprovalRequest) -> String {
        "\(r.projectName): \(r.keyNames.joined(separator: ", "))"
    }

    static func timedTitle(minutes: Int) -> String {
        "Bypass \(minutes) мин"
    }

    /// The command on a single line: line breaks and runs of whitespace collapse to
    /// one space; the view truncates the tail with «…».
    static func commandLine(_ command: String) -> String {
        command.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            VStack(alignment: .leading, spacing: 6) {
                keysLine
                commandBox
            }
            if request.timedMinutes > 0 {
                HStack(spacing: 8) {
                    Text("Временный Bypass")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.78))
                    Spacer(minLength: 4)
                    Stepper(value: Binding(get: { selectedMinutes }, set: onTimedMinutesChange), in: 1...240) {
                        Text("\(selectedMinutes) мин")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .fixedSize()
                    .accessibilityIdentifier("case.approval.minutes")
                }
            }
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: width, alignment: .leading)
        .background(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: Self.bottomCornerRadius,
                bottomTrailingRadius: Self.bottomCornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Self.titleText(request)). \(Self.keysText(request))")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            // The app name gives way first; the phrase always stays readable.
            HStack(spacing: 3.5) {
                Text(request.appName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("хочет запустить команду")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if pendingCount > 0 {
                Text("+\(pendingCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .accessibilityLabel("Ещё \(pendingCount) в очереди")
            }
        }
        .frame(height: 16)
    }

    private var keysLine: some View {
        (Text(request.projectName).fontWeight(.semibold).foregroundColor(Color.white.opacity(0.9))
            + Text(": " + request.keyNames.joined(separator: ", ")).foregroundColor(Color.white.opacity(0.6)))
            .font(.system(size: 11.5))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var commandBox: some View {
        Text(Self.commandLine(request.command))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.88))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .accessibilityLabel("Команда: \(request.command)")
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            CaseApprovalButton(title: "Отклонить", key: "N", prominent: false) { onChoose(.deny) }
            if request.timedMinutes > 0 {
                CaseApprovalButton(title: "Bypass", key: "A",
                                   prominent: false) { onChoose(.allowTimed(minutes: selectedMinutes)) }
                    .accessibilityLabel(Self.timedTitle(minutes: selectedMinutes))
                    .help("Без повторного запроса для этого агента и проекта на \(selectedMinutes) мин")
            }
            CaseApprovalButton(title: "Разрешить", key: "Y", prominent: true) { onChoose(.allow) }
        }
        .opacity(isArmed ? 1 : 0.5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isArmed)
        .allowsHitTesting(isArmed)
    }

    private var selectedMinutes: Int { timedMinutes ?? request.timedMinutes }
}

/// One answer: a capsule with its title and its key, the key drawn by `HotkeyHintView`.
private struct CaseApprovalButton: View {
    let title: String
    let key: String
    let prominent: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HotkeyHintView(keys: [key], style: .keycaps, size: .compact)
            }
            .foregroundStyle(Color.white.opacity(prominent ? 1 : 0.88))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint("Клавиша \(key)")
    }

    private var fill: Color {
        if prominent { return CaseApprovalView.accent.opacity(hovering ? 1 : 0.9) }
        return Color.white.opacity(hovering ? 0.18 : 0.11)
    }
}

/// Hosts `CaseApprovalView` for the controller's visible prompt.
struct CaseApprovalHostView: View {
    @ObservedObject var controller: CaseApprovalController
    let width: CGFloat

    var body: some View {
        if let request = controller.current {
            CaseApprovalView(
                request: request,
                width: width,
                pendingCount: controller.pendingCount,
                isArmed: controller.isArmed,
                onChoose: { controller.choose($0) },
                timedMinutes: controller.selectedTimedMinutes,
                onTimedMinutesChange: { controller.setTimedMinutes($0) }
            )
            // A new prompt is a new card (resets hover and the countdown).
            .id(controller.promptSerial)
        }
    }
}

/// Borderless non-activating panel that attaches the prompt directly under the
/// island (under the meeting nudge or the agent answer card when one is up), at
/// the island's width. A
/// separate panel like `MeetingPillPanel`, so its buttons get clicks without
/// widening the island window's hit zones. It never becomes key: the answer keys
/// come from `CaseApprovalKeyTap`.
@MainActor
final class CaseApprovalPanel: NSPanel {
    private let controller: CaseApprovalController
    private let host: CaseApprovalHostingView
    private var cancellables = Set<AnyCancellable>()

    init(controller: CaseApprovalController) {
        self.controller = controller
        host = CaseApprovalHostingView(rootView: AnyView(EmptyView()))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 312, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary, .ignoresCycle,
                              .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isMovable = false
        hidesOnDeactivate = false
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host

        controller.$current
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in self?.apply(visible: visible) }
            .store(in: &cancellables)
        AppState.shared.$meetingSuggestionActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrameIfVisible() }
            .store(in: &cancellables)
        AppState.shared.$agentAnswerCardHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrameIfVisible() }
            .store(in: &cancellables)
        for name in [NSApplication.didChangeScreenParametersNotification,
                     IslandScreenResolver.selectionDidChangeNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshFrameIfVisible() }
                .store(in: &cancellables)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Gap between the agent answer card and the prompt under it.
    static let agentCardGap: CGFloat = 6

    /// Where the card goes: centered under the island, below the meeting nudge or
    /// the agent answer card (which hangs `agentWingGap` under the island) if shown.
    /// The built-in agent running `whytap case run` shows both at once.
    static func frame(islandFrame: NSRect, cardHeight: CGFloat, meetingNudgeVisible: Bool,
                      agentAnswerHeight: CGFloat = 0) -> NSRect {
        let nudge = meetingNudgeVisible ? MeetingPillPanel.suggestionNudgeHeight : 0
        let agent = agentAnswerHeight > 0
            ? IslandFrameLayout.agentWingGap + agentAnswerHeight + agentCardGap : 0
        let top = islandFrame.minY - max(nudge, agent)
        return NSRect(x: islandFrame.midX - islandFrame.width / 2, y: top - cardHeight,
                      width: islandFrame.width, height: cardHeight)
    }

    private func apply(visible: Bool) {
        if visible {
            sharingType = PrivacyPreferences.shared.screenshotProtectionEnabled ? .none : .readOnly
            refreshFrame()
            orderFrontRegardless()
        } else {
            orderOut(nil)
        }
    }

    private func refreshFrameIfVisible() {
        guard isVisible else { return }
        refreshFrame()
    }

    private func refreshFrame() {
        let islandFrame = IslandFrameLayout.islandFrame(on: IslandScreenResolver.currentDescriptor())
        host.rootView = AnyView(CaseApprovalHostView(controller: controller, width: islandFrame.width))
        let height = ceil(host.fittingSize.height)
        let target = Self.frame(islandFrame: islandFrame, cardHeight: max(height, 1),
                                meetingNudgeVisible: AppState.shared.meetingSuggestionActive,
                                agentAnswerHeight: AppState.shared.agentAnswerCardHeight)
        setFrame(target, display: true, animate: false)
        host.frame = NSRect(origin: .zero, size: target.size)
    }
}

/// Takes the first click even though the panel is never key, so a button answers
/// on the first press.
private final class CaseApprovalHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
