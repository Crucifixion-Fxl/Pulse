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
