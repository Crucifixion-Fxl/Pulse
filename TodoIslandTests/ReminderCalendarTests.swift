import XCTest

@testable import TodoIsland

final class ReminderCalendarTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
  }

  private func reminder(
    _ id: String,
    due: DateComponents?,
    isCompleted: Bool = false,
    priority: ReminderPriority = .none
  ) -> ReminderSnapshot {
    ReminderSnapshot(
      id: id,
      listID: "list",
      title: id,
      dueDateComponents: due,
      priority: priority,
      isRecurring: false,
      isCompleted: isCompleted
    )
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int? = nil) -> DateComponents {
    var components = DateComponents(year: year, month: month, day: day)
    components.hour = hour
    return components
  }

  func testMonthGridCoversSixWeeksAlignedToFirstWeekday() {
    let calendar = self.calendar
    // September 2026 has 30 days and starts on a Tuesday.
    let september = calendar.date(from: date(2026, 9, 15))!
    let grid = MonthCalendar(containing: september, calendar: calendar)

    XCTAssertEqual(grid.days.count, MonthCalendar.totalDayCount)
    XCTAssertEqual(
      calendar.component(.weekday, from: grid.days.first!.date),
      calendar.firstWeekday
    )

    let monthStart = calendar.dateInterval(of: .month, for: september)!.start
    let leadingOffset = calendar
      .dateComponents([.day], from: grid.days.first!.date, to: monthStart).day!
    XCTAssertGreaterThan(leadingOffset, 0)
    XCTAssertLessThan(leadingOffset, 7)

    let monthDayCount = calendar.range(of: .day, in: .month, for: september)!.count
    let inMonthDays = grid.days.filter(\.isInMonth)
    XCTAssertEqual(inMonthDays.count, monthDayCount)
    XCTAssertEqual(
      Set(inMonthDays.map { calendar.startOfDay(for: $0.date) }).count,
      monthDayCount
    )
    XCTAssertTrue(grid.days.contains { !$0.isInMonth })

    XCTAssertEqual(
      grid.weekdaySymbols.first,
      calendar.veryShortStandaloneWeekdaySymbols[calendar.firstWeekday - 1]
    )
    XCTAssertEqual(grid.day(at: grid.days.count)?.date, nil)
    XCTAssertEqual(grid.day(at: 0)?.isInMonth, false)
  }

  func testDayScheduleSeparatesPendingAndCompletedDueThatDay() {
    let calendar = self.calendar
    let selected = calendar.date(from: date(2026, 9, 22))!

    let morning = reminder("morning", due: date(2026, 9, 22, hour: 8))
    let evening = reminder("evening", due: date(2026, 9, 22, hour: 20))
    let allDay = reminder("all-day", due: date(2026, 9, 22))
    let done = reminder("done", due: date(2026, 9, 22, hour: 9), isCompleted: true)
    let otherDay = reminder("other", due: date(2026, 9, 23, hour: 8))
    let undated = reminder("undated", due: nil)

    let schedule = ReminderSchedule.schedule(
      on: selected,
      in: [evening, done, otherDay, morning, allDay, undated],
      calendar: calendar
    )

    XCTAssertEqual(schedule.pending.map(\.id), ["all-day", "morning", "evening"])
    XCTAssertEqual(schedule.completed.map(\.id), ["done"])
  }

  func testDayCountsSummarizePendingAndCompletedPerDay() {
    let calendar = self.calendar
    let september22 = calendar.date(from: date(2026, 9, 22))!
    let september23 = calendar.date(from: date(2026, 9, 23))!

    let counts = ReminderSchedule.dayCounts(
      in: [
        reminder("a", due: date(2026, 9, 22, hour: 8)),
        reminder("b", due: date(2026, 9, 22, hour: 21)),
        reminder("c", due: date(2026, 9, 22), isCompleted: true),
        reminder("d", due: date(2026, 9, 23, hour: 8)),
        reminder("e", due: nil),
      ],
      calendar: calendar
    )

    XCTAssertEqual(counts[september22], ReminderSchedule.DayCounts(pending: 2, completed: 1))
    XCTAssertEqual(counts[september23], ReminderSchedule.DayCounts(pending: 1, completed: 0))
    XCTAssertEqual(counts.count, 2)
  }
}
