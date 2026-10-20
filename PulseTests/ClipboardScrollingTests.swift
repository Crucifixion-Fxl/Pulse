import AppKit
import SwiftUI
import XCTest
@testable import Pulse

@MainActor
final class ClipboardScrollingTests: XCTestCase {
  func testPreciseSwipesReachNativeScrollingUnchanged() {
    let (window, view) = makeRailRegion()
    defer { window.close() }
    var steps: [Int] = []
    view.step = { steps.append($0) }
    // Small diagonal jitter used to override X. Exact multiples of 36
    // reversed direction; these inputs must now reach AppKit unchanged.
    let samples: [(CGFloat, CGFloat, NSEvent.Phase, NSEvent.Phase)] = [
      (-12.0, 0.3, NSEvent.Phase.began, []),
      (-12.0, 0.3, .changed, []),
      (-12.0, 0.3, .ended, []),
      (-36.0, 0.0, [], .began),
      (-8.0, 0.1, [], .changed),
      (0.0, 0.0, [], .ended),
      (36.0, 0.2, .began, []),
      (0.0, -20.0, .changed, []),
      (0.0, 0.0, .cancelled, []),
    ]
    for (x, y, phase, momentum) in samples {
      let event = ScrollSample(window: window, x: x, y: y, precise: true,
        phase: phase, momentum: momentum)
      XCTAssertTrue(view.route(event) === event)
    }
    XCTAssertTrue(steps.isEmpty, "Trackpad input must never trigger discrete paging")
  }

  func testWheelPagesBothDirectionsAndConsumesOnlyInsideRail() {
    let (window, view) = makeRailRegion()
    defer { window.close() }
    var steps: [Int] = []
    view.step = { steps.append($0) }
    for (x, y) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.01), (1.0, -0.01)] {
      XCTAssertNil(view.route(ScrollSample(window: window, x: x, y: y)))
    }
    XCTAssertEqual(steps, [1, -1, 1, -1])
    let outsidePoint = view.convert(NSPoint(x: view.bounds.maxX + 20, y: 20), to: nil)
    let outside = ScrollSample(window: window, y: -1, location: outsidePoint)
    XCTAssertTrue(view.route(outside) === outside)
    let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    let otherWindow = ScrollSample(window: other, y: -1)
    XCTAssertTrue(view.route(otherWindow) === otherWindow)
    view.isHidden = true
    let hidden = ScrollSample(window: window, y: -1)
    XCTAssertTrue(view.route(hidden) === hidden)
    XCTAssertEqual(steps.count, 4)
  }

  func testRailHostsNativeHorizontalScrollViewWithOverflow() async throws {
    let ids = (0..<7).map { _ in UUID() }
    let host = NSHostingView(rootView: ClipboardScrollFixture(ids: ids))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 684, height: 252),
      styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
    let scroll = try XCTUnwrap(scrollViews(host).first)
    let document = try XCTUnwrap(scroll.documentView)
    XCTAssertGreaterThan(document.bounds.width, scroll.contentView.bounds.width + 900)
    // Pixel positions, including sub-card motion, must be representable.
    // The previous offset-only rail had no native scroll view at all.
    scroll.contentView.scroll(to: NSPoint(x: 36, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    XCTAssertEqual(scroll.contentView.bounds.origin.x, 36, accuracy: 0.5)
    scroll.contentView.scroll(to: .zero)
    XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 0.5)

    // Deliver the precise event to the real native responder, not a
    // calculation of the desired offset. No system input is posted.
    func swipe(_ delta: CGFloat) async throws {
      scroll.scrollWheel(with: ScrollSample(window: window, precise: true, phase: .began))
      for _ in 0..<4 {
        scroll.scrollWheel(with: ScrollSample(window: window, x: delta, y: 0.3,
          precise: true, phase: .changed))
        try await Task.sleep(for: .milliseconds(16))
      }
      scroll.scrollWheel(with: ScrollSample(window: window, precise: true, phase: .ended))
      try await Task.sleep(for: .milliseconds(500))
    }
    try await swipe(-60)
    XCTAssertGreaterThan(scroll.contentView.bounds.origin.x, 100)
    try await swipe(60)
    XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 1)

    let textScroll = try XCTUnwrap(scrollViews(host).first { $0 !== scroll })
    func wheelRegions(_ view: NSView) -> [ClipboardScrollEventView] {
      ((view as? ClipboardScrollEventView).map { [$0] } ?? [])
        + view.subviews.flatMap(wheelRegions)
    }
    let region = try XCTUnwrap(wheelRegions(host).first)
    XCTAssertTrue(region.enclosingScrollView === scroll)
    func deliver(_ event: NSEvent) {
      if let forwarded = region.route(event) { textScroll.scrollWheel(with: forwarded) }
    }
    deliver(ScrollSample(window: window, precise: true, phase: .began))
    for _ in 0..<4 {
      XCTAssertNil(region.route(ScrollSample(window: window, x: -60, y: 0.3,
        precise: true, phase: .changed)))
      try await Task.sleep(for: .milliseconds(16))
    }
    deliver(ScrollSample(window: window, precise: true, phase: .ended))
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertGreaterThan(scroll.contentView.bounds.origin.x, 100,
      "Horizontal swipes over a long-text card must reach the outer rail")

    let horizontalPosition = scroll.contentView.bounds.origin.x
    deliver(ScrollSample(window: window, y: -100, precise: true))
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertGreaterThan(textScroll.contentView.bounds.origin.y, 50)
    XCTAssertEqual(scroll.contentView.bounds.origin.x, horizontalPosition, accuracy: 1,
      "Reading long text vertically must not page the rail")

    // A new horizontal gesture must reset the preceding vertical axis.
    deliver(ScrollSample(window: window, x: 1, y: 0.3, precise: true, phase: .began))
    for _ in 0..<4 {
      deliver(ScrollSample(window: window, x: 60, y: 0.3, precise: true, phase: .changed))
      try await Task.sleep(for: .milliseconds(16))
    }
    deliver(ScrollSample(window: window, precise: true, phase: .ended))
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 1)

    XCTAssertNil(region.route(ScrollSample(window: window, y: -1)))
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(scroll.contentView.bounds.origin.x, 232, accuracy: 1,
      "A mouse-wheel tick must advance exactly one card")
    XCTAssertNil(region.route(ScrollSample(window: window, y: 1)))
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 1)
  }

  private func makeRailRegion() -> (NSWindow, ClipboardScrollEventView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
      styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = ClipboardScrollEventView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    window.contentView?.addSubview(view)
    return (window, view)
  }
}

