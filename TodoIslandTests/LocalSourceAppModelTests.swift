import XCTest

@testable import TodoIsland

final class LocalSourceAppModelTests: XCTestCase {
  func testSwitchingListCreationSourcePreservesEnteredName() {
    XCTAssertFalse(
      ListCreationDraftPolicy.shouldResetName(
        previousSource: .iCloud,
        newSource: .local
      ))
    XCTAssertFalse(
      ListCreationDraftPolicy.shouldResetName(
        previousSource: .local,
        newSource: .iCloud
      ))
  }

  func testOpeningListCreationFormStartsWithAnEmptyName() {
    XCTAssertTrue(
      ListCreationDraftPolicy.shouldResetName(
        previousSource: nil,
        newSource: .iCloud
      ))
  }

  @MainActor
  func testDeniedICloudAuthorizationStillLoadsAndMutatesLocalSource() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = LocalOnlyTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()

    XCTAssertEqual(model.authorization, .denied)
    XCTAssertEqual(model.activeList?.source, .local)
    XCTAssertTrue(model.canUseActiveList)

    let listID = try XCTUnwrap(model.activeListID)
    try await store.createReminder(title: "Local task", in: listID, dueComponents: nil)
    await model.reload()

    XCTAssertEqual(model.reminders.map(\.title), ["Local task"])
    XCTAssertEqual(store.createdReminderTitles, ["Local task"])
  }

  @MainActor
  func testUndatedReminderJoinsDayScheduleUndatedSection() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = LocalOnlyTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()

    let listID = try XCTUnwrap(model.activeListID)
    try await store.createReminder(title: "Undated task", in: listID, dueComponents: nil)
    await model.reload()

    XCTAssertTrue(model.monthReminders.isEmpty)
    XCTAssertTrue(model.selectedDaySchedule.pending.isEmpty)
    XCTAssertEqual(model.undatedReminders.map(\.title), ["Undated task"])
    XCTAssertEqual(model.visibleScheduleReminders.map(\.title), ["Undated task"])
  }

  @MainActor
  func testOverduePendingRemindersFlowIntoTodaySchedule() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = LocalOnlyTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    let listID = try XCTUnwrap(model.activeListID)

    let calendar = Calendar.current
    let oldDate = calendar.date(byAdding: .month, value: -1, to: model.selectedDay)!
    try await store.createReminder(
      title: "Old task",
      in: listID,
      dueComponents: calendar.dateComponents([.year, .month, .day], from: oldDate)
    )
    await model.reload()

    XCTAssertTrue(model.monthReminders.isEmpty)
    XCTAssertEqual(model.overdueReminders.map(\.title), ["Old task"])
    XCTAssertEqual(model.selectedDaySchedule.pending.map(\.title), ["Old task"])
    XCTAssertEqual(model.visibleScheduleReminders.map(\.title), ["Old task"])
  }

  @MainActor
  func testTaskInputCreatesReminderDueOnTheSelectedDay() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = LocalOnlyTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    let listID = try XCTUnwrap(model.activeListID)

    let calendar = Calendar.current
    let target = calendar.date(byAdding: .day, value: 3, to: model.selectedDay)!
    model.createTask("Planned task", on: target)
    try await Task.sleep(for: .milliseconds(50))

    let created = try XCTUnwrap(model.monthReminders.first)
    XCTAssertEqual(created.title, "Planned task")
    XCTAssertEqual(created.dueDateComponents?.year, calendar.component(.year, from: target))
    XCTAssertEqual(created.dueDateComponents?.month, calendar.component(.month, from: target))
    XCTAssertEqual(created.dueDateComponents?.day, calendar.component(.day, from: target))
    XCTAssertNil(created.dueDateComponents?.hour)
    // The task lands on its own day, not on today's schedule.
    let targetSchedule = ReminderSchedule.schedule(on: target, in: model.monthReminders)
    XCTAssertEqual(targetSchedule.pending.map(\.title), ["Planned task"])
    XCTAssertTrue(model.selectedDaySchedule.pending.isEmpty)
  }

  @MainActor
  func testCompletingDayItemMarksItCompletedInSchedule() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = LocalOnlyTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    guard let listID = model.activeListID else {
      return XCTFail("Expected an Active List")
    }

    try await store.createReminder(
      title: "Dated task",
      in: listID,
      dueComponents: Calendar.current.dateComponents([.year, .month, .day], from: model.selectedDay)
    )
    await model.reload()
    let reminder = try XCTUnwrap(model.monthReminders.first)
    XCTAssertEqual(model.selectedDaySchedule.pending.map(\.title), ["Dated task"])

    model.complete(reminder)
    try await Task.sleep(for: .milliseconds(400))

    XCTAssertEqual(try XCTUnwrap(model.monthReminders.first).isCompleted, true)
    XCTAssertTrue(model.selectedDaySchedule.pending.isEmpty)
    XCTAssertEqual(model.selectedDaySchedule.completed.map(\.title), ["Dated task"])
  }

  @MainActor
  func testDeniedICloudAuthorizationOffersRecoveryWhileLocalListIsActive() async {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults)
    await model.start()

    XCTAssertEqual(model.activeList?.source, .local)
    XCTAssertEqual(model.iCloudSourceMenuState, .authorizationRequired)
  }

  @MainActor
  func testDefaultLocalListIsCreatedOnlyOnFirstUse() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defaults.set(
      CollapsedIslandVisibility.alwaysVisible.rawValue,
      forKey: "collapsed-island-visibility"
    )
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = LocalOnlyTestReminderStore(startsEmpty: true)
    let model = AppModel(store: store, defaults: defaults)
    await model.start()

    await model.useLocal()
    XCTAssertEqual(store.createdListTitles, ["Todo Island"])
    XCTAssertEqual(model.activeList?.source, .local)

    store.removeAllLists()
    await model.reload()
    await model.useLocal()

    XCTAssertEqual(store.createdListTitles, ["Todo Island"])
    XCTAssertEqual(model.requestedListCreationSource, .local)
  }

  @MainActor
  func testDeletingLastLocalListShowsLocalEmptyStateWithoutRecreatingDefault() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defaults.set(
      CollapsedIslandVisibility.alwaysVisible.rawValue,
      forKey: "collapsed-island-visibility"
    )
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = LocalOnlyTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    let list = try XCTUnwrap(model.activeList)

    await model.prepareListDeletion(list)
    let candidate = try XCTUnwrap(model.listDeletionCandidate)
    await model.confirmListDeletion(candidate)

    XCTAssertNil(model.activeList)
    XCTAssertEqual(model.preferredEmptySource, .local)
    XCTAssertEqual(store.createdListTitles, [])

    await model.useLocal()
    XCTAssertEqual(store.createdListTitles, [])
    XCTAssertEqual(model.requestedListCreationSource, .local)
  }

  @MainActor
  func testConfirmationDialogDismissalDoesNotCancelListDeletion() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = LocalOnlyTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    let list = try XCTUnwrap(model.activeList)

    await model.prepareListDeletion(list)
    let candidate = try XCTUnwrap(model.listDeletionCandidate)
    model.cancelListDeletion()
    await model.confirmListDeletion(candidate)

    let remainingLists = try await store.fetchLists()
    XCTAssertFalse(remainingLists.contains(where: { $0.id == list.id }))
  }
}

