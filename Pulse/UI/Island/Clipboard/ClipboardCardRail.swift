import AppKit
import SwiftUI

/// Native scrolling owns trackpad direction, gesture phases and momentum.
/// Only notched wheels need translating from vertical ticks to card steps.
struct ClipboardCardRail<Content: View>: View {
  let itemIDs: [UUID]
  @Binding var leadingItemID: UUID?
  @ViewBuilder var content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      content()
        .background(ClipboardScrollEvents(step: stepPage))
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollPosition(id: $leadingItemID, anchor: .leading)
    .scrollBounceBehavior(.basedOnSize)
  }

  private func stepPage(_ direction: Int) {
    guard !itemIDs.isEmpty else { return }
    let current = itemIDs.firstIndex { $0 == leadingItemID } ?? 0
    let target = min(max(current + direction, 0), max(0, itemIDs.count - 3))
    withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.9)) {
      leadingItemID = itemIDs[target]
    }
  }
}

private struct ClipboardScrollEvents: NSViewRepresentable {
  var step: (Int) -> Void

  func makeNSView(context: Context) -> ClipboardScrollEventView {
    let view = ClipboardScrollEventView()
    view.step = step
    return view
  }

  func updateNSView(_ view: ClipboardScrollEventView, context: Context) {
    view.step = step
  }

  static func dismantleNSView(_ view: ClipboardScrollEventView, coordinator: ()) {
    view.removeMonitor()
  }
}

final class ClipboardScrollEventView: NSView {
  var step: (Int) -> Void = { _ in }
  private var monitor: Any?
  private var horizontalGesture: Bool?

  // This view observes wheel ticks without covering card buttons or text.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeMonitor()
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      guard let self else { return event }
      return self.route(event)
    }
  }

  func route(_ event: NSEvent) -> NSEvent? {
    guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
      bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
    else { return event }

    if event.hasPreciseScrollingDeltas {
      if event.phase.contains(.began) || event.phase.contains(.mayBegin)
        || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
        horizontalGesture = nil
      }
      if horizontalGesture == nil,
        event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
        horizontalGesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
      }
      defer {
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended) {
          horizontalGesture = nil
        }
      }
      // Nested SwiftUI text scroll views swallow horizontal events. Route
      // the original gesture (including zero-delta end and momentum events)
      // to the enclosing horizontal NSScrollView; never quantize its deltas.
      if horizontalGesture == true, let scrollView = enclosingScrollView {
        scrollView.scrollWheel(with: event)
        return nil
      }
      return event
    }

    let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
      ? event.scrollingDeltaX : event.scrollingDeltaY
    guard delta != 0 else { return event }
    step(delta < 0 ? 1 : -1)
    // Consume the tick so the inner text preview doesn't also scroll.
    return nil
  }

  func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    horizontalGesture = nil
  }
}
