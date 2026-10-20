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
  func testCollapsedStoreHasClickableFrameBeforeBot() throws {
    let store = NSButton(title: "Store", target: nil, action: nil)
    let bot = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: bot, store: store, barHeight: 30)
    header.settle(size: CGSize(width: 340, height: 30), state: .collapsed)
    XCTAssertLessThanOrEqual(store.frame.maxX, bot.frame.minX)
    XCTAssertNotNil(header.hitTest(CGPoint(x: store.frame.midX, y: store.frame.midY)))
  }
}
