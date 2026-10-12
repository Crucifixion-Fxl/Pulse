import XCTest
@testable import TodoIsland

final class MusicTests: XCTestCase {
  // MARK: LRC parsing

  func testLRCParsesTimestampsAndSorts() {
    let lrc = """
      [00:05.00]second
      [00:01.00]first
      """
    let lines = LyricsParse.timedLines(lrc)
    XCTAssertEqual(lines.map(\.time), [1, 5])
    XCTAssertEqual(lines.map(\.text), ["first", "second"])
  }

  func testLRCParsesFractionsAndMultiTimestamps() {
    let lrc = "[1:02.5]a\n[00:12.250]b\n[00:12.00][01:30.0]chorus"
    let lines = LyricsParse.timedLines(lrc)
    // 1:02.5 → 62.5; .250 → 0.25 s; multi-timestamp expands to two entries.
    XCTAssertEqual(
      lines.map(\.time), [12.0, 12.25, 62.5, 90.0]
    )
    XCTAssertEqual(lines.map(\.text), ["chorus", "b", "a", "chorus"])
  }

  func testLRCDropsMetadataAndEmptyLines() {
    let lrc = """
      [ti:Title]
      [ar:Artist]
      [offset:500]

      [00:01.00]
      [00:02.00]line
      """
    let lines = LyricsParse.timedLines(lrc)
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(lines[0].text, "line")
  }

  func testLRCIgnoresMalformedLines() {
    let lrc = """
      [12:xx]dropped
      []dropped
      no timestamp dropped
      [00:03.00]kept
      """
    let lines = LyricsParse.timedLines(lrc)
    XCTAssertEqual(lines.map(\.text), ["kept"])
  }

  func testTranslationMergesByNearestTimestamp() {
    let original = "[00:01.00]你好\n[00:05.00]世界"
    let translation = "[00:01.00]Hello\n[00:05.30]World"
    let lyrics = LyricsParse.lyrics(original: original, translation: translation)
    let lines = try! XCTUnwrap(lyrics).lines
    XCTAssertEqual(lines[0].translation, "Hello")
    XCTAssertEqual(lines[1].translation, "World")  // 0.3 s off, within tolerance
    XCTAssertNotNil(lyrics?.hasTranslation)
  }

  func testLyricsWithoutTranslation() {
    let lyrics = LyricsParse.lyrics(original: "[00:01.00]solo", translation: nil)
    XCTAssertEqual(try! XCTUnwrap(lyrics).lines.count, 1)
    XCTAssertFalse(lyrics!.hasTranslation)
  }

  func testLyricsNilForUnparseableOriginal() {
    XCTAssertNil(LyricsParse.lyrics(original: "[ti:only metadata]", translation: nil))
    XCTAssertNil(LyricsParse.lyrics(original: "", translation: nil))
  }

  func testCurrentLineIndexBoundaries() {
    let lyrics = LyricsParse.lyrics(original: "[00:10.00]a\n[00:20.00]b", translation: nil)!
    let lines = lyrics.lines
    XCTAssertNil(LyricsParse.currentLineIndex(at: 5, lines: lines))
    XCTAssertEqual(LyricsParse.currentLineIndex(at: 10, lines: lines), 0)
    XCTAssertEqual(LyricsParse.currentLineIndex(at: 19.9, lines: lines), 0)
    XCTAssertEqual(LyricsParse.currentLineIndex(at: 25, lines: lines), 1)
    XCTAssertNil(LyricsParse.currentLineIndex(at: 10, lines: []))
  }

  // MARK: Formatting

  func testMMSSFormatting() {
    XCTAssertEqual(MusicFormat.mmss(0), "0:00")
    XCTAssertEqual(MusicFormat.mmss(63.4), "1:03")
    XCTAssertEqual(MusicFormat.mmss(-5), "0:00")
    XCTAssertEqual(MusicFormat.mmss(3661), "61:01")
  }

