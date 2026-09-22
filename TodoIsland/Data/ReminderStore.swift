import Foundation

@MainActor
protocol ReminderStore: AnyObject {
  var onStoreChanged: (() -> Void)? { get set }

  func authorizationStatus() -> ReminderAuthorization
  func requestFullAccess() async throws -> Bool
  func fetchLists() async throws -> [ReminderListSnapshot]
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot]
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot]
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot]
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot]
  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws
  func updateReminder(id: String, from draft: ReminderDraft) async throws
  func setCompleted(_ completed: Bool, reminderID: String) async throws
  func deleteReminder(id: String) async throws
  func createList(title: String, source: ReminderSource) async throws -> ReminderListSnapshot
  func renameList(id: String, title: String) async throws
  func deletionSummary(forListID id: String) async throws -> ReminderListDeletionSummary
  func deleteList(id: String) async throws
  var localStoreAvailability: LocalStoreAvailability { get }
  func retryLocalStore() async
}

extension ReminderStore {
  func createList(title: String, source: ReminderSource) async throws -> ReminderListSnapshot {
    throw ReminderStoreError.operationUnsupported
  }

  func renameList(id: String, title: String) async throws {
    throw ReminderStoreError.operationUnsupported
  }

  func deletionSummary(forListID id: String) async throws -> ReminderListDeletionSummary {
    throw ReminderStoreError.operationUnsupported
  }

  func deleteList(id: String) async throws {
    throw ReminderStoreError.operationUnsupported
  }

  var localStoreAvailability: LocalStoreAvailability { .available }

  func retryLocalStore() async {}
}

enum ReminderStoreError: LocalizedError {
  case listNotFound
  case reminderNotFound
  case emptyTitle
  case emptyListTitle
  case duplicateListName
  case operationUnsupported
  case localStoreUnavailable

  var errorDescription: String? {
    switch self {
    case .listNotFound: String(localized: "error.list-not-found")
    case .reminderNotFound: String(localized: "error.reminder-not-found")
    case .emptyTitle: String(localized: "error.empty-title")
    case .emptyListTitle: String(localized: "error.empty-list-title")
    case .duplicateListName: String(localized: "error.duplicate-list-name")
    case .operationUnsupported: String(localized: "error.operation-unsupported")
    case .localStoreUnavailable: String(localized: "error.local-store-unavailable")
    }
  }
}
