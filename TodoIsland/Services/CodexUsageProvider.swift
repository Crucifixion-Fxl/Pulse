import Foundation

/// Codex token usage as recorded in a rollout's cumulative counters.
struct CodexTokenUsage: Equatable, Sendable {
  var input: Int
  var cached: Int
  var cacheWrite: Int
  var output: Int
}

/// One rate-limit window observation, lane-classified by its span the way
/// CodexBar does it — providers hand the two windows back in either slot,
/// so 300-minute and 10080-minute classification is more reliable than the
/// primary/secondary field order.
struct CodexRateWindow: Equatable, Sendable {
  enum Lane: Equatable, Sendable {
    case session
    case weekly
    case unknown
  }

  var usedPercent: Double
  var windowMinutes: Int
  var resetsAt: Date
  var observedAt: Date?

  init(usedPercent: Double, windowMinutes: Int, resetsAt: Date, observedAt: Date? = nil) {
    self.usedPercent = usedPercent
    // Canonicalize the jitter providers report (295...305, 10070...10090).
    switch windowMinutes {
    case 295...305: self.windowMinutes = 300
    case 10_070...10_090: self.windowMinutes = 10_080
    default: self.windowMinutes = windowMinutes
    }
    self.resetsAt = resetsAt
    self.observedAt = observedAt
  }

  var lane: Lane {
    switch windowMinutes {
    case 300: .session
    case 10_080: .weekly
    default: .unknown
    }
  }
}

/// Pure parsing for Codex rollout files — no I/O, fully unit-testable.
enum CodexUsageParser {
  /// `rollout-2026-09-24T13-49-23-<uuid>.jsonl` → that instant (local
  /// timezone; day granularity is all the aggregation needs).
  static func sessionDate(filename: String, calendar: Calendar = .current) -> Date? {
    guard
      let range = filename.range(
        of: #"rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}"#,
        options: .regularExpression)
    else {
      return nil
    }
    let stamp = String(filename[range])
      .replacingOccurrences(of: "rollout-", with: "")
    let parts = stamp.split(separator: "T")
    guard parts.count == 2 else { return nil }
    let dateParts = parts[0].split(separator: "-").compactMap { Int($0) }
    let timeParts = parts[1].split(separator: "-").compactMap { Int($0) }
    guard dateParts.count == 3, timeParts.count == 3 else { return nil }
    var comps = DateComponents()
    comps.year = dateParts[0]
    comps.month = dateParts[1]
    comps.day = dateParts[2]
    comps.hour = timeParts[0]
    comps.minute = timeParts[1]
    comps.second = timeParts[2]
    return calendar.date(from: comps)
  }

  private struct TokenCountEvent: Decodable {
    let timestamp: String?
    struct Payload: Decodable {
      struct Info: Decodable {
        struct Usage: Decodable {
          let input_tokens: Int?
          let cached_input_tokens: Int?
          let cache_write_input_tokens: Int?
          let output_tokens: Int?
        }
        let total_token_usage: Usage?
      }
      struct Window: Decodable {
        let used_percent: Double?
        let window_minutes: Int?
        let resets_at: Int64?
      }
      struct Limits: Decodable {
        let primary: Window?
      }
      let info: Info?
      let rate_limits: Limits?
    }
    let payload: Payload?
  }

  /// The last `token_count` event in a (tail) buffer: a session's
  /// cumulative counters plus whatever rate-limit window accompanied it.
  static func lastTokenCount(
    in tail: Data, now: Date = Date()
  ) -> (usage: CodexTokenUsage, rateWindow: CodexRateWindow?)? {
    guard !tail.isEmpty else { return nil }
    // Split on newlines from the end; event lines are well under 2 KB so a
    // 128 KB tail always contains the last complete event.
    var lines: [Data] = []
    var start = tail.startIndex
    for index in tail.indices where tail[index] == 0x0A {
      lines.append(tail.subdata(in: start..<index))
      start = tail.index(after: index)
    }
    if start < tail.endIndex { lines.append(tail.subdata(in: start..<tail.endIndex)) }

    for line in lines.reversed() {
      guard line.contains(Data("\"token_count\"".utf8)),
        let event = try? JSONDecoder().decode(TokenCountEvent.self, from: line),
        let usage = event.payload?.info?.total_token_usage
      else { continue }
      let tokens = CodexTokenUsage(
        input: usage.input_tokens ?? 0,
        cached: usage.cached_input_tokens ?? 0,
        cacheWrite: usage.cache_write_input_tokens ?? 0,
        output: usage.output_tokens ?? 0)
      let window = event.payload?.rate_limits?.primary.flatMap { raw in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return CodexRateWindow(
          usedPercent: raw.used_percent ?? 0,
          windowMinutes: raw.window_minutes ?? 0,
          resetsAt: raw.resets_at.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? now,
          observedAt: event.timestamp.flatMap { formatter.date(from: $0) })
      }
      return (tokens, window)
    }
    return nil
  }

