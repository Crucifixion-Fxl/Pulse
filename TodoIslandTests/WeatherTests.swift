import AppKit
import XCTest
@testable import TodoIsland

@MainActor
final class WeatherTests: XCTestCase {
  func testRequestUsesCoarseCoordinatesAndDecodeHandlesNightWeather() throws {
    let coordinates = WeatherCoordinates(latitude: 31.234567, longitude: 121.456789)
    let request = WeatherService.request(for: coordinates)
    let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(query.first { $0.name == "latitude" }?.value, "31.2")
    XCTAssertEqual(query.first { $0.name == "longitude" }?.value, "121.5")
    let now = Date(timeIntervalSince1970: 1_792_163_700)
    let data = Data("""
      {"current":{"temperature_2m":21.8,"weather_code":0,"is_day":0,"time":1792163700},
       "daily":{"temperature_2m_max":[26.5],"temperature_2m_min":[20.3]}}
      """.utf8)
    let weather = try WeatherService.decode(data, city: "测试城市", now: now)
    XCTAssertEqual(weather.temperatureText, "22°")
    XCTAssertEqual(weather.symbol, "moon.stars.fill")
    XCTAssertEqual(weather.city, "测试城市")
    XCTAssertEqual(weather.high, 26.5)
    XCTAssertThrowsError(try WeatherService.decode(data, city: "测试城市", now: now.addingTimeInterval(7 * 3600)))
    XCTAssertThrowsError(try WeatherService.decode(Data("{}".utf8), city: "测试城市", now: now))
  }

  func testWeatherCodesHaveDistinctConditionsAndDayNightSymbols() {
    let symbols = [0: "sun.max.fill", 2: "cloud.sun.fill", 3: "cloud.fill", 45: "cloud.fog.fill",
      55: "cloud.drizzle.fill", 65: "cloud.rain.fill", 75: "cloud.snow.fill", 95: "cloud.bolt.rain.fill"]
    for (code, symbol) in symbols {
      XCTAssertEqual(snapshot(code: code).symbol, symbol)
    }
  }

  func testRefreshCoalescesCachesAndReloadsPersistedWeather() async {
    let suite = "WeatherTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var now = Date()
    var calls = 0
    let store = WeatherStore(defaults: defaults, clock: { now }) {
      calls += 1
      try await Task.sleep(for: .milliseconds(30))
      return self.snapshot(now: now)
    }
    async let first: Void = store.refresh()
    async let second: Void = store.refresh()
    _ = await (first, second)
    XCTAssertEqual(calls, 1)
    XCTAssertNotNil(store.snapshot)
    XCTAssertFalse(store.isLoading)
    await store.refresh()
    XCTAssertEqual(calls, 1)
    now = now.addingTimeInterval(WeatherStore.refreshInterval + 1)
    await store.refresh()
    XCTAssertEqual(calls, 2)
    let restored = WeatherStore(defaults: defaults, clock: { now }) { throw WeatherIssue.network }
    XCTAssertEqual(restored.snapshot, store.snapshot)
    XCTAssertFalse(restored.isStale)
  }

  func testFailureRetainsLastWeatherWithStaleStateAndDenialClearsIt() async {
    let suite = "WeatherTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var failure: WeatherIssue?
    var calls = 0
    let store = WeatherStore(defaults: defaults, loader: {
      calls += 1
      if let failure { throw failure }
      return self.snapshot()
    })
    await store.refresh()
    failure = .network
    await store.refresh(force: true)
    XCTAssertNotNil(store.snapshot)
    XCTAssertTrue(store.isStale)
    XCTAssertEqual(store.issue, .network)
    await store.refresh()
    XCTAssertEqual(calls, 2, "Reopening must not hammer a failed service")
    failure = .locationDenied
    await store.refresh(force: true)
    XCTAssertNil(store.snapshot)
    XCTAssertEqual(store.issue, .locationDenied)
    let restored = WeatherStore(defaults: defaults, loader: { throw WeatherIssue.network })
    XCTAssertNil(restored.snapshot)
  }

  func testWeatherHeaderOnlyAcceptsClicksInsideVisibleWeather() {
    let weather = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: NSView(), additionalQuotas: NSView(),
      weather: weather, barHeight: 32)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 360),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = header
    defer { window.close() }
    func hit(_ point: NSPoint) -> NSView? {
      header.hitTest(header.convert(point, to: header.superview))
    }
    header.settle(size: CGSize(width: 760, height: 360), state: .pinned)
    let point = NSPoint(x: weather.frame.midX, y: weather.frame.midY)
    XCTAssertNotNil(hit(point))
    XCTAssertNil(hit(NSPoint(x: header.bot.frame.midX, y: 16)))
    XCTAssertNil(hit(NSPoint(x: header.quota.frame.midX, y: 16)))
    XCTAssertGreaterThan(weather.frame.minX, 760 / 2 + 90, "Stay clear of the physical notch")
    XCTAssertLessThan(weather.frame.maxX, header.bot.frame.minX)
    header.settle(size: CGSize(width: 340, height: 32), state: .collapsed)
    XCTAssertEqual(weather.layer?.opacity, 0)
    XCTAssertNil(hit(NSPoint(x: weather.frame.midX, y: 16)))
  }

  private func snapshot(code: Int = 0, now: Date = Date()) -> WeatherSnapshot {
    WeatherSnapshot(city: "测试城市", temperature: 22, high: 27, low: 19,
      code: code, isDay: true, observedAt: now, fetchedAt: now)
  }
}
