import AppKit
import QuartzCore

/// Lays out the live hierarchy once at its destination size, then animates
/// the outgoing Retina snapshot, live content and silhouette on the compositor. Native
/// controls stay mounted (including their first responder) throughout.
@MainActor
final class IslandTransitionView: NSView {
  let content: NSView
  let statusHeader: IslandStatusHeader?
  private let live = NSView()
  private let overlay = CALayer()
  private let silhouette = CAShapeLayer()
  private var images: [CALayer] = []
  private var generation = 0
  private var targetFrame: CGRect?
  private var targetState: IslandPresentationState = .collapsed
  private var collapsedRadius: CGFloat = 18
  private var isAnimating = false
  private var hasPendingRequest = false
  private var requestGeneration = 0
  var isRunning: Bool { isAnimating || hasPendingRequest }
  var snapshotCount: Int { images.count }
  var presentedContentOpacity: Float {
    live.layer?.presentation()?.opacity ?? live.layer?.opacity ?? 0
  }
  var presentedSurfaceBounds: CGRect? {
    (silhouette.presentation()?.path ?? silhouette.path)?.boundingBoxOfPath
  }

  override var isFlipped: Bool { true }

  init(content: NSView, statusHeader: IslandStatusHeader? = nil) {
    self.content = content
    self.statusHeader = statusHeader
    super.init(frame: .zero)
    wantsLayer = true
    live.wantsLayer = true
    content.wantsLayer = true
    addSubview(live)
    live.addSubview(content)
    silhouette.fillColor = NSColor.black.cgColor
    overlay.isHidden = true
    layer?.addSublayer(overlay)
    if let statusHeader { addSubview(statusHeader) }
  }

  required init?(coder: NSCoder) { nil }

  /// Model publishers deliver in willSet. Defer publisher-driven window/view
  /// mutations until the new state is readable; even setFrame can synchronously
  /// lay out SwiftUI and publish a height back into the model.
  func transition(
    to frame: CGRect, state: IslandPresentationState,
    collapsedRadius: CGFloat, animated: Bool, deferUntilNextRunLoop: Bool = false
  ) {
    requestGeneration += 1
    let request = requestGeneration
    hasPendingRequest = animated || deferUntilNextRunLoop
    if hasPendingRequest {
      DispatchQueue.main.async { [weak self] in
        guard let self, self.requestGeneration == request else { return }
        self.hasPendingRequest = false
        self.beginTransition(
          to: frame, state: state,
          collapsedRadius: collapsedRadius, animated: animated)
      }
    } else {
      beginTransition(to: frame, state: state, collapsedRadius: collapsedRadius, animated: false)
    }
  }

  private func beginTransition(
    to frame: CGRect, state: IslandPresentationState,
    collapsedRadius: CGFloat, animated: Bool
  ) {
    guard let window else { return }
    if targetFrame == frame, (targetState == .collapsed) == (state == .collapsed) {
      if !animated, isRunning || window.frame != frame {
        generation += 1
        finish(frame: frame)
      }
      return  // watchdog polls and preview -> pinned must not restart motion
    }
    generation += 1
    let token = generation
    let previousState = targetState
    let previousSize = content.bounds.size
    targetFrame = frame
    targetState = state
    self.collapsedRadius = collapsedRadius

    guard animated, previousSize.width > 0, previousSize.height > 0 else {
      finish(frame: frame)
      return
    }

    let oldEnvelope = bounds.size
    // Start from the outline actually on screen, including a partially
    // completed close/open, rather than reconstructing a nominal bar.
    let fromPath = silhouette.presentation()?.path ?? silhouette.path
      ?? path(size: previousSize, state: previousState, envelope: oldEnvelope)
    let outgoingOpacity = isRunning ? (live.layer?.presentation()?.opacity ?? 0) : 1
    if outgoingOpacity > 0.001 {
      guard let image = snapshot() else {
        finish(frame: frame)
        return
      }
      guard generation == token else { return }
      let outgoing = imageLayer(image, size: previousSize, envelope: oldEnvelope)
      outgoing.opacity = outgoingOpacity
      images.append(outgoing)
      overlay.addSublayer(outgoing)
    }

    // Freeze in-flight content opacity before retargeting; do not jump to
    // an animation's model endpoint during a quick open/close/open sequence.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    images = images.filter { image in
      let opacity = image.presentation()?.opacity ?? image.opacity
      image.removeAllAnimations()
      image.opacity = opacity
      if opacity <= 0.001 {
        image.removeFromSuperlayer()
        image.contents = nil
        return false
      }
      return true
    }
    silhouette.removeAllAnimations()
    let visibleSize = fromPath.boundingBoxOfPath.size
    // Reserve room for spring overshoot without resizing the NSWindow per frame.
    let extra =
      state == .collapsed
      ? CGSize.zero
      : CGSize(
        width: abs(frame.width - visibleSize.width) * 0.12,
        height: abs(frame.height - visibleSize.height) * 0.12)
    let envelope = CGSize(
      width: max(frame.width, visibleSize.width) + extra.width,
      height: max(frame.height, visibleSize.height) + extra.height)
    let dx = (envelope.width - oldEnvelope.width) / 2
    for image in images { image.position.x += dx }
    var shift = CGAffineTransform(translationX: dx, y: 0)
    let startPath = fromPath.copy(using: &shift)
    statusHeader?.prepare(envelope: envelope, shiftX: dx)
    live.layer?.removeAllAnimations()
    live.layer?.opacity = 0
    layer?.mask = silhouette
    layer?.backgroundColor = NSColor.black.cgColor
    overlay.isHidden = false
    isAnimating = true
    window.setFrame(
      CGRect(
        x: frame.midX - envelope.width / 2,
        y: frame.maxY - envelope.height,
        width: envelope.width, height: envelope.height), display: false)
    placeContent(size: frame.size)
    overlay.frame = bounds
    silhouette.path = startPath
    CATransaction.commit()