@MainActor
private final class LocalOnlyTestReminderStore: ReminderStore {
  var onStoreChanged: (() -> Void)?
  private var lists: [ReminderListSnapshot]
  private var reminders: [ReminderSnapshot] = []
  private(set) var createdListTitles: [String] = []
  private(set) var createdReminderTitles: [String] = []

  init(startsEmpty: Bool = false) {
    lists = startsEmpty
      ? []
      : [
        ReminderListSnapshot(
          id: "local:test-list",
          title: "Local",
          accent: .fallback,
          source: .local
        )
      ]
  }

  func authorizationStatus() -> ReminderAuthorization { .denied }
  func requestFullAccess() async throws -> Bool { false }
  func fetchLists() async throws -> [ReminderListSnapshot] { lists }
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] {
    reminders.filter { $0.listID == listID }
  }

  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] {
    reminders.filter { reminder in
      guard let due = reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) }) else {
        return false
      }
      return due >= dueFrom && due <= through
    }
  }

  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] {
    reminders.filter { $0.dueDateComponents == nil }
  }

  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] {
    reminders.filter { reminder in
      guard !reminder.isCompleted,
        let due = reminder.dueDateComponents.flatMap({ Calendar.current.date(from: $0) })
      else { return false }
      return due < date
    }
  }

  func fetchCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] {
    []
  }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {
    createdReminderTitles.append(title)
    reminders.append(
      ReminderSnapshot(
        id: "local:reminder-\(reminders.count)",
        listID: listID,
        source: .local,
        title: title,
        dueDateComponents: dueComponents,
        priority: .none,
        isRecurring: false
      ))
  }

  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func deleteReminder(id: String) async throws {}

  func setCompleted(_ completed: Bool, reminderID: String) async throws {
    guard let index = reminders.firstIndex(where: { $0.id == reminderID }) else { return }
    reminders[index].isCompleted = completed
  }

  func createList(title: String, source: ReminderSource) async throws -> ReminderListSnapshot {
    createdListTitles.append(title)
    let list = ReminderListSnapshot(
      id: "local:created-\(createdListTitles.count)",
      title: title,
      accent: .fallback,
      source: .local
    )
    lists.append(list)
    return list
  }

  func deletionSummary(forListID id: String) async throws -> ReminderListDeletionSummary {
    guard let list = lists.first(where: { $0.id == id }) else {
      throw ReminderStoreError.listNotFound
    }
    return ReminderListDeletionSummary(
      list: list,
      pendingCount: reminders.filter { $0.listID == id }.count,
      completedCount: 0
    )
  }

  func deleteList(id: String) async throws {
    lists.removeAll { $0.id == id }
    reminders.removeAll { $0.listID == id }
  }

  func removeAllLists() {
    lists = []
    reminders = []
  }
}
