import Foundation

enum ReminderSorter {
  /// `listRank` orders Reminders by their List (same-List items stay
  /// together); Lists missing from the table sort after ranked ones. Inside
  /// a List the original urgency rules apply: overdue first, then date,
  /// priority, and title.
  static func sorted(
    _ reminders: [ReminderSnapshot],
    listRank: [String: Int] = [:],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> [ReminderSnapshot] {
    reminders.sorted { lhs, rhs in
      let left = key(for: lhs, now: now, calendar: calendar)
      let right = key(for: rhs, now: now, calendar: calendar)

      let leftList = listRank[lhs.listID] ?? .max
      let rightList = listRank[rhs.listID] ?? .max
      if leftList != rightList { return leftList < rightList }
      if left.group != right.group { return left.group < right.group }
      if left.date != right.date { return left.date < right.date }
      if lhs.priority.sortRank != rhs.priority.sortRank {
        return lhs.priority.sortRank < rhs.priority.sortRank
      }
      let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
      return lhs.id < rhs.id
    }
  }

  private static func key(
    for reminder: ReminderSnapshot,
    now: Date,
    calendar: Calendar
  ) -> (group: Int, date: Date) {
    guard let dueDate = reminder.dueDate(in: calendar) else {
      return (3, .distantFuture)
    }

    let today = calendar.startOfDay(for: now)
    let dueDay = calendar.startOfDay(for: dueDate)
    if dueDay < today { return (0, dueDate) }
    if calendar.isDate(dueDate, inSameDayAs: now) { return (1, dueDate) }
    return (2, dueDate)
  }
}
