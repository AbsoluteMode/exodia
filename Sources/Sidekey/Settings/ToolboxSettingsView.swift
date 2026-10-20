// Sources/Sidekey/Settings/ToolboxSettingsView.swift
import SwiftUI

/// Settings -> Toolbox tab. Three-pane layout:
///   Top: chosen tools and one permanent empty add target
///   Left: catalog of all non-Settings tools (draggable + clickable)
///   Right: action / panel for the selected tool
@MainActor
struct ToolboxSettingsView: View {

    @ObservedObject var hoverStore: HoverLayoutStore
    @ObservedObject var selection: SettingsWindowSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Live hotkey config so the Drop-mode caption names the real Drop
    // trigger (post-cutover: "Hold Space") instead of a hardcoded ⌥ /.
    @ObservedObject private var hotkeys: HotkeyPreferences = .shared
    let deps: ToolboxDeps

    @State private var selectedTool: HoverTool? = nil
    @State private var hoveredTool: HoverTool? = nil
    @StateObject private var vocabVM: IslandVocabularyViewModel
    @StateObject private var fillerVM: IslandFillerViewModel
    @StateObject private var caseVM: CaseViewModel
    @State private var dropMode: TranscriptionMode
    @State private var selectedInputLanguage: AppLanguage?
    @State private var selectedOutputLanguage: AppLanguage?

