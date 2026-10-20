import Combine
import SwiftUI

enum AIUsagePeriod: String, CaseIterable, Identifiable {
    case today, week, month, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .today: return "Today"; case .week: return "Last 7 days"
        case .month: return "This month"; case .custom: return "Custom dates…" }
    }
    func interval(now: Date, start: Date, end: Date, calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        let first: Date
        let last: Date
        switch self {
        case .today: first = today; last = today
        case .week: first = calendar.date(byAdding: .day, value: -6, to: today)!; last = today
        case .month: first = calendar.dateInterval(of: .month, for: today)!.start; last = today
        case .custom: first = calendar.startOfDay(for: start); last = calendar.startOfDay(for: end)
        }
        guard first <= last, last <= today,
              let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return DateInterval(start: first, end: exclusiveEnd)
    }
}

struct AIUsageTotal {
    let events: [AIUsageEvent]
    let currency: AIUsageCurrency
    private var matching: [AIUsageEvent] { events.filter { $0.currency == currency } }
    var amount: Double { matching.compactMap(\.amount).reduce(0, +) }
    var estimated: Bool { matching.contains { $0.basis == .estimated } }
    var incomplete: Bool { matching.contains { $0.amount == nil } }
    var text: String {
        guard !matching.isEmpty else { return "—" }
        guard matching.contains(where: { $0.amount != nil }) else { return "Unavailable" }
        let number: String
        if currency == .usd {
            if amount > 0 && amount < 0.0001 { number = "< $0.0001" }
            else { number = String(format: amount > 0 && amount < 0.01 ? "$%.4f" : "$%.2f", amount) }
        } else {
            number = amount > 0 && amount < 0.1 ? "< 0.1" : amount.formatted(.number.precision(.fractionLength(0...1)))
        }
        return (estimated ? "≈ " : "") + number + (incomplete ? " +" : "")
    }
}

/// One Price column, with each unit retained even when a feature has used
/// both providers. Different currencies are never added to one number.
struct AIUsagePrice {
    let events: [AIUsageEvent]
    var text: String {
        [AIUsageCurrency.usd, .elevenLabsCredits].compactMap { currency -> String? in
            let matching = events.filter { $0.currency == currency }
            guard !matching.isEmpty else { return nil }
            let total = AIUsageTotal(events: matching, currency: currency).text
            if total == "Unavailable" { return currency == .usd ? "USD unavailable" : "Credits unavailable" }
            return total + (currency == .elevenLabsCredits ? " credits" : "")
        }.joined(separator: "\n")
    }
}

struct AIUsageCostRow: Identifiable {
    let title: String
    let events: [AIUsageEvent]
    var id: String { title }
    var models: [AIUsageModelRow] {
        Dictionary(grouping: events, by: { $0.context.account.storageID + "|" + $0.context.model })
            .map { AIUsageModelRow(id: $0.key, events: $0.value) }
            .sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
    }
    static func grouped(_ events: [AIUsageEvent]) -> [Self] {
        FeatureGroup.layout.compactMap { group in
            let used = events.filter { group.features.contains($0.context.feature) }
            return used.isEmpty ? nil : Self(title: group.title, events: used)
        }
    }
}

struct AIUsageModelRow: Identifiable {
    let id: String
    let events: [AIUsageEvent]
    var model: String { events[0].context.model }
    var provider: String { events[0].context.account.kind.displayName }
    var currency: AIUsageCurrency { events[0].currency }
    var total: String { AIUsageTotal(events: events, currency: currency).text + (currency == .elevenLabsCredits ? " credits" : "") }
}

@MainActor
final class AIUsageCostsViewModel: ObservableObject {
    @Published var period: AIUsagePeriod = .month
    @Published var start = Calendar.current.dateInterval(of: .month, for: Date())!.start
    @Published var end = Date()
    @Published private(set) var events: [AIUsageEvent] = []
    @Published private(set) var loading = true
    @Published private(set) var failed = false
    @Published private(set) var loadedInterval: DateInterval?
    @Published private(set) var billing: ElevenLabsBillingUsage?
    @Published private(set) var billingLoading = false
    @Published private(set) var billingError: String?
    let store: AIUsageStore
    private let loadBilling: (DateInterval) async throws -> ElevenLabsBillingUsage?
    private var generation = UUID()
    init(store: AIUsageStore,
         loadBilling: @escaping (DateInterval) async throws -> ElevenLabsBillingUsage? = AIUsageRecorder.billingUsage) {
        self.store = store; self.loadBilling = loadBilling
    }
    var pricedEvents: [AIUsageEvent] { events.map { billing?.estimating($0) ?? $0 } }
    func beginVisit() { period = .month }
    func load(_ interval: DateInterval) async {
        let token = UUID(); generation = token
        if loadedInterval != interval { billing = nil }
        loading = true; billingError = nil; billingLoading = true
        do {
            let result = try await store.events(from: interval.start, to: interval.end)
            guard generation == token, !Task.isCancelled else { return }
            events = result; loadedInterval = interval; failed = false; loading = false
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            failed = true; loading = false
        }
        do {
            let result = try await loadBilling(interval)
            guard generation == token, !Task.isCancelled else { return }
            billing = result; billingLoading = false
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            billingError = (error as? ElevenLabsBillingError)?.message ?? "Couldn’t reach ElevenLabs. Try again."
            billingLoading = false
        }
    }
}

