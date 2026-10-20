import AppKit
import SwiftUI

/// A small, borderless turntable. Core Animation owns every moving frame;
/// playback snapshots only change the transport, never restart the entrance.
struct VinylRecordView: NSViewRepresentable {
  let isPlaying: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeNSView(context: Context) -> VinylRecordLayerView { VinylRecordLayerView() }

  func updateNSView(_ view: VinylRecordLayerView, context: Context) {
    view.configure(isPlaying: isPlaying, reduceMotion: reduceMotion)
  }
}

final class VinylRecordLayerView: NSView {
  static let riseDuration = 2.2
  static let armDuration = 1.1
  static let revolutionDuration = 8.0
  static let playingAngle = -CGFloat.pi / 5

  let scene = CALayer()
  let platter = CALayer()
  let record = CALayer()
  let arm = CALayer()
  private let armBody = CALayer()
  private var playing = false
  private var reducedMotion = false
  private var appearedAt: CFTimeInterval?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    setAccessibilityElement(false)
    buildLayers()
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let scale = max(0.01, min(bounds.width / 270, bounds.height / 270))
    scene.position = CGPoint(x: bounds.midX, y: bounds.midY)
    scene.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      if appearedAt == nil { enter() }
    } else {
      freezeRotation()
      platter.removeAllAnimations()
      arm.removeAllAnimations()
      armBody.removeAllAnimations()
      appearedAt = nil
    }
  }

  func configure(isPlaying: Bool, reduceMotion: Bool) {
    guard playing != isPlaying || reducedMotion != reduceMotion else { return }
    playing = isPlaying
    let motionChanged = reducedMotion != reduceMotion
    reducedMotion = reduceMotion
    guard appearedAt != nil else { return }
    if motionChanged && reduceMotion {
      platter.removeAllAnimations()
      arm.removeAllAnimations()
      armBody.removeAllAnimations()
      appearedAt = CACurrentMediaTime() - Self.riseDuration
    }
    updateTransport()
  }

  private func enter() {
    let now = CACurrentMediaTime()
    appearedAt = reducedMotion ? now - Self.riseDuration : now
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    arm.setValue(0, forKeyPath: "transform.rotation.z")
    if !reducedMotion {
      animate(platter, "position.y", from: -84, to: 125,
              duration: Self.riseDuration, curve: CAMediaTimingFunction(controlPoints: 0.22, 0.68, 0.18, 1))
      animate(platter, "opacity", from: 0, to: 1, duration: 1.7)
      animate(platter, "transform.scale", from: 0.86, to: 1, duration: Self.riseDuration)
      animate(arm, "opacity", from: 0, to: 1, duration: 1.0, delay: 1.2)
    }
    CATransaction.commit()
    updateTransport()
  }

  private func updateTransport() {
    let now = CACurrentMediaTime()
    let remainingRise = max(0, Self.riseDuration - (now - (appearedAt ?? now)))
    let angle = (arm.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat)
      ?? (arm.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
    let rotation = freezeRotation()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    arm.removeAnimation(forKey: "transform.rotation.z")
    armBody.removeAllAnimations()
    let target = playing ? Self.playingAngle : 0
    arm.setValue(target, forKeyPath: "transform.rotation.z")
    armBody.shadowRadius = playing ? 2 : 5
    armBody.shadowOffset = CGSize(width: playing ? 1 : 4, height: playing ? -2 : -7)
    if !reducedMotion {
      let delay = playing ? remainingRise + 0.12 : 0
      animate(arm, "transform.rotation.z", from: angle, to: target,
              duration: Self.armDuration, delay: delay,
              curve: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.2, 1))
      // A tiny vertical settle and tightening shadow make the stylus land
      // after the horizontal swing instead of sliding flat over the disc.
      if playing {
        animate(armBody, "transform.translation.y", from: 2.5, to: 0,
                duration: 0.28, delay: delay + Self.armDuration - 0.2)
        animate(armBody, "shadowRadius", from: 5, to: 2,
                duration: 0.28, delay: delay + Self.armDuration - 0.2)
        startRotation(from: rotation, delay: delay + Self.armDuration + 0.08)
      } else if remainingRise == 0 {
        // A short coast preserves the visible angle at pause; never snap to zero.
        let stop = rotation - CGFloat.pi * 2 / Self.revolutionDuration * 0.28
        record.setValue(stop, forKeyPath: "transform.rotation.z")
        animate(record, "transform.rotation.z", from: rotation, to: stop, duration: 0.56,
                curve: CAMediaTimingFunction(controlPoints: 0.2, 0.65, 0.4, 1))
      }
    }
    CATransaction.commit()
  }

  @discardableResult
  private func freezeRotation() -> CGFloat {
    let angle = (record.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat)
      ?? (record.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    record.removeAllAnimations()
    record.setValue(angle, forKeyPath: "transform.rotation.z")
    CATransaction.commit()
    return angle
  }

  private func startRotation(from angle: CGFloat, delay: CFTimeInterval) {
    let speed = CGFloat.pi * 2 / Self.revolutionDuration
    let rampDuration = 0.9
    let end = angle - speed * rampDuration / 2
    // Integral of smoothstep velocity: zero acceleration at both ends,
    // then a seamless handoff to constant speed on the render server.
    let ramp = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    ramp.values = (0...60).map { i -> CGFloat in
      let t = CGFloat(i) / 60
      return angle - speed * rampDuration * (t * t * t - t * t * t * t / 2)
    }
    ramp.duration = rampDuration
    ramp.beginTime = record.convertTime(CACurrentMediaTime(), from: nil) + delay
    ramp.fillMode = .backwards
    record.add(ramp, forKey: "spinUp")

    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = end
    spin.toValue = end - .pi * 2
    spin.duration = Self.revolutionDuration
    spin.beginTime = ramp.beginTime + rampDuration
    spin.repeatCount = .infinity
    // No backwards fill: it would hide the ramp during its delay.
    record.add(spin, forKey: "spin")
  }

  private func animate(
    _ layer: CALayer, _ key: String, from: Any, to: Any,
    duration: CFTimeInterval, delay: CFTimeInterval = 0,
    curve: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
  ) {
    let animation = CABasicAnimation(keyPath: key)
    animation.fromValue = from
    animation.toValue = to
    animation.duration = duration
    animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
    animation.timingFunction = curve
    animation.fillMode = .backwards
    layer.add(animation, forKey: key)
  }

  private func buildLayers() {
    scene.bounds = CGRect(x: 0, y: 0, width: 270, height: 270)
    layer?.addSublayer(scene)
    platter.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
    platter.position = CGPoint(x: 117, y: 125)
    platter.shadowColor = NSColor.black.cgColor
    platter.shadowOpacity = 0.9
    platter.shadowRadius = 15
    platter.shadowOffset = CGSize(width: 0, height: -12)
    platter.shadowPath = CGPath(ellipseIn: platter.bounds, transform: nil)
    scene.addSublayer(platter)

    let base = circle(in: platter.bounds, color: NSColor(white: 0.045, alpha: 1))
    base.borderColor = NSColor(white: 0.23, alpha: 1).cgColor
    base.borderWidth = 0.7
    platter.addSublayer(base)

    // Light stays in the room while the label and pressing rotate beneath it.
    let sheen = CAGradientLayer()
    sheen.frame = platter.bounds.insetBy(dx: 1, dy: 1)
    sheen.type = .conic
    sheen.startPoint = CGPoint(x: 0.5, y: 0.5)
    sheen.endPoint = CGPoint(x: 0.8, y: 1)
    sheen.colors = [0.045, 0.085, 0.22, 0.07, 0.035, 0.065, 0.18, 0.055, 0.045]
      .map { NSColor(white: $0, alpha: 1).cgColor }
    sheen.cornerRadius = 99
    platter.addSublayer(sheen)

    let grooves = CAShapeLayer()
    let rings = CGMutablePath()
    for i in 0..<43 {
      let inset = 5 + CGFloat(i) * 1.48
      rings.addEllipse(in: platter.bounds.insetBy(dx: inset, dy: inset))
    }
    grooves.path = rings
    grooves.fillColor = nil
    grooves.strokeColor = NSColor(white: 0.6, alpha: 0.15).cgColor
    grooves.lineWidth = 0.45
    platter.addSublayer(grooves)
    for inset: CGFloat in [12, 29, 49, 65] {
      let band = CAShapeLayer()
      band.path = CGPath(ellipseIn: platter.bounds.insetBy(dx: inset, dy: inset), transform: nil)
      band.fillColor = nil
      band.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
      band.lineWidth = 1.6
      platter.addSublayer(band)
    }

    record.frame = platter.bounds
    platter.addSublayer(record)
    let label = circle(in: CGRect(x: 68, y: 68, width: 64, height: 64),
                       color: NSColor(red: 0.56, green: 0.36, blue: 0.24, alpha: 1))
    label.borderColor = NSColor(red: 0.8, green: 0.62, blue: 0.43, alpha: 0.7).cgColor
    label.borderWidth = 0.6
    record.addSublayer(label)
    let labelRing = CAShapeLayer()
    labelRing.path = CGPath(ellipseIn: CGRect(x: 73, y: 73, width: 54, height: 54), transform: nil)
    labelRing.strokeColor = NSColor.black.withAlphaComponent(0.2).cgColor
    labelRing.fillColor = nil
    labelRing.lineWidth = 0.7
    record.addSublayer(labelRing)
    for (text, y, size) in [("SIDE A", 111.0, 5.5), ("LONG PLAY", 80.0, 4.0)] {
      let caption = CATextLayer()
      caption.string = text
      caption.font = NSFont.systemFont(ofSize: size, weight: .medium)
      caption.fontSize = size
      caption.alignmentMode = .center
      caption.foregroundColor = NSColor(white: 0.08, alpha: 0.8).cgColor
      caption.contentsScale = 2
      caption.frame = CGRect(x: 75, y: y, width: 50, height: 9)
      record.addSublayer(caption)
    }
    record.addSublayer(circle(in: CGRect(x: 89, y: 89, width: 22, height: 22),
                             color: NSColor(white: 0.12, alpha: 1)))
    let spindle = circle(in: CGRect(x: 97, y: 97, width: 6, height: 6),
                         color: NSColor(white: 0.65, alpha: 1))
    spindle.borderWidth = 1.5
    spindle.borderColor = NSColor(white: 0.16, alpha: 1).cgColor
    platter.addSublayer(spindle)

    // Arm geometry is relative to the bearing at (0, 0), not its bounding box.
    let bearing = circle(in: CGRect(x: 230, y: 217, width: 27, height: 27),
                         color: NSColor(white: 0.11, alpha: 1))
    bearing.borderColor = NSColor(white: 0.28, alpha: 1).cgColor
    bearing.borderWidth = 0.7
    scene.addSublayer(bearing)
    arm.position = CGPoint(x: 243.5, y: 230.5)
    scene.addSublayer(arm)
    arm.addSublayer(armBody)
    armBody.shadowColor = NSColor.black.cgColor
    armBody.shadowOpacity = 0.85
    let tube = CGMutablePath()
    tube.move(to: CGPoint(x: 0, y: 8))
    tube.addLine(to: CGPoint(x: 0, y: -74))
    tube.addQuadCurve(to: CGPoint(x: -6, y: -89), control: CGPoint(x: 0, y: -83))
    tube.addLine(to: CGPoint(x: -14, y: -101))
    for (width, gray) in [(6.0, 0.12), (4.2, 0.56), (1.2, 0.88)] {
      let stroke = CAShapeLayer()
      stroke.path = tube
      stroke.lineWidth = width
      stroke.strokeColor = NSColor(white: gray, alpha: 1).cgColor
      stroke.fillColor = nil
      stroke.lineCap = .round
      stroke.lineJoin = .round
      if width == 1.2 { stroke.position.x = -0.9 }
      armBody.addSublayer(stroke)
    }
    let weight = CALayer()
    weight.frame = CGRect(x: -7, y: 3, width: 14, height: 19)
    weight.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
    weight.borderColor = NSColor(white: 0.45, alpha: 1).cgColor
    weight.borderWidth = 0.7
    weight.cornerRadius = 3
    armBody.addSublayer(weight)
    let cartridge = CALayer()
    cartridge.bounds = CGRect(x: 0, y: 0, width: 10, height: 23)
    cartridge.position = CGPoint(x: -15, y: -102)
    cartridge.setAffineTransform(CGAffineTransform(rotationAngle: -0.5))
    cartridge.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
    cartridge.borderColor = NSColor(white: 0.4, alpha: 1).cgColor
    cartridge.borderWidth = 0.7
    cartridge.cornerRadius = 2
    armBody.addSublayer(cartridge)
    let tip = CALayer()
    tip.frame = CGRect(x: 2, y: 1, width: 6, height: 3)
    tip.backgroundColor = NSColor(red: 0.72, green: 0.44, blue: 0.27, alpha: 1).cgColor
    cartridge.addSublayer(tip)
    arm.addSublayer(circle(in: CGRect(x: -4, y: -4, width: 8, height: 8),
                          color: NSColor(white: 0.68, alpha: 1)))
  }

  private func circle(in rect: CGRect, color: NSColor) -> CALayer {
    let layer = CALayer()
    layer.frame = rect
    layer.cornerRadius = rect.width / 2
    layer.backgroundColor = color.cgColor
    return layer
  }
}
