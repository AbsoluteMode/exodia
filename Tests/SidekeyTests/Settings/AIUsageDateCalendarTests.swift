import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

final class AIUsageCalendarMonthTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        value.firstWeekday = 2
        return value
    }
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    func testJumpingYearsAndMonthsDoesNotSelectOrOverflowLeapDay() {
        let selected = day(2024, 2, 29)
        var view = AIUsageCalendarMonth(date: selected, latest: day(2026, 10, 21), calendar: calendar)
        view.show(year: 2023, month: 2)
        XCTAssertEqual(view.start, day(2023, 2, 1))
        XCTAssertEqual(view.days.filter { calendar.isDate($0, equalTo: view.start, toGranularity: .month) }.count, 28)
        view.show(year: 2024, month: 2)
        XCTAssertTrue(view.days.contains(selected))
        XCTAssertEqual(view.days.filter { calendar.isDate($0, equalTo: view.start, toGranularity: .month) }.count, 29)
    }
    func testFutureMonthsClampAndFutureDaysCannotBeChosen() {
        var view = AIUsageCalendarMonth(date: day(2025, 12, 1), latest: day(2026, 10, 21), calendar: calendar)
        view.show(year: 2026, month: 12)
        XCTAssertEqual(view.start, day(2026, 10, 1))
        XCTAssertNil(view.shifted(1))
        XCTAssertTrue(view.allows(day(2026, 10, 21)))
        XCTAssertFalse(view.allows(day(2026, 10, 22)))
        view.show(year: 2027, month: 1)
        XCTAssertEqual(view.start, day(2026, 10, 1))
    }
    func testWeekOrderAndDayArithmeticFollowLocalCalendarAcrossDST() {
        let view = AIUsageCalendarMonth(date: day(2026, 3, 15), latest: day(2026, 10, 21), calendar: calendar)
        XCTAssertEqual(view.days.count, 42)
        XCTAssertEqual(calendar.component(.weekday, from: view.days[0]), calendar.firstWeekday)
        XCTAssertTrue(view.days.contains(day(2026, 3, 29)))
        XCTAssertTrue(view.days.contains(day(2026, 3, 30)))
        XCTAssertEqual(day(2026, 3, 30).timeIntervalSince(day(2026, 3, 29)), 23 * 3600)
    }
    func testPastYearsRemainReachableAndJanuaryNavigatesIntoPreviousYear() {
        var view = AIUsageCalendarMonth(date: day(2026, 1, 5), latest: day(2026, 10, 21), calendar: calendar)
        XCTAssertEqual(view.shifted(-1), day(2025, 12, 1))
        view.show(year: 1800, month: 5)
        XCTAssertEqual(view.start, day(1800, 5, 1))
        view.show(year: 0, month: 1)
        XCTAssertEqual(view.start, day(1800, 5, 1))
    }
}

