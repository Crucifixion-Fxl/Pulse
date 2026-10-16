import AppKit
import XCTest

@testable import TodoIsland

@MainActor
final class IslandTransitionTests: XCTestCase {
  private let collapsed = CGRect(x: 400, y: 700, width: 340, height: 32)
  private let expanded = CGRect(x: 190, y: 372, width: 760, height: 360)

  private func fixture() -> (TransitionTestWindow, IslandTransitionView, TransitionTestContent) {
    let window = TransitionTestWindow(
      contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = TransitionTestContent()
    let transition = IslandTransitionView(content: content)
    window.contentView = transition
    transition.transition(to: collapsed, state: .collapsed, collapsedRadius: 18, animated: false)
    window.orderFrontRegardless()
    content.layoutSubtreeIfNeeded()
    window.frameWrites = 0
    return (window, transition, content)
  }

  func testOpeningUnfoldsFromCenterBeforeSettling() async throws {
    let (window, transition, _) = fixture()
    defer { window.close() }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    var samples: [(Double, CGFloat, Float)] = []
    let start = CACurrentMediaTime()
    for _ in 0..<14 {
      try await Task.sleep(for: .milliseconds(50))
      let bounds = try XCTUnwrap(transition.presentedSurfaceBounds)
      let progress = (bounds.width - collapsed.width) / (expanded.width - collapsed.width)
      samples.append((CACurrentMediaTime() - start, progress, transition.presentedContentOpacity))
      if transition.isRunning {
        XCTAssertEqual(bounds.midX, transition.bounds.midX, accuracy: 0.5,
          "Both edges must travel symmetrically away from the center")
      }
    }
    print("Opening time / width progress / content opacity: \(samples)")
    let early = try XCTUnwrap(samples.first { $0.0 >= 0.09 })
    XCTAssertLessThan(early.2, 0.15, "The shape should open before the content appears")
    let revealed = try XCTUnwrap(samples.first { $0.0 >= 0.45 })
    XCTAssertGreaterThan(revealed.2, 0.95, "Content must be ready before the spring settles")
    let quarterSecond = try XCTUnwrap(samples.first { $0.0 >= 0.23 })
    XCTAssertLessThan(quarterSecond.1, 0.85,
      "Opening should still visibly unfold at 250ms, not already be full width")
    XCTAssertGreaterThan(quarterSecond.1, 0.35, "Respond promptly without an artificial wait")
    XCTAssertLessThanOrEqual(samples.map(\.1).max() ?? 0, 1.035,
      "A content panel should settle with restrained overshoot")
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertFalse(transition.isRunning)
    XCTAssertEqual(window.frame, expanded)
  }

  func testCompositorMovesWhileWindowAndLiveLayoutRemainFixed() async throws {
    let (window, transition, content) = fixture()
    defer { window.close() }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(transition.isRunning)
    XCTAssertEqual(transition.snapshotCount, 1)
    let early = try XCTUnwrap(transition.presentedSurfaceBounds)
    let frame = window.frame
    let writes = window.frameWrites
    let layouts = content.layouts
    try await Task.sleep(for: .milliseconds(150))
    let later = try XCTUnwrap(transition.presentedSurfaceBounds)
    XCTAssertGreaterThan(later.height, early.height)
    XCTAssertEqual(window.frame, frame)
    XCTAssertEqual(window.frameWrites, writes)
    XCTAssertEqual(content.layouts, layouts)
    XCTAssertEqual(content.bounds.size, expanded.size)
    XCTAssertNil(transition.hitTest(CGPoint(x: 1, y: transition.bounds.height - 1)))
    try await Task.sleep(for: .seconds(1))
    XCTAssertFalse(transition.isRunning)
    XCTAssertEqual(window.frame, expanded)
    XCTAssertEqual(content.convert(content.bounds, to: transition).origin, CGPoint.zero)
    XCTAssertEqual(transition.bounds.size, expanded.size)
    XCTAssertLessThanOrEqual(window.frameWrites, 2)
    XCTAssertEqual(transition.snapshotCount, 0, "Retina snapshots must be released")
  }

  func testRapidReversalAndRetargetDiscardStaleCompletions() async throws {
    let (window, transition, _) = fixture()
    defer { window.close() }
    transition.transition(to: expanded, state: .preview, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .milliseconds(90))
    transition.transition(to: collapsed, state: .collapsed, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .milliseconds(70))
    let taller = CGRect(
      x: expanded.minX, y: expanded.maxY - 410, width: expanded.width, height: 410)
    transition.transition(to: taller, state: .pinned, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .seconds(1.4))
    XCTAssertFalse(transition.isRunning)
    XCTAssertEqual(window.frame, taller)
    XCTAssertEqual(transition.snapshotCount, 0)
  }

  func testNonanimatedUpdateCancelsPendingPreparationAndRunningAnimation() async throws {
    let (window, transition, _) = fixture()
    defer { window.close() }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    transition.transition(to: collapsed, state: .collapsed, collapsedRadius: 18, animated: false)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(window.frame, collapsed)
    XCTAssertFalse(transition.isRunning)
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .milliseconds(100))
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: false)
    XCTAssertEqual(window.frame, expanded)
    XCTAssertFalse(transition.isRunning)
    XCTAssertEqual(transition.snapshotCount, 0)
    try await Task.sleep(for: .seconds(1))
    XCTAssertEqual(window.frame, expanded)
    // The controller's watchdog must repair externally displaced windows,
    // even when its requested destination has not changed.
    window.setFrame(expanded.offsetBy(dx: 20, dy: -10), display: false)
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: false)
    XCTAssertEqual(window.frame, expanded)
  }

  func testNativeFirstResponderSurvivesSnapshotTransition() async throws {
    let (window, transition, content) = fixture()
    defer { window.close() }
    let field = NSTextField(string: "Keep this draft")
    field.frame = CGRect(x: 20, y: 4, width: 200, height: 24)
    content.addSubview(field)
    XCTAssertTrue(window.makeFirstResponder(field))
    let responder = window.firstResponder
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .seconds(1.2))
    XCTAssertTrue(window.firstResponder === responder)
    XCTAssertEqual(field.stringValue, "Keep this draft")
  }
}

private final class TransitionTestWindow: NSWindow {
  var frameWrites = 0
  override var canBecomeKey: Bool { true }
  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    frameWrites += 1
    super.setFrame(frameRect, display: flag)
  }
}

private final class TransitionTestContent: NSView {
  var layouts = 0
  override func layout() {
    layouts += 1
    super.layout()
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.setFill()
    bounds.fill()
    NSColor.systemGreen.setFill()
    CGRect(x: 24, y: 12, width: 80, height: 16).fill()
  }
}
