import XCTest

@testable import Pulse

final class ReminderModelsTests: XCTestCase {
  func testMapsAllRFC5545PriorityRanges() {
    XCTAssertEqual(ReminderPriority(eventKitValue: 0), .none)
    XCTAssertEqual(ReminderPriority(eventKitValue: 1), .high)
    XCTAssertEqual(ReminderPriority(eventKitValue: 4), .high)
    XCTAssertEqual(ReminderPriority(eventKitValue: 5), .medium)
    XCTAssertEqual(ReminderPriority(eventKitValue: 6), .low)
    XCTAssertEqual(ReminderPriority(eventKitValue: 9), .low)
  }

  func testAllDayDraftDoesNotCreateTimeComponents() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 18, minute: 45)))
    let draft = ReminderDraft(
      title: "All day",
      hasDueDate: true,
      dueDate: date,
      includesTime: false,
      priority: .none
    )

    let components = try XCTUnwrap(draft.dueComponents(calendar: calendar))
    XCTAssertEqual(components.year, 2026)
    XCTAssertEqual(components.month, 8)
    XCTAssertEqual(components.day, 12)
    XCTAssertNil(components.hour)
    XCTAssertNil(components.minute)
    XCTAssertNil(components.timeZone)
  }

  func testTimedDraftPreservesExplicitTimeZone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 18, minute: 45)))
    let singapore = try XCTUnwrap(TimeZone(identifier: "Asia/Singapore"))
    let draft = ReminderDraft(
      title: "Timed",
      hasDueDate: true,
      dueDate: date,
      includesTime: true,
      dueTimeZone: singapore,
      priority: .high
    )

    let components = try XCTUnwrap(draft.dueComponents(calendar: calendar))
    XCTAssertEqual(components.hour, 18)
    XCTAssertEqual(components.minute, 45)
    XCTAssertEqual(components.timeZone, singapore)
  }
}
