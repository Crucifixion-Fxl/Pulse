import AppKit
import SwiftUI
import XCTest
@testable import Pulse

@MainActor
final class MusicLyricsScrollingTests: XCTestCase {
  func testSeekingBeforeFirstLyricReturnsToTop() async throws {
    let fixture = try await fixture(elapsed: 35, playing: false)
    defer { fixture.window.close() }
    let scroll = fixture.scroll
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500,
      "Opening a song mid-playback must position its current lyric")
    fixture.model.nowPlayingDidChange(track(elapsed: 0, playing: false))
    try await Task.sleep(for: .milliseconds(750))
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1,
      "Seeking into the intro must not leave later lyrics on screen")
  }

  func testPlaybackAdvancesScrollAndPauseKeepsPosition() async throws {
    let fixture = try await fixture(elapsed: 25, playing: true)
    defer { fixture.window.close() }
    let initial = fixture.scroll.contentView.bounds.minY
    try await Task.sleep(for: .milliseconds(1400))
    XCTAssertGreaterThan(fixture.scroll.contentView.bounds.minY, initial + 20,
      "The running playback clock must advance the lyric scroll")
    fixture.model.nowPlayingDidChange(track(elapsed: 28, playing: false))
    try await Task.sleep(for: .milliseconds(750))
    let pausedScroll = try XCTUnwrap(scrollViews(fixture.window.contentView!).first)
    let paused = pausedScroll.contentView.bounds.minY
    try await Task.sleep(for: .milliseconds(1100))
    XCTAssertEqual(pausedScroll.contentView.bounds.minY, paused, accuracy: 1)
    XCTAssertGreaterThan(paused, 500, "Pause must not reset the lyric list")
  }

  func testChangingSongsAtTheSameLineIndexRepositionsForNewRowHeights() async throws {
    let fixture = try await fixture(elapsed: 35, playing: false)
    defer { fixture.window.close() }
    let previous = fixture.scroll.contentView.bounds.minY
    var next = track(elapsed: 35, playing: false)
    next.title = "Second song"
    fixture.model.nowPlayingDidChange(next)
    try await Task.sleep(for: .milliseconds(400))
    let scroll = try XCTUnwrap(scrollViews(fixture.window.contentView!).first)
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, previous + 500,
      "A new song must center its current row even when its line index is unchanged")
  }

  private func fixture(elapsed: Double, playing: Bool) async throws
    -> (window: NSWindow, model: AppModel, scroll: NSScrollView) {
    let suite = "MusicLyricsScroll-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults,
      lyricsService: LyricsService(providers: [ScrollingLyricsProvider()]))
    model.nowPlayingDidChange(track(elapsed: elapsed, playing: playing))
    try await Task.sleep(for: .milliseconds(50))
    guard case .loaded = model.lyricsState else {
      XCTFail("Fixture lyrics did not load")
      throw NSError(domain: "MusicLyricsScrollingTests", code: 1)
    }
    let host = NSHostingView(rootView: MusicPanelView().environmentObject(model))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 324),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(scrollViews(host).first)
    XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, 1000)
    return (window, model, scroll)
  }

  private func track(elapsed: Double, playing: Bool) -> NowPlayingTrack {
    NowPlayingTrack(title: "Scroll fixture", artist: "Test", album: "", artworkData: nil,
      duration: 100, elapsed: elapsed, isPlaying: playing, playbackRate: playing ? 1 : 0)
  }

  private func scrollViews(_ view: NSView) -> [NSScrollView] {
    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
  }
}

private struct ScrollingLyricsProvider: LyricsProvider {
  func fetchLyrics(title: String, artist: String, duration: TimeInterval) async -> Lyrics? {
    let prefix = title == "Second song"
      ? "A longer second song lyric that wraps onto several lines"
      : "Fixture lyric"
    return Lyrics(timedLines: (0..<50).map { (Double($0 + 10), "\(prefix) \($0)") })
  }
}
