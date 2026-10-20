import AppKit
import SwiftUI
import XCTest
@testable import Pulse

@MainActor
final class SidebarTransitionTests: XCTestCase {
  func testClickKeepsVisibleEdgesUntilCompositorTakesOver() async throws {
    let suite = "OpeningVisibleEdges-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: SidebarLayoutStore(), defaults: defaults,
      aiUsageProvider: SampleAIUsageProvider())
    await model.reload()
    let screen = try XCTUnwrap(NSScreen.screens.first)
    let displayID = try XCTUnwrap(screen.todoIslandDisplayID)
    model.setHostDisplayID(displayID)
    let geometry = DisplayGeometryCalculator.geometry(for: DisplaySupport.metrics(for: screen))
    let host = NSHostingView(rootView: IslandRootView(displayID: displayID,
      usesCompositorTransitions: true).environmentObject(model).environmentObject(AgentSessionStore()))
    host.sizingOptions = []
    let surface = IslandTransitionView(content: host)
    let window = NSWindow(contentRect: .zero, styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.contentView = surface
    defer { window.close() }
    let collapsed = CGRect(origin: CGPoint(x: 100, y: 150), size: geometry.collapsedSize)
    surface.transition(to: collapsed, state: .collapsed, collapsedRadius: 14, animated: false)
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(100))
    func edgeWidth() throws -> CGFloat {
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
      surface.cacheDisplay(in: surface.bounds, to: bitmap)
      let y = bitmap.pixelsHigh / 2
      let occupied = (0..<bitmap.pixelsWide).filter { x in
        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9
      }
      return CGFloat(try XCTUnwrap(occupied.last) - (try XCTUnwrap(occupied.first)) + 1)
        * surface.bounds.width / CGFloat(bitmap.pixelsWide)
    }
    let before = try edgeWidth()
    model.pinIslandFromSurface(on: displayID)
    let expanded = CGRect(x: collapsed.midX - geometry.expandedSize.width / 2,
      y: collapsed.maxY - geometry.expandedSize.height,
      width: geometry.expandedSize.width, height: geometry.expandedSize.height)
    surface.transition(to: expanded, state: .pinned, collapsedRadius: 14, animated: true)
    // Publishers have updated SwiftUI, while the native transition is
    // deliberately queued for the next main-loop turn in production.
    let afterClick = try edgeWidth()
    print("Visible width before click=\(before), before compositor takeover=\(afterClick)")
    XCTAssertGreaterThanOrEqual(afterClick, before - 1,
      "A click must not clip the existing bar narrower before native expansion starts")
  }

  func testOpeningEdgesNeverRetractBeforeReachingExpandedWidth() async throws {
    let suite = "OpeningEdges-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: SidebarLayoutStore(), defaults: defaults,
      aiUsageProvider: SampleAIUsageProvider())
    await model.reload()
    let existing = Set(NSApp.windows.map(\.windowNumber))
    let controller = IslandWindowController(model: model)
    defer { withExtendedLifetime(controller) {} }
    let surface = try XCTUnwrap(NSApp.windows.filter {
      !existing.contains($0.windowNumber)
    }.compactMap { $0.contentView as? IslandTransitionView }.first {
      $0.window?.screen?.todoIslandDisplayID == model.hostDisplayID
    })
    func visibleWidth() throws -> CGFloat {
      // During the closing spring, the window retains its expanded envelope.
      // Measure the silhouette consistently before and after the next click.
      if surface.layer?.mask == nil { return try XCTUnwrap(surface.window).frame.width }
      return try XCTUnwrap(surface.presentedSurfaceBounds).width
    }
    for cycle in 0..<8 {
      let initialWidth = try visibleWidth()
      var widths = [initialWidth]
      model.pinIslandForApproval()
      let start = CACurrentMediaTime()
      while CACurrentMediaTime() - start < 0.45 {
        try await Task.sleep(for: .milliseconds(8))
        widths.append(try visibleWidth())
      }
      var peak = initialWidth
      var largestRetraction: CGFloat = 0
      for width in widths {
        // The small spring settle at its destination is intentional; an
        // inward step during the initial unfold is not.
        if width < surface.content.bounds.width * 0.98 {
          largestRetraction = max(largestRetraction, peak - width)
        }
        peak = max(peak, width)
      }
      XCTAssertLessThanOrEqual(largestRetraction, 1,
        "Opening cycle \(cycle) must not retract before reaching the destination: \(widths)")
      try await Task.sleep(for: .seconds(1))
      model.collapseIsland()
      try await Task.sleep(for: .milliseconds(500))
    }
  }

  func testSurfaceClickRoutesDisplayAndSurvivesReloadWithoutPriorHover() async throws {
    let suite = "SurfaceClick-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: SidebarLayoutStore(), defaults: defaults,
      aiUsageProvider: SampleAIUsageProvider())
    await model.reload()
    model.setHostDisplayID("previous-display")
    model.pinIslandFromSurface(on: "clicked-display")
    XCTAssertEqual(model.hostDisplayID, "clicked-display")
    // A store refresh used to treat a click without mouseEntered as a
    // pointer exit and close the panel in the middle of its opening.
    await model.reload()
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(model.islandState, .pinned)
    model.setIslandHovered(false, on: "clicked-display")
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(model.islandState, .collapsed, "Real pointer exits must still dismiss")
  }

  func testVisibilityPollDoesNotCutShortLiveOpening() async throws {
    let suite = "OpeningVisibility-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: SidebarLayoutStore(), defaults: defaults,
      aiUsageProvider: SampleAIUsageProvider())
    await model.reload()
    let existing = Set(NSApp.windows.map(\.windowNumber))
    // Exercise the animated path regardless of the runner's accessibility settings.
    let controller = IslandWindowController(model: model, reduceMotion: { false })
    defer { withExtendedLifetime(controller) {} }
    // Open shortly before the controller's one-second full-screen poll.
    // This uses the actual SwiftUI content and production subscriptions.
    try await Task.sleep(for: .milliseconds(700))
    let surfaces = NSApp.windows.filter { !existing.contains($0.windowNumber) }
      .compactMap { $0.contentView as? IslandTransitionView }
    XCTAssertFalse(surfaces.isEmpty)
    let transition = try XCTUnwrap(surfaces.first {
      $0.window?.screen?.todoIslandDisplayID == model.hostDisplayID
    })
    let collapsedWidth = try XCTUnwrap(transition.window).frame.width
    model.pinIslandForApproval()
    // Cold SwiftUI layout may consume the first event-loop turns. Wait for
    // actual movement on the active display, not merely a queued request.
    // Settled surfaces now retain their compositor mask too.
    for _ in 0..<25 {
      if (transition.presentedSurfaceBounds?.width ?? 0) > collapsedWidth + 1 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let earlyWidth = try XCTUnwrap(transition.presentedSurfaceBounds).width
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(model.islandState, .pinned)
    XCTAssertTrue(transition.isRunning,
      "A visibility poll must not snap a live spring to its final frame")
    XCTAssertGreaterThan(try XCTUnwrap(transition.presentedSurfaceBounds).width, earlyWidth)
    try await Task.sleep(for: .seconds(1.2))
    XCTAssertFalse(transition.isRunning)
    XCTAssertEqual(transition.snapshotCount, 0)
  }

  func testHiddenAgentTimelinePausesAndResumes() async throws {
    let recorder = SidebarFrameRecorder()
    let view = AgentMascotTimeline(interval: 0.05) { time in
      Color.clear
        .onAppear { recorder.frames += 1 }
        .onChange(of: time) { _, _ in recorder.frames += 1 }
    }
    let host = NSHostingView(rootView: view.environment(\.agentPanelActive, true))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 64, height: 64),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(300))
    let activeFrames = recorder.frames
    let animationsEnabled = AgentMascotAnimationGate.shouldAnimate(
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    if !animationsEnabled {
      XCTAssertEqual(activeFrames, 1, "Accessibility and power settings must keep a static frame")
      host.rootView = view.environment(\.agentPanelActive, false)
      try await Task.sleep(for: .milliseconds(300))
      host.rootView = view.environment(\.agentPanelActive, true)
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertEqual(recorder.frames, activeFrames, "Panel changes must not bypass the motion gate")
      return
    }
    XCTAssertGreaterThan(activeFrames, 2)
    host.rootView = view.environment(\.agentPanelActive, false)
    try await Task.sleep(for: .milliseconds(100))
    let pausedFrames = recorder.frames
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(recorder.frames, pausedFrames)
    host.rootView = view.environment(\.agentPanelActive, true)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertGreaterThan(recorder.frames, pausedFrames + 2)
  }

  func testFirstAgentSwitchDoesNotAddColdLayoutStall() async throws {
    let suite = "SidebarTransition-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: SidebarLayoutStore(), defaults: defaults,
      aiUsageProvider: SampleAIUsageProvider())
    await model.reload()
    model.pinIslandForApproval()
    let agents = AgentSessionStore()
    for i in 0..<2 {
      let data = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit", "source": "codex",
        "session_id": "switch-\(i)", "prompt": "Verify sidebar transition"])
      agents.apply(try XCTUnwrap(HookEvent(from: data)))
    }
    let host = NSHostingView(rootView: IslandRootView()
      .environmentObject(model).environmentObject(agents))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 760, height: 348),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .seconds(1))
    var maxima: [Double] = []
    for _ in 0..<6 {
      model.requestSidebarItem(.reminders)
      try await Task.sleep(for: .milliseconds(600))
      let reminderHeight = model.expandedContentHeight
      var last = CACurrentMediaTime()
      let start = last
      model.requestSidebarItem(.agents)
      var gaps: [Double] = []
      while CACurrentMediaTime() - start < 0.6 {
        try await Task.sleep(for: .milliseconds(8))
        let now = CACurrentMediaTime()
        gaps.append((now - last) * 1000)
        last = now
      }
      maxima.append(gaps.max() ?? 0)
      XCTAssertEqual(model.expandedContentHeight, reminderHeight,
        "A sidebar crossfade must not also trigger a window snapshot/resize")
    }
    print("Sidebar main-thread gaps (ms): \(maxima)")
    // Compare cold entry with this run's warmed switches, rather than a
    // device-specific absolute frame budget. Allow 50% scheduling variance
    // plus one probe interval; rebuilding the pane adds a separate spike.
    let warm = maxima.dropFirst().sorted()
    let warmMedian = warm[warm.count / 2]
    XCTAssertLessThanOrEqual(maxima[0], warmMedian * 1.5 + 8,
      "First agent entry should cost no more than a warmed switch: \(maxima)")
  }

}

@MainActor
private final class SidebarLayoutStore: ReminderStore {
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

@MainActor
private final class SidebarFrameRecorder {
  var frames = 0
}
