import Foundation
import Combine

enum ExtensionCategory: String, CaseIterable, Identifiable {
  case all, productivity, status, appearance, voice
  var id: String { rawValue }
  var titleKey: String { "market.category.\(rawValue)" }
}

enum ExtensionCapability: Equatable {
  case bar(String), status(String), character(BotCharacter), effect(WakeEffect), voice(String)
}

/// Catalog metadata is separate from preferences and presentation. Only real,
/// bundled capabilities are listed until a remote registry exists.
struct PulseExtension: Identifiable, Equatable {
  let slug: String
  let titleKey: String
  let symbol: String
  let category: ExtensionCategory
  let capability: ExtensionCapability
  let keywords: String
  var id: String { "pulse.\(slug)" }
  var summaryKey: String { "market.\(slug).summary" }
  var detailKey: String { "market.\(slug).detail" }
  var publisher: String { "Pulse" }

  func isEnabled(in preferences: ExtensionPreferences) -> Bool {
    switch capability {
    case .bar(let id): preferences.bars.contains(id)
    case .status(let id): preferences.statusItems.contains(id)
    case .character(let value): preferences.bot == value
    case .effect(let value): preferences.wakeEffect == value
    case .voice(let id): preferences.voiceProviderID == id
    }
  }

  func canChange(in preferences: ExtensionPreferences) -> Bool {
    switch capability {
    case .bar: !isEnabled(in: preferences) || preferences.bars.count > 1
    case .status(let id): id != "bot"
    case .character, .effect, .voice: !isEnabled(in: preferences)
    }
  }

  func apply(to preferences: inout ExtensionPreferences) {
    guard canChange(in: preferences) else { return }
    switch capability {
    case .bar(let id): preferences.setBar(id, enabled: !isEnabled(in: preferences))
    case .status(let id): preferences.setStatusItem(id, enabled: !isEnabled(in: preferences))
    case .character(let value): preferences.bot = value
    case .effect(let value): preferences.wakeEffect = value
    case .voice(let id): preferences.voiceProviderID = id
    }
  }

  func matches(_ query: String) -> Bool {
    let text = [id, publisher, L10n.text(titleKey), L10n.text(summaryKey), keywords].joined(separator: " ")
    return query.split(whereSeparator: \.isWhitespace).allSatisfy {
      text.localizedStandardContains(String($0))
    }
  }
}

enum ExtensionCatalog {
  static let entries: [PulseExtension] = [
    .init(slug: "reminders", titleKey: "sidebar.reminders", symbol: "checklist", category: .productivity,
      capability: .bar("reminders"), keywords: "reminders calendar tasks 提醒 日历 待办"),
    .init(slug: "agents", titleKey: "sidebar.agents", symbol: "terminal", category: .productivity,
      capability: .bar("agents"), keywords: "agents codex claude coding 智能体 编程"),
    .init(slug: "weather", titleKey: "store.status.weather", symbol: "cloud.sun.fill", category: .status,
      capability: .status("weather"), keywords: "weather forecast temperature 天气 气温 城市"),
    .init(slug: "music", titleKey: "sidebar.music", symbol: "music.note", category: .productivity,
      capability: .bar("music"), keywords: "music player lyrics 音乐 播放 歌词"),
    .init(slug: "clipboard", titleKey: "sidebar.clipboard", symbol: "doc.on.clipboard", category: .productivity,
      capability: .bar("clipboard"), keywords: "clipboard copy history 剪贴板 复制 历史"),
    .init(slug: "keep-awake", titleKey: "store.status.keepAwake", symbol: "eye", category: .status,
      capability: .status("keepAwake"), keywords: "awake sleep caffeine 唤醒 睡眠"),
    .init(slug: "quota", titleKey: "store.status.quota", symbol: "chart.bar.xaxis", category: .status,
      capability: .status("quota"), keywords: "quota codex usage 额度 用量"),
    .init(slug: "additional-quotas", titleKey: "store.status.additionalQuotas", symbol: "chart.bar", category: .status,
      capability: .status("additionalQuotas"), keywords: "quota anthropic glm usage 额度 用量"),
    .init(slug: "bot", titleKey: "store.status.bot", symbol: "face.smiling", category: .status,
      capability: .status("bot"), keywords: "bot mascot 机器人 状态"),
    .init(slug: "orb", titleKey: "store.bot.orb", symbol: "circle.fill", category: .appearance,
      capability: .character(.orb), keywords: "orb theme character 圆球 造型 外观"),
    .init(slug: "robot", titleKey: "store.bot.robot", symbol: "square.fill", category: .appearance,
      capability: .character(.robot), keywords: "robot theme character 方块 造型 外观"),
    .init(slug: "cat", titleKey: "store.bot.cat", symbol: "cat.fill", category: .appearance,
      capability: .character(.cat), keywords: "cat theme character 猫咪 造型 外观"),
    .init(slug: "black-hole", titleKey: "store.effect.blackHole", symbol: "sparkles", category: .appearance,
      capability: .effect(.blackHole), keywords: "black hole wake effect 黑洞 粒子 唤醒"),
    .init(slug: "aurora", titleKey: "store.effect.aurora", symbol: "waveform.path", category: .appearance,
      capability: .effect(.aurora), keywords: "aurora wake effect 极光 唤醒"),
    .init(slug: "xiaozhi", titleKey: "market.xiaozhi.title", symbol: "waveform", category: .voice,
      capability: .voice("xiaozhi"), keywords: "xiaozhi voice speech ai 小智 语音 对话")
  ]
}

@MainActor
final class ExtensionStoreBrowser: ObservableObject {
  enum Scope: String, CaseIterable {
    case discover, enabled
    var titleKey: String { "market.scope.\(rawValue)" }
  }
  @Published var query = "" { didSet { page = 0 } }
  @Published var category: ExtensionCategory = .all { didSet { page = 0 } }
  @Published var scope: Scope = .discover { didSet { page = 0 } }
  @Published var page = 0
  @Published var selectedID: String?
  @Published var showsDeveloper = false
  static let pageSize = 5

  func results(preferences: ExtensionPreferences, voiceInstalled: Bool) -> [PulseExtension] {
    ExtensionCatalog.entries.filter {
      (category == .all || $0.category == category) && $0.matches(query)
        && (scope == .discover || ($0.isEnabled(in: preferences)
          && ($0.category != .voice || voiceInstalled)))
    }
  }

  func pageCount(for results: [PulseExtension]) -> Int {
    max(1, (results.count + Self.pageSize - 1) / Self.pageSize)
  }

  func currentPage(for results: [PulseExtension]) -> Int {
    min(max(0, page), pageCount(for: results) - 1)
  }

  func visibleEntries(in results: [PulseExtension]) -> [PulseExtension] {
    Array(results.dropFirst(currentPage(for: results) * Self.pageSize).prefix(Self.pageSize))
  }

  /// Keep detail and selection within the visible page after filtering, paging,
  /// or disabling an entry from the Enabled view.
  func selection(in results: [PulseExtension]) -> PulseExtension? {
    let visible = visibleEntries(in: results)
    return visible.first { $0.id == selectedID } ?? visible.first
  }

  func resetFilters() { query = ""; category = .all; scope = .discover; page = 0 }
  func show(_ entry: PulseExtension) { selectedID = entry.id; showsDeveloper = false }
  func back() { selectedID = nil; showsDeveloper = false }
}
