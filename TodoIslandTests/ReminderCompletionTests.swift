import AppKit
import SwiftUI
import XCTest
@testable import TodoIsland

@MainActor
final class ReminderCompletionTests: XCTestCase {
  private func fixture(
    hold: Duration = .milliseconds(100), expiry: Duration = .seconds(8)
  ) async -> (AppModel, CompletionStore) {
    let defaults = UserDefaults(suiteName: "CompletionTests-\(UUID())")!
    let store = CompletionStore()
    let model = AppModel(
      store: store, defaults: defaults,
      completionFeedbackDuration: hold, completionUndoDuration: expiry)
    await model.reload()
    return (model, store)
  }

  private func settle(_ milliseconds: Int = 180) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
  }

  func testUndoDuringFeedbackCannotBeRemovedByOldFinalizer() async throws {
    let (model, store) = await fixture(hold: .milliseconds(150))
    let reminder = store.items[0]
    model.complete(reminder)
    try await settle(20)
    XCTAssertEqual(model.completionUndoItems.last?.reminder.id, reminder.id)
    await model.undoLastCompletion()
    try await settle(200)
    XCTAssertFalse(store.items[0].isCompleted)
    XCTAssertTrue(model.visibleScheduleReminders.contains { $0.id == reminder.id })
    XCTAssertFalse(model.completingReminderIDs.contains(reminder.id))
    XCTAssertTrue(model.completionUndoItems.isEmpty)
  }

  func testRapidCompletionsUndoInClickOrderAndDoNotScroll() async throws {
    let (model, store) = await fixture()
    store.delayFirstSave = true
    let scrollRequest = model.selectionScrollRequestID
    model.selectedReminderID = store.items[0].id
    for reminder in store.items.prefix(3) { model.complete(reminder) }
    // Repeated clicks while saving must not produce duplicate writes.
    model.complete(store.items[0])
    try await settle(250)
    XCTAssertEqual(store.completedWrites.count, 3)
    XCTAssertEqual(model.completionUndoItems.map(\.reminder.id), ["a", "b", "c"])
    XCTAssertEqual(model.selectionScrollRequestID, scrollRequest)
    XCTAssertTrue(["d", "e", "f"].contains(model.selectedReminderID ?? ""))

    for id in ["c", "b", "a"] {
      XCTAssertEqual(model.completionUndoItems.last?.reminder.id, id)
      await model.undoLastCompletion()
    }
    XCTAssertTrue(store.items.allSatisfy { !$0.isCompleted })
    XCTAssertEqual(model.visibleScheduleReminders.count, store.items.count)
    XCTAssertTrue(model.completionUndoItems.isEmpty)
  }

  func testStoreRefreshKeepsPendingRowThroughFeedback() async throws {
    let (model, store) = await fixture(hold: .milliseconds(200))
    model.complete(store.items[0])
    try await settle(20)
    await model.reload()
    XCTAssertTrue(model.reminders.contains { $0.id == "a" })
    XCTAssertTrue(model.visibleScheduleReminders.contains { $0.id == "a" })
    try await settle(250)
    XCTAssertFalse(model.visibleScheduleReminders.contains { $0.id == "a" })
  }

  func testSaveFailureRollsBackFeedbackWithoutUndoOffer() async throws {
    let (model, store) = await fixture()
    store.failSave = true
    model.complete(store.items[0])
    try await settle()
    XCTAssertFalse(store.items[0].isCompleted)
    XCTAssertTrue(model.completingReminderIDs.isEmpty)
    XCTAssertTrue(model.completionUndoItems.isEmpty)
    XCTAssertTrue(model.visibleScheduleReminders.contains { $0.id == "a" })
    XCTAssertNotNil(model.errorMessage)
  }

  func testFailedUndoRemainsRetryable() async throws {
    let (model, store) = await fixture()
    model.complete(store.items[0])
    try await settle()
    store.failUndo = true
    await model.undoLastCompletion()
    XCTAssertTrue(store.items[0].isCompleted)
    XCTAssertEqual(model.completionUndoItems.count, 1)
    XCTAssertFalse(model.isUndoingCompletion)
    store.failUndo = false
    await model.undoLastCompletion()
    XCTAssertFalse(store.items[0].isCompleted)
    XCTAssertTrue(model.completionUndoItems.isEmpty)
  }

  func testNewCompletionRenewsUndoWindowAndExpiryDoesNotReopenItems() async throws {
    let (model, store) = await fixture(expiry: .milliseconds(250))
    model.complete(store.items[0])
    try await settle(170)
    model.complete(store.items[1])
    try await settle(170)
    XCTAssertEqual(model.completionUndoItems.count, 2, "Cancelled timeout cleared a newer undo")
    try await settle(180)
    XCTAssertTrue(model.completionUndoItems.isEmpty)
    XCTAssertTrue(store.items[0].isCompleted)
    XCTAssertTrue(store.items[1].isCompleted)
  }

  func testReduceMotionUsesShortFeedbackAndStillSupportsUndo() async throws {
    let (model, store) = await fixture(hold: .seconds(2))
    model.complete(store.items[0], reduceMotion: true)
    try await settle(250)
    XCTAssertFalse(model.visibleScheduleReminders.contains { $0.id == "a" })
    XCTAssertEqual(model.completionUndoItems.count, 1)
    await model.undoLastCompletion()
    XCTAssertTrue(model.visibleScheduleReminders.contains { $0.id == "a" })
  }

  /// Opt-in live view for CUA inspection. Runs the production view and model
  /// against an in-memory store; never changes the user's reminders or hooks.
  /// Set DOISLAND_COMPLETION_UI_PROBE=1 in the test host's EnvironmentVariables.
  func testInteractiveCompletionSurface() async throws {
    guard ProcessInfo.processInfo.environment["DOISLAND_COMPLETION_UI_PROBE"] == "1" else {
      throw XCTSkip("Opt-in interactive rendering probe")
    }
    let (model, _) = await fixture(hold: .milliseconds(750))
    model.pinIslandForApproval()
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 150, width: 760, height: 420),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "TodoIsland — completion interaction probe"
    window.isReleasedWhenClosed = false
    window.backgroundColor = .black
    window.contentView = NSHostingView(rootView:
      IslandRootView()
        .environmentObject(model)
        .environmentObject(AgentSessionStore())
        .frame(width: 760, height: 420))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .seconds(90))
    window.close()
  }
}

