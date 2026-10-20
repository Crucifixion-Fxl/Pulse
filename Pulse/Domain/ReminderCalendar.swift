import Foundation

/// The month grid shown beside the Day Schedule in the Pinned Island. The
/// grid always covers six weeks so its height stays stable while navigating
/// months, with leading and trailing days of adjacent months as fillers.
struct MonthCalendar: Equatable, Sendable {
  struct Day: Equatable, Sendable {
    let date: Date
    let isInMonth: Bool
  }

  let monthStart: Date
  let days: [Day]
  let weekdaySymbols: [String]

  init(containing date: Date, calendar: Calendar = .current) {
    let monthInterval = calendar.dateInterval(of: .month, for: date)
    let resolvedMonthStart = monthInterval?.start ?? calendar.startOfDay(for: date)
    monthStart = resolvedMonthStart
    let firstWeekdayOfMonth = calendar.component(.weekday, from: resolvedMonthStart)
    let leading = (firstWeekdayOfMonth - calendar.firstWeekday + 7) % 7
    let gridStart = calendar.date(byAdding: .day, value: -leading, to: resolvedMonthStart)
      ?? resolvedMonthStart
    days = (0..<Self.totalDayCount).map { offset in
      let day = calendar.date(byAdding: .day, value: offset, to: gridStart) ?? gridStart
      return Day(
        date: day,
        isInMonth: calendar.isDate(day, equalTo: resolvedMonthStart, toGranularity: .month)
      )
    }

    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let firstIndex = calendar.firstWeekday - 1
    weekdaySymbols = Array(symbols[firstIndex...] + symbols[..<firstIndex])
  }

  static let totalDayCount = 42

  var monthTitle: String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("yMMMM")
    return formatter.string(from: monthStart)
  }

  func day(at index: Int) -> Day? {
    guard days.indices.contains(index) else { return nil }
    return days[index]
  }
}

/// Derives the Day Schedule for a selected date and the per-day item counts
/// behind the calendar dots from one month-scoped fetch. Grouping uses day
/// boundaries in the given calendar so a Reminder keeps its day regardless of
/// how the backend stored its Due Date.
enum ReminderSchedule {
  struct DayCounts: Equatable, Sendable {
    var pending = 0
    var completed = 0

    var isEmpty: Bool { pending == 0 && completed == 0 }
  }

  struct DaySchedule: Equatable, Sendable {
    let date: Date
    let pending: [ReminderSnapshot]
    let completed: [ReminderSnapshot]
  }

  static func schedule(
    on day: Date,
    in reminders: [ReminderSnapshot],
    listRank: [String: Int] = [:],
    calendar: Calendar = .current,
    now: Date = Date()
  ) -> DaySchedule {
    let target = calendar.startOfDay(for: day)
    let today = calendar.startOfDay(for: now)
    let dueThatDay = reminders.filter { reminder in
      guard let due = reminder.dueDate(in: calendar) else { return false }
      return calendar.isDate(due, inSameDayAs: target)
    }
    var pending = dueThatDay.filter { !$0.isCompleted }
    // Overdue pending Reminders flow forward: they greet the user on the
    // current day until completed, instead of staying stuck on past dates.
    if target == today {
      pending += reminders.filter { reminder in
        guard !reminder.isCompleted, let due = reminder.dueDate(in: calendar) else {
          return false
        }
        return calendar.startOfDay(for: due) < today
      }
    }
    return DaySchedule(
      date: target,
      pending: ReminderSorter.sorted(
        pending, listRank: listRank, now: now, calendar: calendar),
      completed: ReminderSorter.sorted(dueThatDay.filter(\.isCompleted), calendar: calendar)
    )
  }

  static func dayCounts(
    in reminders: [ReminderSnapshot],
    calendar: Calendar = .current
  ) -> [Date: DayCounts] {
    var counts: [Date: DayCounts] = [:]
    for reminder in reminders {
      guard let due = reminder.dueDate(in: calendar) else { continue }
      let day = calendar.startOfDay(for: due)
      if reminder.isCompleted {
        counts[day, default: DayCounts()].completed += 1
      } else {
        counts[day, default: DayCounts()].pending += 1
      }
    }
    return counts
  }
}

/// Builds a GitHub-style contribution grid from Reminders completed recently:
/// one column per week, seven rows per weekday, each cell holding that
/// day's completion count. Future cells in the current week are nil.
enum ReminderHeatmap {
  struct Grid: Equatable, Sendable {
    let weeks: [[Date?]]
    let counts: [Date: Int]
  }

  static let defaultWeekCount = 24

  static func grid(
    weekCount: Int = defaultWeekCount,
    in reminders: [ReminderSnapshot],
    calendar: Calendar = .current,
    now: Date = Date()
  ) -> Grid {
    let today = calendar.startOfDay(for: now)
    var counts: [Date: Int] = [:]
    for reminder in reminders {
      guard let completed = reminder.completionDate else { continue }
      let day = calendar.startOfDay(for: completed)
      if day <= today { counts[day, default: 0] += 1 }
    }

    let todayWeekdayIndex =
      (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
    let futureCellCount = 6 - todayWeekdayIndex
    let totalCells = weekCount * 7
    guard
      let gridStart = calendar.date(
        byAdding: .day, value: -(totalCells - 1 - futureCellCount), to: today)
    else { return Grid(weeks: [], counts: [:]) }

    var days: [Date?] = (0..<totalCells).map { offset in
      guard let day = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
        return nil
      }
      return day > today ? nil : day
    }
    var weeks: [[Date?]] = []
    while !days.isEmpty {
      weeks.append(Array(days.prefix(7)))
      days.removeFirst(min(7, days.count))
    }
    return Grid(weeks: weeks, counts: counts)
  }
}
