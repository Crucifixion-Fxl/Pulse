import AppKit
import SwiftUI
import XCTest
@testable import Pulse

@MainActor
final class ReminderScrollingTests: XCTestCase {
  func testWheelEasesContinuouslyReversesAndClampsAtEdges() async throws {
    let (window, region, scroll) = try await fixture()
    defer { window.close() }
    let clip = scroll.contentView
    func wheel(_ y: CGFloat) -> NSEvent {
      ReminderWheelSample(window: window, y: y, location: region.convert(NSPoint(x: region.visibleRect.midX, y: region.visibleRect.midY), to: nil))
    }
    XCTAssertNil(region.route(wheel(-12)))
    XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.1, "A wheel tick must not jump to its destination")
    try await Task.sleep(for: .milliseconds(60))
    let first = clip.bounds.origin.y
    XCTAssertGreaterThan(first, 0)
    let destination = 12 * max(1, scroll.verticalLineScroll)
    XCTAssertLessThan(first, destination)
    XCTAssertNil(region.route(wheel(-12)))
    XCTAssertEqual(clip.bounds.origin.y, first, accuracy: 0.1, "Retarget without jumping")
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertGreaterThan(clip.bounds.origin.y, first)
    XCTAssertNil(region.route(wheel(30)))
    let reverseStart = clip.bounds.origin.y
    try await Task.sleep(for: .milliseconds(60))
    XCTAssertLessThan(clip.bounds.origin.y, reverseStart)
    try await Task.sleep(for: .milliseconds(600))
    XCTAssertEqual(clip.bounds.origin.y, 0, accuracy: 0.5)
    XCTAssertNil(region.route(wheel(-10000)))
    try await Task.sleep(for: .milliseconds(800))
    let maxY = clip.constrainBoundsRect(NSRect(x: 0, y: 100000, width: clip.bounds.width, height: clip.bounds.height)).origin.y
    XCTAssertEqual(clip.bounds.origin.y, maxY, accuracy: 0.5)
    XCTAssertNil(region.route(wheel(-10)))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(clip.bounds.origin.y, maxY, accuracy: 0.5)
  }

  func testTrackpadAndMomentumStayNativeAndInterruptWheel() async throws {
    let (window, region, scroll) = try await fixture()
    defer { window.close() }
    func event(_ y: CGFloat, precise: Bool = true, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) -> NSEvent {
      ReminderWheelSample(window: window, y: y, precise: precise, phase: phase, momentum: momentum,
        location: region.convert(NSPoint(x: region.visibleRect.midX, y: region.visibleRect.midY), to: nil))
    }
    XCTAssertNil(region.route(event(-12, precise: false)))
    try await Task.sleep(for: .milliseconds(40))
    let takeover = event(0, phase: .began)
    XCTAssertTrue(region.route(takeover) === takeover)
    let stopped = scroll.contentView.bounds.origin.y
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(scroll.contentView.bounds.origin.y, stopped, accuracy: 0.1)
    scroll.scrollWheel(with: takeover)
    for (y, phase, momentum) in [
      (-25.0, NSEvent.Phase.changed, NSEvent.Phase()),
      (-25.0, .changed, []), (0.0, .ended, []),
      (-15.0, [], .began), (-5.0, [], .changed), (0.0, [], .ended)
    ] {
      let sample = event(y, phase: phase, momentum: momentum)
      XCTAssertTrue(region.route(sample) === sample)
      scroll.scrollWheel(with: sample)
      try await Task.sleep(for: .milliseconds(16))
    }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, stopped + 30)
  }

  func testInactiveOutsideAndReducedMotionLeaveEventsUntouched() async throws {
    let (window, region, scroll) = try await fixture()
    defer { window.close() }
    let request = UUID()
    let inside = ReminderWheelSample(window: window, y: -10,
      location: region.convert(NSPoint(x: region.visibleRect.midX, y: region.visibleRect.midY), to: nil))
    let outside = ReminderWheelSample(window: window, y: -10, location: NSPoint(x: -20, y: -20))
    XCTAssertTrue(region.route(outside) === outside)
    region.configure(isActive: false, reduceMotion: false, selectionRequest: request)
    XCTAssertTrue(region.route(inside) === inside)
    region.configure(isActive: true, reduceMotion: true, selectionRequest: request)
    XCTAssertTrue(region.route(inside) === inside)
    region.configure(isActive: true, reduceMotion: false, selectionRequest: request)
    XCTAssertNil(region.route(inside))
    try await Task.sleep(for: .milliseconds(40))
    region.configure(isActive: true, reduceMotion: false, selectionRequest: UUID())
    let stopped = scroll.contentView.bounds.origin.y
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(scroll.contentView.bounds.origin.y, stopped, accuracy: 0.1)
  }

  private func fixture() async throws -> (NSWindow, ReminderScrollEventView, NSScrollView) {
    let host = NSHostingView(rootView: ReminderScrollFixture())
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 240),
      styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(120))
    host.layoutSubtreeIfNeeded()
    func regions(_ view: NSView) -> [ReminderScrollEventView] {
      ((view as? ReminderScrollEventView).map { [$0] } ?? []) + view.subviews.flatMap(regions)
    }
    let region = try XCTUnwrap(regions(host).first)
    let scroll = try XCTUnwrap(region.enclosingScrollView)
    XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, 1000)
    return (window, region, scroll)
  }
}

private struct ReminderScrollFixture: View {
  private let request = UUID()
  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVStack(spacing: 0) {
        ForEach(0..<40) { i in Text("Reminder \(i)").frame(maxWidth: .infinity).frame(height: 38) }
      }.background(ReminderScrollEvents(isActive: true, reduceMotion: false, selectionRequest: request))
    }.scrollBounceBehavior(.basedOnSize)
  }
}
/// Event samples at the responder seam, never posted as system input.
private final class ReminderWheelSample: NSEvent {
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