@MainActor
private final class CompletionStore: ReminderStore {
  var onStoreChanged: (() -> Void)?
  var failSave = false
  var failUndo = false
  var delayFirstSave = false
  var completedWrites: [String] = []
  var items: [ReminderSnapshot] = zip(["a", "b", "c", "d", "e", "f"], [
    "检查对勾描出与标题淡化", "连续完成时保持阅读位置", "点击撤销恢复上一项", "检查最后一项的空状态", "键盘上下选择与空格完成", "减少动态效果仍可撤销",
  ]).map { id, title in
    ReminderSnapshot(id: id, listID: "probe", title: title,
      dueDateComponents: Calendar.current.dateComponents([.year, .month, .day], from: Date()),
      priority: .none, isRecurring: false)
  }
  func authorizationStatus() -> ReminderAuthorization { .fullAccess }
  func requestFullAccess() async throws -> Bool { true }
  func fetchLists() async throws -> [ReminderListSnapshot] {
    [ReminderListSnapshot(id: "probe", title: "交互验收", accent: .fallback)]
  }
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] {
    items.filter { !$0.isCompleted }
  }
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] { items }
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] { [] }
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] {
    items.filter(\.isCompleted)
  }
  func createReminder(title: String, in listID: String, dueComponents: DateComponents?) async throws {}
  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func setCompleted(_ completed: Bool, reminderID: String) async throws {
    if completed && delayFirstSave && reminderID == "a" {
      try await Task.sleep(for: .milliseconds(60))
    }
    if completed ? failSave : failUndo { throw ReminderStoreError.operationUnsupported }
    if completed { completedWrites.append(reminderID) }
    let index = items.firstIndex { $0.id == reminderID }!
    let item = items[index]
    items[index] = ReminderSnapshot(
      id: item.id, listID: item.listID, source: item.source, title: item.title,
      dueDateComponents: item.dueDateComponents, priority: item.priority,
      isRecurring: item.isRecurring, isCompleted: completed,
      completionDate: completed ? Date() : nil)
  }
  func deleteReminder(id: String) async throws {}
}
