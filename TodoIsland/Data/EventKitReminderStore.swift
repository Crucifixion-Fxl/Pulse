import AppKit
@preconcurrency import EventKit
import Foundation

@MainActor
final class EventKitReminderStore: ReminderBackend {
  let source = ReminderSource.iCloud
  var onStoreChanged: (() -> Void)?

  private let eventStore: EKEventStore
  private var changeObserver: NSObjectProtocol?

  init(eventStore: EKEventStore = EKEventStore()) {
    self.eventStore = eventStore
    changeObserver = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged,
      object: eventStore,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.onStoreChanged?()
      }
    }
  }

  isolated deinit {
    if let changeObserver {
      NotificationCenter.default.removeObserver(changeObserver)
    }
  }

  func authorizationStatus() -> ReminderAuthorization {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .notDetermined: .notDetermined
    case .restricted: .restricted
    case .denied: .denied
    case .fullAccess, .authorized: .fullAccess
    case .writeOnly: .denied
    @unknown default: .denied
    }
  }

  func requestFullAccess() async throws -> Bool {
    let granted = try await eventStore.requestFullAccessToReminders()
    if granted { eventStore.reset() }
    return granted
  }

  func createList(title: String) async throws -> ReminderListSnapshot {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ReminderStoreError.emptyListTitle }

    let calendars = eventStore.calendars(for: .reminder).filter(Self.isICloudCalendar)
    guard !calendars.contains(where: {
      $0.title.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }) else {
      throw ReminderStoreError.duplicateListName
    }
    guard let source = Self.iCloudSource(in: eventStore) else {
      throw ReminderStoreError.listNotFound
    }

    let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
    calendar.source = source
    calendar.title = normalized
    try eventStore.saveCalendar(calendar, commit: true)
    return Self.snapshot(calendar)
  }

  func fetchLists() async throws -> [ReminderListSnapshot] {
    eventStore.calendars(for: .reminder)
      .filter(Self.isICloudCalendar)
      .map(Self.snapshot)
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] {
    guard let calendar = reminderCalendar(id: listID) else {
      throw ReminderStoreError.listNotFound
    }
    let predicate = eventStore.predicateForIncompleteReminders(
      withDueDateStarting: nil,
      ending: nil,
      calendars: [calendar]
    )

    return try await withCheckedThrowingContinuation { continuation in
      eventStore.fetchReminders(matching: predicate) { reminders in
        DispatchQueue.main.async {
          let snapshots = (reminders ?? []).map(Self.snapshot)
          continuation.resume(returning: snapshots)
        }
      }
    }
  }

  /// macOS has no due-date-ranged predicate that includes completed
  /// reminders, so this fetches the calendars' reminders and filters by Due
  /// Date here, using the same calendar the Day Schedule groups with.
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] {
    let calendars = eventStore.calendars(for: .reminder).filter(Self.isICloudCalendar)
    guard !calendars.isEmpty else { return [] }
    let predicate = eventStore.predicateForReminders(in: calendars)

    return try await withCheckedThrowingContinuation { continuation in
      eventStore.fetchReminders(matching: predicate) { reminders in
        DispatchQueue.main.async {
          let calendar = Calendar.current
          let snapshots = (reminders ?? []).filter { reminder in
            guard let due = reminder.dueDateComponents.flatMap({ calendar.date(from: $0) }) else {
              return false
            }
            return due >= dueFrom && due <= through
          }
          .map(Self.snapshot)
          continuation.resume(returning: snapshots)
        }
      }
    }
  }

  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] {
    let calendars = eventStore.calendars(for: .reminder).filter(Self.isICloudCalendar)
    guard !calendars.isEmpty else { return [] }
    let predicate = eventStore.predicateForIncompleteReminders(
      withDueDateStarting: nil,
      ending: nil,
      calendars: calendars
    )

    return try await withCheckedThrowingContinuation { continuation in
      eventStore.fetchReminders(matching: predicate) { reminders in
        DispatchQueue.main.async {
          let snapshots = (reminders ?? []).filter { $0.dueDateComponents == nil }.map(Self.snapshot)
          continuation.resume(returning: snapshots)
        }
      }
    }
  }

  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] {
    let calendars = eventStore.calendars(for: .reminder).filter(Self.isICloudCalendar)
    guard !calendars.isEmpty else { return [] }
    let predicate = eventStore.predicateForIncompleteReminders(
      withDueDateStarting: nil,
      ending: date,
      calendars: calendars
    )

    return try await withCheckedThrowingContinuation { continuation in
      eventStore.fetchReminders(matching: predicate) { reminders in
        DispatchQueue.main.async {
          let calendar = Calendar.current
          let snapshots = (reminders ?? []).filter { reminder in
            guard let components = reminder.dueDateComponents,
              let due = calendar.date(from: components)
            else { return false }
            return due < date
          }
          .map(Self.snapshot)
          continuation.resume(returning: snapshots)
        }
      }
    }
  }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ReminderStoreError.emptyTitle }
    guard let calendar = reminderCalendar(id: listID) else {
      throw ReminderStoreError.listNotFound
    }

    let reminder = EKReminder(eventStore: eventStore)
    reminder.calendar = calendar
    reminder.title = normalized
    reminder.dueDateComponents = dueComponents
    reminder.priority = ReminderPriority.none.rawValue
    try eventStore.save(reminder, commit: true)
  }

  func updateReminder(id: String, from draft: ReminderDraft) async throws {
    guard !draft.normalizedTitle.isEmpty else { throw ReminderStoreError.emptyTitle }
    guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
      throw ReminderStoreError.reminderNotFound
    }

    reminder.title = draft.normalizedTitle
    reminder.dueDateComponents = draft.dueComponents()
    reminder.priority = draft.priority.rawValue
    try eventStore.save(reminder, commit: true)
  }

  func setCompleted(_ completed: Bool, reminderID: String) async throws {
    guard let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder else {
      throw ReminderStoreError.reminderNotFound
    }
    reminder.isCompleted = completed
    try eventStore.save(reminder, commit: true)
  }

  func deleteReminder(id: String) async throws {
    guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else {
      throw ReminderStoreError.reminderNotFound
    }
    try eventStore.remove(reminder, commit: true)
  }

  private func reminderCalendar(id: String) -> EKCalendar? {
    eventStore.calendars(for: .reminder)
      .first { $0.calendarIdentifier == id && Self.isICloudCalendar($0) }
  }

  private static func isICloudCalendar(_ calendar: EKCalendar) -> Bool {
    calendar.source.sourceType == .calDAV
      && calendar.source.title.range(of: "icloud", options: .caseInsensitive) != nil
  }

  private static func iCloudSource(in eventStore: EKEventStore) -> EKSource? {
    eventStore.sources.first {
      $0.sourceType == .calDAV
        && $0.title.range(of: "icloud", options: .caseInsensitive) != nil
    }
  }

  private static func snapshot(_ calendar: EKCalendar) -> ReminderListSnapshot {
    ReminderListSnapshot(
      id: calendar.calendarIdentifier,
      title: calendar.title,
      accent: accent(from: calendar.cgColor),
      source: .iCloud
    )
  }

  private static func snapshot(_ reminder: EKReminder) -> ReminderSnapshot {
    ReminderSnapshot(
      id: reminder.calendarItemIdentifier,
      listID: reminder.calendar.calendarIdentifier,
      source: .iCloud,
      title: reminder.title,
      dueDateComponents: reminder.dueDateComponents,
      priority: ReminderPriority(eventKitValue: reminder.priority),
      isRecurring: !(reminder.recurrenceRules?.isEmpty ?? true),
      isCompleted: reminder.isCompleted
    )
  }

  private static func accent(from cgColor: CGColor?) -> AccentSnapshot {
    guard
      let cgColor,
      let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB)
    else { return .fallback }

    return AccentSnapshot(
      red: Double(color.redComponent),
      green: Double(color.greenComponent),
      blue: Double(color.blueComponent),
      alpha: Double(color.alphaComponent)
    )
  }
}