  /// Aggregates parsed sessions into the panel's snapshot shape: exactly
  /// fifteen ascending days ending today (zero-filled), the day split
  /// following the panel's input/output/cache breakdown, and the Codex
  /// subscription cards built from live OAuth windows when present, else
  /// from the newest session-recorded window.
  static func buildSnapshot(
    sessions: [(date: Date, usage: CodexTokenUsage, rateWindow: CodexRateWindow?)],
    liveWindows: (session: CodexRateWindow?, weekly: CodexRateWindow?)? = nil,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> AIUsageSnapshot {
    let today = calendar.startOfDay(for: now)
    var days: [AIUsageDay] = []
    var byDay: [Date: (input: Int, output: Int, cache: Int)] = [:]
    var newestSessionWindow: CodexRateWindow?
    var newestWindowObservation: Date?

    for session in sessions {
      let key = calendar.startOfDay(for: session.date)
      let entry = byDay[key] ?? (0, 0, 0)
      byDay[key] = (
        entry.input + max(0, session.usage.input - session.usage.cached),
        entry.output + session.usage.output,
        entry.cache + session.usage.cached + session.usage.cacheWrite
      )
      if let window = session.rateWindow,
        newestWindowObservation == nil
          || (window.observedAt ?? session.date) > newestWindowObservation! {
        newestSessionWindow = window
        newestWindowObservation = window.observedAt ?? session.date
      }
    }

    for offset in stride(from: 14, through: 0, by: -1) {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
      let totals = byDay[day] ?? (0, 0, 0)
      days.append(
        AIUsageDay(
          day: day, inputTokens: totals.input, outputTokens: totals.output,
          cacheTokens: totals.cache))
    }

    // Live OAuth windows win; a session-recorded window is the fallback.
    var weekly = liveWindows?.weekly
    var sessionWindow = liveWindows?.session
    if weekly == nil, sessionWindow == nil, let fallback = newestSessionWindow {
      switch fallback.lane {
      case .weekly: weekly = fallback
      case .session, .unknown: sessionWindow = fallback
      }
    }

    var subscriptions: [AISubscription] = []
    if let weekly {
      subscriptions.append(Self.percentCard(id: "codex-weekly", name: "Weekly limit", window: weekly))
    }
    if var sessionWindow {
      // The weekly window caps the session one: a spent week must not
      // leave the 5h bar implying headroom that is not really there.
      if let weekly, weekly.usedPercent >= 100 {
        sessionWindow.usedPercent = max(sessionWindow.usedPercent, 100)
      }
      subscriptions.append(
        Self.percentCard(id: "codex-session", name: "5-hour window", window: sessionWindow))
    }
    if subscriptions.isEmpty {
      // Nothing observed a window yet — an expired-looking zero is more
      // honest than no card.
      subscriptions.append(
        AISubscription(
          id: "codex-weekly",
          vendor: .openAI,
          planName: "Weekly limit",
          quota: AIQuota(used: 0, limit: 100, unit: .percent),
          resetsAt: now))
    }

    return AIUsageSnapshot(days: days, subscriptions: subscriptions, isSample: false)
  }

  private static func percentCard(
    id: String, name: String, window: CodexRateWindow
  ) -> AISubscription {
    AISubscription(
      id: id,
      vendor: .openAI,
      planName: name,
      quota: AIQuota(
        used: Int(window.usedPercent.rounded()),
        limit: 100,
        unit: .percent),
      resetsAt: window.resetsAt)
  }
}

/// Live quota windows from the ChatGPT backend using the Codex CLI's own
/// credentials — the same source of truth CodexBar uses. The tokens from
/// `~/.codex/auth.json` live only in memory for this request; they are
/// never logged or persisted anywhere else.
enum CodexOAuthUsage {
  struct Credentials: Decodable {
    struct Tokens: Decodable {
      let access_token: String?
      let account_id: String?
    }
    let tokens: Tokens?
  }

