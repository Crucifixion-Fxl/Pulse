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

  func testOverduePendingRemindersCarryIntoToday() {
    let calendar = self.calendar
    let now = calendar.date(from: date(2026, 9, 22, hour: 10))!
    let yesterday = calendar.date(from: date(2026, 9, 21, hour: 9))!
    let future = calendar.date(from: date(2026, 9, 23))!

    let dueToday = reminder("due-today", due: date(2026, 9, 22, hour: 8))
    let overdue = reminder("overdue", due: date(2026, 9, 21, hour: 9))
    let oldCompleted = reminder("old-done", due: date(2026, 9, 15), isCompleted: true)
    let undated = reminder("undated", due: nil)
    let reminders = [dueToday, overdue, oldCompleted, undated]

    let todaySchedule = ReminderSchedule.schedule(
      on: now, in: reminders, calendar: calendar, now: now
    )
    // Overdue items sort ahead of today's own reminders.
    XCTAssertEqual(todaySchedule.pending.map(\.id), ["overdue", "due-today"])
    XCTAssertTrue(todaySchedule.completed.isEmpty)

    let pastSchedule = ReminderSchedule.schedule(
      on: yesterday, in: reminders, calendar: calendar, now: now
    )
    XCTAssertEqual(pastSchedule.pending.map(\.id), ["overdue"])

    let futureSchedule = ReminderSchedule.schedule(
      on: future, in: reminders, calendar: calendar, now: now
    )
    XCTAssertTrue(futureSchedule.pending.isEmpty)
    XCTAssertTrue(futureSchedule.completed.isEmpty)
  }

  func testHeatmapGridCoversTrailingWeeksAndCountsCompletionsPerDay() {
    let calendar = self.calendar
    let now = calendar.date(from: date(2026, 9, 22, hour: 18))!
    let weekCount = 4

    let completedOnce = ReminderSnapshot(
      id: "once",
      listID: "list",
      title: "once",
      dueDateComponents: date(2026, 9, 10),
      priority: .none,
      isRecurring: false,
      isCompleted: true,
      completionDate: calendar.date(from: date(2026, 9, 10, hour: 12))
    )
    let completedTwiceA = ReminderSnapshot(
      id: "twice-a",
      listID: "list",
      title: "twice-a",
      dueDateComponents: date(2026, 9, 15),
      priority: .none,
      isRecurring: false,
      isCompleted: true,
      completionDate: calendar.date(from: date(2026, 9, 15, hour: 9))
    )
    let completedTwiceB = ReminderSnapshot(
      id: "twice-b",
      listID: "list",
      title: "twice-b",
      dueDateComponents: date(2026, 9, 15),
      priority: .none,
      isRecurring: false,
      isCompleted: true,
      completionDate: calendar.date(from: date(2026, 9, 15, hour: 20))
    )
    let pendingOnly = reminder("pending", due: date(2026, 9, 22, hour: 8))

    let grid = ReminderHeatmap.grid(
      weekCount: weekCount,
      in: [completedOnce, completedTwiceA, completedTwiceB, pendingOnly],
      calendar: calendar,
      now: now
    )

    XCTAssertEqual(grid.weeks.count, weekCount)
    XCTAssertTrue(grid.weeks.allSatisfy { $0.count == 7 })

    // The grid ends with the week containing today; later weekdays are nil.
    let lastWeek = grid.weeks.last!
    // September 22 2026 is a Tuesday and the calendar starts on Monday.
    XCTAssertEqual(lastWeek[1], calendar.startOfDay(for: now))
    XCTAssertNil(lastWeek[2])
    XCTAssertNil(lastWeek[6])

    let september15 = calendar.startOfDay(for: calendar.date(from: date(2026, 9, 15))!)
    let september10 = calendar.startOfDay(for: calendar.date(from: date(2026, 9, 10))!)
    XCTAssertEqual(grid.counts[september15], 2)
    XCTAssertEqual(grid.counts[september10], 1)
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
