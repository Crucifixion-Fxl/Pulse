import AppKit
import SwiftUI
import XCTest
@testable import TodoIsland

@MainActor
final class SidebarTransitionTests: XCTestCase {
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
