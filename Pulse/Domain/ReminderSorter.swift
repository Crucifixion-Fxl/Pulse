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
    guard reminders.count > 1 else { return reminders }
    let today = calendar.startOfDay(for: now)
    // Resolve calendar components once per item, not twice per comparison.
    // Keep these keys local so edits, timezone changes and midnight are reflected
    // immediately on the next sort without cache invalidation.
    return reminders.map { reminder in
      (reminder: reminder,
       key: key(for: reminder, now: now, today: today, calendar: calendar),
       list: listRank[reminder.listID] ?? .max)
    }.sorted { lhsEntry, rhsEntry in
      let lhs = lhsEntry.reminder
      let rhs = rhsEntry.reminder
      let left = lhsEntry.key
      let right = rhsEntry.key

      if lhsEntry.list != rhsEntry.list { return lhsEntry.list < rhsEntry.list }
      if left.group != right.group { return left.group < right.group }
      if left.date != right.date { return left.date < right.date }
      if lhs.priority.sortRank != rhs.priority.sortRank {
        return lhs.priority.sortRank < rhs.priority.sortRank
      }
      let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
      return lhs.id < rhs.id
    }.map(\.reminder)
  }

  private static func key(
    for reminder: ReminderSnapshot,
    now: Date,
    today: Date,
    calendar: Calendar
  ) -> (group: Int, date: Date) {
    guard let dueDate = reminder.dueDate(in: calendar) else {
      return (3, .distantFuture)
    }

    let dueDay = calendar.startOfDay(for: dueDate)
    if dueDay < today { return (0, dueDate) }
    if calendar.isDate(dueDate, inSameDayAs: now) { return (1, dueDate) }
    return (2, dueDate)
  }
}