  func testTitleNormalization() {
    XCTAssertEqual(MusicSearch.normalizedTitle("晴天（Live）"), "晴天")
    XCTAssertEqual(MusicSearch.normalizedTitle("Song (feat. A)"), "Song")
    XCTAssertEqual(MusicSearch.normalizedTitle("Song - Remastered 2011"), "Song")
    XCTAssertEqual(MusicSearch.normalizedTitle("  a   b "), "a b")
    XCTAssertEqual(MusicSearch.query(title: " 晴天 ", artist: "周杰伦"), "晴天 周杰伦")
    XCTAssertEqual(MusicSearch.query(title: "", artist: ""), "")
  }

  func testLyricsIdentityIgnoresCaseAndJitter() {
    let a = LyricsIdentity(title: " Song ", artist: "Artist", duration: 253.4)
    let b = LyricsIdentity(title: "song", artist: "artist", duration: 253.6)
    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, LyricsIdentity(title: "song", artist: "artist", duration: 999))
  }

  // MARK: NetEase provider parsing

  func testNetEaseSearchPicksBestDuration() {
    let json = """
      {"result":{"songs":[
        {"id":1,"duration":180000},
        {"id":2,"duration":253000},
        {"id":3,"duration":310000}
      ]}}
      """
    let hit = NetEaseLyricsProvider.bestSearchHit(
      Data(json.utf8), expectedDuration: 254
    )
    XCTAssertEqual(hit?.id, 2)
    XCTAssertEqual(hit?.duration ?? 0, 253, accuracy: 0.001)
  }

  func testNetEaseSearchEmptyResult() {
    XCTAssertNil(
      NetEaseLyricsProvider.bestSearchHit(Data("{}".utf8), expectedDuration: 100)
    )
    XCTAssertNil(
      NetEaseLyricsProvider.bestSearchHit(
        Data(#"{"result":{"songs":[]}}"#.utf8), expectedDuration: 100
      )
    )
  }

  func testNetEaseLyricsParsesLrcAndTlyric() {
    let json = """
      {"lrc":{"lyric":"[00:01.00]你好\\n[00:05.00]世界"},
       "tlyric":{"lyric":"[00:01.00]Hello\\n[00:05.00]World"}}
      """
    let lyrics = NetEaseLyricsProvider.parseLyrics(Data(json.utf8))
    let lines = try! XCTUnwrap(lyrics).lines
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines[0].text, "你好")
    XCTAssertEqual(lines[0].translation, "Hello")
    XCTAssertTrue(lyrics!.hasTranslation)
  }

  func testNetEaseLyricsWithoutTranslation() {
    let json = #"{"lrc":{"lyric":"[00:01.00]只此一行"}}"#
    let lyrics = NetEaseLyricsProvider.parseLyrics(Data(json.utf8))
    XCTAssertEqual(try! XCTUnwrap(lyrics).lines.count, 1)
    XCTAssertNil(lyrics!.lines[0].translation)
  }

  // MARK: LRCLIB provider parsing

  func testLRCLIBPicksBestSyncedHit() {
    let json = """
      [
        {"trackName":"A","duration":100,"syncedLyrics":null},
        {"trackName":"B","duration":240,"syncedLyrics":"[00:01.00]x"},
        {"trackName":"C","duration":251,"syncedLyrics":"[00:01.00]y"}
      ]
      """
    let synced = LRCLIBLyricsProvider.bestSyncedLyrics(
      Data(json.utf8), expectedDuration: 253
    )
    XCTAssertEqual(synced, "[00:01.00]y")  // nearest duration among synced hits
  }

  func testLRCLIBReturnsNilWithoutSyncedHits() {
    let json = #"[{"trackName":"A","duration":100,"syncedLyrics":null}]"#
    XCTAssertNil(
      LRCLIBLyricsProvider.bestSyncedLyrics(Data(json.utf8), expectedDuration: 100)
    )
  }

  // MARK: NowPlaying info mapping

  func testMakeTrackMapsInfoDictionary() {
    let artwork = Data([0x89, 0x50, 0x4E, 0x47])
    let info: [String: Any] = [
      NowPlayingInfoKey.title: "晴天",
      NowPlayingInfoKey.artist: "周杰伦",
      NowPlayingInfoKey.album: "叶惠美",
      NowPlayingInfoKey.duration: NSNumber(value: 269),
      NowPlayingInfoKey.elapsed: NSNumber(value: 42.5),
      NowPlayingInfoKey.rate: NSNumber(value: 1.0),
      NowPlayingInfoKey.artwork: artwork as NSData,
    ]
    let track = NowPlayingController.makeTrack(from: info)
    XCTAssertEqual(track?.title, "晴天")
    XCTAssertEqual(track?.artist, "周杰伦")
    XCTAssertEqual(track?.album, "叶惠美")
    XCTAssertEqual(track?.duration ?? 0, 269)
    XCTAssertEqual(track?.elapsed ?? 0, 42.5, accuracy: 0.001)
    XCTAssertEqual(track?.isPlaying, true)
    XCTAssertEqual(track?.artworkData, artwork)
    XCTAssertEqual(track?.progress ?? 0, 0.158, accuracy: 0.01)
  }

  func testMakeTrackInfersPlayingFromElapsedAdvance() {
    let previous = NowPlayingTrack(
      title: "t", artist: "a", album: "", artworkData: nil,
      duration: 200, elapsed: 10, isPlaying: true, playbackRate: 0
    )
    // Rate key absent; elapsed moved forward on the same track.
    let info: [String: Any] = [
      NowPlayingInfoKey.title: "t",
      NowPlayingInfoKey.artist: "a",
      NowPlayingInfoKey.elapsed: NSNumber(value: 12),
    ]
    XCTAssertEqual(NowPlayingController.makeTrack(from: info, previous: previous)?.isPlaying, true)
    // Elapsed stuck → paused.
    XCTAssertEqual(
      NowPlayingController.makeTrack(
        from: [
          NowPlayingInfoKey.title: "t", NowPlayingInfoKey.artist: "a",
          NowPlayingInfoKey.elapsed: NSNumber(value: 10),
        ], previous: previous
      )?.isPlaying,
      false
    )
  }

  func testMakeTrackNilForEmptyDict() {
    XCTAssertNil(NowPlayingController.makeTrack(from: nil))
    XCTAssertNil(NowPlayingController.makeTrack(from: [:]))
    XCTAssertNil(NowPlayingController.makeTrack(from: ["irrelevant": "x"]))
  }

  func testMakeTrackExtrapolatesElapsedFromPlaybackDate() {
    // mediaremoted reports elapsed as an anchor at CurrentPlaybackDate;
    // playing tracks must advance to `now`, paused ones must not move.
    let now = Date()
    let anchor = now.addingTimeInterval(-10)  // anchor was 10 s ago
    let playing = NowPlayingController.makeTrack(
      from: [
        NowPlayingInfoKey.title: "song",
        NowPlayingInfoKey.artist: "artist",
        NowPlayingInfoKey.elapsed: NSNumber(value: 100.0),
        NowPlayingInfoKey.rate: NSNumber(value: 1.0),
        NowPlayingInfoKey.currentPlaybackDate: NSNumber(value: anchor.timeIntervalSince1970),
      ],
      now: now
    )
    XCTAssertEqual(playing?.elapsed ?? 0, 110.0, accuracy: 0.05)

    let paused = NowPlayingController.makeTrack(
      from: [
        NowPlayingInfoKey.title: "song",
        NowPlayingInfoKey.artist: "artist",
        NowPlayingInfoKey.elapsed: NSNumber(value: 100.0),
        NowPlayingInfoKey.rate: NSNumber(value: 0.0),
        NowPlayingInfoKey.currentPlaybackDate: NSNumber(value: anchor.timeIntervalSince1970),
      ],
      now: now
    )
    XCTAssertEqual(paused?.elapsed ?? 0, 100.0, accuracy: 0.001)
  }

  func testMakeTrackExtrapolatesFromTimestampFallback() {
    // Players that omit CurrentPlaybackDate still track playback via the
    // fetch timestamp.
    let now = Date()
    let fetched = now.addingTimeInterval(-4)
    let track = NowPlayingController.makeTrack(
      from: [
        NowPlayingInfoKey.title: "song",
        NowPlayingInfoKey.artist: "artist",
        NowPlayingInfoKey.elapsed: NSNumber(value: 50.0),
        NowPlayingInfoKey.rate: NSNumber(value: 1.0),
        NowPlayingInfoKey.timestamp: NSNumber(value: fetched.timeIntervalSince1970),
      ],
      now: now
    )
    XCTAssertEqual(track?.elapsed ?? 0, 54.0, accuracy: 0.05)
  }

  // MARK: Panel height

  func testMusicSidebarHeightMatchesAIPanel() {
    XCTAssertEqual(
      IslandSidebarItem.music.preferredContentHeight,
      IslandSidebarItem.aiUsage.preferredContentHeight
    )
  }

  // MARK: AppModel wiring

  @MainActor
  func testTrackIdentityChangeTriggersLyricsFetchOnce() async throws {
    let provider = ScriptedProvider(outcome: .found)
    let model = makeModel(provider: provider)
    let track = makeTrack(title: "晴天", artist: "周杰伦", duration: 269)

    model.nowPlayingDidChange(track)
    model.nowPlayingDidChange(track)  // same identity
    model.nowPlayingDidChange(
      makeTrack(title: "晴天", artist: "周杰伦", duration: 269.2)  // elapsed jitter only
    )
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(provider.fetchCount, 1)
    guard case .loaded = model.lyricsState else {
      return XCTFail("expected loaded, got \(model.lyricsState)")
    }

    model.nowPlayingDidChange(makeTrack(title: "七里香", artist: "周杰伦", duration: 300))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(provider.fetchCount, 2)
  }

  @MainActor
  func testLyricsFailureSurfacesNotFound() async throws {
    let model = makeModel(provider: ScriptedProvider(outcome: .missing))
    model.nowPlayingDidChange(makeTrack(title: "x", artist: "y", duration: 100))
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.lyricsState, .notFound)
  }

  @MainActor
  func testNilTrackResetsLyricsState() async throws {
    let model = makeModel(provider: ScriptedProvider(outcome: .found))
    model.nowPlayingDidChange(makeTrack(title: "x", artist: "y", duration: 100))
    try await Task.sleep(for: .milliseconds(50))
    model.nowPlayingDidChange(nil)
    XCTAssertNil(model.nowPlaying)
    XCTAssertEqual(model.lyricsState, .idle)
  }

  // MARK: Helpers

  @MainActor
  private func makeModel(provider: ScriptedProvider) -> AppModel {
    let defaults = UserDefaults(suiteName: #function)!
    defer { defaults.removePersistentDomain(forName: #function) }
    return AppModel(
      store: LocalOnlyTestReminderStore(),
      defaults: defaults,
      lyricsService: LyricsService(providers: [provider]),
      nowPlayingController: FakeNowPlayingController()
    )
  }

  // MARK: Publish gate

  @MainActor
  func testShouldPublishGateDropsIdleTicksAndKeepsRealChanges() {
    // Panel visible: everything flows (progress bar advances on publishes).
    XCTAssertTrue(
      NowPlayingController.shouldPublish(previous: nil, next: nil, panelVisible: true))

    // Hidden, idle: {} -> {} suppressed; transitions publish.
    XCTAssertFalse(
      NowPlayingController.shouldPublish(previous: nil, next: nil, panelVisible: false))
    XCTAssertTrue(
      NowPlayingController.shouldPublish(previous: nil, next: base, panelVisible: false))
    XCTAssertTrue(
      NowPlayingController.shouldPublish(previous: base, next: nil, panelVisible: false))
  }

  @MainActor
  func testOnScheduleTickIsEquivalentWhileSeekAndPauseAreNot() {
    let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    let playing = NowPlayingTrack(
      title: "T", artist: "A", album: "L", artworkData: nil,
      duration: 200, elapsed: 50, isPlaying: true, playbackRate: 1,
      playerBundleID: "x", receivedAt: t0)

    // On-schedule re-anchor 0.5s later with the projected elapsed.
    let onSchedule = shifted(playing, at: 50.5, receivedAt: t0.addingTimeInterval(0.5))
    XCTAssertTrue(onSchedule.isEquivalentUpdate(to: playing))

    // Seek ±seconds: far off the projection.
    XCTAssertFalse(shifted(playing, at: 58, receivedAt: t0.addingTimeInterval(0.5))
      .isEquivalentUpdate(to: playing))
    XCTAssertFalse(shifted(playing, at: 48, receivedAt: t0.addingTimeInterval(0.5))
      .isEquivalentUpdate(to: playing))

    // Pause flips isPlaying/rate even with identical elapsed.
    var paused = playing
    paused.isPlaying = false
    paused.playbackRate = 0
    XCTAssertFalse(paused.isEquivalentUpdate(to: playing))

    // Paused jitter of a still-frozen elapsed stays equivalent.
    let pausedJitter = shifted(paused, at: 50.1, receivedAt: t0.addingTimeInterval(0.5))
    XCTAssertTrue(pausedJitter.isEquivalentUpdate(to: paused))
  }

  @MainActor
  func testRateJitterToleranceAndProjectionUsesPreviousRate() {
    let t0 = Date(timeIntervalSinceReferenceDate: 2000)
    let playing = NowPlayingTrack(
      title: "T", artist: "A", album: "L", artworkData: nil,
      duration: 200, elapsed: 20, isPlaying: true, playbackRate: 2,
      playerBundleID: "x", receivedAt: t0)

    // Rate jitter within 0.01 is equivalent even if elapsed wobbles.
    var jittered = playing
    jittered.playbackRate = 2.005
    jittered.receivedAt = t0.addingTimeInterval(1)
    jittered.elapsed = 22
    XCTAssertTrue(jittered.isEquivalentUpdate(to: playing))

    // 0.02 rate change publishes.
    var rateChanged = playing
    rateChanged.playbackRate = 2.02
    XCTAssertFalse(rateChanged.isEquivalentUpdate(to: playing))

    // Projection runs at the PREVIOUS rate: 1s at 2x means elapsed ~22 is
    // on-schedule (not 21 at the new rate).
    var reanchored = playing
    reanchored.receivedAt = t0.addingTimeInterval(1)
    reanchored.elapsed = 22
    XCTAssertTrue(reanchored.isEquivalentUpdate(to: playing))

    // Title/artwork changes always publish.
    var otherTitle = playing
    otherTitle.title = "T2"
    XCTAssertFalse(otherTitle.isEquivalentUpdate(to: playing))
    var otherArt = playing
    otherArt.artworkData = Data([1, 2, 3])
    XCTAssertFalse(otherArt.isEquivalentUpdate(to: playing))
  }

  @MainActor
  func testReanchorExtrapolatesAlongPlaybackRate() {
    let t0 = Date(timeIntervalSinceReferenceDate: 3000)
    let playing = NowPlayingTrack(
      title: "T", artist: "A", album: "L", artworkData: nil,
      duration: 200, elapsed: 30, isPlaying: true, playbackRate: 1,
      playerBundleID: "x", receivedAt: t0)
    let reanchored = playing.reanchored(to: t0.addingTimeInterval(10))
    XCTAssertEqual(reanchored.elapsed, 40, accuracy: 0.001)
    XCTAssertEqual(reanchored.receivedAt, t0.addingTimeInterval(10))

    var paused = playing
    paused.isPlaying = false
    paused.playbackRate = 0
    XCTAssertEqual(
      paused.reanchored(to: t0.addingTimeInterval(10)).elapsed, 30, accuracy: 0.001)
  }

  // MARK: Fume-style print timing

  func testPrintTimingEvenDistributionAndQuantization() {
    // 10 chars over [10, 20): one char per second, +0.2 phase lead.
    let timing = LyricPrintTiming(charCount: 10, start: 10, end: 20)
    XCTAssertEqual(timing.lineProgress(at: 5), 0)
    XCTAssertEqual(timing.lineProgress(at: 25), 1)
    XCTAssertEqual(timing.printedCount(at: 10), 0, "0.0*10+0.2 floors to 0")
    XCTAssertEqual(timing.printedCount(at: 10.81), 1, "0.081*10+0.2 -> 1")
    XCTAssertEqual(timing.printedCount(at: 15), 5)
    XCTAssertEqual(timing.printedCount(at: 20), 10)
    XCTAssertEqual(timing.printedCount(at: 100), 10, "clamped to charCount")
  }

  func testPrintTimingFillFractionIsMonotonicAndBounded() {
    let timing = LyricPrintTiming(charCount: 7, start: 0, end: 7)
    var last = -1.0
    for step in 0...70 {
      let f = timing.fillFraction(at: Double(step) / 10)
      XCTAssertGreaterThanOrEqual(f, last)
      XCTAssertTrue((0...1).contains(f))
      last = f
    }
    XCTAssertEqual(timing.fillFraction(at: 7), 1)
    // Empty line fills instantly with the window.
    let empty = LyricPrintTiming(charCount: 0, start: 0, end: 3)
    XCTAssertEqual(empty.fillFraction(at: 0.5), 0)
    XCTAssertEqual(empty.fillFraction(at: 3), 1)
  }

  func testPrintTimingGlowEnvelopePeaksNear80Percent() {
    let timing = LyricPrintTiming(charCount: 10, start: 0, end: 10)
    XCTAssertEqual(timing.glowEnvelope(at: 0), 0)
    XCTAssertEqual(timing.glowEnvelope(at: 10), 0)
    let peak = timing.glowEnvelope(at: 8)
    XCTAssertEqual(peak, 1, accuracy: 1e-9, "sin peaks at p=0.8")
    XCTAssertGreaterThan(timing.glowEnvelope(at: 4), timing.glowEnvelope(at: 1))
    XCTAssertGreaterThan(timing.glowEnvelope(at: 9), 0)
    XCTAssertLessThan(timing.glowEnvelope(at: 9.5), timing.glowEnvelope(at: 9))
  }

  func testLyricsPrintWindowUsesNextLineAndFallsBackAtTheEnd() {
    let lyrics = Lyrics(timedLines: [(0, "a"), (10, "b"), (30, "c")])
    XCTAssertEqual(lyrics.printWindow(for: 0).end, 10)
    XCTAssertEqual(lyrics.printWindow(for: 1).end, 30)
    // Final line: no successor -> fallback span, never shorter than 0.2s.
    let last = lyrics.printWindow(for: 2, fallbackSpan: 4)
    XCTAssertEqual(last.start, 30)
    XCTAssertEqual(last.end, 34)
    // A degenerate next-line timestamp still yields a printable window.
    let tight = Lyrics(timedLines: [(0, "a"), (0.05, "b")])
    XCTAssertLessThan(tight.printWindow(for: 0).end - tight.printWindow(for: 0).start, 0.21)
    XCTAssertGreaterThanOrEqual(
      tight.printWindow(for: 0).end - tight.printWindow(for: 0).start, 0.2)
  }

  private var base: NowPlayingTrack {
    NowPlayingTrack(
      title: "T", artist: "A", album: "L", artworkData: nil,
      duration: 200, elapsed: 50, isPlaying: true, playbackRate: 1)
  }

  private func shifted(
    _ track: NowPlayingTrack, at elapsed: TimeInterval, receivedAt: Date
  ) -> NowPlayingTrack {
    var copy = track
    copy.elapsed = elapsed
    copy.receivedAt = receivedAt
    return copy
  }

  private func makeTrack(
    title: String, artist: String, duration: TimeInterval
  ) -> NowPlayingTrack {
    NowPlayingTrack(
      title: title, artist: artist, album: "", artworkData: nil,
      duration: duration, elapsed: 10, isPlaying: true, playbackRate: 1
    )
  }
}

/// Deterministic provider with an instance fetch counter; the
/// throttle-free chain runs it exactly once per distinct LyricsIdentity.
@MainActor
private final class ScriptedProvider: LyricsProvider {
  enum Outcome { case found, missing }

  private(set) var fetchCount = 0
  private let outcome: Outcome

  init(outcome: Outcome) {
    self.outcome = outcome
  }

  func fetchLyrics(
    title: String, artist: String, duration: TimeInterval
  ) async -> Lyrics? {
    fetchCount += 1
    guard outcome == .found else { return nil }
    return LyricsParse.lyrics(
      original: "[00:01.00]line one\n[00:02.00]line two", translation: nil
    )
  }
}

@MainActor
private final class FakeNowPlayingController: NowPlayingControlling {
  var isAvailable = true
  var supportsSeeking = true
  var onUpdate: ((NowPlayingTrack?) -> Void)?
  var onLiveTemplatesChanged: (Set<Int32>) -> Void = { _ in }
  private(set) var panelActiveCalls: [Bool] = []

  func start() {}
  func refresh() {}
  func setPanelActive(_ active: Bool) { panelActiveCalls.append(active) }
  func togglePlayPause() {}
  func play() {}
  func pause() {}
  func next() {}
  func previous() {}
  func seek(to seconds: Double) {}
}

  // MARK: Favorites parsing

  func testFavoritePlaylistParseExtractsTracks() {
    let json = """
      {"playlist":{"tracks":[
        {"id":1,"name":"晴天","duration":269000,"artists":[{"name":"周杰伦"}]},
        {"id":2,"name":"Reset","duration":210500,"artists":[{"name":"A"},{"name":"B"}]}
      ]}}
      """
    let tracks = try! XCTUnwrap(FavoritePlaylistParse.tracks(Data(json.utf8)))
    XCTAssertEqual(tracks.count, 2)
    XCTAssertEqual(tracks[0].name, "晴天")
    XCTAssertEqual(tracks[0].artist, "周杰伦")
    XCTAssertEqual(tracks[0].duration, 269, accuracy: 0.001)
    XCTAssertEqual(tracks[1].artist, "A/B")
    XCTAssertEqual(tracks[1].duration, 210.5, accuracy: 0.001)
  }

  func testFavoritePlaylistParseRejectsUnusable() {
    XCTAssertNil(FavoritePlaylistParse.tracks(Data("{}".utf8)))
    XCTAssertNil(FavoritePlaylistParse.tracks(Data("nope".utf8)))
  }

  func testFavoriteTrackIDsAndV3Parsing() {
    let v6 = """
      {"playlist":{"trackIds":[{"id":5},{"id":6}],"tracks":[
        {"id":5,"name":"A","duration":1000,"artists":[]}],"name":"x"}}
      """
    XCTAssertEqual(FavoritePlaylistParse.trackIDs(Data(v6.utf8)), [5, 6])

    let v3 = """
      {"songs":[{"id":6,"name":"B","dt":250000,"ar":[{"name":"X"},{"name":"Y"}],"fee":0}]}
      """
    let tracks = try! XCTUnwrap(FavoritePlaylistParse.v3Tracks(Data(v3.utf8)))
    XCTAssertEqual(tracks, [FavoriteTrack(id: 6, name: "B", artist: "X/Y", duration: 250)])
  }
