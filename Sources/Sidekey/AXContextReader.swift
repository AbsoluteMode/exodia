import ApplicationServices
import Foundation

/// Reads a best-effort plain-text snapshot of the *focused window* of a given
/// process via the Accessibility (AX) tree, to feed the smart-mode cleaner as
/// "additional context from the active app".
///
/// Permission: AX reading reuses the **Accessibility** TCC grant the app
/// already holds for the hotkey monitors — no new permission is requested.
///
/// Coverage is intentionally partial. Native AppKit/Catalyst apps expose rich
/// AX text (Finder, Notes, superwhisper, Mail …). Chromium/Electron surfaces
/// (browsers, Slack, Discord, VS Code, Notion) expose almost nothing unless the
/// host opts into web a11y, so `context(for:)` returns `nil` there and the
/// caller simply falls back to the app name. This is a free win where it works
/// and a silent no-op where it doesn't.
///
/// The live AX traversal is injected as `collectFragments` so the assembly
/// logic (dedup, trim, truncate, empty handling) is unit-testable without a
/// real accessibility tree.
struct AXContextReader {
    typealias FragmentCollector = (pid_t) -> [String]
    struct FormattingSnapshot: Sendable {
        let context: String?
        let documentURL: URL?
        let focusedRole: String?
    }

    /// Default upper bound on the assembled context string. Shared by the
    /// instance default and the `snapshot(forPID:)` convenience.
    static let defaultMaxCharacters = 2000

    /// Upper bound on the assembled context string. A deliberately small
    /// client-side bound on the context handed to the LLM cleanup prompt: it
    /// keeps the prompt short and limits how much on-screen text can ever
    /// leave the device when cleanup runs on the user's own provider.
    var maxCharacters: Int

    /// Pulls raw text fragments out of `pid`'s focused window. Defaults to the
    /// live AX traversal; tests inject a stub.
    var collectFragments: FragmentCollector

    init(
        maxCharacters: Int = AXContextReader.defaultMaxCharacters,
        collectFragments: @escaping FragmentCollector = AXContextReader.liveCollect
    ) {
        self.maxCharacters = maxCharacters
        self.collectFragments = collectFragments
    }

    /// The assembled active-app context for `pid`, or `nil` when nothing
    /// usable is exposed (the common case for web-based apps).
    func context(for pid: pid_t) -> String? {
        Self.assemble(collectFragments(pid), limit: maxCharacters)
    }

    /// Default wall-clock ceiling for the entire AX walk. The per-message
    /// timeout (0.5 s) and the node budget (600) each bound only one
    /// dimension — a single message and the tree size — but their product is
    /// *minutes* on an app that answers Accessibility slowly. That left the
    /// drop frozen on "thinking…" for ~55 s while the already-resolved
    /// transcript waited to be cleaned + pasted (prod, 2026-06-17). This caps
    /// the whole walk; on expiry the best-effort context is abandoned and the
    /// paste proceeds without it (the same silent no-op as a web app that
    /// exposes nothing).
    /// WHY: docs/decisions/2026-06-17-ax-context-snapshot-timeout.md
    static let defaultWalkTimeout: Duration = .seconds(1.5)

    /// Off-main, time-bounded convenience: reads `pid`'s focused-window context
    /// on a detached task so the synchronous AX traversal never runs on the
    /// caller's thread (and a hung app can't beachball the drop), and races it
    /// against `timeout` so a target app that answers AX slowly can never stall
    /// the drop. Returns `nil` when `pid` is `nil` (no known target) or when the
    /// walk does not finish within `timeout`. `collect` is injected for tests.
    static func snapshot(
        forPID pid: pid_t?,
        timeout: Duration = AXContextReader.defaultWalkTimeout,
        collect: @escaping FragmentCollector = AXContextReader.liveCollect
    ) async -> String? {
        await boundedSnapshot(forPID: pid, timeout: timeout) { pid in
            assemble(collect(pid), limit: defaultMaxCharacters)
        } ?? nil
    }

    /// Collect formatting metadata within the SAME caller deadline as text.
    /// URLs are used locally to select a fixed profile, never added to the prompt.
    static func formattingSnapshot(
        forPID pid: pid_t?,
        timeout: Duration = AXContextReader.defaultWalkTimeout,
        collect: @escaping (pid_t) -> FormattingSnapshot = liveFormattingSnapshot
    ) async -> FormattingSnapshot? {
        await boundedSnapshot(forPID: pid, timeout: timeout, collect: collect)
    }

