import AppKit
import QuartzCore

/// A deep-black core surrounded by a dense monochrome particle corona.
/// Rasterized dust provides depth; replicated particles follow curved paths.
/// All motion runs on the compositor, with no per-frame view/window layout.
@MainActor
final class BlackHoleWakeView: NSView {
  let originalSize: CGSize
  let awakenedWidth: CGFloat
  let awakenedHeight: CGFloat
  static let sidePadding: CGFloat = 144
  static let bottomPadding: CGFloat = 88
  var coreFrame: CGRect {
    CGRect(x: Self.sidePadding, y: 0, width: awakenedWidth, height: awakenedHeight)
  }
  private let scene = CALayer()
  private let core = CALayer()
  private let atmosphere = CALayer()
  private let stars = CALayer()
  private let particles = CALayer()
  private let silhouette = CAShapeLayer()
  private var voiceRims: [CAShapeLayer] = []
  private let voiceCaption = CATextLayer()
  private var isDismissing = false
  private(set) var voiceEnergy: CGFloat = 0
  private let reduceMotion: Bool
  private var initialScaleX: CGFloat { originalSize.width / awakenedWidth }
  private var initialScaleY: CGFloat { originalSize.height / awakenedHeight }
  private(set) var isAwake = false
  var presentedWidth: CGFloat {
    awakenedWidth * CGFloat((scene.presentation() ?? scene).transform.m11)
  }

  override var isFlipped: Bool { true }

  init(size: CGSize, radius: CGFloat, reduceMotion: Bool) {
    originalSize = size
    awakenedWidth = size.width + min(64, size.width * 0.14)
    awakenedHeight = size.height + 30
    self.reduceMotion = reduceMotion
    super.init(frame: CGRect(x: 0, y: 0,
      width: awakenedWidth + Self.sidePadding * 2,
      height: awakenedHeight + Self.bottomPadding))
    wantsLayer = true
    guard let layer else { return }
    scene.bounds = bounds
    scene.anchorPoint = CGPoint(x: 0.5, y: 0)
    scene.position = CGPoint(x: bounds.midX, y: 0)
    core.frame = coreFrame
    core.backgroundColor = NSColor.black.cgColor
    // Compensate for the initial scale so the first black outline matches the
    // existing island exactly. There is never a full-size flash before unfolding.
    silhouette.path = outline(width: awakenedWidth, height: awakenedHeight,
      radiusX: radius / initialScaleX, radiusY: radius / initialScaleY)
    core.mask = silhouette
    layer.addSublayer(scene)
    atmosphere.frame = bounds
    atmosphere.opacity = 0
    scene.addSublayer(atmosphere)
    stars.frame = bounds
    stars.opacity = 0
    scene.addSublayer(stars)
    addParticleCloud()
    if !reduceMotion { addParticleFlow() }
    addWhiteRim()
    scene.addSublayer(core)
    scene.transform = CATransform3DMakeScale(initialScaleX, initialScaleY, 1)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(L10n.text("wake.charging"))
  }

  required init?(coder: NSCoder) { nil }

  func begin() {
    animateScale(x: 1, y: 1, duration: reduceMotion ? 0.15 : AIWakeGesture.holdDuration)
    fade(atmosphere, to: 1, duration: reduceMotion ? 0.15 : 0.3)
    fade(stars, to: 0.8, duration: reduceMotion ? 0.15 : 0.62)
  }

  func awaken() {
    guard !isAwake else { return }
    isAwake = true
    setAccessibilityLabel(L10n.text("wake.awake"))
    fade(stars, to: 1, duration: 0.3)
    guard !reduceMotion else { return }
    // A restrained sparkle in the particle cloud marks the completed hold.
    let ignition = CAKeyframeAnimation(keyPath: "opacity")
    ignition.values = [0.8, 1, 0.65, 1]
    ignition.keyTimes = [0, 0.2, 0.55, 1]
    ignition.duration = 0.8
    stars.add(ignition, forKey: "ignition")
  }

  func setVoiceState(_ state: XiaozhiVoiceSession.State) {
    let captions: [XiaozhiVoiceSession.State: String] = [
      .connecting: L10n.text("voice.connecting"), .switching: L10n.text("voice.switching"), .listening: L10n.text("voice.listening"),
      .thinking: L10n.text("voice.thinking"), .speaking: L10n.text("voice.speaking"), .stopped: L10n.text("voice.stopped")]
    showVoiceCaption(captions[state] ?? "")
  }

