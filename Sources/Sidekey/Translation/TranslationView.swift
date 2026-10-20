import AppKit
import SwiftUI

struct TranslationView: View {
    @ObservedObject var text: TextTranslationModel
    @ObservedObject var subtitles: LiveSubtitleModel
    @ObservedObject var presentation: TranslationWindowController.Presentation
    let openSettings: (AIFeature) -> Void
    @FocusState private var inputFocused: Bool
    @State private var copied = false
    @State private var followsLatest = true

    private var isText: Bool { presentation.mode == .text }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 22)).foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("Translate").font(.system(size: 22, weight: .semibold))
                Spacer()
                Picker("Mode", selection: $presentation.mode) {
                    ForEach(TranslationWindowController.Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }
            if isText { textControls } else { audioControls }
            if let issue = isText ? text.issue : subtitles.issue { errorCard(issue) }
            if isText { textContent } else { subtitleContent }
            footer
        }
        .padding(22)
        .padding(.top, 24)
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: isText ? 490 : 270, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { if isText { inputFocused = true } }
        .onChange(of: presentation.mode) { _, mode in if mode == .text { inputFocused = true } }
        .onChange(of: text.result) { _, _ in copied = false }
        .onChange(of: subtitles.lines) { _, _ in copied = false }
    }

    private var textControls: some View {
        HStack(spacing: 10) {
            Label("Detect language", systemImage: "globe").foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            MacPopup(items: [.init(value: "auto", label: "Auto · RU ↔ EN")] + languageItems, selection: Binding(
                get: { if case .language(let code) = text.target { return code }; return "auto" },
                set: { text.target = $0 == "auto" ? .automatic : .language($0) }
            ), maxWidth: 210, appearance: .adaptive)
                .accessibilityLabel("Translate to")
            Spacer(minLength: 0)
            if subtitles.phase.isActive {
                Button { presentation.mode = .subtitles } label: { Image(systemName: "waveform.circle.fill") }
                    .accessibilityLabel("Show active subtitles").help("Subtitles are still listening")
            }
        }.font(.system(size: 13))
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Speech").font(.system(size: 11)).foregroundStyle(.secondary)
                    MacPopup(items: [.init(value: "auto", label: "Auto-detect")] + languageItems,
                             selection: $subtitles.sourceCode, maxWidth: 170, appearance: .adaptive)
                        .accessibilityLabel("Speech")
                        .disabled(subtitles.phase.isActive)
                }
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Translate to").font(.system(size: 11)).foregroundStyle(.secondary)
                    MacPopup(items: languageItems, selection: $subtitles.targetCode, maxWidth: 170, appearance: .adaptive)
                        .accessibilityLabel("Translate to")
                        .disabled(subtitles.phase.isActive)
                }
            }.font(.system(size: 12))
            HStack {
                Label(status, systemImage: subtitles.phase.isActive ? "waveform" : "speaker.wave.2")
                    .foregroundStyle(subtitles.phase.isActive ? Color.blue : Color.secondary)
                Spacer()
                Toggle("Original", isOn: $subtitles.showsOriginal).toggleStyle(.checkbox)
                Toggle("Follow", isOn: $followsLatest).toggleStyle(.checkbox)
            }.font(.system(size: 12))
        }
    }

    private var languageItems: [MacPopup<String>.Item] {
        AppLanguage.all.sorted { $0.englishName < $1.englishName }.map {
            .init(value: $0.code, label: $0.displayName)
        }
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR TEXT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { text.input = ""; inputFocused = true }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(text.input.isEmpty)
            }
            ZStack(alignment: .topLeading) {
                if text.input.isEmpty {
                    Text("A word, a thought, a whole paragraph…")
                        .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text.input)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 16))
                    .focused($inputFocused)
                    .accessibilityLabel("Text to translate")
            }
            .padding(10)
            .frame(minHeight: 110, maxHeight: 180)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            HStack {
                Text("TRANSLATION").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if text.isTranslating { ProgressView().controlSize(.small) }
            }
            ScrollView {
                Text(text.result.isEmpty ? (text.isTranslating ? "Translating…" : "Your translation will appear here.") : text.result)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(text.result.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            if text.input.count > TextTranslationModel.inputLimit {
                Text("Keep each translation under 12,000 characters.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var subtitleContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if subtitles.lines.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "captions.bubble").font(.system(size: 32, weight: .light)).foregroundStyle(.blue)
                            Text(subtitles.phase.isActive ? "Waiting for speech…" : "Understand what you hear")
                                .font(.system(size: 20, weight: .medium))
                            Text(subtitles.phase.isActive
                                 ? "Play audio on your Mac. If nothing arrives, check System Audio Recording in macOS Privacy & Security."
                                 : "Translate videos and calls into live subtitles. Only your Mac’s system audio is captured.")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).frame(maxWidth: 360)
                            if subtitles.phase.isActive, !subtitles.hasAudio {
                                Button("Open audio permissions") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }.font(.caption)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                    ForEach(subtitles.lines) { line in
                        VStack(alignment: .leading, spacing: 6) {
                            if subtitles.showsOriginal {
                                Text(line.source).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Text(line.translation ?? (subtitles.phase.isActive ? "Translating…" : "Translation unavailable"))
                                .font(.system(size: 21, weight: .medium))
                                .foregroundStyle(line.translation == nil ? .secondary : .primary)
                                .textSelection(.enabled)
                        }.fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                    }
                    if !subtitles.partial.isEmpty {
                        Text(subtitles.partial).font(.system(size: 13)).foregroundStyle(.tertiary)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(18)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: subtitles.lines) { _, _ in if followsLatest { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: subtitles.partial) { _, _ in if followsLatest { proxy.scrollTo("latest", anchor: .bottom) } }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                let value = isText ? text.result : subtitles.lines.compactMap(\.translation).joined(separator: "\n\n")
                guard !value.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
            }.disabled(isText ? text.result.isEmpty : !subtitles.lines.contains { $0.translation != nil })
            if !isText, !subtitles.phase.isActive, !subtitles.lines.isEmpty {
                Button("Clear") { subtitles.clear(); copied = false }
            }
            Spacer()
            if isText {
                if text.isTranslating { Button("Cancel") { text.cancel() } }
                Button("Translate") { text.translate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!text.canTranslate)
            } else if subtitles.phase == .finishing {
                ProgressView().controlSize(.small)
                Button("Cancel") { subtitles.cancel() }
            } else if subtitles.phase.isActive {
                Button(subtitles.phase == .connecting ? "Cancel" : "Stop") { subtitles.stop() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Start subtitles", systemImage: "play.fill") { subtitles.start() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var status: String {
        switch subtitles.phase {
        case .idle: return "System audio only"
        case .connecting: return "Connecting…"
        case .listening: return "Listening to system audio"
        case .finishing: return "Finishing…"
        case .failed: return "Stopped"
        }
    }

    private func errorCard(_ issue: TranslationIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(issue.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let feature = issue.feature {
                Button("API & Models") { openSettings(feature) }.controlSize(.small)
            }
        }.padding(12).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
