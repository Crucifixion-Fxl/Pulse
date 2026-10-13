import Foundation

/// Codex token usage as recorded in a rollout's cumulative counters.
struct CodexTokenUsage: Equatable, Sendable {
  var input: Int
  var cached: Int
  var cacheWrite: Int
  var output: Int
}

/// The newest rate-limit window a session reported.
struct CodexRateLimit: Equatable, Sendable {
  var usedPercent: Double
  var resetsAt: Date
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
  ) -> (usage: CodexTokenUsage, rateLimit: CodexRateLimit?)? {
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
      let limit = event.payload?.rate_limits?.primary.flatMap { window in
        CodexRateLimit(
          usedPercent: window.used_percent ?? 0,
          resetsAt: window.resets_at.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? now)
      }
      return (tokens, limit)
    }
    return nil
  }

  /// Aggregates parsed sessions into the panel's snapshot shape: exactly
  /// fifteen ascending days ending today (zero-filled), the day split
  /// following the panel's input/output/cache breakdown, and the Codex
  /// subscription built from the newest rate-limit window seen.
  static func buildSnapshot(
    sessions: [(date: Date, usage: CodexTokenUsage, rateLimit: CodexRateLimit?)],
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> AIUsageSnapshot {
    let today = calendar.startOfDay(for: now)
    var days: [AIUsageDay] = []
    var byDay: [Date: (input: Int, output: Int, cache: Int)] = [:]
    var newestRate: CodexRateLimit?

    for session in sessions {
      let key = calendar.startOfDay(for: session.date)
      let entry = byDay[key] ?? (0, 0, 0)
      byDay[key] = (
        entry.input + max(0, session.usage.input - session.usage.cached),
        entry.output + session.usage.output,
        entry.cache + session.usage.cached + session.usage.cacheWrite
      )
      if let rate = session.rateLimit {
        if newestRate == nil || rate.resetsAt > newestRate!.resetsAt {
          newestRate = rate
        }
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

    let subscription: AISubscription
    if let rate = newestRate {
      subscription = AISubscription(
        id: .openAI,
        planName: "Codex",
        quota: AIQuota(
          used: Int(rate.usedPercent.rounded()),
          limit: 100,
          unit: .percent),
        resetsAt: rate.resetsAt)
    } else {
      // Sessions exist but none reported a window yet — an expired-looking
      // zero is more honest than no card.
      subscription = AISubscription(
        id: .openAI,
        planName: "Codex",
        quota: AIQuota(used: 0, limit: 100, unit: .percent),
        resetsAt: now)
    }

    return AIUsageSnapshot(days: days, subscriptions: [subscription], isSample: false)
  }
}

/// Real Codex usage from `~/.codex/sessions`: the last `token_count` event
/// of each recent rollout carries the session's cumulative tokens and the
/// account's current rate-limit window.
struct CodexAIUsageProvider: AIUsageProvider {
  private static let dayWindow = 15

  var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser

  func fetchUsage() async throws -> AIUsageSnapshot {
    let sessionsRoot = homeDirectory.appendingPathComponent(".codex/sessions")
    guard let enumerator = FileManager.default.enumerator(
      at: sessionsRoot, includingPropertiesForKeys: []
    ) else {
      throw URLError(.fileDoesNotExist)
    }

    let today = Calendar.current.startOfDay(for: Date())
    let cutoff = Calendar.current.date(byAdding: .day, value: -Self.dayWindow + 1, to: today)!
    var parsed: [(date: Date, usage: CodexTokenUsage, rateLimit: CodexRateLimit?)] = []

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
        parsed.append((date, entry.usage, entry.rateLimit))
      }
    }

    guard !parsed.isEmpty else {
      throw URLError(.cannotParseResponse)
    }
    return CodexUsageParser.buildSnapshot(sessions: parsed)
  }

  /// The final `length` bytes of an open file, or everything when shorter.
  private static func tail(_ handle: FileHandle, length: Int = 131_072) throws -> Data {
    let end = Int(try handle.seekToEndOfFile())
    let start = max(0, end - length)
    try handle.seek(toOffset: UInt64(start))
    return try handle.read(upToCount: end - start) ?? Data()
  }
}
