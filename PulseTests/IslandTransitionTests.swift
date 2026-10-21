import AppKit
import XCTest

@testable import Pulse

@MainActor
final class IslandTransitionTests: XCTestCase {
  private let collapsed = CGRect(x: 400, y: 700, width: 340, height: 32)
  private let expanded = CGRect(x: 190, y: 372, width: 760, height: 360)

  private func fixture(header: IslandStatusHeader? = nil)
    -> (TransitionTestWindow, IslandTransitionView, TransitionTestContent) {
    let window = TransitionTestWindow(
      contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = TransitionTestContent()
    let transition = IslandTransitionView(content: content, statusHeader: header)
    window.contentView = transition
    transition.transition(to: collapsed, state: .collapsed, collapsedRadius: 18, animated: false)
    window.orderFrontRegardless()
    content.layoutSubtreeIfNeeded()
    window.frameWrites = 0
    return (window, transition, content)
  }

  func testEyeUnfoldsLeftWithoutReservedSpaceOrResizingNeighbours() async throws {
    let awake = NSView(), store = NSView(), weather = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: NSView(), weather: weather,
      keepAwake: awake, store: store, barHeight: 32)
    header.setHeaderOrder(["quota", "additionalQuotas", "spacer", "store", "keepAwake", "weather", "bot"])
    let (window, transition, _) = fixture(header: header)
    defer { window.close() }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: false)
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(awake.frame.width, 26)
    XCTAssertEqual(awake.frame.minX - store.frame.maxX, 4)
    let eyeRight = awake.frame.maxX
    let oldStore = store.frame
    let oldWeather = weather.frame
    header.setKeepAwakeEditing(true)
    XCTAssertEqual(awake.frame.width, 186)
    XCTAssertEqual(weather.frame, oldWeather, "Weather must retain its content and size")
    XCTAssertEqual(store.frame.width, oldStore.width)
    XCTAssertLessThan(store.frame.minX, oldStore.minX - 150)
    var positions: [CGFloat] = []
    for _ in 0..<26 {
      try await Task.sleep(for: .milliseconds(16))
      let visibleStore = store.layer?.presentation()?.frame ?? store.frame
      let visibleEye = awake.layer?.presentation()?.frame ?? awake.frame
      positions.append(visibleStore.minX)
      XCTAssertEqual(visibleStore.width, oldStore.width, accuracy: 0.1)
      XCTAssertEqual(visibleEye.maxX, eyeRight, accuracy: 2.1, "Eye stays anchored while its controls unfold left")
    }
    XCTAssertTrue(positions.contains { $0 < oldStore.minX - 1 && $0 > store.frame.minX + 1 })
    header.setKeepAwakeEditing(false)
    try await Task.sleep(for: .milliseconds(430))
    XCTAssertEqual(awake.frame.width, 26)
    XCTAssertEqual(store.frame, oldStore)
    for (phase, width): (KeepAwakePhase, CGFloat) in [(.active, 100), (.stopping, 78),
      (.starting, 48), (.recoveryRequired, 44), (.idle, 26)] {
      header.setKeepAwakePhase(phase)
      XCTAssertEqual(awake.frame.width, width)
      XCTAssertEqual(weather.frame, oldWeather)
    }
  }

  func testHeaderDragReordersAcrossSidesAndCommitsOnlyOnDrop() async throws {
    let bot = NSView(), store = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: bot, additionalQuotas: NSView(),
      weather: NSView(), keepAwake: NSView(), store: store, barHeight: 32)
    let (window, transition, _) = fixture(header: header)
    defer { window.close() }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: false)
    try await Task.sleep(for: .milliseconds(40))
    var saved: [[String]] = []
    header.onOrderChanged = { saved.append($0) }
    header.beginDragging("bot", at: CGPoint(x: bot.frame.midX, y: 16))
    header.updateDragging(to: CGPoint(x: 25, y: 16))
    XCTAssertEqual(header.headerOrder.first, "bot")
    XCTAssertTrue(saved.isEmpty)
    XCTAssertEqual(bot.frame.minX, 20, accuracy: 0.5, "Dragged view follows the pointer")
    XCTAssertNotNil(header.quota.layer?.animation(forKey: "headerPosition"), "Neighbours animate out of the way")
    header.finishDragging()
    XCTAssertEqual(saved.count, 1)
    XCTAssertLessThan(bot.frame.maxX, header.quota.frame.minX)
    let committed = header.headerOrder
    header.beginDragging("store", at: CGPoint(x: store.frame.midX, y: 16))
    header.updateDragging(to: CGPoint(x: 25, y: 16))
    header.finishDragging(cancelled: true)
    XCTAssertEqual(header.headerOrder, committed)
    XCTAssertEqual(saved.count, 1, "Cancel must not persist the preview order")
    header.setEnabledItems(["bot", "quota", "keepAwake"], animated: false)
    header.setEnabledItems(ExtensionPreferences.availableStatusItems, animated: false)
    XCTAssertEqual(header.headerOrder, committed)
    XCTAssertLessThan(bot.frame.maxX, header.quota.frame.minX)
    header.settle(size: collapsed.size, state: .collapsed)
    XCTAssertGreaterThan(bot.frame.minX, header.quota.frame.maxX, "Collapsed bar retains its compact layout")
    header.settle(size: expanded.size, state: .pinned)
    XCTAssertLessThan(bot.frame.maxX, header.quota.frame.minX)
  }

  func testDisabledHeaderItemsReleaseSpaceAndAnimateRightward() async throws {
    let weather = NSView(), awake = NSView(), store = NSView(), extras = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: NSView(), additionalQuotas: extras,
      weather: weather, keepAwake: awake, store: store, barHeight: 32)
    let (window, transition, _) = fixture(header: header)
    defer { window.close() }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: false)
    try await Task.sleep(for: .milliseconds(40))
    let initial = awake.frame.minX
    let releasedWidth = weather.frame.width + 6
    header.setEnabledItems(["quota", "additionalQuotas", "bot", "keepAwake"])
    XCTAssertTrue(weather.isHidden)
    XCTAssertEqual(awake.frame.minX, initial + releasedWidth, accuracy: 0.5)
    XCTAssertEqual(store.frame.minX - awake.frame.maxX, 6, accuracy: 0.5)
    var positions: [CGFloat] = []
    for _ in 0..<24 {
      try await Task.sleep(for: .milliseconds(16))
      positions.append(awake.layer?.presentation()?.frame.minX ?? awake.frame.minX)
    }
    XCTAssertTrue(positions.contains { $0 > initial + 1 && $0 < awake.frame.minX - 1 },
      "The eye must visibly move through intermediate positions toward the store")
    XCTAssertEqual(try XCTUnwrap(positions.last), awake.frame.minX, accuracy: 0.5)
    // Immediate layout is also the reduced-motion path.
    header.setEnabledItems(["additionalQuotas", "bot"], animated: false)
    XCTAssertTrue(header.quota.isHidden)
    XCTAssertTrue(awake.isHidden)
    XCTAssertEqual(extras.frame.minX, header.quota.frame.minX, accuracy: 0.5)
    XCTAssertNil(awake.layer?.animation(forKey: "headerPosition"))
    header.setEnabledItems(ExtensionPreferences.availableStatusItems, animated: false)
    XCTAssertFalse(weather.isHidden)
    XCTAssertFalse(awake.isHidden)
    XCTAssertEqual(awake.frame.minX, initial, accuracy: 0.5)
  }

  func testHeaderRelayoutReversalStartsAtVisiblePosition() async throws {
    let awake = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: NSView(), weather: NSView(),
      keepAwake: awake, store: NSView(), barHeight: 32)
    let (window, transition, _) = fixture(header: header)
    defer { window.close() }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: false)
    try await Task.sleep(for: .milliseconds(40))
    header.setEnabledItems(["bot", "keepAwake"])
    try await Task.sleep(for: .milliseconds(80))
    let visible = try XCTUnwrap(awake.layer?.presentation()?.position)
    header.setEnabledItems(ExtensionPreferences.availableStatusItems)
    let animation = try XCTUnwrap(awake.layer?.animation(forKey: "headerPosition") as? CASpringAnimation)
    let origin = try XCTUnwrap(animation.fromValue as? NSValue).pointValue
    XCTAssertEqual(origin.x, visible.x, accuracy: 1)
  }

  func testStatusItemsStayLiveAndTravelWithTheOpeningSilhouette() async throws {
    let quota = NSView()
    let bot = NSView()
    let header = IslandStatusHeader(quota: quota, bot: bot, barHeight: collapsed.height)
    let (window, transition, _) = fixture(header: header)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(30))
    let initial = header.presentedItemFrames.map { $0.midX - header.bounds.midX }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    var leftOffsets: [CGFloat] = []
    var rightOffsets: [CGFloat] = []
    for _ in 0..<24 {
      try await Task.sleep(for: .milliseconds(16))
      let frames = header.presentedItemFrames
      leftOffsets.append(frames[0].midX - header.bounds.midX)
      rightOffsets.append(frames[1].midX - header.bounds.midX)
      for item in [quota, bot] {
        XCTAssertEqual(item.layer?.presentation()?.opacity ?? item.layer?.opacity, 1)
        XCTAssertTrue(item.superview === header, "Keep the same views and their animation state")
      }
      let surface = try XCTUnwrap(transition.presentedSurfaceBounds)
      XCTAssertGreaterThanOrEqual(frames[0].minX, surface.minX)
      XCTAssertLessThanOrEqual(frames[1].maxX, surface.maxX)
      XCTAssertEqual(frames[0].height, collapsed.height)
      XCTAssertEqual(frames[1].height, collapsed.height)
    }
    XCTAssertLessThan(try XCTUnwrap(leftOffsets.last), initial[0] - 100)
    XCTAssertGreaterThan(try XCTUnwrap(rightOffsets.last), initial[1] + 100)
    XCTAssertTrue(leftOffsets.contains { $0 < initial[0] - 20 && $0 > initial[0] - 140 },
      "The quota must travel through intermediate positions, not jump")
    XCTAssertTrue(rightOffsets.contains { $0 > initial[1] + 20 && $0 < initial[1] + 140 })
    // Reverse before the opening completes: preserve live items on the way back.
    transition.transition(to: collapsed, state: .collapsed, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .seconds(1.2))
    XCTAssertFalse(transition.isRunning)
    for (frame, original) in zip(header.presentedItemFrames, initial) {
      XCTAssertEqual(frame.midX - header.bounds.midX, original, accuracy: 0.5)
    }
    XCTAssertEqual(header.subviews.count, 2, "No duplicate status items after reversing")
    XCTAssertNil(header.hitTest(CGPoint(x: 20, y: 16)), "Surface clicks pass through the header")
  }

  func testAdditionalQuotasRevealOnlyAfterOpeningAndHideOnReversal() async throws {
    let extras = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: NSView(),
      additionalQuotas: extras, barHeight: collapsed.height)
    let (window, transition, _) = fixture(header: header)
    defer { window.close() }
    XCTAssertEqual(extras.layer?.opacity, 0)
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(extras.layer?.presentation()?.opacity ?? extras.layer?.opacity, 0,
      "Extra vendors must not flash over the notch at the start of opening")
    try await Task.sleep(for: .milliseconds(230))
    let partial = try XCTUnwrap(extras.layer?.presentation()?.opacity)
    XCTAssertGreaterThan(partial, 0)
    XCTAssertLessThan(partial, 1, "Reveal gradually instead of inserting fully opaque chips")
    transition.transition(to: collapsed, state: .collapsed, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .milliseconds(160))
    XCTAssertEqual(extras.layer?.presentation()?.opacity ?? extras.layer?.opacity, 0)
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    try await Task.sleep(for: .seconds(1.2))
    XCTAssertEqual(extras.layer?.opacity, 1)
    XCTAssertEqual(extras.frame.minX - header.quota.frame.minX, 72, accuracy: 0.5)
    XCTAssertLessThanOrEqual(extras.frame.maxX, expanded.width / 2 - 90,
      "Keep all vendor chips in the left wing, clear of the physical notch")
    XCTAssertTrue(extras.superview === header)
  }

  func testOpeningUnfoldsFromCenterBeforeSettling() async throws {
    let (window, transition, _) = fixture()
    defer { window.close() }
    transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
    var samples: [(Double, CGFloat, Float)] = []
    let start = CACurrentMediaTime()
    for _ in 0..<14 {
      try await Task.sleep(for: .seconds(0.05 / 1.3))
      let bounds = try XCTUnwrap(transition.presentedSurfaceBounds)
      let progress = (bounds.width - collapsed.width) / (expanded.width - collapsed.width)
      samples.append((CACurrentMediaTime() - start, progress, transition.presentedContentOpacity))
      if transition.isRunning {
        XCTAssertEqual(bounds.midX, transition.bounds.midX, accuracy: 0.5,
          "Both edges must travel symmetrically away from the center")
      }
    }
    print("Opening time / width progress / content opacity: \(samples)")
    let early = try XCTUnwrap(samples.first { $0.0 >= 0.09 / 1.3 })
    XCTAssertLessThan(early.2, 0.15, "The shape should open before the content appears")
    let revealed = try XCTUnwrap(samples.first { $0.0 >= 0.45 / 1.3 })
    XCTAssertGreaterThan(revealed.2, 0.95, "Content must be ready before the spring settles")
    let midOpening = try XCTUnwrap(samples.first { $0.0 >= 0.23 / 1.3 })
    XCTAssertLessThan(midOpening.1, 0.85,
      "The 1.3x opening should retain its unfolding phase near 190ms")
    XCTAssertGreaterThan(midOpening.1, 0.35, "Respond promptly without an artificial wait")
    XCTAssertLessThanOrEqual(samples.map(\.1).max() ?? 0, 1.035,
      "A content panel should settle with restrained overshoot")
    try await Task.sleep(for: .milliseconds(700))
    XCTAssertFalse(transition.isRunning)
    XCTAssertEqual(window.frame, expanded)
  }

  func testOpeningMaskNeverFlashesDestinationBeforeSpringStarts() async throws {
    for _ in 0..<12 {
      let (window, transition, _) = fixture()
      defer { window.close() }
      try await Task.sleep(for: .milliseconds(20))
      transition.transition(to: expanded, state: .pinned, collapsedRadius: 18, animated: true)
      var previousWidth = collapsed.width
      var largestRetraction: CGFloat = 0
      for _ in 0..<20 {
        try await Task.sleep(for: .milliseconds(8))
        guard transition.layer?.mask != nil,
          let width = transition.presentedSurfaceBounds?.width else { continue }
        largestRetraction = max(largestRetraction, previousWidth - width)
        previousWidth = width
      }
      XCTAssertLessThanOrEqual(largestRetraction, 1,
        "The opening mask must not show its final width before the spring's first frame")
    }
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
