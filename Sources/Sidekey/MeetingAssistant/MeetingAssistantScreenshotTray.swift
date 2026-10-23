import AppKit
import SwiftUI

struct MeetingAssistantAttachButton: View {
    @ObservedObject var model: MeetingAssistantModel
    var body: some View {
        Button { model.lookAtScreen() } label: {
            HStack(spacing: 4) {
                if model.screenBusy {
                    ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "camera").font(.system(size: 10)).frame(width: 12, height: 12)
                }
                Text("Прикрепить скрин").font(.system(size: 10)).fixedSize()
            }
        }
        .buttonStyle(MeetingAssistantButtonStyle())
        .disabled(model.screenBusy || model.screenshots.count >= MeetingAssistantModel.screenshotLimit)
        .help(model.screenshots.count >= MeetingAssistantModel.screenshotLimit ? "Прикреплено 6 из 6 скринов. Удали один, чтобы добавить новый." : "Сделать и прикрепить снимок текущего экрана")
        .accessibilityLabel("Прикрепить скриншот экрана")
    }
}

struct MeetingAssistantScreenshotTray: View {
    @ObservedObject var model: MeetingAssistantModel
    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(Array(model.screenshots.enumerated()), id: \.element.id) { index, attachment in
                        ZStack(alignment: .topTrailing) {
                            Button { model.mutate { model.previewScreenshot = attachment } } label: {
                                Image(nsImage: attachment.image).resizable().scaledToFill()
                                    .frame(width: 64, height: 42)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                            }
                            .buttonStyle(MeetingAssistantButtonStyle())
                            .accessibilityLabel("Открыть скриншот \(index + 1)")
                            Button { model.removeScreenshot(attachment.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 12, height: 16)
                            }
                            .buttonStyle(MeetingAssistantButtonStyle())
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .offset(x: 1, y: -2)
                            .help("Удалить скриншот")
                            .accessibilityLabel("Удалить скриншот \(index + 1)")
                        }
                        .frame(width: 76, height: 54)
                        .padding(.top, 3)
                        .id(attachment.id)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .frame(minWidth: 328, alignment: .trailing)
                .padding(.horizontal, 3)
            }
            .frame(height: 62)
            .onChange(of: model.screenshots.map(\.id)) { old, new in
                if new.count > old.count, let last = new.last {
                    withAnimation(model.animation) { reader.scrollTo(last, anchor: .trailing) }
                }
            }
        }
        .popover(item: $model.previewScreenshot, arrowEdge: .bottom) { attachment in
            VStack(alignment: .leading, spacing: 10) {
                Image(nsImage: attachment.image).resizable().scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 330)
                HStack {
                    Text("Скриншот")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Удалить") { model.removeScreenshot(attachment.id) }
                        .buttonStyle(MeetingAssistantButtonStyle()).font(.system(size: 11))
                }
            }
            .padding(12)
            .frame(width: 520)
            .background(MeetingAssistantProtectedWindow(enabled: model.screenshotProtected).frame(width: 0, height: 0))
        }
    }
}
