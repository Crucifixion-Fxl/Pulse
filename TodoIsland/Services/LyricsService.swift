import Foundation

/// A lyrics source. Implementations never throw: failures surface as nil
/// and the UI shows its not-found state.
protocol LyricsProvider: Sendable {
  func fetchLyrics(
    title: String, artist: String, duration: TimeInterval
  ) async -> Lyrics?
}

// MARK: - NetEase (网易云非官方接口)

/// NetEase first: best Chinese catalog, and `tlyric` carries a Chinese
/// translation for foreign tracks.
struct NetEaseLyricsProvider: LyricsProvider {
  var session: URLSession = .shared

  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
    + " (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

  func fetchLyrics(
    title: String, artist: String, duration: TimeInterval
  ) async -> Lyrics? {
    // Search by combined query; NetEase ranks the best hit first. queryItems
    // handle the CJK escaping.
    var components = URLComponents(string: "https://music.163.com/api/search/get")!
    components.queryItems = [
      URLQueryItem(name: "s", value: MusicSearch.query(title: title, artist: artist)),
      URLQueryItem(name: "type", value: "1"),
      URLQueryItem(name: "limit", value: "5"),
    ]
    guard let searchURL = components.url else { return nil }
    guard
      let searchData = await get(searchURL),
      let hit = Self.bestSearchHit(searchData, expectedDuration: duration)
    else { return nil }

    guard let lyricBase = URL(string: "https://music.163.com/api/song/lyric") else {
      return nil
    }
    let lyricURL = lyricBase.appending(queryItems: [
      URLQueryItem(name: "id", value: String(hit.id)),
      URLQueryItem(name: "lv", value: "1"),
      URLQueryItem(name: "kv", value: "1"),
      URLQueryItem(name: "tv", value: "-1"),
    ])
    guard let lyricData = await get(lyricURL) else { return nil }
    return Self.parseLyrics(lyricData)
  }

  private func get(_ url: URL) async -> Data? {
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
    return try? await session.data(for: request).0
  }

  /// Pure: `{"result":{"songs":[{"id","duration"(ms)},…]}}` → the song
  /// whose duration is closest to `expectedDuration`; nil with no songs
  /// or malformed JSON.
  static func bestSearchHit(
    _ data: Data, expectedDuration: TimeInterval
  ) -> (id: Int, duration: TimeInterval)? {
    struct SearchResponse: Decodable {
      struct Result: Decodable {
        struct Song: Decodable {
          let id: Int
          let duration: Double?
        }
        let songs: [Song]?
      }
      let result: Result?
    }
    guard
      let response = try? JSONDecoder().decode(SearchResponse.self, from: data),
      let songs = response.result?.songs, !songs.isEmpty
    else { return nil }
    return songs
      .compactMap { song in
        song.duration.map { (id: song.id, duration: $0 / 1000) }
      }
      .min { abs($0.duration - expectedDuration) < abs($1.duration - expectedDuration) }
  }

  /// Pure: `{"lrc":{"lyric":…},"tlyric":{"lyric":…}}` (tlyric optional).
  static func parseLyrics(_ data: Data) -> Lyrics? {
    struct LyricResponse: Decodable {
      struct Body: Decodable {
        let lyric: String?
      }
      let lrc: Body?
      let tlyric: Body?
    }
    guard
      let response = try? JSONDecoder().decode(LyricResponse.self, from: data),
      let original = response.lrc?.lyric
    else { return nil }
    return LyricsParse.lyrics(
      original: original, translation: response.tlyric?.lyric
    )
  }
}

// MARK: - LRCLIB fallback

struct LRCLIBLyricsProvider: LyricsProvider {
  var session: URLSession = .shared

  func fetchLyrics(
    title: String, artist: String, duration: TimeInterval
  ) async -> Lyrics? {
    guard let base = URL(string: "https://lrclib.net/api/search") else { return nil }
    let url = base.appending(queryItems: [
      URLQueryItem(name: "track_name", value: title),
      URLQueryItem(name: "artist_name", value: artist),
    ])
    var request = URLRequest(url: url, timeoutInterval: 5)
    request.setValue("TodoIsland/1.6 (personal notch app)", forHTTPHeaderField: "User-Agent")
    guard let data = try? await session.data(for: request).0 else { return nil }
    guard let synced = Self.bestSyncedLyrics(data, expectedDuration: duration) else {
      return nil
    }
    return LyricsParse.lyrics(original: synced, translation: nil)
  }

  /// Pure: picks the hit minimizing |duration − expected| among hits that
  /// carry a syncedLyrics LRC.
  static func bestSyncedLyrics(
    _ data: Data, expectedDuration: TimeInterval
  ) -> String? {
    struct Hit: Decodable {
      let duration: Double?
      let syncedLyrics: String?
    }
    guard let hits = try? JSONDecoder().decode([Hit].self, from: data) else {
      return nil
    }
    return hits
      .compactMap { hit -> (lyrics: String, duration: Double)? in
        guard let synced = hit.syncedLyrics, !synced.isEmpty else { return nil }
        return (synced, hit.duration ?? expectedDuration)
      }
      .min {
        abs($0.duration - expectedDuration) < abs($1.duration - expectedDuration)
      }?
      .lyrics
  }
}

// MARK: - Chain with cache

/// NetEase first, LRCLIB fallback, with an in-memory cache and a
/// remembered-miss set so a failed lookup doesn't re-hit the network on
/// every hover.
actor LyricsService {
  private var cache: [LyricsIdentity: Lyrics] = [:]
  private var misses: Set<LyricsIdentity> = []
  private let providers: [any LyricsProvider]

  init(providers: [any LyricsProvider] = [
    NetEaseLyricsProvider(), LRCLIBLyricsProvider()
  ]) {
    self.providers = providers
  }

  func lyrics(
    title: String, artist: String, duration: TimeInterval
  ) async -> Lyrics? {
    let key = LyricsIdentity(title: title, artist: artist, duration: duration)
    if let cached = cache[key] { return cached }
    guard !misses.contains(key) else { return nil }

    let queryTitle = MusicSearch.normalizedTitle(title)
    for provider in providers {
      if Task.isCancelled { return nil }
      if let found = await provider.fetchLyrics(
        title: queryTitle, artist: artist, duration: duration
      ) {
        cache[key] = found
        return found
      }
    }
    misses.insert(key)
    return nil
  }
}