  struct UsageResponse: Decodable {
    struct Window: Decodable {
      let used_percent: Int?
      let reset_at: Int?
      let limit_window_seconds: Int?
    }
    struct RateLimit: Decodable {
      let primary_window: Window?
      let secondary_window: Window?
    }
    let rate_limit: RateLimit?
  }

  static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

  static func fetchWindows(
    homeDirectory: URL,
    session: URLSession = .shared,
    now: Date = Date()
  ) async throws -> (session: CodexRateWindow?, weekly: CodexRateWindow?) {
    let authURL = homeDirectory.appendingPathComponent(".codex/auth.json")
    guard
      let authData = try? Data(contentsOf: authURL),
      let credentials = try? JSONDecoder().decode(Credentials.self, from: authData),
      let accessToken = credentials.tokens?.access_token,
      let accountID = credentials.tokens?.account_id
    else {
      throw URLError(.userAuthenticationRequired)
    }

    var request = URLRequest(url: endpoint)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    request.timeoutInterval = 10

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
    guard let rate = decoded.rate_limit else {
      throw URLError(.cannotParseResponse)
    }

    func window(_ raw: UsageResponse.Window?) -> CodexRateWindow? {
      raw.flatMap {
        CodexRateWindow(
          usedPercent: Double($0.used_percent ?? 0),
          windowMinutes: ($0.limit_window_seconds ?? 0) / 60,
          resetsAt: $0.reset_at.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? now)
      }
    }

    // Lane classification is by window span, not slot order.
    let primary = window(rate.primary_window)
    let secondary = window(rate.secondary_window)
    var sessionWindow: CodexRateWindow?
    var weekly: CodexRateWindow?
    for candidate in [primary, secondary].compactMap({ $0 }) {
      switch candidate.lane {
      case .session where sessionWindow == nil: sessionWindow = candidate
      case .weekly where weekly == nil: weekly = candidate
      default: break
      }
    }
    return (sessionWindow, weekly)
  }
}

/// Real Codex usage: live quota windows from the ChatGPT backend (OAuth
/// credentials from `~/.codex/auth.json`) plus per-day tokens parsed from
/// `~/.codex/sessions` rollouts.
struct CodexAIUsageProvider: AIUsageProvider {
  private static let dayWindow = 15

  var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

  func fetchUsage() async throws -> AIUsageSnapshot {
    // Independent sources: live windows work with zero recent sessions,
    // and day tokens still render when the backend is unreachable.
    let windows = try? await CodexOAuthUsage.fetchWindows(homeDirectory: homeDirectory)

    let sessionsRoot = homeDirectory.appendingPathComponent(".codex/sessions")
    var parsed: [(date: Date, usage: CodexTokenUsage, rateWindow: CodexRateWindow?)] = []
    if let enumerator = FileManager.default.enumerator(
      at: sessionsRoot, includingPropertiesForKeys: [])
    {
      let today = Calendar.current.startOfDay(for: Date())
      let cutoff = Calendar.current.date(byAdding: .day, value: -Self.dayWindow + 1, to: today)!
      // NSFastEnumeration's iterator is unavailable in async contexts; the
      // sessions tree is a few hundred URLs, so materialize it.
      let urls = (enumerator.allObjects as? [URL]) ?? []
      for url in urls where
        url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl"
      {
        guard let date = CodexUsageParser.sessionDate(filename: url.lastPathComponent),
          date >= cutoff
        else { continue }
        guard
          let handle = try? FileHandle(forReadingFrom: url),
          let tail = try? Self.tail(handle)
        else { continue }
        try? handle.close()
        if let entry = CodexUsageParser.lastTokenCount(in: tail) {
          parsed.append((date, entry.usage, entry.rateWindow))
        }
      }
    }

    guard windows?.session != nil || windows?.weekly != nil || !parsed.isEmpty else {
      throw URLError(.cannotParseResponse)
    }
    return CodexUsageParser.buildSnapshot(sessions: parsed, liveWindows: windows)
  }

  /// The final `length` bytes of an open file, or everything when shorter.
  private static func tail(_ handle: FileHandle, length: Int = 131_072) throws -> Data {
    let end = Int(try handle.seekToEndOfFile())
    let start = max(0, end - length)
    try handle.seek(toOffset: UInt64(start))
    return try handle.read(upToCount: end - start) ?? Data()
  }
}
