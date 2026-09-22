import AppKit
import QuartzCore

/// Drives the panel frame with a damped spring so the surface can overshoot
/// and wobble as it changes size, which a cubic AppKit easing cannot express.
/// The top edge and horizontal center stay pinned to the target frame; only
/// width and height are simulated.
@MainActor
final class IslandFrameSpring {
  private let proxy = IslandFrameSpringProxy()
  private var displayLink: CADisplayLink?
  private var width: CGFloat = 0
  private var height: CGFloat = 0
  private var widthVelocity: CGFloat = 0
  private var heightVelocity: CGFloat = 0
  private var target: CGRect = .zero
  private var omega: CGFloat = 0
  private var damping: CGFloat = 0
  private var lastTimestamp: CFTimeInterval = 0
  private var onFrame: ((CGRect) -> Void)?

  var isRunning: Bool { displayLink != nil }

  isolated deinit {
    displayLink?.invalidate()
    proxy.spring = nil
  }

  /// Cancels any running transition and marks the spring settled at `frame`.
  func settle(at frame: CGRect) {
    stop()
    target = frame
    width = frame.width
    height = frame.height
    widthVelocity = 0
    heightVelocity = 0
  }

  /// Springs the panel frame toward `newTarget`, starting from the current
  /// simulated size so an interrupted transition keeps its momentum. The
  /// display link comes from the window itself so it follows screen changes.
  func animate(
    on window: NSWindow,
    from current: CGRect,
    to newTarget: CGRect,
    response: Double,
    dampingFraction: Double,
    onFrame: @escaping (CGRect) -> Void
  ) {
    if !isRunning || width == 0 || height == 0 {
      width = current.width
      height = current.height
      widthVelocity = 0
      heightVelocity = 0
    }
    target = newTarget
    omega = 2 * .pi / max(0.01, response)
    damping = dampingFraction
    self.onFrame = onFrame
    if displayLink == nil {
      lastTimestamp = 0
      proxy.spring = self
      let link = window.displayLink(
        target: proxy,
        selector: #selector(IslandFrameSpringProxy.tick(_:))
      )
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
  }

  private func stop() {
    displayLink?.invalidate()
    displayLink = nil
    proxy.spring = nil
    onFrame = nil
    lastTimestamp = 0
  }

  /// Called by the display-link proxy on the main thread; internal only so
  /// the same-file proxy can reach it.
  func step(_ timestamp: CFTimeInterval) {
    guard let onFrame else { return }
    if lastTimestamp == 0 { lastTimestamp = timestamp }
    // Cap the effective rate at 60 fps: resizing the panel relayouts the
    // hosting view on the main thread, and 120 Hz doubles that cost without a
    // visible difference at this motion speed. Skipped ticks accumulate into
    // the next dt.
    if timestamp - lastTimestamp < 1 / 75 { return }
    let dt = min(1 / 30, max(0, timestamp - lastTimestamp))
    lastTimestamp = timestamp

    advance(&width, &widthVelocity, toward: target.width, dt: dt)
    advance(&height, &heightVelocity, toward: target.height, dt: dt)

    if isSettled(width, widthVelocity, target.width) && isSettled(height, heightVelocity, target.height) {
      let handler = onFrame
      stop()
      handler(target)
      return
    }
    onFrame(
      CGRect(
        x: target.midX - width / 2,
        y: target.maxY - height,
        width: width,
        height: height
      )
    )
  }

  private func advance(
    _ value: inout CGFloat,
    _ velocity: inout CGFloat,
    toward targetValue: CGFloat,
    dt: CGFloat
  ) {
    let acceleration = -omega * omega * (value - targetValue) - 2 * damping * omega * velocity
    velocity += acceleration * dt
    value += velocity * dt
  }

  private func isSettled(_ value: CGFloat, _ velocity: CGFloat, _ targetValue: CGFloat) -> Bool {
    abs(value - targetValue) < 0.5 && abs(velocity) < 8
  }
}

/// CADisplayLink retains its target, so an intermediate proxy keeps a weak
/// reference back to the spring. Display links on the main run loop always
/// fire on the main thread.
private final class IslandFrameSpringProxy: NSObject {
  nonisolated(unsafe) weak var spring: IslandFrameSpring?

  @objc func tick(_ link: CADisplayLink) {
    let timestamp = link.timestamp
    let spring = self.spring
    MainActor.assumeIsolated {
      spring?.step(timestamp)
    }
  }
}
