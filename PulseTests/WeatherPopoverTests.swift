import AppKit
import SwiftUI
import XCTest

@testable import Pulse

@MainActor
final class WeatherPopoverTests: XCTestCase {
  func testWeatherPopoverKeepsIslandOpenAfterSurfacePointerExit() async throws {
    let suite = "WeatherPopover-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults)
    await model.start()
    model.pinIslandFromSurface(on: nil)
    let weather = WeatherStore(defaults: defaults, loader: {
      WeatherSnapshot(city: "Popover Test", temperature: 22, high: 27, low: 19,
        code: 2, isDay: true, observedAt: Date(), fetchedAt: Date())
    })
    await weather.refresh()
    let host = NSHostingView(rootView:
      WeatherStatusView(store: weather, isActive: true).environmentObject(model))
    let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 240, height: 32),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(100))
    let existingWindows = Set(NSApp.windows.map(\.windowNumber))
    let location = NSPoint(x: 100, y: 16)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
    try await Task.sleep(for: .milliseconds(200))
    let popoverWindow = try XCTUnwrap(NSApp.windows.first {
      !existingWindows.contains($0.windowNumber) && $0.isVisible
    }, "The real weather popover must open before testing pointer exit")
    defer { popoverWindow.close() }
    XCTAssertTrue(model.isWeatherDetailsPresented)

    // AppKit transfers tracking to the popover's separate window; the island
    // surface receives onHover(false) even while reading its weather details.
    model.setIslandHovered(false)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(model.islandState, .pinned,
      "Entering weather details must not collapse the island underneath")

    popoverWindow.performClose(nil)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertFalse(model.isWeatherDetailsPresented)
    XCTAssertEqual(model.islandState, .collapsed,
      "Closing weather details outside the surface must restore normal dismissal")
  }

  func testWeatherOpeningCancelsPendingExitAndDoesNotReleaseOtherHolds() async throws {
    let suite = "WeatherHold-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults)
    await model.start()
    model.pinIslandFromSurface(on: nil)
    model.setIslandHovered(false)
    try await Task.sleep(for: .milliseconds(50))
    model.setWeatherDetailsPresented(true)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(model.islandState, .pinned)

    model.setKeepAwakeControlsPresented(true)
    model.setWeatherDetailsPresented(false)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(model.islandState, .pinned)
    model.setKeepAwakeControlsPresented(false)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(model.islandState, .collapsed)
  }

  func testWeatherFocusHandoffKeepsIslandOpenButNormalDeactivationStillClosesIt() async {
    let suite = "WeatherFocus-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: LocalOnlyTestReminderStore(), defaults: defaults)
    await model.start()
    model.pinIslandFromSurface(on: nil)
    model.setWeatherDetailsPresented(true)
    let controller = IslandWindowController(model: model)
    defer { withExtendedLifetime(controller) {} }

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    XCTAssertEqual(model.islandState, .pinned)
    model.setWeatherDetailsPresented(false)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    XCTAssertEqual(model.islandState, .collapsed)
  }

}
