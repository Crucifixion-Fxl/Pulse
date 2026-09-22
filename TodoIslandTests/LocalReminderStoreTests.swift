import XCTest

@testable import TodoIsland

final class LocalReminderStoreTests: XCTestCase {
  @MainActor
  func testLocalListAndReminderLifecycleRetainsCompletedItemsUntilListDeletion() async throws {
    let store = try LocalReminderStore(isStoredInMemoryOnly: true)
    let list = try await store.createList(title: "Personal")

    XCTAssertEqual(list.source, .local)
    let initialLists = try await store.fetchLists()
    XCTAssertEqual(initialLists, [list])

    try await store.createReminder(title: "Buy coffee", in: list.id, dueComponents: nil)
    var pending = try await store.fetchPendingReminders(in: list.id)
    var reminder = try XCTUnwrap(pending.first)
    XCTAssertEqual(reminder.source, .local)
    XCTAssertFalse(reminder.isRecurring)

    let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
    let draft = ReminderDraft(
      title: "Buy beans",
      hasDueDate: true,
      dueDate: dueDate,
      includesTime: true,
      dueTimeZone: TimeZone(identifier: "Asia/Singapore"),
      priority: .high
    )
    try await store.updateReminder(id: reminder.id, from: draft)
    pending = try await store.fetchPendingReminders(in: list.id)
    reminder = try XCTUnwrap(pending.first)
    XCTAssertEqual(reminder.title, "Buy beans")
    XCTAssertEqual(reminder.priority, .high)
    XCTAssertEqual(reminder.dueDateComponents?.timeZone?.identifier, "Asia/Singapore")

    try await store.setCompleted(true, reminderID: reminder.id)
    pending = try await store.fetchPendingReminders(in: list.id)
    XCTAssertTrue(pending.isEmpty)

    let summary = try await store.deletionSummary(forListID: list.id)
    XCTAssertEqual(summary.pendingCount, 0)
    XCTAssertEqual(summary.completedCount, 1)

    try await store.deleteList(id: list.id)
    let remainingLists = try await store.fetchLists()
    XCTAssertTrue(remainingLists.isEmpty)
  }

  @MainActor
  func testLocalListNamesAreUniqueIgnoringCase() async throws {
    let store = try LocalReminderStore(isStoredInMemoryOnly: true)
    _ = try await store.createList(title: "Personal")

    do {
      _ = try await store.createList(title: "personal")
      XCTFail("Expected a duplicate-name error")
    } catch let error as ReminderStoreError {
      guard case .duplicateListName = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testNamespacedIdentityRoundTripsColonsInRawIdentifiers() throws {
    let id = ReminderStoreIdentity.namespaced("calendar:item:42", source: .iCloud)
    let parsed = try XCTUnwrap(ReminderStoreIdentity.split(id))

    XCTAssertEqual(parsed.source, .iCloud)
    XCTAssertEqual(parsed.rawID, "calendar:item:42")
  }

  @MainActor
  func testSourceAwareStoreNamespacesAndRoutesLocalOperations() async throws {
    let local = try LocalReminderStore(isStoredInMemoryOnly: true)
    let store = SourceAwareReminderStore(localStoreFactory: { local })

    let list = try await store.createList(title: "Private", source: .local)
    XCTAssertEqual(ReminderStoreIdentity.split(list.id)?.source, .local)

    try await store.createReminder(title: "Only here", in: list.id, dueComponents: nil)
    let reminders = try await store.fetchPendingReminders(in: list.id)

    XCTAssertEqual(reminders.map(\.title), ["Only here"])
    XCTAssertEqual(reminders.first?.source, .local)
    XCTAssertEqual(ReminderStoreIdentity.split(reminders.first?.id ?? "")?.source, .local)
  }

  @MainActor
  func testDayRangeFetchIncludesCompletedAndExcludesUndated() async throws {
    let store = try LocalReminderStore(isStoredInMemoryOnly: true)
    let list = try await store.createList(title: "Personal")

    try await store.createReminder(title: "Undated", in: list.id, dueComponents: nil)
    try await store.createReminder(
      title: "Dated",
      in: list.id,
      dueComponents: DateComponents(year: 2026, month: 9, day: 22, hour: 8)
    )
    let pending = try await store.fetchPendingReminders(in: list.id)
    let dated = try XCTUnwrap(pending.first { $0.title == "Dated" })
    try await store.setCompleted(true, reminderID: dated.id)

    let calendar = Calendar.current
    let dayStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

    let dayReminders = try await store.fetchReminders(dueFrom: dayStart, through: dayEnd)
    XCTAssertEqual(dayReminders.map(\.title), ["Dated"])
    XCTAssertTrue(try XCTUnwrap(dayReminders.first).isCompleted)

    let undated = try await store.fetchUndatedPendingReminders()
    XCTAssertEqual(undated.map(\.title), ["Undated"])
  }

  @MainActor
  func testSourceAwareDayFetchNamespacesDatedReminders() async throws {
    let local = try LocalReminderStore(isStoredInMemoryOnly: true)
    let store = SourceAwareReminderStore(localStoreFactory: { local })
    let list = try await store.createList(title: "Private", source: .local)

    try await store.createReminder(
      title: "Scheduled",
      in: list.id,
      dueComponents: DateComponents(year: 2026, month: 9, day: 22, hour: 9)
    )

    let calendar = Calendar.current
    let dayStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

    let reminders = try await store.fetchReminders(dueFrom: dayStart, through: dayEnd)
    XCTAssertEqual(reminders.map(\.title), ["Scheduled"])
    XCTAssertEqual(ReminderStoreIdentity.split(reminders.first?.id ?? "")?.source, .local)
    let undated = try await store.fetchUndatedPendingReminders()
    XCTAssertTrue(undated.isEmpty)
  }
}