    private static func boundedSnapshot<Value>(
        forPID pid: pid_t?, timeout: Duration, collect: @escaping (pid_t) -> Value
    ) async -> Value? {
        guard let pid else { return nil }
        // An AsyncStream lets the deadline win without waiting for synchronous
        // AX IPC to acknowledge cancellation. A task group would wait for its
        // losing child before returning. Late results are discarded.
        // WHY: docs/decisions/2026-09-07-smart-latency.md
        let results = AsyncStream<Value?> { continuation in
            let work = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return }
                let value = collect(pid)
                guard !Task.isCancelled else { return }
                continuation.yield(value)
                continuation.finish()
            }
            let timer = Task.detached {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                continuation.yield(nil)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                work.cancel()
                timer.cancel()
            }
        }
        for await value in results { return value }
        return nil
    }

    /// Trim, drop blanks, de-duplicate (first occurrence wins, order
    /// preserved), join with newlines, and truncate to `limit`. Returns `nil`
    /// when no usable text remains.
    static func assemble(_ fragments: [String], limit: Int) -> String? {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in fragments {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            kept.append(trimmed)
        }
        guard !kept.isEmpty else { return nil }

        let joined = kept.joined(separator: "\n")
        guard joined.count > limit else { return joined }

        let truncated = String(joined.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated.isEmpty ? nil : truncated
    }

    // MARK: - Live AX traversal (production default)

    static func liveFormattingSnapshot(_ pid: pid_t) -> FormattingSnapshot {
        let metadata = focusedFormattingMetadata(pid)
        return FormattingSnapshot(context: assemble(liveCollect(pid), limit: defaultMaxCharacters),
                                  documentURL: metadata.url, focusedRole: metadata.role)
    }

    private static func focusedFormattingMetadata(_ pid: pid_t) -> (url: URL?, role: String?) {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return (nil, nil) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard !Task.isCancelled else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
            return result
        }
        func element(_ object: CFTypeRef?) -> AXUIElement? {
            guard let object, CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
        func url(_ object: CFTypeRef?) -> URL? {
            if let url = object as? URL { return url }
            if let text = object as? String {
                return text.hasPrefix("/") ? URL(fileURLWithPath: text) : URL(string: text)
            }
            return nil
        }
        guard let focused = element(value(app, kAXFocusedUIElementAttribute)) else { return (nil, nil) }
        let role = value(focused, kAXRoleAttribute) as? String
        var current: AXUIElement? = focused
        for _ in 0..<16 {
            guard let node = current, !Task.isCancelled else { break }
            if value(node, kAXRoleAttribute) as? String == "AXWebArea" {
                // Read the containing document, not links mentioned in content.
                return (url(value(node, "AXURL")), role)
            }
            if let document = url(value(node, kAXDocumentAttribute)), document.isFileURL {
                return (document, role)
            }
            current = element(value(node, kAXParentAttribute))
        }
        // Some browsers expose their page only as the window's AXDocument.
        if let window = element(value(app, kAXFocusedWindowAttribute)) {
            return (url(value(window, kAXDocumentAttribute)), role)
        }
        return (nil, role)
    }

    /// Walks the focused window of `pid` collecting value/title/description
    /// strings. Synchronous and potentially slow on deep trees, so callers
    /// should invoke it off the main thread. Returns `[]` when AX is not
    /// trusted or the app exposes no focused window.
    static func liveCollect(_ pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }

        let app = AXUIElementCreateApplication(pid)
        // Bound per-message waits so an unresponsive target app can't stall the
        // drop on the default (~6s) AX timeout.
        AXUIElementSetMessagingTimeout(app, 0.5)
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            app, kAXFocusedWindowAttribute as CFString, &focusedRef
        )
        guard status == .success,
              let windowRef = focusedRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return [] }
        // swiftlint:disable:next force_cast
        let window = windowRef as! AXUIElement

        var fragments: [String] = []
        var budget = 600  // node-visit cap so a huge tree can't stall the drop

        func visit(_ element: AXUIElement) {
            // `budget` caps the tree size; `Task.isCancelled` caps the wall
            // clock — `snapshot(forPID:)` cancels this detached walk once its
            // timeout fires, so a tree that answers AX slowly stops descending
            // instead of churning for minutes after the drop has moved on.
            guard budget > 0, !Task.isCancelled else { return }
            budget -= 1

            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                guard !Task.isCancelled else { return }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let text = value as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { fragments.append(trimmed) }
                }
            }

            guard !Task.isCancelled else { return }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    guard budget > 0, !Task.isCancelled else { break }
                    visit(child)
                }
            }
        }

        visit(window)
        return fragments
    }
}
