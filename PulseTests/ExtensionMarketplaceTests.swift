import AppKit
import SwiftUI
import XCTest
@testable import Pulse

@MainActor
final class ExtensionMarketplaceTests: XCTestCase {
  func testSearchCombinesKeywordsCategoryAndEnabledState() {
    let browser = ExtensionStoreBrowser()
    var preferences = ExtensionPreferences()
    browser.query = "  PULSE weather  "
    XCTAssertEqual(browser.results(preferences: preferences, voiceInstalled: false).map(\.id), ["pulse.weather"])
    browser.query = "天气"
    XCTAssertEqual(browser.results(preferences: preferences, voiceInstalled: false).map(\.id), ["pulse.weather"])
    browser.category = .appearance
    XCTAssertTrue(browser.results(preferences: preferences, voiceInstalled: false).isEmpty)
    browser.resetFilters()
    browser.scope = .enabled
    preferences.setStatusItem("weather", enabled: false)
    let enabled = browser.results(preferences: preferences, voiceInstalled: false).map(\.id)
    XCTAssertFalse(enabled.contains("pulse.weather"))
    XCTAssertFalse(enabled.contains("pulse.xiaozhi"), "Missing voice runtime must not appear usable")
    XCTAssertFalse(enabled.contains("pulse.cat"))
    XCTAssertTrue(enabled.contains("pulse.orb"))
    XCTAssertTrue(browser.results(preferences: preferences, voiceInstalled: true).map(\.id).contains("pulse.xiaozhi"))
  }

  func testEveryExtensionIsReachableAndFiltersResetPagination() {
    let browser = ExtensionStoreBrowser()
    let results = browser.results(preferences: ExtensionPreferences(), voiceInstalled: true)
    var ids: [String] = []
    for page in 0..<browser.pageCount(for: results) {
      browser.page = page
      let visible = browser.visibleEntries(in: results)
      XCTAssertLessThanOrEqual(visible.count, 4)
      ids += visible.map(\.id)
    }
    XCTAssertEqual(ids, ExtensionCatalog.entries.map(\.id))
    XCTAssertEqual(Set(ids).count, ids.count)
    browser.query = "not-a-real-plugin"
    XCTAssertEqual(browser.page, 0)
    XCTAssertTrue(browser.results(preferences: ExtensionPreferences(), voiceInstalled: true).isEmpty)
    browser.page = 90
    XCTAssertEqual(browser.currentPage(for: []), 0)
    browser.category = .voice
    XCTAssertEqual(browser.page, 0)
    browser.resetFilters()
    XCTAssertEqual(browser.results(preferences: ExtensionPreferences(), voiceInstalled: true).count, ids.count)
  }

  func testCatalogActionsPersistAndPreserveRequiredFeatures() throws {
    let suite = "MarketplaceActions-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var preferences = ExtensionPreferences()
    for entry in ExtensionCatalog.entries where entry.category == .productivity { entry.apply(to: &preferences) }
    XCTAssertEqual(preferences.bars.count, 1)
    let bot = try XCTUnwrap(ExtensionCatalog.entries.first { $0.id == "pulse.bot" })
    XCTAssertFalse(bot.canChange(in: preferences))
    bot.apply(to: &preferences)
    XCTAssertTrue(preferences.statusItems.contains("bot"))
    try XCTUnwrap(ExtensionCatalog.entries.first { $0.id == "pulse.cat" }).apply(to: &preferences)
    try XCTUnwrap(ExtensionCatalog.entries.first { $0.id == "pulse.aurora" }).apply(to: &preferences)
    try XCTUnwrap(ExtensionCatalog.entries.first { $0.id == "pulse.weather" }).apply(to: &preferences)
    preferences.save(to: defaults)
    XCTAssertEqual(ExtensionPreferences.load(from: defaults), preferences)
    XCTAssertEqual(preferences.bot, .cat)
    XCTAssertEqual(preferences.wakeEffect, .aurora)
    XCTAssertFalse(preferences.statusItems.contains("weather"))
  }

  func testAllCatalogMetadataHasBothTranslations() throws {
    let keys = ExtensionCatalog.entries.flatMap { [$0.titleKey, $0.summaryKey, $0.detailKey] }
      + ExtensionCategory.allCases.map(\.titleKey)
      + ExtensionStoreBrowser.Scope.allCases.map(\.titleKey)
    for language in ["en", "zh-Hans"] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: path))
      for key in keys {
        XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key,
          "Missing \(language) translation: \(key)")
      }
    }
  }

  func testRenderedMarketplaceRoutesRetainSearchAndConfiguration() async throws {
    let suite = "MarketplaceUI-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults)
    await model.reload()
    model.pinIsland()
    let browser = ExtensionStoreBrowser()
    let host = NSHostingView(rootView: ExtensionStoreView(browser: browser)
      .environmentObject(model).padding(12).background(.black))
    host.sizingOptions = []
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 760, height: 444),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(180))

    func capture(_ name: String) throws {
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(png.count, 5000)
      try png.write(to: URL(fileURLWithPath: "/tmp/pulse-market-\(name).png"))
    }
    try capture("browse")
    browser.page = browser.currentPage(for: browser.results(preferences: model.extensionPreferences, voiceInstalled: true)) + 1
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(browser.page, 1)
    browser.query = "weather"
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(browser.query, "weather")
    XCTAssertEqual(browser.page, 0)
    try capture("search")
    let weather = try XCTUnwrap(ExtensionCatalog.entries.first { $0.id == "pulse.weather" })
    browser.show(weather)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(browser.selectedID, "pulse.weather")
    try capture("detail")
    weather.apply(to: &model.extensionPreferences)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertFalse(model.extensionPreferences.statusItems.contains("weather"))
    browser.back()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(browser.query, "weather", "Back must preserve the search context")
    browser.scope = .enabled
    try await Task.sleep(for: .milliseconds(80))
    try capture("empty")
    browser.resetFilters()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(browser.query.isEmpty)
    browser.category = .appearance
    try await Task.sleep(for: .milliseconds(80))
    try capture("appearance")
    try XCTUnwrap(ExtensionCatalog.entries.first { $0.id == "pulse.cat" }).apply(to: &model.extensionPreferences)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(model.extensionPreferences.bot, .cat)
    browser.showsDeveloper = true
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(browser.showsDeveloper)
    try capture("developer")
    browser.back()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(browser.category, .appearance)
  }
}
