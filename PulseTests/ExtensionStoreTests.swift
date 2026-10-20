import AppKit
import SwiftUI
import XCTest
@testable import Pulse

final class ExtensionStoreTests: XCTestCase {
  func testPreferencesPersistAndNeverEmptySidebarOrRemoveBot() throws {
    let suite = "ExtensionStore-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var prefs = ExtensionPreferences.load(from: defaults)
    for bar in ExtensionPreferences.availableBars { prefs.setBar(bar, enabled: false) }
    XCTAssertEqual(prefs.bars.count, 1)
    for item in ExtensionPreferences.availableStatusItems { prefs.setStatusItem(item, enabled: false) }
    XCTAssertEqual(prefs.statusItems, ["bot"])
    prefs.bot = .cat
    prefs.wakeEffect = .aurora
    prefs.save(to: defaults)
    XCTAssertEqual(ExtensionPreferences.load(from: defaults), prefs)
    prefs.setBar("agents", enabled: true)
    XCTAssertTrue(prefs.bars.contains("agents"))
  }

  func testCorruptAndUnknownPreferencesRecover() {
    let suite = "ExtensionStore-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("broken".utf8), forKey: ExtensionPreferences.defaultsKey)
    XCTAssertEqual(ExtensionPreferences.load(from: defaults), ExtensionPreferences())
    var prefs = ExtensionPreferences()
    prefs.bars = ["removed-plugin"]
    prefs.statusItems = []
    prefs.save(to: defaults)
    let recovered = ExtensionPreferences.load(from: defaults)
    XCTAssertEqual(recovered.bars, ["reminders"])
    XCTAssertEqual(recovered.statusItems, ["bot"])
  }

  @MainActor
  func testEveryEffectRespondsToVoiceAndDismissesWithReducedMotion() {
    for effect in WakeEffect.allCases {
      for reduced in [false, true] {
        let view = BlackHoleWakeView(size: CGSize(width: 340, height: 30), radius: 18,
          reduceMotion: reduced, effect: effect)
        view.begin()
        view.awaken()
        view.setVoiceState(.listening)
        view.setVoiceLevel(input: 1, output: 0.4)
        XCTAssertGreaterThan(view.voiceEnergy, 0)
        XCTAssertTrue(view.isAwake)
        XCTAssertEqual(view.effect, effect)
        view.dismiss()
        view.setVoiceState(.speaking)
        XCTAssertNil(view.accessibilityLabel())
      }
    }
  }

