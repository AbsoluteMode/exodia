import AppKit
import SwiftUI

/// Uses AppKit's documented preview handoff while keeping the existing SwiftUI
/// card (including its tap and native drag source) as the hosted content.
@MainActor
struct ToolboxNativeDropTarget<Content: View>: NSViewRepresentable {
    let targetID: ToolboxHoverEditorItem
    let isEnabled: Bool
    let validate: (String) -> Bool
    let onTarget: (Bool) -> Void
    let onDrop: (String) -> Bool
    private let content: Content

    init(
        targetID: ToolboxHoverEditorItem,
        isEnabled: Bool,
        validate: @escaping (String) -> Bool,
        onTarget: @escaping (Bool) -> Void,
        onDrop: @escaping (String) -> Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.targetID = targetID
        self.isEnabled = isEnabled
        self.validate = validate
        self.onTarget = onTarget
        self.onDrop = onDrop
        self.content = content()
    }

    func makeNSView(context: Context) -> ToolboxDropTargetView {
        let view = ToolboxDropTargetView(rootView: hostedContent(context: context))
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ToolboxDropTargetView, context: Context) {
        configure(nsView)
        nsView.rootView = hostedContent(context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ToolboxDropTargetView,
                     context: Context) -> CGSize? {
        ToolboxDropTargetView.tileSize
    }

    static func dismantleNSView(_ nsView: ToolboxDropTargetView, coordinator: ()) {
        nsView.clearDragState()
        nsView.unregisterDraggedTypes()
    }

    private func configure(_ view: ToolboxDropTargetView) {
        view.configure(targetID: targetID, isEnabled: isEnabled,
                       validate: validate, onTarget: onTarget, onDrop: onDrop)
    }

    private func hostedContent(context: Context) -> AnyView {
        let transaction = context.transaction
        return AnyView(content
            .environment(\.self, context.environment)
            .transaction { $0 = transaction })
    }
}

/// A real registered destination, rather than a mouse-transparent overlay.
/// Normal NSHostingView hit testing preserves the hosted card's clicks, remove
/// button, and `.draggable` source. No drag image is replaced or hidden by us.
@MainActor
final class ToolboxDropTargetView: NSHostingView<AnyView> {
    // ToolboxTileView and ToolboxAddTile: 56-point circle + 6 spacing + 26 label.
    static let tileSize = CGSize(width: 56, height: 88)

    private(set) var targetID: ToolboxHoverEditorItem = .add
    private(set) var isDropEnabled = false
    private var validate: (String) -> Bool = { _ in false }
    private var onTarget: (Bool) -> Void = { _ in }
    private var onDrop: (String) -> Bool = { _ in false }
    private var sequenceNumber: Int?
    private var cachedPayload: String?
    private var preparedPayload: String?
    private var isTargeted = false

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = .intrinsicContentSize
        safeAreaRegions = []
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var intrinsicContentSize: NSSize { Self.tileSize }

    func configure(
        targetID: ToolboxHoverEditorItem,
        isEnabled: Bool,
        validate: @escaping (String) -> Bool,
        onTarget: @escaping (Bool) -> Void,
        onDrop: @escaping (String) -> Bool
    ) {
        let enabled = isEnabled && targetID != .tool(.settings)
        if self.targetID != targetID || isDropEnabled != enabled {
            clearDragState()
        }
        self.targetID = targetID
        self.validate = validate
        self.onTarget = onTarget
        self.onDrop = onDrop
        if isDropEnabled != enabled {
            isDropEnabled = enabled
            if enabled {
                registerForDraggedTypes([.string])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender, refreshPayload: true)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender, refreshPayload: false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard updateTarget(sender, refreshPayload: true) == .copy,
              let payload = cachedPayload else { return false }
        // AppKit inspects this between prepare and perform. With false, it
        // removes its native image before perform imports/displays the card.
        sender.animatesToDestination = false
        preparedPayload = payload
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isDropEnabled, sequenceNumber == sender.draggingSequenceNumber,
              let payload = preparedPayload,
              sender.draggingPasteboard.string(forType: .string) == payload,
              validate(payload) else {
            clearDragState(for: sender)
            return false
        }
        clearDragState()
        return onDrop(payload)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDragState(for: sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        clearDragState(for: sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearDragState(for: sender)
    }

    func clearDragState() {
        sequenceNumber = nil
        cachedPayload = nil
        preparedPayload = nil
        setTargeted(false)
    }

    private func clearDragState(for sender: (any NSDraggingInfo)?) {
        if let sender, let sequenceNumber,
           sender.draggingSequenceNumber != sequenceNumber { return }
        clearDragState()
    }

    private func updateTarget(_ sender: any NSDraggingInfo, refreshPayload: Bool) -> NSDragOperation {
        if sequenceNumber != sender.draggingSequenceNumber {
            clearDragState()
            sequenceNumber = sender.draggingSequenceNumber
        }
        guard isDropEnabled, sender.draggingSourceOperationMask.contains(.copy) else {
            clearDragState()
            return []
        }
        let payload = refreshPayload ? sender.draggingPasteboard.string(forType: .string) : cachedPayload
        guard let payload, validate(payload) else {
            clearDragState()
            return []
        }
        cachedPayload = payload
        setTargeted(true)
        return .copy
    }

    private func setTargeted(_ targeted: Bool) {
        guard isTargeted != targeted else { return }
        isTargeted = targeted
        onTarget(targeted)
    }
}