    init(hoverStore: HoverLayoutStore, selection: SettingsWindowSelection, deps: ToolboxDeps) {
        self.hoverStore = hoverStore
        self.selection = selection
        self.deps = deps
        _vocabVM = StateObject(wrappedValue: IslandVocabularyViewModel(
            vocabulary: deps.vocabulary()))
        _fillerVM = StateObject(wrappedValue: IslandFillerViewModel())
        _caseVM = StateObject(wrappedValue: CaseViewModel(service: .shared))
        _dropMode = State(initialValue: deps.currentDropMode())
        _selectedInputLanguage = State(initialValue: deps.currentLanguage())
        _selectedOutputLanguage = State(initialValue: deps.currentTargetLanguage())
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                hoverRow
                HStack(alignment: .top, spacing: 16) {
                    catalogPane
                        .frame(maxWidth: .infinity)
                    rightPane
                        .frame(width: 300)
                }
                .frame(minHeight: 300)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Hover Row

    private var hoverRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR HOVER")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.42))

            ToolboxHoverEditor(hoverStore: hoverStore, reduceMotion: reduceMotion) { item in
                switch item {
                case .tool(let tool):
                    hoverSlotTile(tool: tool)
                case .add:
                    ToolboxAddTile()
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    )
            )

            toolHoverDescription
        }
    }

    @ViewBuilder
    private func hoverSlotTile(tool: HoverTool) -> some View {
        let isLocked = tool == .settings
        let info = HoverToolRegistry.info(for: tool)
        let isSelected = selectedTool == tool

        let tile = ToolboxTileView(
            title: info.title,
            sfSymbol: info.sfSymbol,
            isSelected: isSelected,
            isLocked: isLocked,
            isAdded: false,
            badge: languageBadge(for: tool),
            onTap: { handleToolTap(tool) }
        )
        .help(toolDescription(for: tool))
        .onHover { hovering in
            updateHoveredTool(tool, hovering: hovering)
        }
        ZStack(alignment: .topTrailing) {
            if isLocked {
                tile
            } else {
                tile.draggable(tool.rawValue)
                Button {
                    hoverStore.removeTool(tool)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color(white: 0.18)))
                }
                .buttonStyle(.plain)
                .help("Remove \(info.title) from hover")
                .accessibilityLabel("Remove \(info.title) from hover")
                .offset(x: 6, y: -4)
            }
        }
    }

    // MARK: - Catalog

    private var catalogPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TOOLBOX")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.42))

            let catalogTools = HoverTool.allCases.filter { $0 != .settings }

            ScrollView(.vertical, showsIndicators: false) {
                let columns = [GridItem(.adaptive(minimum: 70, maximum: 90), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(catalogTools, id: \.self) { tool in
                        catalogTile(tool)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
    }

    @ViewBuilder
    private func catalogTile(_ tool: HoverTool) -> some View {
        let info = HoverToolRegistry.info(for: tool)
        let isInHover = hoverStore.slots.contains(tool)
        let isSelected = selectedTool == tool

        ToolboxTileView(
            title: info.title,
            sfSymbol: info.sfSymbol,
            isSelected: isSelected,
            isLocked: false,
            isAdded: isInHover,
            badge: languageBadge(for: tool),
            onTap: { handleToolTap(tool) }
        )
        .draggable(tool.rawValue) {
            ToolboxTileView(title: info.title, sfSymbol: info.sfSymbol,
                            isSelected: false, isLocked: false, isAdded: false,
                            onTap: {})
                .opacity(0.85)
        }
        .help(toolDescription(for: tool))
        .onHover { hovering in
            updateHoveredTool(tool, hovering: hovering)
        }
        .disabled(isInHover)
        .contextMenu {
            Button("Add to hover") {
                hoverStore.placeTool(tool, at: hoverStore.lockSlotIndex)
            }
            .disabled(isInHover)
        }
        .opacity(isInHover ? 0.45 : 1)
        .overlay(alignment: .topTrailing) {
            if isInHover {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(4)
                    .background(Circle().fill(Color.white.opacity(0.18)))
                    .offset(x: 4, y: -4)
            }
        }
    }

    private var toolHoverDescription: some View {
        Group {
            if let tool = hoveredTool {
                let description = toolDescription(for: tool)
                Text(description)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
                .transition(.opacity)
            } else {
                Text("Drag tools into the empty slot to add them, or onto another tool to reorder. Settings stays pinned.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .animation(.easeInOut(duration: 0.14), value: hoveredTool)
    }

    // MARK: - Right Pane

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACTION")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(.white.opacity(0.42))

            ZStack {
                if let tool = selectedTool {
                    rightPaneContent(for: tool)
                } else {
                    rightPanePlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.035))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    )
            )
        }
    }

    private var rightPanePlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.white.opacity(0.25))
            Text("Select a tool to use it here")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rightPaneContent(for tool: HoverTool) -> some View {
        let info = HoverToolRegistry.info(for: tool)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 32, height: 32)
                    Image(systemName: info.sfSymbol)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(info.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            switch tool {
            case .vocab:
                IslandVocabularyEditorPanel(viewModel: vocabVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .filler:
                IslandFillerEditorPanel(viewModel: fillerVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .caseVault:
                IslandCaseVaultPanel(viewModel: caseVM)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .inputLang:
                IslandLanguagePickerPanel(
                    selectedLanguage: selectedInputLanguage,
                    onSelectLanguage: { language in
                        selectedInputLanguage = language
                        deps.setLanguage(language)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .outputLang:
                IslandLanguagePickerPanel(
                    selectedLanguage: selectedOutputLanguage,
                    leadingOption: IslandLanguageControl.offOption(),
                    onSelectLanguage: { language in
                        selectedOutputLanguage = language
                        deps.setTargetLanguage(language)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .dropMode:
                dropModePane
            case .notifs:
                NotifyHoverPanel(showsBackButton: false, onBack: {})
            case .clipboard:
                clipboardPane
            case .brightness:
                ToolboxDisplayPane()
            case .hotkeys, .notes, .meetingRecord, .monitor, .translate, .subtitles, .screenshot, .quit, .settings:
                Color.clear
            }
        }
        .animation(.easeInOut(duration: 0.16), value: tool)
    }

    /// Config-driven Drop trigger label for the caption — e.g. "Hold Space"
    /// (post-cutover) or "Toggle ⌥ /" for a tap-combo binding. Sourced from
    /// `normalizedDropGesture` + `dropVoiceShortcut` so it tracks the live
    /// binding and never shows stale `.holdSpace`+`.tap` state.
    private var dropTriggerLabel: String {
        let gesture = hotkeys.configuration.normalizedDropGesture.voiceTitle
        let keys = hotkeys.dropVoiceShortcut.shortcutChipTitles.joined(separator: " ")
        return "\(gesture) \(keys)"
    }

    private var dropModePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcription speed for Drop (\(dropTriggerLabel)).")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ForEach([TranscriptionMode.fast, .smart], id: \.rawValue) { mode in
                    Button {
                        guard deps.currentDropMode() != mode else { return }
                        _ = deps.toggleDropMode()
                        dropMode = deps.currentDropMode()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode == .fast ? "bolt" : "sparkles")
                                .font(.system(size: 12, weight: .medium))
                            Text(mode == .fast ? "Fast" : "Smart")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(dropMode == mode ? .white : .white.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(dropMode == mode
                                      ? Color.white.opacity(0.18)
                                      : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    dropMode == mode
                                        ? Color.white.opacity(0.3)
                                        : Color.white.opacity(0.1),
                                    lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolDescription(for tool: HoverTool) -> String {
        HoverToolRegistry.description(
            for: tool,
            mode: dropMode,
            inputLanguage: selectedInputLanguage,
            outputLanguage: selectedOutputLanguage
        )
    }

    private func languageBadge(for tool: HoverTool) -> String? {
        let language: AppLanguage?
        switch tool {
        case .inputLang:
            language = selectedInputLanguage
        case .outputLang:
            language = selectedOutputLanguage
        default:
            return nil
        }

        guard let language else { return nil }
        return IslandLanguageControl.languageCodeBadge(for: language)
    }

    private var clipboardPane: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
            Text("Opens the Clipboard strip.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
            Button("Open Clipboard") {
                deps.openClipboard()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12)))
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tap handling

    private func handleToolTap(_ tool: HoverTool) {
        let kind = HoverToolRegistry.info(for: tool).kind
        if case .navigate(let target) = kind {
            selection.setHighlight(target)
            selectedTool = nil
        } else {
            selectedTool = (selectedTool == tool) ? nil : tool
        }
    }

    private func updateHoveredTool(_ tool: HoverTool, hovering: Bool) {
        if hovering {
            hoveredTool = tool
        } else if hoveredTool == tool {
            hoveredTool = nil
        }
    }
}

// MARK: - Hover editor

enum ToolboxHoverEditorItem: Hashable {
    case tool(HoverTool)
    case add
}

/// The editor owns transient drop feedback; only a completed drop changes the
/// persisted layout. Kept separate from the tool panels so the grid can also be
/// hosted without initializing their stores.
@MainActor
struct ToolboxHoverEditor<Tile: View>: View {
    @ObservedObject var hoverStore: HoverLayoutStore
    let reduceMotion: Bool
    @State private var targetedItem: ToolboxHoverEditorItem?
    private let tile: (ToolboxHoverEditorItem) -> Tile

    init(hoverStore: HoverLayoutStore, reduceMotion: Bool,
         @ViewBuilder tile: @escaping (ToolboxHoverEditorItem) -> Tile) {
        self.hoverStore = hoverStore
        self.reduceMotion = reduceMotion
        self.tile = tile
    }

    private var items: [ToolboxHoverEditorItem] {
        // Match the insertion index used by the store: a new tool occupies the
        // old Add position, while the permanent Add and Settings move together.
        hoverStore.slots.filter { $0 != .settings }.map(ToolboxHoverEditorItem.tool)
            + [.add, .tool(.settings)]
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                count: HoverLayoutStore.columns), spacing: 16) {
            ForEach(items, id: \.self) { item in
                editorCell(item)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: hoverStore.slots)
    }

    private func editorCell(_ item: ToolboxHoverEditorItem) -> some View {
        ToolboxNativeDropTarget(
            targetID: item,
            isEnabled: item != .tool(.settings),
            validate: { raw in acceptsDrop(raw, onto: item) },
            onTarget: { isTargeted in
                if isTargeted {
                    targetedItem = item
                } else if targetedItem == item {
                    targetedItem = nil
                }
            },
            onDrop: { raw in commitDrop([raw], onto: item) }
        ) {
            tile(item)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(targetedItem == item ? 0.12 : 0))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(targetedItem == item ? 0.7 : 0),
                                              lineWidth: 1.5)
                        }
                        .padding(-4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.1),
                                   value: targetedItem == item)
                }
        }
    }

    private func acceptsDrop(_ raw: String, onto item: ToolboxHoverEditorItem) -> Bool {
        guard let tool = HoverTool(rawValue: raw), tool != .settings else { return false }
        switch item {
        case .add: return true
        case .tool(let target): return target != .settings && hoverStore.slots.contains(target)
        }
    }

    private func commitDrop(_ items: [String], onto item: ToolboxHoverEditorItem) -> Bool {
        targetedItem = nil
        guard let raw = items.first, let tool = HoverTool(rawValue: raw), tool != .settings else { return false }
        let index: Int
        switch item {
        case .add:
            index = hoverStore.lockSlotIndex
        case .tool(let target):
            guard target != .settings,
                  let targetIndex = hoverStore.slots.firstIndex(of: target) else { return false }
            index = targetIndex
        }
        // A validated drop onto the same position is still accepted. The store
        // skips unchanged arrays, so this avoids both a save and a failed-drop
        // return animation for self/end drops.
        hoverStore.placeTool(tool, at: index)
        return true
    }
}