  @MainActor
  func testStoreRendersAllSectionsAndCapturesPreview() throws {
    let suite = "ExtensionStore-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    let host = NSHostingView(rootView: ExtensionStoreView().environmentObject(model)
      .padding(24).background(.black).environment(\.locale, Locale(identifier: "en")))
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 760, height: 460),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(png.count, 10000)
    try png.write(to: URL(fileURLWithPath: "/tmp/pulse-extension-store.png"))
  }

  @MainActor
  func testStoreStaysPinnedUntilExplicitExit() async throws {
    let suite = "ExtensionStore-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    model.toggleExtensionStore()
    model.setIslandHovered(false)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertTrue(model.isExtensionStorePresented)
    XCTAssertEqual(model.islandState, .pinned)
    model.toggleExtensionStore()
    XCTAssertFalse(model.isExtensionStorePresented)
    XCTAssertEqual(model.islandState, .pinned)
  }

  @MainActor
  func testProviderCatalogCreatesProtocolSessionAndHasSetupInstructions() {
    for provider in VoiceProviderRegistry.providers {
      let session: any VoiceSessionProvider = provider.makeSession()
      session.stop()
      XCTAssertEqual(provider.setupURL.scheme, "https")
      XCTAssertEqual(VoiceProviderRegistry.provider(id: provider.id).id, provider.id)
    }
    XCTAssertEqual(VoiceProviderRegistry.provider(id: "removed-provider").id, "xiaozhi")
  }

  @MainActor
  func testStoreKeepsRenderedStatusHeaderAndUsesFilledGrid() async throws {
    let suite = "StoreHeader-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults,
      aiUsageProvider: SampleAIUsageProvider())
    model.weatherStore = WeatherStore(defaults: defaults, loader: {
      WeatherSnapshot(city: "北京市", temperature: 7, high: 12, low: 4,
        code: 0, isDay: false, observedAt: Date(), fetchedAt: Date())
    })
    await model.weatherStore.refresh()
    await model.reload()
    model.pinIsland()
    XCTAssertTrue(model.canUseActiveList)
    let agents = AgentSessionStore()
    func status(_ item: IslandStatusItem) -> NSView {
      let host = NSHostingView(rootView: IslandStatusItemView(item: item, displayID: nil)
        .environmentObject(model).environmentObject(agents)
        .environment(\.locale, Locale(identifier: "zh-Hans")))
      host.sizingOptions = item == .weather ? [.intrinsicContentSize] : []
      return host
    }
    let weather = status(.weather)
    let awake = status(.keepAwake)
    let button = NSHostingView(rootView: ExtensionStoreButton().environmentObject(model))
    button.sizingOptions = []
    let header = IslandStatusHeader(quota: status(.quota), bot: status(.bot),
      weather: weather, keepAwake: awake, store: button, barHeight: 32)
    header.layer?.backgroundColor = NSColor.black.cgColor
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 760, height: 32),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = header
    defer { window.close() }
    header.settle(size: CGSize(width: 760, height: 32), state: .pinned)
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(150))
    func render(_ rect: CGRect) throws -> NSBitmapImageRep {
      header.layoutSubtreeIfNeeded()
      let image = try XCTUnwrap(header.bitmapImageRepForCachingDisplay(in: rect))
      header.cacheDisplay(in: rect, to: image)
      return image
    }
    func png(_ rect: CGRect) throws -> Data {
      try XCTUnwrap(render(rect).representation(using: .png, properties: [:]))
    }
    XCTAssertEqual(weather.frame.minX - awake.frame.maxX, 6, accuracy: 0.5)
    XCTAssertEqual(button.frame.minX - weather.frame.maxX, 6, accuracy: 0.5)
    XCTAssertLessThan(weather.frame.width, 108, "Short weather text must not reserve a blank tail")
    // The weather glyph must occupy the leading 24pt, without a flexible spacer.
    let leading = try render(CGRect(x: weather.frame.minX, y: 0, width: 24, height: 32))
    var visiblePixels = 0
    for y in 0..<leading.pixelsHigh {
      for x in 0..<leading.pixelsWide {
        if let color = leading.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          max(color.redComponent, color.greenComponent, color.blueComponent) > 0.3 {
          visiblePixels += 1
        }
      }
    }
    XCTAssertGreaterThan(visiblePixels, 100, "Weather icon must begin beside the eye")
    let weatherBefore = try png(weather.frame)
    let buttonBefore = try png(button.frame)
    let framesBefore = header.presentedItemFrames
    let preview = CGRect(x: awake.frame.maxX - 32, y: 0,
      width: header.bounds.maxX - awake.frame.maxX + 32, height: 32)
    try png(preview).write(to: URL(fileURLWithPath: "/tmp/pulse-header-normal.png"))

    model.toggleExtensionStore()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(model.isExtensionStorePresented)
    XCTAssertEqual(header.presentedItemFrames, framesBefore)
    XCTAssertEqual(try png(weather.frame), weatherBefore, "Opening the store must preserve the live weather")
    XCTAssertNotEqual(try png(button.frame), buttonBefore, "Selected grid must visibly change")
    try png(preview).write(to: URL(fileURLWithPath: "/tmp/pulse-header-store.png"))
  }

  @MainActor
  func testStoreIsHiddenAndNotClickableWhenCollapsed() throws {
    let store = NSButton(title: "Store", target: nil, action: nil)
    let bot = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: bot, store: store, barHeight: 30)
    func hitStore() -> NSView? {
      // hitTest takes a point in the superview/window coordinate system.
      let center = CGPoint(x: store.frame.midX, y: store.frame.midY)
      return header.hitTest(header.convert(center, to: header.superview))
    }
    XCTAssertTrue(store.isHidden)
    header.settle(size: CGSize(width: 340, height: 30), state: .collapsed)
    XCTAssertTrue(store.isHidden)
    XCTAssertNil(hitStore())
    header.settle(size: CGSize(width: 760, height: 460), state: .pinned)
    XCTAssertFalse(store.isHidden)
    XCTAssertNotNil(hitStore())
    header.move(to: CGSize(width: 340, height: 30), state: .collapsed, spring: CASpringAnimation())
    XCTAssertTrue(store.isHidden, "Hide immediately when closing, including during the spring")
    XCTAssertNil(hitStore())
  }
}
