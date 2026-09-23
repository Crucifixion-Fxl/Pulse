import XCTest

@testable import TodoIsland

final class IslandStateTests: XCTestCase {
  func testMotionProfilesUseSmoothStateSpecificTiming() {
    XCTAssertEqual(
      IslandPresentationState.preview.motionProfile,
      IslandMotionProfile(response: 0.5, dampingFraction: 0.68)
    )
    XCTAssertEqual(
      IslandPresentationState.pinned.motionProfile,
      IslandMotionProfile(response: 0.44, dampingFraction: 0.75)
    )
    XCTAssertEqual(
      IslandPresentationState.collapsed.motionProfile,
      IslandMotionProfile(response: 0.24, dampingFraction: 1.0)
    )
  }

  @MainActor
  func testCompletedReminderShowsCheckForTwoHundredMillisecondsBeforeRemoval() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = CompletionFeedbackTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    let reminder = try XCTUnwrap(model.reminders.first)

    model.complete(reminder)

    XCTAssertTrue(model.completingReminderIDs.contains(reminder.id))
    XCTAssertTrue(model.reminders.contains(where: { $0.id == reminder.id }))

    try await Task.sleep(for: .milliseconds(120))
    XCTAssertTrue(model.completingReminderIDs.contains(reminder.id))
    XCTAssertTrue(model.reminders.contains(where: { $0.id == reminder.id }))

    try await Task.sleep(for: .milliseconds(140))
    XCTAssertFalse(model.completingReminderIDs.contains(reminder.id))
    XCTAssertFalse(model.reminders.contains(where: { $0.id == reminder.id }))
    XCTAssertEqual(store.completedReminderIDs, [reminder.id])
  }

  @MainActor
  func testLeavingBeforePreviewDelayKeepsIslandCollapsed() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defaults.set(
      CollapsedIslandVisibility.alwaysVisible.rawValue,
      forKey: "collapsed-island-visibility"
    )
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: HoverTestReminderStore(), defaults: defaults)
    model.setIslandHovered(true)
    model.setIslandHovered(false)

    try await Task.sleep(for: .milliseconds(250))

    XCTAssertEqual(model.islandState, .collapsed)
  }

  @MainActor
  func testPreviewCollapsesHalfSecondAfterPointerLeaves() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defaults.set(
      CollapsedIslandVisibility.alwaysVisible.rawValue,
      forKey: "collapsed-island-visibility"
    )
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: HoverTestReminderStore(), defaults: defaults)
    model.setIslandHovered(true)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(model.islandState, .preview)

    model.setIslandHovered(false)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(model.islandState, .preview)

    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(model.islandState, .collapsed)
  }

  @MainActor
  func testPinnedIslandCollapsesTwoHundredMillisecondsAfterPointerLeaves() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: ListSelectionTestReminderStore(), defaults: defaults)
    await model.start()
    XCTAssertTrue(model.reminders.isEmpty)

    model.pinIsland()
    model.setIslandHovered(true)
    model.setIslandHovered(false)

    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(model.islandState, .pinned)

    try await Task.sleep(for: .milliseconds(140))
    XCTAssertEqual(model.islandState, .collapsed)
  }

  @MainActor
  func testPinnedIslandCancelsCollapseWhenPointerReturnsWithinTwoHundredMilliseconds()
    async throws
  {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: ListSelectionTestReminderStore(), defaults: defaults)
    await model.start()
    model.pinIsland()
    model.setIslandHovered(true)
    model.setIslandHovered(false)

    try await Task.sleep(for: .milliseconds(100))
    model.setIslandHovered(true)
    try await Task.sleep(for: .milliseconds(180))

    XCTAssertEqual(model.islandState, .pinned)
  }

  @MainActor
  func testReminderDraftSurvivesAutoCollapseAndResumesWhenPointerReturns() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: CompletionFeedbackTestReminderStore(), defaults: defaults)
    await model.start()
    let reminder = try XCTUnwrap(model.reminders.first)
    model.pinIsland()
    model.beginEditing(reminder)
    model.draft?.title = "Continue editing"
    let focusRequestBeforeCollapse = model.editingFocusRequestID
    model.setIslandHovered(true)
    model.setIslandHovered(false)

    try await Task.sleep(for: .milliseconds(260))

    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertEqual(model.editingReminderID, reminder.id)
    XCTAssertEqual(model.draft?.title, "Continue editing")

    model.setIslandHovered(true)

    XCTAssertEqual(model.islandState, .pinned)
    XCTAssertEqual(model.editingReminderID, reminder.id)
    XCTAssertEqual(model.draft?.title, "Continue editing")
    XCTAssertNotEqual(model.editingFocusRequestID, focusRequestBeforeCollapse)
  }

  @MainActor
  func testPinnedNoListRecoveryStaysOpenAfterPointerLeaves() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: NoListTestReminderStore(), defaults: defaults)
    await model.start()
    model.pinIsland()
    model.setIslandHovered(true)
    model.setIslandHovered(false)

    try await Task.sleep(for: .milliseconds(600))

    XCTAssertTrue(model.lists.isEmpty)
    XCTAssertEqual(model.islandState, .pinned)
  }

  @MainActor
  func testPinnedLockedIslandStaysOpenAfterPointerLeaves() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: HoverTestReminderStore(), defaults: defaults)
    model.pinIsland()
    model.setIslandHovered(true)
    model.setIslandHovered(false)

    try await Task.sleep(for: .milliseconds(600))

    XCTAssertEqual(model.authorization, .denied)
    XCTAssertEqual(model.islandState, .pinned)
  }

  @MainActor
  func testCompletingLastReminderAllowsPinnedIslandToAutoCollapse() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = CompletionFeedbackTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    let reminder = try XCTUnwrap(model.reminders.first)
    model.pinIsland()
    model.setIslandHovered(true)
    model.setIslandHovered(false)

    model.complete(reminder)
    try await Task.sleep(for: .milliseconds(850))

    XCTAssertTrue(model.reminders.isEmpty)
    XCTAssertEqual(model.islandState, .collapsed)
  }

  func testPreviewNeverPinsWithoutClick() {
    var machine = IslandStateMachine()
    machine.pointerEntered()
    XCTAssertEqual(machine.state, .preview)
    machine.pointerExited()
    XCTAssertEqual(machine.state, .collapsed)
  }

  @MainActor
  func testWindowAppliesTheStateEmittedByPublishedTransition() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: HoverTestReminderStore(), defaults: defaults)
    let controller = IslandWindowController(model: model)

    model.pinIsland()
    XCTAssertEqual(model.islandState, .pinned)
    XCTAssertEqual(controller.appliedState, .pinned)

    model.collapseIsland()
    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertEqual(controller.appliedState, .collapsed)
  }

  func testPinnedStateIgnoresPointerExitUntilDismissed() {
    var machine = IslandStateMachine()
    machine.pointerEntered()
    machine.click()
    machine.pointerExited()
    XCTAssertEqual(machine.state, .pinned)
    machine.dismiss()
    XCTAssertEqual(machine.state, .collapsed)
  }

  @MainActor
  func testPanelKeyLossForMenuDoesNotDismissPinnedIsland() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let model = AppModel(store: HoverTestReminderStore(), defaults: defaults)
    let controller = IslandWindowController(model: model)
    model.pinIsland()

    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

    XCTAssertEqual(model.islandState, .pinned)
  }

  @MainActor
  func testSelectingListKeepsPinnedIslandOpenAndLoadsThatList() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    defer { defaults.removePersistentDomain(forName: #function) }

    let store = ListSelectionTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    model.pinIsland()

    model.selectList("second-list")
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(model.islandState, .pinned)
    XCTAssertEqual(model.activeListID, "second-list")
    XCTAssertEqual(model.reminders.map(\.title), ["Second list reminder"])
  }
}