@MainActor
struct ToolboxAddTile: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .light))
                .frame(width: 56, height: 56)
                .background(Circle().strokeBorder(Color.white.opacity(0.22),
                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            Text("ADD TOOL")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .frame(width: 56, height: 26)
        }
        .foregroundStyle(.white.opacity(0.45))
        .contentShape(Rectangle())
        .help("Drag a tool here to add it to your hover")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop a tool here to add it to hover")
    }
}

// MARK: - ToolboxTileView

/// Reusable circular tile used in both the hover row and the catalog.
@MainActor
struct ToolboxTileView: View {
    let title: String
    let sfSymbol: String
    let isSelected: Bool
    let isLocked: Bool
    let isAdded: Bool
    let badge: String?
    let onTap: () -> Void

    private static let tileSize: CGFloat = 56

    init(
        title: String,
        sfSymbol: String,
        isSelected: Bool,
        isLocked: Bool,
        isAdded: Bool,
        badge: String? = nil,
        onTap: @escaping () -> Void
    ) {
        self.title = title
        self.sfSymbol = sfSymbol
        self.isSelected = isSelected
        self.isLocked = isLocked
        self.isAdded = isAdded
        self.badge = badge
        self.onTap = onTap
    }

    var body: some View {
        // Intentionally NOT a `Button`: `.draggable(_:)` over a `Button` does
        // not initiate a drag session on macOS 15 (Apple regression
        // FB14518001), which broke dragging catalog tiles onto hover slots.
        // A plain tappable view coexists with `.draggable`; the `.isButton`
        // trait restores VoiceOver semantics the Button gave us for free.
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isSelected
                          ? Color.white.opacity(0.18)
                          : Color.white.opacity(0.07))
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected
                                          ? Color.white.opacity(0.55)
                                          : Color.white.opacity(0.11),
                                          lineWidth: 1)
                    )
                    .frame(width: Self.tileSize, height: Self.tileSize)

                Image(systemName: sfSymbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(isAdded ? 0.5 : 0.88))

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.4)
                        .foregroundStyle(Color.black.opacity(0.78))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 18, minHeight: 14)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.92))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5)
                                )
                        )
                        .offset(x: Self.tileSize * 0.31, y: -Self.tileSize * 0.34)
                        .allowsHitTesting(false)
                }

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(3)
                        .background(Circle()
                            .fill(Color(red: 0.11, green: 0.11, blue: 0.14))
                            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1)))
                        .offset(x: Self.tileSize * 0.31, y: Self.tileSize * 0.31)
                }
            }

            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(width: Self.tileSize, height: 26)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
