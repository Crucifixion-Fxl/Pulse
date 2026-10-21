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
    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults)
    await model.reload()
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
  func testHiddenStoreDoesNotExpandShortAuthorizationPanel() async throws {
    var measuredHeight: CGFloat = 0
    let host = NSHostingView(rootView: ExtensionStoreTransition(isPresented: false, reduceMotion: true) {
      Color.red.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
          GeometryReader { geometry in
            Color.clear.onAppear { measuredHeight = geometry.size.height }
              .onChange(of: geometry.size.height) { _, height in measuredHeight = height }
          }
        }
    } store: {
      Color.blue.frame(height: 500).fixedSize(horizontal: false, vertical: true)
    }.frame(width: 760, height: 220))
    host.sizingOptions = []
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 760, height: 220),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(measuredHeight, 220, accuracy: 0.5,
      "The invisible store must not enlarge or crop the permission panel")
  }

  @MainActor
  func testStoreCrossfadeRetainsBothPanesAndSupportsReducedMotion() async throws {
    for reduced in [false, true] {
      var panelAppearances = 0
      var storeAppearances = 0
      func content(_ presented: Bool) -> some View {
        ExtensionStoreTransition(isPresented: presented, reduceMotion: reduced) {
          Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1).onAppear { panelAppearances += 1 }
        } store: {
          Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1).onAppear { storeAppearances += 1 }
        }
      }
      let host = NSHostingView(rootView: content(false))
      host.sizingOptions = []
      let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 100, height: 100),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer { window.close() }
      window.orderFront(nil)
      try await Task.sleep(for: .milliseconds(100))
      func pixel() throws -> NSColor {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2,
          y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
      }
      XCTAssertGreaterThan(try pixel().redComponent, 0.9)
      host.rootView = content(true)
      // CI can defer the first SwiftUI frame beyond 80 ms. Observe an actual
      // transition frame instead of assuming wall time equals animation time.
      host.layoutSubtreeIfNeeded()
      let deadline = CACurrentMediaTime() + 1
      var middle = try pixel()
      while CACurrentMediaTime() < deadline {
        let reachedFrame = reduced ? middle.blueComponent > 0.9
          : middle.redComponent > 0.1 && middle.blueComponent > 0.1
        if reachedFrame { break }
        try await Task.sleep(for: .milliseconds(8))
        middle = try pixel()
      }
      if reduced {
        XCTAssertGreaterThan(middle.blueComponent, 0.9)
        XCTAssertLessThan(middle.redComponent, 0.1)
      } else {
        XCTAssertGreaterThan(middle.redComponent, 0.1, "Outgoing panel must remain during the fade")
        XCTAssertGreaterThan(middle.blueComponent, 0.1, "Incoming store must already be appearing")
      }
      try await Task.sleep(for: .milliseconds(220))
      XCTAssertGreaterThan(try pixel().blueComponent, 0.9)
      for _ in 0..<3 {
        host.rootView = content(false)
        try await Task.sleep(for: .milliseconds(40))
        host.rootView = content(true)
        try await Task.sleep(for: .milliseconds(40))
      }
      host.rootView = content(false)
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertGreaterThan(try pixel().redComponent, 0.9)
      XCTAssertEqual(panelAppearances, 1, "Toggling must retain the existing panel")
      XCTAssertEqual(storeAppearances, 1, "Toggling must retain the existing store")
    }
  }

  @MainActor
  func testStoreExpandsWithoutSnapshotsOrColdLayoutStall() async throws {
    let suite = "StoreTransition-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults,
      aiUsageProvider: SampleAIUsageProvider())
    await model.reload()
    let existing = Set(NSApp.windows.map(\.windowNumber))
    let controller = IslandWindowController(model: model, reduceMotion: { false })
    defer { withExtendedLifetime(controller) {} }
    model.pinIslandForApproval()
    try await Task.sleep(for: .seconds(2))
    let surface = try XCTUnwrap(NSApp.windows.filter { !existing.contains($0.windowNumber) }
      .compactMap { $0.contentView as? IslandTransitionView }.first {
        $0.window?.screen?.todoIslandDisplayID == model.hostDisplayID
      })
    let frame = try XCTUnwrap(surface.window).frame
    let header = try XCTUnwrap(surface.statusHeader)
    let headerFrames = header.presentedItemFrames
    var maxima: [Double] = []
    for _ in 0..<6 {
      var last = CACurrentMediaTime()
      let start = last
      model.toggleExtensionStore()
      var gaps: [Double] = []
      while CACurrentMediaTime() - start < 0.35 {
        try await Task.sleep(for: .milliseconds(8))
        let now = CACurrentMediaTime()
        gaps.append((now - last) * 1000)
        last = now
        XCTAssertEqual(surface.presentedContentOpacity, 1, accuracy: 0.01,
          "Store crossfade must keep the live content visible")
        XCTAssertEqual(surface.snapshotCount, 0)
        XCTAssertEqual(surface.window?.frame.width, frame.width)
        XCTAssertEqual(surface.window?.frame.maxY, frame.maxY)
        XCTAssertEqual(header.presentedItemFrames.map(\.origin.x), headerFrames.map(\.origin.x))
      }
      maxima.append(gaps.max() ?? 0)
      if model.isExtensionStorePresented {
        XCTAssertGreaterThan(model.expandedContentHeight ?? 0, 350,
          "Store must expand to fit its complete content")
        let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: URL(fileURLWithPath: "/tmp/pulse-expanded-store.png"))
      }
    }
    print("Store main-thread gaps (ms): \(maxima)")
    // Compare opening with opening. Closing shrinks the surface and has a
    // different layout cost; mixing it into the median falsely flags a cold stall.
    let warm = maxima.enumerated().filter { $0.offset > 0 && $0.offset.isMultiple(of: 2) }
      .map(\.element).sorted()
    XCTAssertLessThanOrEqual(maxima[0], warm[warm.count / 2] * 1.5 + 8,
      "First store entry must not pay a separate cold layout cost: \(maxima)")
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
