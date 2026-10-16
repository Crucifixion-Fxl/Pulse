import Combine
import Foundation

@MainActor
final class WeatherStore: ObservableObject {
  @Published private(set) var snapshot: WeatherSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var issue: WeatherIssue?
  private let defaults: UserDefaults
  private let loader: @MainActor () async throws -> WeatherSnapshot
  private let clock: () -> Date
  private var inFlight: Task<Void, Never>?
  private var lastAttempt: Date?
  private static let cacheKey = "weather.snapshot.v1"
  static let refreshInterval: TimeInterval = 15 * 60

  init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
       loader: (@MainActor () async throws -> WeatherSnapshot)? = nil) {
    self.defaults = defaults
    self.clock = clock
    if let loader { self.loader = loader } else {
      let location = WeatherLocationProvider()
      self.loader = {
        let (coordinates, city) = try await location.locate()
        return try await WeatherService().fetch(location: coordinates, city: city)
      }
    }
    if let data = defaults.data(forKey: Self.cacheKey),
      let cached = try? JSONDecoder().decode(WeatherSnapshot.self, from: data),
      (0..<(6 * 3600)).contains(clock().timeIntervalSince(cached.fetchedAt)) {
      snapshot = cached
    }
  }

  var isStale: Bool {
    guard let snapshot else { return false }
    return issue != nil || clock().timeIntervalSince(snapshot.fetchedAt) >= Self.refreshInterval
  }

  func refresh(force: Bool = false) async {
    if let inFlight { await inFlight.value; return }
    if !force {
      if let snapshot, (0..<Self.refreshInterval).contains(clock().timeIntervalSince(snapshot.fetchedAt)) { return }
      if let lastAttempt, clock().timeIntervalSince(lastAttempt) < 120 { return }
    }
    lastAttempt = clock()
    isLoading = true
    let task = Task {
      defer { isLoading = false; inFlight = nil }
      do {
        let next = try await loader()
        snapshot = next
        issue = nil
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.cacheKey) }
      } catch {
        issue = error as? WeatherIssue ?? .network
        if issue == .locationDenied {
          snapshot = nil
          defaults.removeObject(forKey: Self.cacheKey)
        }
      }
    }
    inFlight = task
    await task.value
  }
}
