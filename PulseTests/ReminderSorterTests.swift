import XCTest

@testable import Pulse

final class ReminderSorterTests: XCTestCase {
  func testOrdersByDueGroupThenPriorityAndTitle() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 12)))

    let reminders = [
      reminder("undated", title: "Zebra", priority: .none),
      reminder(
        "future", title: "Future", due: DateComponents(year: 2026, month: 8, day: 13),
        priority: .high),
      reminder(
        "today-low", title: "Beta", due: DateComponents(year: 2026, month: 8, day: 12, hour: 9),
        priority: .low),
      reminder(
        "overdue", title: "Old", due: DateComponents(year: 2026, month: 8, day: 11), priority: .none
      ),
      reminder(
        "today-high", title: "Alpha", due: DateComponents(year: 2026, month: 8, day: 12, hour: 9),
        priority: .high),
    ]

    let result = ReminderSorter.sorted(reminders, now: now, calendar: calendar)
    XCTAssertEqual(result.map(\.id), ["overdue", "today-high", "today-low", "future", "undated"])
  }

  func testListRankPrecedesUrgencyAndTiesUseNaturalTitleThenID() {
    let items = [
      ReminderSnapshot(id: "unranked", listID: "other", title: "First",
        dueDateComponents: DateComponents(year: 2000, month: 1, day: 1),
        priority: .high, isRecurring: false),
      reminder("b", title: "Task 2", priority: .none),
      reminder("ten", title: "Task 10", priority: .none),
      reminder("a", title: "Task 2", priority: .none),
    ]
    XCTAssertEqual(ReminderSorter.sorted(items, listRank: ["list": 0]).map(\.id),
      ["a", "b", "ten", "unranked"])
    XCTAssertEqual(ReminderSorter.sorted([]), [])
    XCTAssertEqual(ReminderSorter.sorted([items[0]]), [items[0]])
  }

  func testSortingRecomputesKeysAfterEditsAndAcrossDSTMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = try XCTUnwrap(calendar.date(from:
      DateComponents(year: 2026, month: 3, day: 8, hour: 23)))
    var items = [
      reminder("tomorrow", title: "Tomorrow",
        due: DateComponents(year: 2026, month: 3, day: 9), priority: .none),
      reminder("today", title: "Today",
        due: DateComponents(year: 2026, month: 3, day: 8, hour: 3), priority: .none),
      reminder("yesterday", title: "Yesterday",
        due: DateComponents(year: 2026, month: 3, day: 7, hour: 23), priority: .none),
    ]
    XCTAssertEqual(ReminderSorter.sorted(items, now: now, calendar: calendar).map(\.id),
      ["yesterday", "today", "tomorrow"])
    items[2].dueDateComponents = nil
    let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: now))
    XCTAssertEqual(ReminderSorter.sorted(items, now: nextDay, calendar: calendar).map(\.id),
      ["today", "tomorrow", "yesterday"])
  }

  private func reminder(
    _ id: String,
    title: String,
    due: DateComponents? = nil,
    priority: ReminderPriority
  ) -> ReminderSnapshot {
    ReminderSnapshot(
      id: id, listID: "list", title: title, dueDateComponents: due, priority: priority,
      isRecurring: false)
  }
}
