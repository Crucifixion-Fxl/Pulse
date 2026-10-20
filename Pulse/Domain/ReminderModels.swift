import Foundation

enum ReminderSource: String, CaseIterable, Codable, Hashable, Sendable {
  case iCloud
  case local

  var symbolName: String {
    switch self {
    case .iCloud: "icloud"
    case .local: "desktopcomputer"
    }
  }
}

struct ReminderListSnapshot: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let accent: AccentSnapshot
  let source: ReminderSource

  init(
    id: String,
    title: String,
    accent: AccentSnapshot,
    source: ReminderSource = .iCloud
  ) {
    self.id = id
    self.title = title
    self.accent = accent
    self.source = source
  }
}

struct AccentSnapshot: Hashable, Sendable {
  let red: Double
  let green: Double
  let blue: Double
  let alpha: Double

  static let fallback = AccentSnapshot(red: 0.25, green: 0.49, blue: 0.93, alpha: 1)
}

enum ReminderPriority: Int, CaseIterable, Codable, Hashable, Sendable {
  case none = 0
  case high = 1
  case medium = 5
  case low = 9

  var sortRank: Int {
    switch self {
    case .high: 0
    case .medium: 1
    case .low: 2
    case .none: 3
    }
  }

  init(eventKitValue: Int) {
    switch eventKitValue {
    case 1...4: self = .high
    case 5: self = .medium
    case 6...9: self = .low
    default: self = .none
    }
  }
}

struct ReminderSnapshot: Identifiable, Hashable, Sendable {
  let id: String
  let listID: String
  let source: ReminderSource
  var title: String
  var dueDateComponents: DateComponents?
  var priority: ReminderPriority
  let isRecurring: Bool
  var isCompleted: Bool
  let completionDate: Date?

  init(
    id: String,
    listID: String,
    source: ReminderSource = .iCloud,
    title: String,
    dueDateComponents: DateComponents?,
    priority: ReminderPriority,
    isRecurring: Bool,
    isCompleted: Bool = false,
    completionDate: Date? = nil
  ) {
    self.id = id
    self.listID = listID
    self.source = source
    self.title = title
    self.dueDateComponents = dueDateComponents
    self.priority = priority
    self.isRecurring = isRecurring
    self.isCompleted = isCompleted
    self.completionDate = completionDate
  }

  func dueDate(in calendar: Calendar) -> Date? {
    guard let components = dueDateComponents else { return nil }
    return calendar.date(from: components)
  }
}

struct ReminderDraft: Equatable, Sendable {
  var title: String
  var hasDueDate: Bool
  var dueDate: Date
  var includesTime: Bool
  var dueTimeZone: TimeZone?
  var priority: ReminderPriority

  init(
    title: String,
    hasDueDate: Bool,
    dueDate: Date,
    includesTime: Bool,
    dueTimeZone: TimeZone? = nil,
    priority: ReminderPriority
  ) {
    self.title = title
    self.hasDueDate = hasDueDate
    self.dueDate = dueDate
    self.includesTime = includesTime
    self.dueTimeZone = dueTimeZone
    self.priority = priority
  }

  init(reminder: ReminderSnapshot, calendar: Calendar = .current) {
    title = reminder.title
    hasDueDate = reminder.dueDateComponents != nil
    dueDate = reminder.dueDate(in: calendar) ?? Date()
    includesTime = reminder.dueDateComponents?.hour != nil
    dueTimeZone = reminder.dueDateComponents?.timeZone
    priority = reminder.priority
  }

  var normalizedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func dueComponents(calendar: Calendar = .current) -> DateComponents? {
    guard hasDueDate else { return nil }
    let date = calendar.dateComponents([.year, .month, .day], from: dueDate)
    var components = DateComponents(year: date.year, month: date.month, day: date.day)
    if includesTime {
      let time = calendar.dateComponents([.hour, .minute], from: dueDate)
      components.hour = time.hour
      components.minute = time.minute
      components.timeZone = dueTimeZone
    }
    return components
  }
}

enum ReminderAuthorization: Equatable, Sendable {
  case notDetermined
  case denied
  case restricted
  case fullAccess
}

struct ReminderListDeletionSummary: Equatable, Sendable {
  let list: ReminderListSnapshot
  let pendingCount: Int
  let completedCount: Int
}

enum LocalStoreAvailability: Equatable, Sendable {
  case available
  case unavailable(message: String, dataURL: URL?)
}
