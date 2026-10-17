import AppKit
import QuartzCore

/// An opaque, expanding patch of space. Every star stays INSIDE the black
/// silhouette; no outer halo, orbit lines or transparent effects envelope.
/// All motion runs on the compositor, with no per-frame view/window layout.
@MainActor
final class BlackHoleWakeView: NSView {
  let originalSize: CGSize
  let awakenedWidth: CGFloat
  let awakenedHeight: CGFloat
  private let scene = CALayer()
  private let stars = CALayer()
  private let silhouette = CAShapeLayer()
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
    super.init(frame: CGRect(x: 0, y: 0, width: awakenedWidth, height: awakenedHeight))
    wantsLayer = true
    guard let layer else { return }
    scene.bounds = bounds
    scene.anchorPoint = CGPoint(x: 0.5, y: 0)
    scene.position = CGPoint(x: bounds.midX, y: 0)
    scene.backgroundColor = NSColor.black.cgColor
    // Compensate for the initial scale so the first black outline matches the
    // existing island exactly. There is never a full-size flash before unfolding.
    silhouette.path = outline(width: awakenedWidth, height: awakenedHeight,
      radiusX: radius / initialScaleX, radiusY: radius / initialScaleY)
    scene.mask = silhouette
    layer.addSublayer(scene)
    stars.frame = bounds
    stars.opacity = 0
    scene.addSublayer(stars)
    addStarfield()
    if !reduceMotion { addInfall() }
    scene.transform = CATransform3DMakeScale(initialScaleX, initialScaleY, 1)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(L10n.text("wake.charging"))
  }

  required init?(coder: NSCoder) { nil }

  func begin() {
    animateScale(x: 1, y: 1, duration: reduceMotion ? 0.15 : AIWakeGesture.holdDuration)
    fadeStars(to: 0.8, duration: reduceMotion ? 0.15 : 0.62)
  }

  func awaken() {
    guard !isAwake else { return }
    isAwake = true
    setAccessibilityLabel(L10n.text("wake.awake"))
    fadeStars(to: 1, duration: 0.3)
    guard !reduceMotion else { return }
    // A restrained collective sparkle marks the completed hold, with no ring
    // or flash outside the black surface.
    let ignition = CAKeyframeAnimation(keyPath: "opacity")
    ignition.values = [0.8, 1, 0.65, 1]
    ignition.keyTimes = [0, 0.2, 0.55, 1]
    ignition.duration = 0.8
    stars.add(ignition, forKey: "ignition")
  }

  func dismiss() {
    animateScale(x: initialScaleX, y: initialScaleY, duration: reduceMotion ? 0.15 : 0.38)
    let visible = stars.presentation()?.opacity ?? stars.opacity
    stars.removeAnimation(forKey: "ignition")
    stars.opacity = visible
    fadeStars(to: 0, duration: 0.3)
  }

  private func addStarfield() {
    let now = CACurrentMediaTime()
    // Sparse tiny points establish depth; bright stars are deliberately rare.
    for index in 0..<72 {
      let x = fraction(Double(index + 1) * 0.61803398875)
      let y = fraction(Double(index + 3) * 0.75487766625)
      let centerDistance = abs(x - 0.5) * 2
      let bright = index % 11 == 0
      let diameter: CGFloat = bright ? 1.6 : (index % 3 == 0 ? 1.0 : 0.65)
      let star = CALayer()
      star.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
      star.position = CGPoint(x: 5 + x * (awakenedWidth - 10), y: 4 + y * (awakenedHeight - 8))
      star.cornerRadius = diameter / 2
      star.backgroundColor = NSColor.white.cgColor
      // The center reads as a deeper void; denser stars remain in the wings.
      let alpha = Float((bright ? 0.9 : 0.38) * (0.28 + 0.72 * centerDistance))
      star.opacity = alpha
      if bright {
        star.shadowColor = NSColor.white.cgColor
        star.shadowOpacity = 0.6
        star.shadowRadius = 1.6
        star.shadowOffset = .zero
      }
      stars.addSublayer(star)
      if !reduceMotion {
        let twinkle = CABasicAnimation(keyPath: "opacity")
        twinkle.fromValue = alpha * 0.4
        twinkle.toValue = alpha
        twinkle.duration = 1.8 + Double(index % 7) * 0.35
        twinkle.autoreverses = true
        twinkle.repeatCount = .infinity
        twinkle.beginTime = now - Double(index) * 0.29
        twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        star.add(twinkle, forKey: "starlight")
      }
    }
  }

  private func addInfall() {
    let now = CACurrentMediaTime()
    let center = CGPoint(x: awakenedWidth / 2, y: awakenedHeight * 0.55)
    for index in 0..<40 {
      let angle = Double(index) * 2.39996323
      let path = CGMutablePath()
      for sample in 0...48 {
        let t = Double(sample) / 48
        let radius = 1.12 - 0.98 * pow(t, 1.5)
        let theta = angle + t * 0.9
        let point = CGPoint(
          x: center.x + cos(theta) * (awakenedWidth / 2 - 5) * radius,
          y: center.y + sin(theta) * (awakenedHeight / 2 - 4) * radius)
        if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
      }
      let particle = CALayer()
      let diameter: CGFloat = index % 6 == 0 ? 1.8 : 1.0
      particle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
      particle.cornerRadius = diameter / 2
      particle.backgroundColor = NSColor.white.cgColor
      particle.opacity = 0
      if index % 6 == 0 {
        particle.shadowColor = NSColor.white.cgColor
        particle.shadowOpacity = 0.5
        particle.shadowRadius = 2
        particle.shadowOffset = .zero
      }
      stars.addSublayer(particle)
      let travel = CAKeyframeAnimation(keyPath: "position")
      travel.path = path
      travel.calculationMode = .paced
      travel.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.85, 0.55)
      let visibility = CAKeyframeAnimation(keyPath: "opacity")
      visibility.values = [0, 0.8, 0.5, 0]
      visibility.keyTimes = [0, 0.18, 0.58, 1]
      let group = CAAnimationGroup()
      group.duration = 3.2 + Double(index % 7) * 0.3
      travel.duration = group.duration
      visibility.duration = group.duration
      group.animations = [travel, visibility]
      group.repeatCount = .infinity
      group.beginTime = now - Double(index) * 0.213
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

  private func fadeStars(to opacity: Float, duration: TimeInterval) {
    let from = stars.presentation()?.opacity ?? stars.opacity
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    stars.opacity = opacity
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    animation.toValue = opacity
    animation.duration = duration
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    stars.add(animation, forKey: "reveal")
    CATransaction.commit()
  }

  private func fraction(_ value: Double) -> Double { value - floor(value) }

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
