import Foundation

/// One day of aggregated model usage across every vendor.
struct AIUsageDay: Hashable, Sendable, Identifiable {
  /// Start of the day this row aggregates.
  let day: Date
  var inputTokens: Int
  var outputTokens: Int
  var cacheTokens: Int

  var totalTokens: Int { inputTokens + outputTokens + cacheTokens }
  var id: Date { day }
}

/// A vendor the user holds an AI subscription with.
enum AIUsageVendor: String, CaseIterable, Hashable, Sendable {
  case zhipuGLM
  case anthropic
  case openAI

  var localizedKey: String {
    switch self {
    case .zhipuGLM: "ai.vendor.zhipu"
    case .anthropic: "ai.vendor.anthropic"
    case .openAI: "ai.vendor.openai"
    }
  }
}

enum AIQuotaStatus: Hashable, Sendable {
  case normal
  case warning
  case danger
}

/// A weekly allowance and how much of it is spent.
struct AIQuota: Hashable, Sendable {
  enum Unit: String, Hashable, Sendable {
    case tokens
    case requests
    case credits

    var localizedKey: String {
      switch self {
      case .tokens: "ai.unit.tokens"
      case .requests: "ai.unit.requests"
      case .credits: "ai.unit.credits"
      }
    }
  }

  var used: Int
  var limit: Int
  var unit: Unit

  var fraction: Double {
    guard limit > 0 else { return 0 }
    return min(max(Double(used) / Double(limit), 0), 1)
  }

  var status: AIQuotaStatus {
    switch fraction {
    case 0.95...: .danger
    case 0.8...: .warning
    default: .normal
    }
  }
}

/// One subscription card: vendor identity, plan, weekly quota, reset date.
struct AISubscription: Hashable, Sendable, Identifiable {
  let id: AIUsageVendor
  /// Proper noun rendered as-is; never localized.
  var planName: String
  var quota: AIQuota
  var resetsAt: Date
}

/// Everything the AI usage panel renders for one fetch.
struct AIUsageSnapshot: Hashable, Sendable {
  /// Exactly fifteen entries (half a month), ascending; the last is today.
  var days: [AIUsageDay]
  var subscriptions: [AISubscription]
  /// True while the numbers are fabricated; real providers clear it so the
  /// sample badge disappears.
  var isSample: Bool = true

  var today: AIUsageDay? { days.last }
  var weekTotalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }
}

/// Pure formatting helpers; locale and calendar injectable for tests.
enum AIUsageFormat {
  /// 1_252_000 → "1.25M" (en) / "125.2万" (zh); 386_214 → "386.2K" / "38.6万".
  static func compactTokens(_ tokens: Int, locale: Locale = .current) -> String {
    if locale.language.languageCode?.identifier.hasPrefix("zh") == true {
      let value = Double(tokens) / 10_000
      return trimZero("\(value.rounded(toPlaces: 1))") + "万"
    }
    switch tokens {
    case 1_000_000...:
      return "\((Double(tokens) / 1_000_000).rounded(toPlaces: 2))M"
    case 1_000...:
      return "\((Double(tokens) / 1_000).rounded(toPlaces: 1))K"
    default:
      return "\(tokens)"
    }
  }

  /// Grouped integer: 1252000 → "1,252,000" (locale-aware grouping).
  static func grouped(_ value: Int, locale: Locale = .current) -> String {
    value.formatted(.number.grouping(.automatic).locale(locale))
  }

  /// Whole days from `now` until `date`; nil when the date already passed.
  static func days(
    until date: Date,
    from now: Date = Date(),
    calendar: Calendar = .current
  ) -> Int? {
    guard date > now else { return nil }
    let startOfDayNow = calendar.startOfDay(for: now)
    let startOfDayThen = calendar.startOfDay(for: date)
    return calendar.dateComponents([.day], from: startOfDayNow, to: startOfDayThen).day
  }

  static func weekdayShort(_ date: Date, calendar: Calendar = .current) -> String {
    let symbols = calendar.veryShortWeekdaySymbols
    let weekday = calendar.component(.weekday, from: date)
    return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
  }

  private static func trimZero(_ value: String) -> String {
    value.hasSuffix(".0") ? String(value.dropLast(2)) : value
  }
}

private extension Double {
  func rounded(toPlaces places: Int) -> Double {
    let divisor = pow(10, Double(places))
    return (self * divisor).rounded() / divisor
  }
}

/// Deterministic sample data; dates are anchored to `now` so the panel
/// always shows a plausible trailing half month ending today.
enum AIUsageSample {
  static func makeSnapshot(now: Date, calendar: Calendar = .current) -> AIUsageSnapshot {
    let today = calendar.startOfDay(for: now)
    // Daily totals in thousands, oldest → today (half a month).
    let dailyTotals = [
      520, 1043, 689, 1187, 830, 1364, 715, 972,
      612, 878, 1312, 742, 956, 1418, 1252,
    ]
    let days = dailyTotals.enumerated().map { offset, totalK -> AIUsageDay in
      let date = calendar.date(byAdding: .day, value: offset - (dailyTotals.count - 1), to: today)!
      // Today's split is exact; earlier days use the ~31/41/28% profile.
      let (input, output, cache): (Int, Int, Int) =
        offset == dailyTotals.count - 1
        ? (386_214, 512_047, 354_101)
        : (
          Int((Double(totalK) * 0.31).rounded()) * 1_000,
          Int((Double(totalK) * 0.41).rounded()) * 1_000,
          Int((Double(totalK) * 0.28).rounded()) * 1_000
        )
      return AIUsageDay(
        day: date, inputTokens: input, outputTokens: output, cacheTokens: cache
      )
    }

    let subscriptions = [
      AISubscription(
        id: .zhipuGLM,
        planName: "Coding Plan",
        quota: AIQuota(used: 2_040, limit: 3_000, unit: .requests),
        resetsAt: calendar.date(byAdding: .day, value: 3, to: today)!.addingTimeInterval(14 * 3600)
      ),
      AISubscription(
        id: .anthropic,
        planName: "Claude Max",
        quota: AIQuota(used: 920, limit: 1_000, unit: .credits),
        resetsAt: calendar.date(byAdding: .day, value: 5, to: today)!.addingTimeInterval(9 * 3600)
      ),
      AISubscription(
        id: .openAI,
        planName: "ChatGPT Plus",
        quota: AIQuota(used: 812, limit: 2_000, unit: .requests),
        resetsAt: calendar.date(byAdding: .day, value: 1, to: today)!.addingTimeInterval(12 * 3600)
      ),
    ]

    return AIUsageSnapshot(days: days, subscriptions: subscriptions, isSample: true)
  }
}