@MainActor
private final class HoverTestReminderStore: ReminderStore {
  var onStoreChanged: (() -> Void)?

  func authorizationStatus() -> ReminderAuthorization { .denied }
  func requestFullAccess() async throws -> Bool { false }
  func fetchLists() async throws -> [ReminderListSnapshot] { [] }
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] { [] }
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] { [] }
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] { [] }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {}
  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func setCompleted(_ completed: Bool, reminderID: String) async throws {}
  func deleteReminder(id: String) async throws {}
}

@MainActor
private final class ListSelectionTestReminderStore: ReminderStore {
  var onStoreChanged: (() -> Void)?

  private let availableLists = [
    ReminderListSnapshot(
      id: "first-list", title: "First", accent: .fallback),
    ReminderListSnapshot(
      id: "second-list", title: "Second", accent: .fallback),
  ]

  func authorizationStatus() -> ReminderAuthorization { .fullAccess }
  func requestFullAccess() async throws -> Bool { true }
  func fetchLists() async throws -> [ReminderListSnapshot] { availableLists }

  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] {
    guard listID == "second-list" else { return [] }
    return [
      ReminderSnapshot(
        id: "second-reminder",
        listID: listID,
        title: "Second list reminder",
        dueDateComponents: nil,
        priority: .none,
        isRecurring: false
      )
    ]
  }

  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] { [] }
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] { [] }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {}
  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func setCompleted(_ completed: Bool, reminderID: String) async throws {}
  func deleteReminder(id: String) async throws {}
}

@MainActor
private final class CompletionFeedbackTestReminderStore: ReminderStore {
  var onStoreChanged: (() -> Void)?
  private(set) var completedReminderIDs: [String] = []
  private var pendingReminders = [
    ReminderSnapshot(
      id: "completion-reminder",
      listID: "completion-list",
      title: "Complete me",
      dueDateComponents: nil,
      priority: .none,
      isRecurring: false
    )
  ]

  func authorizationStatus() -> ReminderAuthorization { .fullAccess }
  func requestFullAccess() async throws -> Bool { true }
  func fetchLists() async throws -> [ReminderListSnapshot] {
    [ReminderListSnapshot(id: "completion-list", title: "Test", accent: .fallback)]
  }
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] {
    pendingReminders
  }
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] { [] }
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] { [] }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {}
  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func setCompleted(_ completed: Bool, reminderID: String) async throws {
    guard completed else { return }
    completedReminderIDs.append(reminderID)
    pendingReminders.removeAll { $0.id == reminderID }
  }
  func deleteReminder(id: String) async throws {}
}

@MainActor
private final class NoListTestReminderStore: ReminderStore {
  var onStoreChanged: (() -> Void)?

  func authorizationStatus() -> ReminderAuthorization { .fullAccess }
  func requestFullAccess() async throws -> Bool { true }
  func fetchLists() async throws -> [ReminderListSnapshot] { [] }
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] { [] }
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] { [] }
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] { [] }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {}
  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func setCompleted(_ completed: Bool, reminderID: String) async throws {}
  func deleteReminder(id: String) async throws {}
}
