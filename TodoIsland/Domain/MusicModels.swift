import Foundation

/// One now-playing snapshot as published to the music panel.
struct NowPlayingTrack: Equatable, Sendable {
  var title: String
  var artist: String
  var album: String
  var artworkData: Data?
  /// Seconds; 0 when the player does not report it.
  var duration: TimeInterval
  /// Seconds at snapshot time, as computed by mediaremoted.
  var elapsed: TimeInterval
  var isPlaying: Bool
  var playbackRate: Double
  var playerBundleID: String?
  /// When this snapshot was built; the view extrapolates elapsed from
  /// here so lyric lines advance smoothly between helper updates.
  var receivedAt: Date = Date()

  var progress: Double {
    guard duration > 0 else { return 0 }
    return min(max(elapsed / duration, 0), 1)
  }

  /// Identity that should (re)trigger a lyrics fetch. Elapsed and rate
  /// jitter must never change it.
  var lyricsIdentity: LyricsIdentity {
    LyricsIdentity(title: title, artist: artist, duration: duration)
  }
}

/// Normalized (title, artist, duration-rounded-to-second) cache key.
struct LyricsIdentity: Hashable, Sendable {
  var title: String
  var artist: String
  var duration: TimeInterval

  init(title: String, artist: String, duration: TimeInterval) {
    self.title = Self.normalize(title)
    self.artist = Self.normalize(artist)
    // Floor: reported durations jitter by fractions of a second and must
    // not cross an identity boundary at the .5 mark.
    self.duration = duration.rounded(.down)
  }

  static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: .caseInsensitive, locale: .current)
  }
}

struct LyricLine: Equatable, Sendable, Identifiable {
  let time: TimeInterval
  let text: String
  var translation: String?
  /// Index within the lyrics array, assigned by the Lyrics factory so
  /// ScrollViewReader ids stay stable.
  var id: Int

  init(time: TimeInterval, text: String, translation: String? = nil, id: Int) {
    self.time = time
    self.text = text
    self.translation = (translation?.isEmpty == true) ? nil : translation
    self.id = id
  }
}

struct Lyrics: Equatable, Sendable {
  var lines: [LyricLine]

  var hasTranslation: Bool { lines.contains { $0.translation != nil } }

  init(timedLines: [(time: TimeInterval, text: String)]) {
    lines = timedLines.enumerated().map { index, line in
      LyricLine(time: line.time, text: line.text, id: index)
    }
  }

  init(lines: [LyricLine]) {
    self.lines = lines
  }
}

/// Pure LRC parsing and lookup. No I/O — fully unit-testable.
enum LyricsParse {
  /// Timestamp tolerance when merging a translation line onto its
  /// original: NetEase tlyric usually matches exactly.
  static let translationTolerance: TimeInterval = 0.6

