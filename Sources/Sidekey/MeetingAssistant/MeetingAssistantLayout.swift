import AppKit
import SwiftUI

struct MeetingAssistantProtectedWindow: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> PolicyView { PolicyView(enabled: enabled) }
    func updateNSView(_ view: PolicyView, context: Context) { view.enabled = enabled; view.apply() }
    final class PolicyView: NSView {
        var enabled: Bool
        init(enabled: Bool) { self.enabled = enabled; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() { window?.sharingType = enabled ? .none : .readOnly }
    }
}

enum MeetingAssistantLimits {
    static let pending = 5
    static let answers = 20
    static let conversation = 20
}

struct MeetingAssistantListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MeetingAssistantBoundedList<Content: View>: View {
    let limit: CGFloat
    let onResize: () -> Void
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 1
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .trailing, spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: MeetingAssistantListHeight.self, value: proxy.size.height)
                })
        }
        .frame(height: min(max(height, 1), limit))
        .onPreferenceChange(MeetingAssistantListHeight.self) { value in
            if abs(height - value) > 0.5 {
                height = value
                DispatchQueue.main.async { onResize() }
            }
        }
    }
}