private struct ClipboardScrollFixture: View {
  let ids: [UUID]
  @State private var position: UUID?

  var body: some View {
    ClipboardCardRail(itemIDs: ids, leadingItemID: $position) {
      HStack(spacing: 12) {
        ForEach(ids, id: \.self) { _ in
          ClipboardTextPreview(text: (1...20).map { "Paragraph \($0): sample text" }
            .joined(separator: "\n"))
            .frame(width: 220, height: 252)
        }
      }.scrollTargetLayout()
    }.frame(width: 684, height: 252)
  }
}

/// Event samples at the responder seam, never posted as system input.
private final class ScrollSample: NSEvent {
  private let targetWindow: NSWindow
  private let x: CGFloat
  private let y: CGFloat
  private let precise: Bool
  private let samplePhase: NSEvent.Phase
  private let momentum: NSEvent.Phase
  private let location: NSPoint

  init(window: NSWindow, x: CGFloat = 0, y: CGFloat = 0, precise: Bool = false,
    phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [],
    location: NSPoint = NSPoint(x: 20, y: 20)) {
    targetWindow = window
    self.x = x
    self.y = y
    self.precise = precise
    samplePhase = phase
    self.momentum = momentum
    self.location = location
    super.init()
  }

  required init?(coder: NSCoder) { fatalError("Not used") }
  override var type: NSEvent.EventType { .scrollWheel }
  override var window: NSWindow? { targetWindow }
  override var locationInWindow: NSPoint { location }
  override var scrollingDeltaX: CGFloat { x }
  override var scrollingDeltaY: CGFloat { y }
  override var hasPreciseScrollingDeltas: Bool { precise }
  override var phase: NSEvent.Phase { samplePhase }
  override var momentumPhase: NSEvent.Phase { momentum }
}
