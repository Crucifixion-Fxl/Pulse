import XCTest

@testable import Pulse

final class CollapsedIslandVisibilityTests: XCTestCase {
  @MainActor
  func testMissingPreferenceDefaultsToAlwaysVisibleAndPersists() async {
    let defaults = makeDefaults()
    defer { clear(defaults) }

    let model = AppModel(store: VisibilityTestReminderStore(), defaults: defaults)

    XCTAssertEqual(model.collapsedIslandVisibility, .alwaysVisible)
    XCTAssertEqual(
      defaults.string(forKey: "collapsed-island-visibility"),
      CollapsedIslandVisibility.alwaysVisible.rawValue
    )
    XCTAssertTrue(model.isCollapsedIslandVisible)

    await model.start()
    XCTAssertEqual(model.activeListID, VisibilityTestReminderStore.listID)
  }

  /// The internal-player bridge is subscribed exactly once; collapse and
  /// suspend cycles must not accumulate duplicate objectWillChange sinks
  /// (each duplicate re-ran syncInternalPlayer on every 0.25s tick).
  @MainActor
  func testCollapseCyclesDoNotAccumulateInternalPlayerBridges() async {
    let defaults = makeDefaults()
    defer { clear(defaults) }

    let model = AppModel(store: VisibilityTestReminderStore(), defaults: defaults)
    await model.start()
    XCTAssertEqual(model.internalPlayerCancellable.count, 1)

    for _ in 0..<3 {
      model.pinIsland()
      model.collapseIsland()
    }
    XCTAssertEqual(model.internalPlayerCancellable.count, 1)
  }

  @MainActor
  func testVisibilityChoicePersists() async {
    let defaults = makeDefaults()
    defer { clear(defaults) }

    let model = AppModel(store: VisibilityTestReminderStore(), defaults: defaults)
    await model.start()

    model.setCollapsedIslandVisibility(.autoHide)

    XCTAssertEqual(model.collapsedIslandVisibility, .autoHide)
    XCTAssertEqual(
      defaults.string(forKey: "collapsed-island-visibility"),
      CollapsedIslandVisibility.autoHide.rawValue
    )
  }

  @MainActor
  func testSavedAutoHideStartsHiddenWithoutAVisibleCollapsedFlash() async {
    let defaults = makeDefaults(visibility: .autoHide)
    defer { clear(defaults) }

    let model = AppModel(store: VisibilityTestReminderStore(), defaults: defaults)
    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertFalse(model.isCollapsedIslandVisible)

    await model.start()

    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertFalse(model.isCollapsedIslandVisible)
    XCTAssertEqual(model.activeListID, VisibilityTestReminderStore.listID)
  }

  @MainActor
  func testAutoHiddenCollapsedIslandRevealsImmediatelyAndHidesAfterExitDelay() async throws {
    let defaults = makeDefaults(visibility: .autoHide)
    defer { clear(defaults) }

    let model = AppModel(store: VisibilityTestReminderStore(), defaults: defaults)
    await model.start()

    model.setIslandHovered(true)
    XCTAssertTrue(model.isCollapsedIslandVisible)
    XCTAssertEqual(model.islandState, .collapsed)

    try await Task.sleep(for: .milliseconds(50))
    model.setIslandHovered(false)
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertTrue(model.isCollapsedIslandVisible)

    try await Task.sleep(for: .milliseconds(140))
    XCTAssertFalse(model.isCollapsedIslandVisible)
    XCTAssertEqual(model.islandState, .collapsed)
  }

  @MainActor
  func testHoverRevealExitsBackToHiddenCollapsedState() async throws {
    let defaults = makeDefaults(visibility: .autoHide)
    defer { clear(defaults) }

    let model = AppModel(store: VisibilityTestReminderStore(), defaults: defaults)
    await model.start()

    // Hover reveals the bar (never expands it), and leaving returns the
    // autoHide bar to its hidden collapsed state.
    model.setIslandHovered(true)
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertTrue(model.isCollapsedIslandVisible)

    model.setIslandHovered(false)
    try await Task.sleep(for: .milliseconds(560))

    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertFalse(model.isCollapsedIslandVisible)
  }

