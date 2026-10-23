import AppKit
import SwiftUI

/// Only an actual editor requests key status. Buttons on the passive panel
/// keep keyboard focus with the meeting app. Escape releases editing only.
struct MeetingAssistantInput: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var submit: () -> Void
    var focusChanged: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        field.isBezeled = false; field.drawsBackground = false
        field.font = .systemFont(ofSize: 12); field.textColor = .labelColor
        field.alignment = .left; field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
    }
    final class Field: NSTextField {
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeKey(); super.mouseDown(with: event) }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MeetingAssistantInput
        init(_ parent: MeetingAssistantInput) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focusChanged(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focusChanged(false) }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.submit(); control.window?.makeFirstResponder(nil); control.window?.resignKey(); return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                control.window?.makeFirstResponder(nil); control.window?.resignKey(); return true
            }
            return false
        }
    }
}