  func setVoiceError(_ code: String) {
    let text: String
    switch code {
    case "microphone": text = L10n.text("voice.error.microphone")
    case "not_installed", "not_bound": text = L10n.text("voice.error.setup")
    case "idle_timeout": text = L10n.text("voice.ended")
    case "busy": text = L10n.text("voice.error.busy")
    default: text = L10n.text("voice.error.connection")
    }
    showVoiceCaption(text)
    setVoiceLevel(input: 0, output: 0)
  }

  private func showVoiceCaption(_ text: String) {
    guard !isDismissing else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if voiceCaption.superlayer == nil {
      voiceCaption.frame = CGRect(x: 18, y: awakenedHeight - 24, width: awakenedWidth - 36, height: 18)
      voiceCaption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
      voiceCaption.fontSize = 11
      voiceCaption.alignmentMode = .center
      voiceCaption.truncationMode = .end
      voiceCaption.foregroundColor = NSColor(white: 0.78, alpha: 1).cgColor
      voiceCaption.contentsScale = window?.backingScaleFactor ?? 2
      core.addSublayer(voiceCaption)
    }
    voiceCaption.string = text
    CATransaction.commit()
    setAccessibilityLabel(text)
  }

  /// Only the white rim responds to sound. Dust, atmosphere, the opaque core,
  /// and the native window retain their geometry and independent animations.
  func setVoiceLevel(input: Double, output: Double) {
    let target = CGFloat(max(XiaozhiVoiceSession.clamp(input), XiaozhiVoiceSession.clamp(output)))
    let coefficient: CGFloat = target > voiceEnergy ? 0.48 : 0.14
    voiceEnergy += (target - voiceEnergy) * coefficient
    if voiceEnergy < 0.001 { voiceEnergy = 0 }
    let energy = reduceMotion ? min(voiceEnergy, 0.25) : voiceEnergy
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, rim) in voiceRims.enumerated() {
      let inner = index == 0
      rim.lineWidth = (inner ? 2 : 2.2) + energy * (inner ? 2.4 : 3.5)
      rim.shadowRadius = (inner ? 4 : 11) + energy * (inner ? 6 : 12)
      rim.opacity = Float((inner ? 0.9 : 0.24) + energy * (inner ? 0.1 : 0.3))
      // A soft outward breath, anchored at the notch's top edge.
      rim.transform = CATransform3DMakeScale(1, 1 + energy * (reduceMotion ? 0 : 0.035), 1)
    }
    CATransaction.commit()
  }

  func dismiss() {
    // Captions belong to the live conversation, not the shrinking core.
    // Clear immediately and ignore late transport callbacks during dismissal.
    isDismissing = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    voiceCaption.string = nil
    voiceCaption.isHidden = true
    CATransaction.commit()
    setAccessibilityLabel(nil)
    animateScale(x: initialScaleX, y: initialScaleY, duration: reduceMotion ? 0.15 : 0.38)
    let visible = stars.presentation()?.opacity ?? stars.opacity
    stars.removeAnimation(forKey: "ignition")
    fade(stars, to: 0, duration: 0.3, from: visible)
    fade(atmosphere, to: 0, duration: 0.3)
  }

  /// Distance from an enclosing rounded core. The hidden upper half keeps the
  /// visible distribution attached to the screen edge instead of forming a ring.
  private func distanceFromCore(_ point: CGPoint) -> CGFloat {
    let radius: CGFloat = 24
    let center = CGPoint(x: coreFrame.midX, y: (awakenedHeight - 80) / 2)
    let half = CGSize(width: awakenedWidth / 2, height: (awakenedHeight + 80) / 2)
    let qx = (abs(point.x - center.x) - half.width) / 1.6 + radius
    let qy = abs(point.y - center.y) - half.height + radius
    return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
  }

  private func addParticleCloud() {
    let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    let pixelWidth = Int(ceil(bounds.width * scale))
    let pixelHeight = Int(ceil(bounds.height * scale))
    // The black atmosphere extends beyond every particle, including moving
    // copies. Both use the same contour, so detached corner clouds cannot form.
    if let mist = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = mist.data {
      let pixels = data.assumingMemoryBound(to: UInt8.self)
      for y in 0..<pixelHeight {
        for x in 0..<pixelWidth {
          let point = CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)
          let distance = max(0, distanceFromCore(point))
          let fade = min(1, max(0, (78 - distance) / 48))
          let opacity = 0.94 * fade * fade * (3 - 2 * fade)
          pixels[(y * pixelWidth + x) * 4 + 3] = UInt8(opacity * 255)
        }
      }
      let bed = CALayer()
      bed.frame = bounds
      bed.contents = mist.makeImage()
      bed.contentsScale = scale
      // The atmosphere is independent of dust shimmer and awakening ignition.
      // Once revealed it remains fully present until explicit dismissal.
      atmosphere.addSublayer(bed)
    }

    particles.frame = bounds
    stars.addSublayer(particles)
    // A shared feathered mask also constrains replicated flow and plane drift.
    // Keep a generous dark margin beyond the last visible speck.
    if let maskContext = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = maskContext.data {
      let pixels = data.assumingMemoryBound(to: UInt8.self)
      for y in 0..<pixelHeight {
        for x in 0..<pixelWidth {
          let distance = distanceFromCore(CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale))
          let fade = min(1, max(0, (46 - distance) / 20))
          pixels[(y * pixelWidth + x) * 4 + 3] = UInt8(fade * fade * (3 - 2 * fade) * 255)
        }
      }
      let mask = CALayer()
      mask.frame = bounds
      mask.contents = maskContext.makeImage()
      mask.contentsScale = scale
      particles.mask = mask
    }

    // Thousands of independent specks are drawn once into three depth planes,
    // rather than allocating thousands of animated layers or views.
    var randomState: UInt64 = 0x50554C5345
    func random() -> Double {
      randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
      return Double(randomState >> 11) / Double(UInt64.max >> 11)
    }
    for plane in 0..<3 {
      guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
      context.scaleBy(x: scale, y: scale)
      for _ in 0..<24000 {
        let point = CGPoint(x: random() * bounds.width, y: random() * bounds.height)
        let distance = distanceFromCore(point)
        guard distance > 0, distance < 46 else { continue }
        // Dense at the lip, softer toward the outer cloud, no hard cutoff.
        let envelope = exp(-distance / 32) * pow(max(0, 1 - distance / 54), 0.7)
        guard random() < 0.62 * envelope else { continue }
        let diameter = 0.35 + pow(random(), 2) * (plane == 2 ? 1.2 : 0.85)
        let alpha = (0.32 + random() * 0.68) * pow(envelope, 0.25)
        context.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)
        context.fillEllipse(in: CGRect(x: point.x, y: point.y, width: diameter, height: diameter))
      }
      let dust = CALayer()
      dust.frame = bounds
      dust.contents = context.makeImage()
      dust.contentsScale = scale
      particles.addSublayer(dust)
      if !reduceMotion {
        let drift = CABasicAnimation(keyPath: "transform.translation")
        let sign: CGFloat = plane % 2 == 0 ? 1 : -1
        drift.fromValue = NSValue(point: CGPoint(x: -2 * sign, y: 0))
        drift.toValue = NSValue(point: CGPoint(x: 2 * sign, y: 2))
        drift.duration = 3.2 + Double(plane) * 0.8
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dust.add(drift, forKey: "dustDrift")
        let shimmer = CABasicAnimation(keyPath: "opacity")
        shimmer.fromValue = 0.62
        shimmer.toValue = 1
        shimmer.duration = 1.7 + Double(plane) * 0.7
        shimmer.autoreverses = true
        shimmer.repeatCount = .infinity
        shimmer.timeOffset = Double(plane) * 0.7
        shimmer.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dust.add(shimmer, forKey: "dustShimmer")
      }
    }
  }

  private func addWhiteRim() {
    guard let path = silhouette.path else { return }
    // Follow the actual black silhouette, including its unfolding corner shape.
    // The core is composited above this rim, keeping the glow outside its edge.
    for (width, opacity, blur) in [(CGFloat(2), Float(0.9), CGFloat(4)),
      (CGFloat(2.2), Float(0.24), CGFloat(11))] {
      let rim = CAShapeLayer()
      rim.frame = coreFrame
      rim.anchorPoint = CGPoint(x: 0.5, y: 0)
      rim.position = CGPoint(x: coreFrame.midX, y: 0)
      rim.path = path
      rim.fillColor = nil
      rim.strokeColor = NSColor.white.cgColor
      rim.lineWidth = width
      rim.opacity = opacity
      rim.shadowColor = NSColor.white.cgColor
      rim.shadowOpacity = 0.9
      rim.shadowRadius = blur
      rim.shadowOffset = .zero
      stars.addSublayer(rim)
      voiceRims.append(rim)
    }
  }

  private func addParticleFlow() {
    let now = CACurrentMediaTime()
    // Mirrored currents sweep around both shoulders and along the lower lip,
    // then bend upward into the black center. Replication keeps layer count low.
    for stream in 0..<48 {
      let left = stream % 2 == 0
      let direction: CGFloat = left ? -1 : 1
      let distance = 5 + CGFloat((stream * 17) % 38)
      let edgeX = coreFrame.midX + direction * (awakenedWidth / 2 + distance * 1.6)
      let lowerY = awakenedHeight + distance * 0.72
      let startY = CGFloat((stream * 11) % 35) - 14
      let path = CGMutablePath()
      path.move(to: CGPoint(x: edgeX + direction * 20, y: startY))
      path.addCurve(to: CGPoint(x: coreFrame.midX + direction * awakenedWidth * 0.28, y: lowerY),
        control1: CGPoint(x: edgeX + direction * 10, y: lowerY * 0.8),
        control2: CGPoint(x: coreFrame.midX + direction * awakenedWidth * 0.46, y: lowerY + 10))
      path.addCurve(to: CGPoint(x: coreFrame.midX + direction * 8, y: awakenedHeight - 8),
        control1: CGPoint(x: coreFrame.midX + direction * awakenedWidth * 0.14, y: lowerY),
        control2: CGPoint(x: coreFrame.midX + direction * 30, y: awakenedHeight + 5))
      let duration = 4.2 + Double(stream % 9) * 0.29
      let copies = CAReplicatorLayer()
      copies.frame = bounds
      copies.instanceCount = 24
      copies.instanceDelay = duration / 24
      // Slight positional variation avoids evenly spaced bead-like tracks.
      copies.instanceTransform = CATransform3DMakeTranslation(0, 0.22, 0)
      particles.addSublayer(copies)
      let particle = CALayer()
      let diameter: CGFloat = stream % 5 == 0 ? 1.55 : 0.85
      particle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
      particle.cornerRadius = diameter / 2
      particle.backgroundColor = NSColor.white.cgColor
      particle.opacity = 0
      copies.addSublayer(particle)
      let travel = CAKeyframeAnimation(keyPath: "position")
      travel.path = path
      travel.calculationMode = .paced
      travel.timingFunction = CAMediaTimingFunction(controlPoints: 0.35, 0, 0.8, 0.6)
      let visibility = CAKeyframeAnimation(keyPath: "opacity")
      visibility.values = [0, 0.55, 0.8, 0]
      visibility.keyTimes = [0, 0.15, 0.65, 1]
      let group = CAAnimationGroup()
      group.duration = duration
      travel.duration = duration
      visibility.duration = duration
      group.animations = [travel, visibility]
      group.repeatCount = .infinity
      group.beginTime = now - duration * 2 - Double(stream) * 0.137
      particle.add(group, forKey: "infall")
    }
  }

  private func animateScale(x: CGFloat, y: CGFloat, duration: TimeInterval) {
    let current = (scene.presentation() ?? scene).transform
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scene.transform = CATransform3DMakeScale(x, y, 1)
    for (key, from, to) in [("transform.scale.x", current.m11, x), ("transform.scale.y", current.m22, y)] {
      let movement = CABasicAnimation(keyPath: key)
      movement.fromValue = from
      movement.toValue = to
      movement.duration = duration
      movement.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.16, 1)
      movement.fillMode = .backwards
      scene.add(movement, forKey: key)
    }
    CATransaction.commit()
  }

  private func fade(_ layer: CALayer, to opacity: Float, duration: TimeInterval, from explicitOpacity: Float? = nil) {
    let from = explicitOpacity ?? layer.presentation()?.opacity ?? layer.opacity
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = opacity
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    animation.toValue = opacity
    animation.duration = duration
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(animation, forKey: "reveal")
    CATransaction.commit()
  }

  private func outline(width: CGFloat, height: CGFloat, radiusX: CGFloat, radiusY: CGFloat) -> CGPath {
    let rx = min(radiusX, width / 2)
    let ry = min(radiusY, height)
    let k: CGFloat = 0.5522848
    let path = CGMutablePath()
    path.move(to: .zero)
    path.addLine(to: CGPoint(x: width, y: 0))
    path.addLine(to: CGPoint(x: width, y: height - ry))
    path.addCurve(to: CGPoint(x: width - rx, y: height),
      control1: CGPoint(x: width, y: height - ry * (1 - k)),
      control2: CGPoint(x: width - rx * (1 - k), y: height))
    path.addLine(to: CGPoint(x: rx, y: height))
    path.addCurve(to: CGPoint(x: 0, y: height - ry),
      control1: CGPoint(x: rx * (1 - k), y: height),
      control2: CGPoint(x: 0, y: height - ry * (1 - k)))
    path.closeSubpath()
    return path
  }
}