  @MainActor
  func testAlwaysVisiblePreferenceNeverHidesOrdinaryCollapsedIsland() async throws {
    let defaults = makeDefaults(visibility: .alwaysVisible)
    defer { clear(defaults) }

    let model = AppModel(store: VisibilityTestReminderStore(), defaults: defaults)
    await model.start()
    model.setIslandHovered(true)
    model.setIslandHovered(false)

    try await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertTrue(model.isCollapsedIslandVisible)
  }

  @MainActor
  func testRecoveryStateOverridesSavedAutoHidePreference() async {
    let defaults = makeDefaults(visibility: .autoHide)
    defer { clear(defaults) }

    let store = VisibilityTestReminderStore(authorization: .denied, providesList: false)
    let model = AppModel(store: store, defaults: defaults)
    await model.start()

    XCTAssertFalse(model.canUseActiveList)
    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertTrue(model.isCollapsedIslandVisible)
  }

  @MainActor
  func testSwitchingToAutoHideDoesNotDismissExpandedIsland() async {
    let defaults = makeDefaults(visibility: .alwaysVisible)
    defer { clear(defaults) }

    let model = AppModel(store: VisibilityTestReminderStore(), defaults: defaults)
    await model.start()
    model.pinIsland()

    model.setCollapsedIslandVisibility(.autoHide)

    XCTAssertEqual(model.islandState, .pinned)
    XCTAssertTrue(model.isCollapsedIslandVisible)

    model.collapseIsland()
    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertFalse(model.isCollapsedIslandVisible)
  }

  @MainActor
  func testAuthorizationRequestWorksWithoutSavedVisibilityChoice() async {
    let defaults = makeDefaults()
    defer { clear(defaults) }

    let store = VisibilityTestReminderStore(authorization: .notDetermined)
    let model = AppModel(store: store, defaults: defaults)

    await model.requestAccess()

    XCTAssertEqual(store.authorizationRequestCount, 1)
    XCTAssertEqual(model.authorization, .fullAccess)
  }

  @MainActor
  func testBackgroundReloadDoesNotRevealAutoHiddenIsland() async throws {
    let defaults = makeDefaults(visibility: .autoHide)
    defer { clear(defaults) }

    let store = VisibilityTestReminderStore()
    let model = AppModel(store: store, defaults: defaults)
    await model.start()
    XCTAssertFalse(model.isCollapsedIslandVisible)

    store.onStoreChanged?()
    try await Task.sleep(for: .milliseconds(350))

    XCTAssertEqual(model.islandState, .collapsed)
    XCTAssertFalse(model.isCollapsedIslandVisible)
  }

  private func makeDefaults(
    visibility: CollapsedIslandVisibility? = nil
  ) -> UserDefaults {
    let suiteName = "\(#fileID).\(#function).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(suiteName, forKey: "test-suite-name")
    if let visibility {
      defaults.set(visibility.rawValue, forKey: "collapsed-island-visibility")
    }
    return defaults
  }

  private func clear(_ defaults: UserDefaults) {
    guard let suiteName = defaults.string(forKey: "test-suite-name") else { return }
    defaults.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private final class VisibilityTestReminderStore: ReminderStore {
  static let listID = "visibility-list"

  var onStoreChanged: (() -> Void)?
  var authorization: ReminderAuthorization
  let providesList: Bool
  private(set) var authorizationRequestCount = 0

  init(
    authorization: ReminderAuthorization = .fullAccess,
    providesList: Bool = true
  ) {
    self.authorization = authorization
    self.providesList = providesList
  }

  func authorizationStatus() -> ReminderAuthorization { authorization }

  func requestFullAccess() async throws -> Bool {
    authorizationRequestCount += 1
    authorization = .fullAccess
    return true
  }

  func fetchLists() async throws -> [ReminderListSnapshot] {
    guard providesList, authorization == .fullAccess else { return [] }
    return [
      ReminderListSnapshot(id: Self.listID, title: "Visibility", accent: .fallback)
    ]
  }

  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] { [] }
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] { [] }
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] { [] }

  func createReminder(
    title: String,
    in listID: String,
    dueComponents: DateComponents?
  ) async throws {}
  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func setCompleted(_ completed: Bool, reminderID: String) async throws {}
  func deleteReminder(id: String) async throws {}
}