@MainActor
final class AIUsageCalendarYearTests: XCTestCase {
    func testEditableYearAcceptsPastYearRejectsInvalidAndOffersRecentYears() throws {
        var selected: [Int] = []
        let control = AIUsageCalendarYear(year: 2026, latest: 2026) { selected.append($0) }
        let coordinator = control.makeCoordinator()
        let field = NSComboBox()
        field.stringValue = "2024"; coordinator.commit(field)
        field.stringValue = "1800"; coordinator.commit(field)
        for invalid in ["", "year", "0", "2027", "-1"] {
            field.stringValue = invalid; coordinator.commit(field)
            XCTAssertEqual(field.stringValue, "2026")
        }
        XCTAssertEqual(selected, [2024, 1800])
        field.addItems(withObjectValues: ["2025", "2024"])
        field.selectItem(at: 1)
        coordinator.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: field))
        XCTAssertEqual(selected.last, 2024)
    }

    func testReturnInYearEditorBrowsesWithoutCommittingOrClosing() throws {
        var chosen = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let original = chosen
        var closed = false
        let host = NSHostingView(rootView: AIUsageDateCalendar(title: "From", date: Binding(get: { chosen }, set: { chosen = $0 }),
            latest: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 21))!, close: { closed = true }))
        host.frame = NSRect(x: 0, y: 0, width: 310, height: 318)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 310, height: 318), styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        func find(_ node: NSView) -> NSComboBox? {
            if let field = node as? NSComboBox { return field }
            return node.subviews.compactMap(find).first
        }
        let field = try XCTUnwrap(find(host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = "2024"
        editor.insertNewline(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(chosen, original)
        XCTAssertFalse(closed)
        XCTAssertEqual(field.stringValue, "2024")
        XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
    }

    func testCalendarPicturesInBothAppearancesAndRussianLocale() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_COST_CALENDAR_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_COST_CALENDAR_RENDER_DIR for offscreen proof")
        }
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for locale in ["en_US", "ru_RU"] {
            var calendar = Calendar(identifier: .gregorian); calendar.locale = Locale(identifier: locale)
            calendar.firstWeekday = locale == "ru_RU" ? 2 : 1
            let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21))!
            let selected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
            for dark in [false, true] {
                let host = NSHostingView(rootView: AIUsageDateCalendar(title: "From", date: .constant(selected), latest: today, close: {}, calendar: calendar)
                    .background(MacSettingsTheme.bgContent).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 310, height: 318)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 310, height: 318), styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false; window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("calendar-\(locale)-\(dark ? "dark" : "light").png"))
                XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
                window.contentView = nil; window.close()
            }
        }
    }
}

@MainActor
final class AIUsageCalendarMonthFeedbackTests: XCTestCase {
    private func selector(selected: @escaping (Int) -> Void = { _ in }) -> AIUsageCalendarMonthSelector {
        AIUsageCalendarMonthSelector(items: [
            .init(value: 9, title: "September", enabled: true),
            .init(value: 10, title: "October", enabled: true),
            .init(value: 11, title: "November", enabled: false)
        ], selection: 10, select: selected)
    }
    func testNativeMonthSelectionPreservesTagsAndRejectsDisabledChoices() {
        var selected: [Int] = []
        let control = selector { selected.append($0) }
        let coordinator = control.makeCoordinator()
        let button = AIUsageCalendarMonthButton(frame: .zero, pullsDown: false)
        control.configure(button, coordinator: coordinator)
        XCTAssertFalse(button.autoenablesItems)
        XCTAssertEqual(button.selectedItem?.tag, 10)
        button.selectItem(withTag: 9); button.sendAction(button.action, to: button.target)
        button.selectItem(withTag: 11); button.sendAction(button.action, to: button.target)
        button.isEnabled = false
        button.selectItem(withTag: 10); button.sendAction(button.action, to: button.target)
        XCTAssertEqual(selected, [9])
    }
    func testNativeMonthHighlightChangesPixelsAndDisabledSuppressesItInBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["EXODIA_COST_CALENDAR_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for dark in [false, true] {
            let face = selector().frame(width: 114, height: 30).padding(4)
                .background(MacSettingsTheme.bgContent).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: face)
            host.frame = NSRect(x: 0, y: 0, width: 122, height: 38)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 122, height: 38), styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false; window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            func find(_ view: NSView) -> AIUsageCalendarMonthButton? {
                if let button = view as? AIUsageCalendarMonthButton { return button }
                return view.subviews.compactMap(find).first
            }
            let button = try XCTUnwrap(find(host))
            defer { window.contentView = nil; window.close() }
            var pictures: [String: Data] = [:]
            for (name, pressed, enabled) in [("rest", false, true), ("pressed", true, true), ("disabled", false, false), ("disabled-pressed", true, false)] {
                button.isEnabled = enabled
                button.highlight(pressed)
                button.needsDisplay = true
                XCTAssertEqual(button.isHighlighted, pressed && enabled)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let picture = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                pictures[name] = picture
                if let output { try picture.write(to: output.appendingPathComponent("month-\(name)-\(dark ? "dark" : "light").png")) }
            }
            XCTAssertNotEqual(pictures["rest"], pictures["pressed"])
            XCTAssertEqual(pictures["disabled"], pictures["disabled-pressed"])
            XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
        }
    }
}
