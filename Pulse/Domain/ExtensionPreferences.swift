import Foundation

/// Built-in catalog identifiers are stable across launches; remote plugins are a later phase.
enum BotCharacter: String, Codable, CaseIterable, Identifiable {
  case orb, robot, cat
  var id: String { rawValue }
  var titleKey: String { "store.bot.\(rawValue)" }
}

enum WakeEffect: String, Codable, CaseIterable, Identifiable {
  case blackHole, aurora
  var id: String { rawValue }
  var titleKey: String { "store.effect.\(rawValue)" }
}

struct ExtensionPreferences: Codable, Equatable {
  var bars: [String] = ["reminders", "agents", "music", "clipboard"]
  var statusItems: [String] = ["quota", "additionalQuotas", "bot", "weather", "keepAwake"]
  var bot: BotCharacter = .orb
  var wakeEffect: WakeEffect = .blackHole
  var voiceProviderID = "xiaozhi"
  /// Separate from enablement so hiding a widget never loses its position.
  /// Optional for backwards-compatible decoding of existing preferences.
  var headerOrder: [String]?

  static let defaultHeaderOrder = ["quota", "additionalQuotas", "spacer", "keepAwake", "weather", "store", "bot"]

  var orderedHeaderItems: [String] { Self.normalizedHeaderOrder(headerOrder) }

  static func normalizedHeaderOrder(_ order: [String]?) -> [String] {
    var result: [String] = []
    for id in (order ?? defaultHeaderOrder) + defaultHeaderOrder
      where defaultHeaderOrder.contains(id) && !result.contains(id) {
      result.append(id)
    }
    return result
  }

  mutating func setHeaderOrder(_ order: [String]) {
    headerOrder = Self.normalizedHeaderOrder(order)
  }

  mutating func moveHeaderItem(_ id: String, before target: String) {
    guard id != "spacer", id != target, Self.defaultHeaderOrder.contains(id),
      Self.defaultHeaderOrder.contains(target) else { return }
    var order = orderedHeaderItems.filter { $0 != id }
    order.insert(id, at: order.firstIndex(of: target)!)
    setHeaderOrder(order)
  }

  static let defaultsKey = "pulse-extension-preferences-v1"
  static let availableBars = ["reminders", "agents", "music", "clipboard"]
  static let availableStatusItems = ["quota", "additionalQuotas", "bot", "weather", "keepAwake"]

  mutating func normalize() {
    bars = Self.availableBars.filter { bars.contains($0) }
    if bars.isEmpty { bars = ["reminders"] }
    statusItems = Self.availableStatusItems.filter { statusItems.contains($0) || $0 == "bot" }
    if let headerOrder { self.headerOrder = Self.normalizedHeaderOrder(headerOrder) }
  }

  mutating func setBar(_ id: String, enabled: Bool) {
    guard Self.availableBars.contains(id), enabled || bars.count > 1 else { return }
    bars.removeAll { $0 == id }
    if enabled { bars.append(id) }
    normalize()
  }

  mutating func setStatusItem(_ id: String, enabled: Bool) {
    guard Self.availableStatusItems.contains(id), id != "bot" else { return }
    statusItems.removeAll { $0 == id }
    if enabled { statusItems.append(id) }
    normalize()
  }

  static func load(from defaults: UserDefaults) -> Self {
    var result = defaults.data(forKey: defaultsKey)
      .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    result.normalize()
    return result
  }

  func save(to defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
  }
}
