import AppKit
import SwiftUI
import XCTest
@testable import TodoIsland

@MainActor
final class IslandStartupLayoutTests: XCTestCase {
  func testBotRemainsAtRightEdgeThroughoutColdLayoutAndPrewarm() async throws {
    let suite = "StartupLayout-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: StartupLayoutStore(), defaults: defaults)
    await model.reload()
    // Pin the display and use its actual bar geometry. A fixed 340×30
    // fixture misplaces the surface on a notched display, and a nil id
    // changes metrics whenever the pointer moves to another monitor.
    let screen = try XCTUnwrap(NSScreen.screens.first)
    let displayID = try XCTUnwrap(screen.todoIslandDisplayID)
    let size = DisplayGeometryCalculator.geometry(for: DisplaySupport.metrics(for: screen)).collapsedSize
    let host = NSHostingView(rootView: IslandRootView(displayID: displayID, usesCompositorTransitions: true)
      .environmentObject(model).environmentObject(AgentSessionStore()))
    host.sizingOptions = []
    func statusItem(_ item: IslandStatusItem) -> NSView {
      let view = NSHostingView(rootView: IslandStatusItemView(item: item, displayID: displayID)
        .environmentObject(model).environmentObject(AgentSessionStore()))
      view.sizingOptions = []
      return view
    }
    let header = IslandStatusHeader(quota: statusItem(.quota), bot: statusItem(.bot), barHeight: size.height)
    let surface = IslandTransitionView(content: host, statusHeader: header)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = surface
    surface.transition(to: window.frame, state: .collapsed,
      collapsedRadius: screen.safeAreaInsets.top > 0 ? 14 : 18, animated: false)
    defer { window.close() }
    window.orderFront(nil)
    var centers: [CGFloat] = []
    for _ in 0..<28 {
      try await Task.sleep(for: .milliseconds(100))
      surface.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
      surface.cacheDisplay(in: surface.bounds, to: bitmap)
      var xs: [Int] = []
      for y in 0..<bitmap.pixelsHigh {
        // Ignore the quota chip; only the right-hand bot is under test.
        for x in (bitmap.pixelsWide * 2 / 3)..<bitmap.pixelsWide {
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
          if color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent > 0.8 {
            xs.append(x)
          }
        }
      }
      let center = xs.isEmpty ? -1 : CGFloat(xs.reduce(0,+)) / CGFloat(xs.count) / CGFloat(bitmap.pixelsWide)
      centers.append(center)
    }
    print("Startup bot normalized centers: \(centers)")
    let faceSize = min(26, max(18, size.height - 6)).rounded()
    let expected = (size.width - 12 - faceSize / 2) / size.width
    XCTAssertTrue(centers.allSatisfy { abs($0 - expected) < 0.02 },
      "Bot must remain at the trailing edge before, during, and after hidden pane prewarm: \(centers)")
  }
}

@MainActor
private final class StartupLayoutStore: ReminderStore {
  var onStoreChanged: (() -> Void)?
  func authorizationStatus() -> ReminderAuthorization { .fullAccess }
  func requestFullAccess() async throws -> Bool { true }
  func fetchLists() async throws -> [ReminderListSnapshot] {
    [ReminderListSnapshot(id: "startup", title: "Startup", accent: .fallback)]
  }
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] { [] }
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] { [] }
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] { [] }
  func createReminder(title: String, in listID: String, dueComponents: DateComponents?) async throws {}
  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func setCompleted(_ completed: Bool, reminderID: String) async throws {}
  func deleteReminder(id: String) async throws {}
}
