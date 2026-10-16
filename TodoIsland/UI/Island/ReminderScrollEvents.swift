import AppKit
import SwiftUI

/// Keeps precise gestures in AppKit; only discrete wheel ticks need easing.
struct ReminderScrollEvents: NSViewRepresentable {
  let isActive: Bool
  let reduceMotion: Bool
  let selectionRequest: UUID

  func makeNSView(context: Context) -> ReminderScrollEventView { ReminderScrollEventView() }

  func updateNSView(_ view: ReminderScrollEventView, context: Context) {
    view.configure(isActive: isActive, reduceMotion: reduceMotion, selectionRequest: selectionRequest)
  }

  static func dismantleNSView(_ view: ReminderScrollEventView, coordinator: ()) {
    view.removeMonitor()
  }
}

final class ReminderScrollEventView: NSView {
  private var monitor: Any?
  private var frameLink: CADisplayLink?
  private var active = false
  private var reducedMotion = false
  private var selectionRequest: UUID?
  private var targetY: CGFloat = 0
  private var positionY: CGFloat = 0
  private var velocity: CGFloat = 0
  private var lastTime: CFTimeInterval = 0
  private var lastAppliedY: CGFloat = 0

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func configure(isActive: Bool, reduceMotion: Bool, selectionRequest: UUID) {
    if !isActive || reduceMotion || self.selectionRequest != selectionRequest { stopAnimation() }
    active = isActive
    reducedMotion = reduceMotion
    self.selectionRequest = selectionRequest
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeMonitor()
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) {
      [weak self] event in
      guard let self else { return event }
      if event.type != .scrollWheel {
        if event.window === self.window { self.stopAnimation() }
        return event
      }
      return self.route(event)
    }
  }

  func route(_ event: NSEvent) -> NSEvent? {
    guard active, let window, event.window === window, !isHiddenOrHasHiddenAncestor,
      bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil)),
      let scroll = enclosingScrollView
    else { return event }

    // Forward every phase, including zero-delta end and momentum events.
    // A physical gesture immediately takes over from a wheel animation.
    guard !event.hasPreciseScrollingDeltas, !reducedMotion else {
      stopAnimation()
      return event
    }
    guard event.scrollingDeltaY != 0,
      abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
    else { return event }

    let clip = scroll.contentView
    let current = clip.bounds.origin.y
    if frameLink == nil || abs(current - lastAppliedY) > 1 {
      stopAnimation()
      positionY = current
      targetY = current
      lastAppliedY = current
    }
    let delta = -event.scrollingDeltaY * max(1, scroll.verticalLineScroll)
    targetY = constrainedY(targetY + delta, in: clip)
    // Brake immediately when the wheel reverses rather than drifting away.
    if delta * velocity < 0 { velocity = 0 }
    guard abs(targetY - current) > 0.1 else { return nil }
    if frameLink == nil {
      lastTime = CACurrentMediaTime()
      let link = displayLink(target: self, selector: #selector(advanceAnimation(_:)))
      frameLink = link
      link.add(to: .main, forMode: .common)
    }
    return nil
  }

  @objc private func advanceAnimation(_ link: CADisplayLink) {
    guard active, window != nil, !isHiddenOrHasHiddenAncestor,
      let scroll = enclosingScrollView
    else { stopAnimation(); return }
    let clip = scroll.contentView
    // Keyboard navigation, date changes and layout own their new position.
    guard abs(clip.bounds.origin.y - lastAppliedY) <= 1 else { stopAnimation(); return }
    let now = CACurrentMediaTime()
    let dt = min(now - lastTime, 0.05)
    lastTime = now
    targetY = constrainedY(targetY, in: clip)
    // Exact critically damped spring: continuous velocity between ticks,
    // no overshoot at the ends, independent of display refresh rate.
    let omega: CGFloat = 26
    let displacement = positionY - targetY
    let coefficient = velocity + omega * displacement
    let decay = exp(-omega * dt)
    positionY = targetY + (displacement + coefficient * dt) * decay
    velocity = (velocity - omega * coefficient * dt) * decay
    let settled = abs(positionY - targetY) < 0.1 && abs(velocity) < 2
    let y = constrainedY(settled ? targetY : positionY, in: clip)
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
    scroll.reflectScrolledClipView(clip)
    lastAppliedY = clip.bounds.origin.y
    if settled { stopAnimation() }
  }

  private func constrainedY(_ y: CGFloat, in clip: NSClipView) -> CGFloat {
    var proposed = clip.bounds
    proposed.origin.y = y
    return clip.constrainBoundsRect(proposed).origin.y
  }

  private func stopAnimation() {
    frameLink?.invalidate()
    frameLink = nil
    velocity = 0
  }

  func removeMonitor() {
    stopAnimation()
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
}
