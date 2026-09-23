import Foundation

@MainActor
final class SourceAwareReminderStore: ReminderStore {
  typealias LocalStoreFactory = @MainActor () throws -> LocalReminderStore

  var onStoreChanged: (() -> Void)?

  private let iCloudStore: EventKitReminderStore
  private let localStoreFactory: LocalStoreFactory
  private var localStore: LocalReminderStore?
  private var localFailure: (message: String, dataURL: URL?)?

  init(
    iCloudStore: EventKitReminderStore = EventKitReminderStore(),
    localStoreFactory: LocalStoreFactory? = nil
  ) {
    self.iCloudStore = iCloudStore
    self.localStoreFactory = localStoreFactory ?? { try LocalReminderStore() }
    installLocalStore()
    wireChangeHandlers()
  }

  var localStoreAvailability: LocalStoreAvailability {
    if let localFailure {
      return .unavailable(message: localFailure.message, dataURL: localFailure.dataURL)
    }
    return .available
  }

  func authorizationStatus() -> ReminderAuthorization {
    iCloudStore.authorizationStatus()
  }

  func requestFullAccess() async throws -> Bool {
    try await iCloudStore.requestFullAccess()
  }

  func fetchLists() async throws -> [ReminderListSnapshot] {
    var lists: [ReminderListSnapshot] = []
    if authorizationStatus() == .fullAccess {
      do {
        lists += try await iCloudStore.fetchLists().map(Self.namespace)
      } catch {
        // An iCloud refresh failure must not prevent access to app-owned Local data.
      }
    }
    if let localStore {
      do {
        lists += try await localStore.fetchLists().map(Self.namespace)
      } catch {
        localFailure = (error.localizedDescription, localStore.dataURL)
        self.localStore = nil
      }
    }
    return lists.sorted {
      if $0.source != $1.source { return $0.source == .iCloud }
      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
  }

  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] {
    let target = try split(listID)
    return try await backend(for: target.source)
      .fetchPendingReminders(in: target.rawID)
      .map(Self.namespace)
  }

  /// Month-calendar data across both Sources. A failure in one Source must
  /// not blank the other Source's contributions, so per-Source errors are
  /// swallowed just like in fetchLists.
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] {
    var reminders: [ReminderSnapshot] = []
    if authorizationStatus() == .fullAccess,
      let dated = try? await iCloudStore.fetchReminders(dueFrom: dueFrom, through: through)
    {
      reminders += dated.map(Self.namespace)
    }
    if let localStore,
      let dated = try? await localStore.fetchReminders(dueFrom: dueFrom, through: through)
    {
      reminders += dated.map(Self.namespace)
    }
    return reminders
  }

  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] {
    var reminders: [ReminderSnapshot] = []
    if authorizationStatus() == .fullAccess,
      let undated = try? await iCloudStore.fetchUndatedPendingReminders()
    {
      reminders += undated.map(Self.namespace)
    }
    if let localStore, let undated = try? await localStore.fetchUndatedPendingReminders() {
      reminders += undated.map(Self.namespace)
    }
    return reminders
  }

  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] {
    var reminders: [ReminderSnapshot] = []
    if authorizationStatus() == .fullAccess,
      let overdue = try? await iCloudStore.fetchOverduePendingReminders(before: date)
    {
      reminders += overdue.map(Self.namespace)
    }
    if let localStore,
      let overdue = try? await localStore.fetchOverduePendingReminders(before: date)
    {
      reminders += overdue.map(Self.namespace)
    }
    return reminders
  }

  func fetchUndatedCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] {
    var reminders: [ReminderSnapshot] = []
    if authorizationStatus() == .fullAccess,
      let completed = try? await iCloudStore.fetchUndatedCompletedReminders(completedFrom: date)
    {
      reminders += completed.map(Self.namespace)
    }
    if let localStore,
      let completed = try? await localStore.fetchUndatedCompletedReminders(completedFrom: date)
    {
      reminders += completed.map(Self.namespace)
    }
    return reminders
  }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {
    let target = try split(listID)
    try await backend(for: target.source)
      .createReminder(title: title, in: target.rawID, dueComponents: dueComponents)
  }

  func updateReminder(id: String, from draft: ReminderDraft) async throws {
    let target = try split(id)
    try await backend(for: target.source).updateReminder(id: target.rawID, from: draft)
  }

  func setCompleted(_ completed: Bool, reminderID: String) async throws {
    let target = try split(reminderID)
    try await backend(for: target.source).setCompleted(completed, reminderID: target.rawID)
  }

  func deleteReminder(id: String) async throws {
    let target = try split(id)
    try await backend(for: target.source).deleteReminder(id: target.rawID)
  }

  func createList(title: String, source: ReminderSource) async throws -> ReminderListSnapshot {
    if source == .iCloud, authorizationStatus() != .fullAccess {
      throw ReminderStoreError.operationUnsupported
    }
    return Self.namespace(try await backend(for: source).createList(title: title))
  }

  func renameList(id: String, title: String) async throws {
    let target = try split(id)
    try await backend(for: target.source).renameList(id: target.rawID, title: title)
  }

  func deletionSummary(forListID id: String) async throws -> ReminderListDeletionSummary {
    let target = try split(id)
    let summary = try await backend(for: target.source).deletionSummary(forListID: target.rawID)
    return ReminderListDeletionSummary(
      list: Self.namespace(summary.list),
      pendingCount: summary.pendingCount,
      completedCount: summary.completedCount
    )
  }

  func deleteList(id: String) async throws {
    let target = try split(id)
    try await backend(for: target.source).deleteList(id: target.rawID)
  }

  func retryLocalStore() async {
    guard localStore == nil else { return }
    installLocalStore()
    wireChangeHandlers()
    onStoreChanged?()
  }

  private func installLocalStore() {
    do {
      let store = try localStoreFactory()
      localStore = store
      localFailure = nil
    } catch {
      localStore = nil
      let url = try? LocalReminderStore.defaultStoreURL()
      localFailure = (error.localizedDescription, url)
    }
  }

  private func wireChangeHandlers() {
    iCloudStore.onStoreChanged = { [weak self] in self?.onStoreChanged?() }
    localStore?.onStoreChanged = { [weak self] in self?.onStoreChanged?() }
  }

  private func backend(for source: ReminderSource) throws -> any ReminderBackend {
    switch source {
    case .iCloud:
      guard authorizationStatus() == .fullAccess else {
        throw ReminderStoreError.operationUnsupported
      }
      return iCloudStore
    case .local:
      guard let localStore else { throw ReminderStoreError.localStoreUnavailable }
      return localStore
    }
  }

  private func split(_ id: String) throws -> (source: ReminderSource, rawID: String) {
    guard let identity = ReminderStoreIdentity.split(id) else {
      throw ReminderStoreError.reminderNotFound
    }
    return identity
  }

  private static func namespace(_ list: ReminderListSnapshot) -> ReminderListSnapshot {
    ReminderListSnapshot(
      id: ReminderStoreIdentity.namespaced(list.id, source: list.source),
      title: list.title,
      accent: list.accent,
      source: list.source
    )
  }

  private static func namespace(_ reminder: ReminderSnapshot) -> ReminderSnapshot {
    ReminderSnapshot(
      id: ReminderStoreIdentity.namespaced(reminder.id, source: reminder.source),
      listID: ReminderStoreIdentity.namespaced(reminder.listID, source: reminder.source),
      source: reminder.source,
      title: reminder.title,
      dueDateComponents: reminder.dueDateComponents,
      priority: reminder.priority,
      isRecurring: reminder.isRecurring,
      isCompleted: reminder.isCompleted
    )
  }
}