    DispatchQueue.main.async { [weak self] in
      guard let self, self.generation == token else { return }
      self.content.layoutSubtreeIfNeeded()
      guard self.generation == token else { return }
      self.animate(from: startPath, frame: frame, state: state, token: token)
    }
  }

  private func animate(
    from: CGPath?, frame: CGRect,
    state: IslandPresentationState, token: Int
  ) {
    let motion = state.motionProfile
    let spring = CASpringAnimation(keyPath: "path")
    let omega = 2 * Double.pi / motion.response
    spring.mass = 1
    spring.stiffness = omega * omega
    spring.damping = 2 * motion.dampingFraction * omega
    spring.fromValue = from
    let endPath = path(size: frame.size, state: state, envelope: bounds.size)
    spring.toValue = endPath
    spring.duration = spring.settlingDuration
    // The model path is already the destination. Hold the starting path
    // until the compositor activates the spring, so its first commit
    // cannot flash the full-width destination and then retract.
    spring.beginTime = silhouette.convertTime(CACurrentMediaTime(), from: nil)
    spring.fillMode = .backwards

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let contentSpeed = state == .collapsed ? 1 : IslandMotionProfile.openingSpeed
    for outgoing in images {
      fade(outgoing, from: outgoing.opacity, to: 0, duration: 0.12 / contentSpeed)
    }
    if let incoming = live.layer {
      // Give the silhouette a head start so text does not appear inside a
      // narrow slit, then reveal the live controls as the shoulders unfold.
      fade(incoming, from: 0, to: 1,
        duration: state == .collapsed ? 0.18 : 0.30 / contentSpeed,
        delay: state == .collapsed ? 0 : 0.10 / contentSpeed)
    }
    silhouette.path = endPath
    silhouette.add(spring, forKey: "islandSilhouette")
    statusHeader?.move(to: frame.size, state: state, spring: spring)
    CATransaction.commit()

    // One completion, not a display-link callback. A stale completion can
    // never collapse a newer transition or reveal an outdated snapshot.
    DispatchQueue.main.asyncAfter(deadline: .now() + spring.duration) { [weak self] in
      guard let self, self.generation == token else { return }
      self.finish(frame: frame)
    }
  }

  private func finish(frame: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    window?.setFrame(frame, display: false)
    placeContent(size: frame.size)
    statusHeader?.settle(size: frame.size, state: targetState)
    live.layer?.removeAllAnimations()
    live.layer?.opacity = 1
    // Keep a single owner of the visible outline between transitions too.
    // SwiftUI can prepare its destination content without changing the
    // currently displayed bar's width, shoulders, or bottom corners.
    silhouette.path = path(size: frame.size, state: targetState, envelope: frame.size)
    layer?.mask = silhouette
    layer?.backgroundColor = NSColor.black.cgColor
    overlay.isHidden = true
    silhouette.removeAllAnimations()
    for image in images {
      image.removeFromSuperlayer()
      image.contents = nil
    }
    images.removeAll()
    isAnimating = false
    CATransaction.commit()
  }

  private func placeContent(size: CGSize) {
    // The root GeometryReader always sees the final content size, even
    // while the transparent panel envelope accommodates the overshoot.
    live.frame = CGRect(
      x: (bounds.width - size.width) / 2, y: 0,
      width: size.width, height: size.height)
    content.frame = CGRect(origin: .zero, size: size)
  }

  private func path(size: CGSize, state: IslandPresentationState, envelope: CGSize) -> CGPath {
    IslandSurfaceShape(
      shoulderInset: state == .collapsed ? 0 : 8,
      topShoulderDepth: state == .collapsed ? 0 : 8,
      bottomRadius: state == .collapsed ? collapsedRadius : 36
    )
    .path(
      in: CGRect(
        x: (envelope.width - size.width) / 2, y: 0,
        width: size.width, height: size.height)
    ).cgPath
  }

  private func snapshot() -> CGImage? {
    // Capture the outgoing layer tree before laying out the incoming state.
    // cacheDisplay would evaluate SwiftUI's new body at the old frame size,
    // both capturing the wrong content and publishing an intermediate height.
    let scale = window?.backingScaleFactor ?? 2
    guard let layer = content.layer,
      let context = CGContext(
        data: nil, width: Int(ceil(content.bounds.width * scale)),
        height: Int(ceil(content.bounds.height * scale)), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    (layer.presentation() ?? layer).render(in: context)
    return context.makeImage()
  }

  private func imageLayer(_ image: CGImage, size: CGSize, envelope: CGSize) -> CALayer {
    let result = CALayer()
    result.contents = image
    result.contentsScale = window?.backingScaleFactor ?? 2
    result.frame = CGRect(
      x: (envelope.width - size.width) / 2, y: 0,
      width: size.width, height: size.height)
    return result
  }

  private func fade(
    _ layer: CALayer, from: Float, to: Float, duration: Double, delay: Double = 0
  ) {
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    animation.toValue = to
    animation.duration = duration
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
    animation.fillMode = .backwards
    layer.opacity = to
    layer.add(animation, forKey: "contentFade")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    if isRunning, let path = silhouette.presentation()?.path ?? silhouette.path,
      !path.contains(convert(point, from: superview))
    {
      return nil
    }
    return super.hitTest(point)
  }
}
