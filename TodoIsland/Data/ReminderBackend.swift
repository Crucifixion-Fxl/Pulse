import Foundation

@MainActor
protocol ReminderBackend: AnyObject {
  var source: ReminderSource { get }
  var onStoreChanged: (() -> Void)? { get set }

  func fetchLists() async throws -> [ReminderListSnapshot]
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot]
  /// Dated Reminders due within the closed range, including Completed ones,
  /// for the month calendar surface.
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot]
  /// Pending Reminders without a Due Date, across every accessible list.
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot]
  /// Pending, dated Reminders due strictly before the given instant, across
  /// every accessible list, feeding the overdue carry-over.
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot]
  /// Completed Reminders without a Due Date whose completion falls on or
  /// after the given instant, feeding the day progress summary.
  func fetchUndatedCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot]
  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws
  func updateReminder(id: String, from draft: ReminderDraft) async throws
  func setCompleted(_ completed: Bool, reminderID: String) async throws
  func deleteReminder(id: String) async throws
  func createList(title: String) async throws -> ReminderListSnapshot
  func renameList(id: String, title: String) async throws
  func deletionSummary(forListID id: String) async throws -> ReminderListDeletionSummary
  func deleteList(id: String) async throws
}

extension ReminderBackend {
  func renameList(id: String, title: String) async throws {
    throw ReminderStoreError.operationUnsupported
  }

  func deletionSummary(forListID id: String) async throws -> ReminderListDeletionSummary {
    throw ReminderStoreError.operationUnsupported
  }

  func deleteList(id: String) async throws {
    throw ReminderStoreError.operationUnsupported
  }
}

enum ReminderStoreIdentity {
  private static let separator = ":"

  static func namespaced(_ rawID: String, source: ReminderSource) -> String {
    source.rawValue + separator + rawID
  }

  static func split(_ id: String) -> (source: ReminderSource, rawID: String)? {
    for source in ReminderSource.allCases {
      let prefix = source.rawValue + separator
      if id.hasPrefix(prefix) {
        return (source, String(id.dropFirst(prefix.count)))
      }
    }
    return nil
  }
}
