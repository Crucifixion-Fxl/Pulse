import AppKit
import CryptoKit
import QuartzCore
import XCTest
@testable import TodoIsland

@MainActor
final class RunningCharacterTests: XCTestCase {
  private func calendar(_ zone: String = "Asia/Singapore") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

  func testSevenDaysRemainStableAcrossRestartAndWrapAtLocalMidnight() throws {
    let cal = calendar()
    let monday = date("2026-10-18T16:00:00Z")
    let expected = ["sigewinne", "furina", "navia", "nahida", "clorinde", "emilie", "chasca"]
    XCTAssertEqual(RunnerArtwork.characters.map(\.id), expected)
    for (day, id) in expected.enumerated() {
      let start = cal.date(byAdding: .day, value: day, to: monday)!
      XCTAssertEqual(RunnerArtwork.character(on: start, calendar: cal)?.id, id)
      XCTAssertEqual(RunnerArtwork.character(on: start.addingTimeInterval(86399), calendar: cal)?.id, id)
    }
    XCTAssertEqual(RunnerArtwork.character(on: monday.addingTimeInterval(-1), calendar: cal)?.id, "chasca")
    XCTAssertEqual(RunnerArtwork.character(on: cal.date(byAdding: .day, value: 7, to: monday)!, calendar: cal)?.id, "sigewinne")
    // The same instant can belong to different local dates after a time-zone change.
    XCTAssertEqual(RunnerArtwork.character(on: monday, calendar: calendar("America/Los_Angeles"))?.id, "chasca")
  }

  func testNextMidnightUsesCalendarDaysAcrossDaylightSaving() {
    let cal = calendar("America/Los_Angeles")
    let spring = date("2026-03-08T08:00:00Z")
    let autumn = date("2026-11-01T07:00:00Z")
    XCTAssertEqual(RunnerArtwork.nextDay(after: spring, calendar: cal).timeIntervalSince(spring), 23 * 3600)
    XCTAssertEqual(RunnerArtwork.nextDay(after: autumn, calendar: cal).timeIntervalSince(autumn), 25 * 3600)
  }

  func testEveryBundledCharacterHasDistinctTransparentFramesAtSixtyFPS() throws {
    XCTAssertEqual(RunnerArtwork.characters.count, 7)
    for character in RunnerArtwork.characters {
      let clip = try RunnerArtwork.load(character)
      XCTAssertEqual(clip.frames.count, character.frameCount)
      XCTAssertLessThanOrEqual(character.duration / Double(character.frameCount), 1.0 / 60 + 0.00001)
      let hashes = try clip.frames.map { frame -> String in
        let data = try XCTUnwrap(frame.dataProvider?.data)
        return SHA256.hash(data: data as Data).description
      }
      XCTAssertEqual(Set(hashes).count, hashes.count, "\(character.id): do not repeat poses to inflate the frame rate")
      let bitmap = NSBitmapImageRep(cgImage: clip.frames[0])
      XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
      XCTAssertThrowsError(try RunnerArtwork.verifiedFrames(Data("invalid".utf8), character: character))
    }
  }

  func testStoreChangesAtMidnightAndFreshStoreKeepsSameCharacter() async throws {
    let store = RunnerArtworkStore(), fresh = RunnerArtworkStore()
    let cal = calendar()
    let before = date("2026-10-19T15:59:59Z"), after = before.addingTimeInterval(1)
    await store.refresh(for: before, calendar: cal)
    XCTAssertEqual(store.clip?.character.id, "sigewinne")
    let original = store.clip?.frames.first
    await store.refresh(for: before, calendar: cal)
    XCTAssertTrue(original === store.clip?.frames.first, "Unrelated refresh must not reload/restart animation")
    await store.refresh(for: after, calendar: cal)
    await fresh.refresh(for: after, calendar: cal)
    XCTAssertEqual(store.clip?.character.id, "furina")
    XCTAssertEqual(store.clip?.character, fresh.clip?.character)
    // An older decode completing later must not replace the newer day.
    let older = Task { await store.refresh(for: before, calendar: cal) }
    await Task.yield()
    await store.refresh(for: after, calendar: cal)
    await older.value
    XCTAssertEqual(store.clip?.character.id, "furina")
  }

  func testNativePlaybackPreservesTimingChangesCharacterAndStops() throws {
    let first = try RunnerArtwork.load(XCTUnwrap(RunnerArtwork.characters.first))
    let second = try RunnerArtwork.load(XCTUnwrap(RunnerArtwork.characters.last))
    let view = RunnerSpriteView(frame: NSRect(x: 0, y: 0, width: 52, height: 32))
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    view.update(clip: first, isPlaying: true)
    let animation = try XCTUnwrap(view.sprite.animation(forKey: "run") as? CAKeyframeAnimation)
    XCTAssertEqual(animation.duration, first.character.duration)
    XCTAssertEqual(animation.values?.count, first.frames.count + 1)
    XCTAssertEqual(animation.repeatCount, .infinity)
    view.update(clip: second, isPlaying: true)
    XCTAssertEqual(view.sprite.animation(forKey: "run")?.duration, second.character.duration)
    view.update(clip: second, isPlaying: false)
    XCTAssertNil(view.sprite.animation(forKey: "run"))
    XCTAssertNotNil(view.sprite.contents)
    view.update(clip: second, isPlaying: true)
    XCTAssertNotNil(view.sprite.animation(forKey: "run"))
    view.removeFromSuperview()
    XCTAssertNil(view.sprite.animation(forKey: "run"))
  }

  func testCharacterSitsBetweenWeatherAndBotAndFadesWithHeader() {
    let runner = NSView(), weather = NSView(), bot = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: bot, additionalQuotas: NSView(),
      weather: weather, runner: runner, barHeight: 32)
    header.settle(size: CGSize(width: 760, height: 360), state: .pinned)
    XCTAssertGreaterThan(weather.frame.minX, 480)
    XCTAssertLessThan(weather.frame.maxX, runner.frame.minX)
    XCTAssertLessThan(runner.frame.maxX, bot.frame.minX)
    XCTAssertEqual(runner.layer?.opacity, 1)
    header.settle(size: CGSize(width: 340, height: 32), state: .collapsed)
    XCTAssertEqual(runner.layer?.opacity, 0)
    header.settle(size: CGSize(width: 760, height: 360), state: .pinned)
    XCTAssertEqual(runner.layer?.opacity, 1)
  }
}
