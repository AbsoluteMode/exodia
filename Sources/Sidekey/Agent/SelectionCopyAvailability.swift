import AppKit
import ApplicationServices

/// Read-only preflight for the optional selection fallback. Never opens menus,
/// changes focus, or assumes that missing Accessibility data means Copy works.
enum SelectionCopyAvailability {
    @MainActor
    static func isCopyEnabled(targetPID: pid_t) -> Bool {
        // A nonactivating Whytap panel can own keyboard focus while another
        // application remains frontmost. Global Cmd+C would hit that panel.
        guard targetPID != ProcessInfo.processInfo.processIdentifier,
              NSApp?.keyWindow == nil else { return false }

        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        let application = AXUIElementCreateApplication(targetPID)
        guard let value = attribute(application, kAXMenuBarAttribute, deadline: deadline),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return false
        }
        let menuBar = value as! AXUIElement
        var pending: [(AXUIElement, Int)] = [(menuBar, 0)]
        var visited = 0
        while let (element, depth) = pending.popLast() {
            guard visited < 192, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            visited += 1
            if depth == 3 {
                let character = attribute(element, kAXMenuItemCmdCharAttribute, deadline: deadline) as? String
                let virtualKey = attribute(element, kAXMenuItemCmdVirtualKeyAttribute, deadline: deadline) as? NSNumber
                if character?.lowercased() == "c" || virtualKey?.intValue == 0x08,
                   isEnabledCopyCommand(
                    character: character,
                    virtualKey: virtualKey?.intValue,
                    modifiers: (attribute(element, kAXMenuItemCmdModifiersAttribute, deadline: deadline) as? NSNumber)?.intValue,
                    enabled: (attribute(element, kAXEnabledAttribute, deadline: deadline) as? NSNumber)?.boolValue
                   ) {
                    return true
                }
            }
            guard depth < 3 else { continue }
            if let children = children(element, deadline: deadline) {
                pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
            }
        }
        return false
    }

    static func isEnabledCopyCommand(character: String?, virtualKey: Int?, modifiers: Int?, enabled: Bool?) -> Bool {
        // AX uses Command by default (0), unlike NSEvent.ModifierFlags.
        // Require bare Cmd+C, never Option/Shift/Control-C or plain C.
        enabled == true && modifiers == 0 &&
            (virtualKey.map { $0 == 0x08 } ?? (character?.lowercased() == "c"))
    }

    private static func attribute(_ element: AXUIElement, _ name: String, deadline: TimeInterval) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.01)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(_ element: AXUIElement, deadline: TimeInterval) -> [AXUIElement]? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
              count > 0 else { return nil }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(count, 64), &values) == .success else {
            return nil
        }
        return values as? [AXUIElement]
    }
}
