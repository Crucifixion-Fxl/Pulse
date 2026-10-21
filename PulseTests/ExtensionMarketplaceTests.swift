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

  func testDetailSelectionFollowsVisibleCatalog() throws {
    let browser = ExtensionStoreBrowser()
    var preferences = ExtensionPreferences()
    let all = browser.results(preferences: preferences, voiceInstalled: true)
    XCTAssertEqual(browser.selection(in: all)?.id, "pulse.reminders")
    let weather = try XCTUnwrap(all.first { $0.slug == "weather" })
    browser.show(weather)
    XCTAssertEqual(browser.selection(in: all), weather)
    browser.query = "weather"
    XCTAssertEqual(browser.selection(in: browser.results(preferences: preferences, voiceInstalled: true)), weather)
    browser.scope = .enabled
    weather.apply(to: &preferences)
    XCTAssertNil(browser.selection(in: browser.results(preferences: preferences, voiceInstalled: true)))
    browser.resetFilters()
    browser.category = .appearance
    XCTAssertEqual(browser.selection(in: browser.results(preferences: preferences, voiceInstalled: true))?.id, "pulse.orb")
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
    func findScrollView(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView { return scroll }
      return view.subviews.lazy.compactMap { findScrollView($0) }.first
    }
    let scroll = try XCTUnwrap(findScrollView(host))
    let document = try XCTUnwrap(scroll.documentView)
    XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height * 2,
      "All extensions must be available in one continuous list")
    // A lazy stack refines its document height as rows materialize. Continue
    // scrolling until the actual final row is reached, as repeated wheel input does.
    for _ in 0..<6 {
      scroll.contentView.scroll(to: CGPoint(x: 0,
        y: document.bounds.height - scroll.contentView.bounds.height))
      scroll.reflectScrolledClipView(scroll.contentView)
      try await Task.sleep(for: .milliseconds(80))
      if abs(scroll.contentView.bounds.maxY - document.bounds.height) < 1 { break }
    }
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
    XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.height, accuracy: 1)
    browser.show(try XCTUnwrap(ExtensionCatalog.entries.last))
    try await Task.sleep(for: .milliseconds(80))
    try capture("scrolled-bottom")
    browser.query = "weather"
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(browser.query, "weather")
    XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
    try capture("search")
    let weather = try XCTUnwrap(ExtensionCatalog.entries.first { $0.id == "pulse.weather" })
    browser.show(weather)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(browser.selectedID, "pulse.weather")
    try capture("detail")
    weather.apply(to: &model.extensionPreferences)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertFalse(model.extensionPreferences.statusItems.contains("weather"))
    browser.selectedID = nil
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
    XCTAssertEqual(browser.category, .appearance)
  }
}
