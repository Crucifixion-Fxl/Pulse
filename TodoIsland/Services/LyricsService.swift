import AppKit
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


// MARK: - Favorites playlist

/// Fetches the NetEase "我喜欢的音乐" playlist anonymously (the playlist id
/// equals the account's numeric uid) and plays tracks through the
/// orpheus:// URL scheme the desktop app registers.
struct FavoritePlaylistProvider: Sendable {
  var session: URLSession = .shared

  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
    + " (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

  /// The "我喜欢的音乐" playlist is private: its tracks only come back with
  /// the owner's MUSIC_U session cookie (defaults key netease-music-u).
  var musicU: String?

  /// v6 caps embedded track details at ten regardless of n — full lists
  /// need the two-stage walk: v6 for the trackIds, then batched
  /// v3/song/detail (its own shape: ar[] artists, dt ms) a hundred ids
  /// per call.
  func tracks(playlistID: Int) async -> [FavoriteTrack]? {
    guard
      let detail = await get(
        "https://music.163.com/api/v6/playlist/detail",
        query: ["id": String(playlistID), "n": "1"]
      ),
      let embedded = FavoritePlaylistParse.tracks(detail)
    else { return nil }

    guard
      let ids = FavoritePlaylistParse.trackIDs(detail), ids.count > embedded.count
    else { return embedded }

    var detailed = embedded
    // Materialise: dropFirst keeps original indices, and 0-based slicing
    // below would trap (the crash that emptied the rail).
    let remaining = Array(ids.dropFirst(embedded.count))
    for chunk in stride(from: 0, to: remaining.count, by: 100).map({
      Array(remaining[$0..<min($0 + 100, remaining.count)])
    }) {
      let c = "[" + chunk.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"
      guard
        let data = await get(
          "https://music.163.com/api/v3/song/detail",
          query: ["c": c]
        ),
        let batch = FavoritePlaylistParse.v3Tracks(data)
      else { continue }
      detailed.append(contentsOf: batch)
    }
    return detailed.isEmpty ? nil : detailed
  }

  private func get(_ urlString: String, query: [String: String]) async -> Data? {
    var components = URLComponents(string: urlString)!
    components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let url = components.url else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
    if let musicU, !musicU.isEmpty {
      request.setValue("MUSIC_U=\(musicU); NMTID=0", forHTTPHeaderField: "Cookie")
    }
    return try? await session.data(for: request).0
  }

  /// Hands the song to the NetEase desktop app; the island's Now Playing
  /// follows automatically once it starts.
  static func play(trackID: Int) {
    guard let url = URL(string: "orpheus://song/?id=\(trackID)") else { return }
    NSWorkspace.shared.open(url)
  }
}

/// Favorites cache: session memory + JSON in Application Support so the
/// rail renders instantly on relaunch.
actor FavoritePlaylistStore {
  private var cached: [Int: [FavoriteTrack]] = [:]

  private var fileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/TodoIsland/favorites.json")
  }

  func tracks(playlistID: Int) async -> [FavoriteTrack]? {
    if let cached = cached[playlistID] { return cached }
    guard
      let data = try? Data(contentsOf: fileURL),
      let persisted = try? JSONDecoder().decode([Int: [FavoriteTrack]].self, from: data),
      let tracks = persisted[playlistID]
    else { return nil }
    cached[playlistID] = tracks
    return tracks
  }

  func store(_ tracks: [FavoriteTrack], playlistID: Int) async {
    cached[playlistID] = tracks
    var persisted = (try? Data(contentsOf: fileURL))
      .flatMap { try? JSONDecoder().decode([Int: [FavoriteTrack]].self, from: $0) } ?? [:]
    persisted[playlistID] = tracks
    if let data = try? JSONEncoder().encode(persisted) {
      try? FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: fileURL)
    }
  }
}