/// One surface with a nearby period control, feature totals and contextual
/// model detail. No current-route lookup: every row comes from recorded usage.
@MainActor
struct AIUsageCostsView: View {
    @ObservedObject var model: AIUsageCostsViewModel
    let now: () -> Date
    init(model: AIUsageCostsViewModel, now: @escaping () -> Date = Date.init) { self.model = model; self.now = now }
    private var interval: DateInterval? { model.period.interval(now: now(), start: model.start, end: model.end) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 12) {
                        Text("Costs").font(.system(size: 15, weight: .semibold))
                        MacPopup(items: AIUsagePeriod.allCases.map { .init(value: $0, label: $0.title) },
                                 selection: $model.period, minWidth: 140, maxWidth: 180)
                            .accessibilityLabel("Cost period")
                        Spacer(minLength: 0)
                        AIUsageRefreshButton(isEnabled: !model.loading && !model.billingLoading) {
                            Task { await refresh() }
                        }
                    }
                    if let interval {
                        Text(dateLabel(interval)).font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
                    }
                    if model.period == .custom {
                        HStack(spacing: 16) {
                            AIUsageDateControl(title: "From", date: $model.start, latest: now())
                            AIUsageDateControl(title: "To", date: $model.end, latest: now())
                        }.font(.system(size: 12))
                    }
                    if interval == nil {
                        Text("Choose an end date on or after the start date.").foregroundStyle(MacSettingsTheme.red)
                    }
                }.padding(18)

                if model.failed {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Couldn’t load cost history.")
                        Button("Retry") { Task { await refresh() } }
                    }.padding(18)
                } else if interval != nil && (model.loading || model.loadedInterval != interval) {
                    ProgressView("Loading usage…").padding(24)
                } else if interval != nil {
                    if model.events.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No activity in this period").font(.system(size: 13, weight: .medium))
                            Text("Usage is recorded from this update onward. Earlier spending is not included.")
                                .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
                        }.padding(18)
                    } else {
                        table
                    }
                }
                if interval != nil { billingSection }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(MacSettingsTheme.text)
        .task { await refresh() }
        .onChange(of: model.period) { _, _ in Task { await refresh() } }
        .onChange(of: model.start) { _, _ in Task { await refresh() } }
        .onChange(of: model.end) { _, _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: AIUsageStore.changed)) { _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.didStartVisit)) { _ in
            if model.period == .month { Task { await refresh() } }
            else { model.beginVisit() }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Feature").frame(maxWidth: .infinity, alignment: .leading)
                Text("Price").frame(width: 190, alignment: .trailing)
            }.font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2).padding(.horizontal, 18).padding(.vertical, 10)
            divider
            ForEach(AIUsageCostRow.grouped(model.pricedEvents)) { row in
                AIUsageFeatureCostRow(row: row)
                divider
            }
            HStack(spacing: 12) {
                Text("Total").frame(maxWidth: .infinity, alignment: .leading)
                AIUsagePriceLabel(events: model.pricedEvents)
            }.font(.system(size: 13, weight: .semibold)).monospacedDigit().padding(18)
        }
    }
    private var billingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.billingLoading {
                ProgressView("Checking ElevenLabs usage…").controlSize(.small)
            } else if let error = model.billingError {
                Text("ElevenLabs usage").font(.system(size: 13, weight: .semibold))
                Text(error).font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
            } else if let billing = model.billing {
                divider
                Text("ElevenLabs · Reported usage").font(.system(size: 13, weight: .semibold))
                Text("Workspace usage by API key for this period. Includes other apps; separate from feature estimates.")
                    .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
                if billing.rows.isEmpty {
                    Text("No reported usage in this period.").font(.system(size: 12))
                } else {
                    ForEach(billing.rows) { row in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.keyName).font(.system(size: 12, weight: .medium))
                                Text(row.model).font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
                                    .textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.credits.formatted(.number.precision(.fractionLength(0...1))) + " credits")
                                .font(.system(size: 13)).monospacedDigit()
                        }.padding(.vertical, 4)
                    }
                    HStack {
                        Text("ElevenLabs total")
                        Spacer()
                        Text(billing.credits.formatted(.number.precision(.fractionLength(0...1))) + " credits")
                    }.font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
            }
        }.padding(18)
    }
    private var divider: some View { Rectangle().fill(MacSettingsTheme.rowSeparator).frame(height: 0.5) }
    private func refresh() async { if let interval { await model.load(interval) } }
    private func dateLabel(_ interval: DateInterval) -> String {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: interval.end)!
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted)
        return interval.start.formatted(format) + " – " + last.formatted(format)
    }
}