  /// Parses "[mm:ss.xx]text" lines, including multiple timestamps per
  /// line ("[00:12.0][01:30.0]chorus") and centisecond vs millisecond
  /// fractions. Metadata tags ([ti:], [ar:], [al:], [by:], [offset:])
  /// and whitespace-only lines are dropped; output is sorted by time.
  static func timedLines(_ lrc: String) -> [(time: TimeInterval, text: String)] {
    var results: [(TimeInterval, String)] = []
    for rawLine in lrc.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("[") else { continue }

      var rest = Substring(line)
      var timestamps: [TimeInterval] = []
      while let open = rest.first, open == "[",
        let close = rest.firstIndex(of: "]")
      {
        let tag = rest[rest.index(after: rest.startIndex)..<close]
        if let time = parseTimestamp(String(tag)) {
          timestamps.append(time)
        } else if !tag.isEmpty, tag.first?.isLetter == true {
          // Metadata tag consumes the whole line.
          rest = ""
          break
        }
        rest = rest[rest.index(after: close)...]
      }

      let text = String(rest).trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty, !timestamps.isEmpty else { continue }
      for time in timestamps {
        results.append((time, text))
      }
    }
    return results.sorted { $0.0 < $1.0 }
  }

  /// Merges an original LRC with an optional translation LRC by nearest
  /// timestamp. Returns nil when the original yields no timed lines.
  static func lyrics(original: String, translation: String?) -> Lyrics? {
    let originalLines = timedLines(original)
    guard !originalLines.isEmpty else { return nil }

    let translationLines = translation.map { timedLines($0) } ?? []
    let lines = originalLines.enumerated().map { index, line -> LyricLine in
      var matched: String?
      if !translationLines.isEmpty {
        var best: (offset: Int, distance: TimeInterval)?
        for (offset, candidate) in translationLines.enumerated() {
          let distance = abs(candidate.time - line.time)
          if best == nil || distance < best!.distance {
            best = (offset, distance)
          }
        }
        if let best, best.distance <= translationTolerance {
          matched = translationLines[best.offset].text
        }
      }
      return LyricLine(time: line.time, text: line.text, translation: matched, id: index)
    }
    return Lyrics(lines: lines)
  }

  /// Index of the line active at `elapsed`: the last line whose time is
  /// <= elapsed. Nil before the first line's time or when there are no
  /// lines.
  static func currentLineIndex(at elapsed: TimeInterval, lines: [LyricLine]) -> Int? {
    guard !lines.isEmpty else { return nil }
    var low = 0
    var high = lines.count - 1
    var answer: Int?
    while low <= high {
      let mid = (low + high) / 2
      if lines[mid].time <= elapsed {
        answer = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return answer
  }

  /// "[mm:ss.xx]" → seconds; nil when malformed.
  private static func parseTimestamp(_ tag: String) -> TimeInterval? {
    let pattern = "^\\d{1,3}:(\\d{1,2})(?:\\.(\\d{1,3}))?$"
    guard let match = tag.range(of: pattern, options: .regularExpression) else {
      return nil
    }
    let parts = tag[match].components(separatedBy: ":")
    guard let minutes = Double(parts[0]) else { return nil }
    let secondParts = parts[1].components(separatedBy: ".")
    guard let seconds = Double(secondParts[0]), seconds < 60 else { return nil }
    var fraction = 0.0
    if secondParts.count == 2, let digits = Double(secondParts[1]) {
      // ".5" means 0.5 s; ".50" too; ".500" means 0.500 s.
      let divisor = pow(10, Double(secondParts[1].count))
      fraction = digits / divisor
    }
    return minutes * 60 + seconds + fraction
  }
}

enum MusicFormat {
  /// 63.4 → "1:03"; 0 → "0:00"; negatives clamp to 0; hours roll into
  /// minutes (3661 → "61:01").
  static func mmss(_ seconds: TimeInterval) -> String {
    let clamped = max(seconds, 0)
    let total = Int(clamped.rounded(.down))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
  }
}

/// Query shaping for lyrics search endpoints.
enum MusicSearch {
  /// Strips parenthetical and bracketed qualifiers ("（Live）", "(feat. X)",
  /// "(with Y)"), "- Remastered" / "- LIVE" tails, and collapses spaces.
  static func normalizedTitle(_ title: String) -> String {
    var result = title
    for pattern in [
      #"[（(\[](?:[^\）)\]]*)[\）)\]]\s*"#,
      #"\s*-\s*(?:Remastered|REMASTERED|Live|LIVE)\b.*"#,
    ] {
      result = result.replacingOccurrences(
        of: pattern, with: "", options: .regularExpression
      )
    }
    return result
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  /// "title artist", both trimmed; empty parts collapse.
  static func query(title: String, artist: String) -> String {
    [title, artist]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

/// One entry of the NetEase "我喜欢的音乐" playlist.
struct FavoriteTrack: Equatable, Hashable, Sendable, Identifiable, Codable {
  let id: Int
  var name: String
  var artist: String
  /// Seconds; 0 when the API omits it.
  var duration: TimeInterval
}

/// Pure parsing of the anonymous playlist-detail response.
enum FavoritePlaylistParse {
  /// `{"playlist":{"tracks":[{"id","name","duration"(ms),
  /// "artists":[{"name"}]}]}}` — nil on anything unusable.
  static func tracks(_ data: Data) -> [FavoriteTrack]? {
    struct Response: Decodable {
      struct Playlist: Decodable {
        struct Track: Decodable {
          let id: Int
          let name: String
          let duration: Double?
          let artists: [Artist]?
        }
        struct Artist: Decodable {
          let name: String?
        }
        let tracks: [Track]?
      }
      let playlist: Playlist?
    }
    guard
      let response = try? JSONDecoder().decode(Response.self, from: data),
      let tracks = response.playlist?.tracks
    else { return nil }
    return tracks.map { track in
      FavoriteTrack(
        id: track.id,
        name: track.name,
        artist: track.artists?.compactMap(\.name).joined(separator: "/") ?? "",
        duration: (track.duration ?? 0) / 1000
      )
    }
  }
}