@MainActor
private struct AIUsageRefreshButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button("Refresh", action: action)
            .buttonStyle(AIUsageRefreshStyle(hovered: hovered, focused: focused))
            .focused($focused)
            .disabled(!isEnabled)
            .onHover { hovered = isEnabled && $0 }
            .onChange(of: isEnabled) { _, enabled in if !enabled { hovered = false } }
    }
}

struct AIUsageRefreshStyle: ButtonStyle {
    let hovered: Bool
    let focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(MacSettingsTheme.text)
            .background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .fill(MacSettingsTheme.text.opacity(isEnabled ? (configuration.isPressed ? 0.16 : (hovered ? 0.08 : 0)) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isEnabled && focused ? MacSettingsTheme.accent : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.42)
    }
}

@MainActor
private struct AIUsageFeatureCostRow: View {
    let row: AIUsageCostRow
    @State private var shown = false
    @State private var hovered = false
    @State private var pinned = false
    @State private var closeTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 12) {
            Button {
                pinned.toggle(); shown = pinned
            } label: {
                HStack(spacing: 9) {
                    Text(row.title).font(.system(size: 13, weight: .medium))
                    Text("\(row.models.count) \(row.models.count == 1 ? "model" : "models")")
                        .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
                }
                .padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focused($focused)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? MacSettingsTheme.accent : .clear, lineWidth: 1.5) }
            .accessibilityLabel("\(row.title), \(row.models.count) models used. Show model costs")
            .onHover { inside in
                hovered = inside
                closeTask?.cancel()
                if inside { shown = true } else { scheduleClose() }
            }
            .onChange(of: focused) { _, value in
                if value { shown = true } else { scheduleClose() }
            }
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                AIUsageModelsPopover(row: row)
                    .onHover { inside in closeTask?.cancel(); if !inside { scheduleClose() } }
                    .onExitCommand { shown = false; pinned = false }
            }
            Spacer(minLength: 0)
            AIUsagePriceLabel(events: row.events)
        }
        .font(.system(size: 13)).monospacedDigit().padding(.horizontal, 18).padding(.vertical, 10)
        .background(hovered ? MacSettingsTheme.hover : .clear)
        .onChange(of: shown) { _, value in if !value { pinned = false } }
        .onExitCommand { shown = false; pinned = false }
        .onDisappear { closeTask?.cancel() }
    }
    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, !hovered, !focused, !pinned else { return }
            shown = false
        }
    }
}

private struct AIUsagePriceLabel: View {
    let events: [AIUsageEvent]
    var body: some View {
        Text(AIUsagePrice(events: events).text)
            .multilineTextAlignment(.trailing)
            .frame(width: 190, alignment: .trailing)
            .help("≈ Estimated cost. ElevenLabs uses recorded audio time × reported credits per minute for that model. + Additional calls have no usable price. Credits are separate from USD.")
    }
}

/// A calendar popover avoids NSDatePicker's persistent selected text segment.
/// Its closed control shares the period menu's geometry, fill and typography.
@MainActor
struct AIUsageDateControl: View {
    let title: String
    @Binding var date: Date
    let latest: Date
    @State private var presented = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Button { presented.toggle() } label: {
                MacPopupLabel(title: date.formatted(date: .numeric, time: .omitted), minWidth: 116, maxWidth: 136)
            }
            .buttonStyle(.plain)
            .focused($focused)
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? MacSettingsTheme.accent : .clear, lineWidth: 1.5) }
            .accessibilityLabel("\(title) date")
            .accessibilityValue(date.formatted(date: .complete, time: .omitted))
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                AIUsageDateCalendar(title: title, date: $date, latest: latest) { presented = false }
            }
        }
        .onExitCommand { presented = false }
    }
}

@MainActor
struct AIUsageDateCalendar: View {
    let title: String
    @Binding var date: Date
    let latest: Date
    let close: () -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            DatePicker(title, selection: $date, in: ...latest, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .onChange(of: date) { _, _ in close() }
        .onExitCommand(perform: close)
    }
}

@MainActor
struct AIUsageModelsPopover: View {
    let row: AIUsageCostRow
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(row.title) · Models used").font(.system(size: 12.5, weight: .semibold)).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(row.models) { item in
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.model).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                                Text(item.provider).font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
                                if item.events.contains(where: { $0.audioSeconds > 0 }) {
                                    Text((item.events.reduce(0) { $0 + $1.audioSeconds } / 60).formatted(.number.precision(.fractionLength(0...2))) + " min recorded")
                                        .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(item.total).font(.system(size: 12)).monospacedDigit().multilineTextAlignment(.trailing)
                        }.padding(.vertical, 10)
                        if item.id != row.models.last?.id { Divider() }
                    }
                }
            }.frame(height: min(320, CGFloat(row.models.count) * 76))
            if row.events.contains(where: { $0.amount == nil }) {
                Text("The provider did not report a usable price. These calls are excluded from the numeric total.")
                    .font(.system(size: 11.5)).foregroundStyle(MacSettingsTheme.text2).padding(.top, 9)
            }
        }.padding(16).frame(width: 390).foregroundStyle(MacSettingsTheme.text)
    }
}
