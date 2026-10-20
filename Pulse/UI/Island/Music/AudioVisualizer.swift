import AppKit
import SwiftUI

/// Decorative bars animated by Core Animation's render server. The app only
/// updates layers when playback, motion preferences or the view size changes.
/// There is no per-frame SwiftUI layout or application timer.
struct AudioVisualizer: NSViewRepresentable {
  let isPlaying: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeNSView(context: Context) -> AudioVisualizerView {
    AudioVisualizerView()
  }

  func updateNSView(_ view: AudioVisualizerView, context: Context) {
    view.configure(isPlaying: isPlaying, reduceMotion: reduceMotion)
  }
}

final class AudioVisualizerView: NSView {
  static let barCount = 24
  static let barSpacing: CGFloat = 5
  // Both sine frequencies (2.2 and 5.1 rad/s) repeat after 20π seconds.
  static let period = 20 * Double.pi
  static let sampleCount = Int(ceil(period * 30))
  static let animationKey = "audioBarHeight"

  private(set) var bars: [CALayer] = []
  private var isPlaying = false
  private var reduceMotion = false
  private var renderedSize: CGSize?
  private var needsConfiguration = true

  // Sample once for the process, then let the compositor interpolate.
  // The original 30 Hz waveform is preserved to within 0.6 pt, including
  // the kink where the minimum bar height clamps to 5 pt.
  static let heightSamples: [[CGFloat]] = (0..<barCount).map { index in
    (0...sampleCount).map { frame in
      barHeight(index, phase: Double(frame) / Double(sampleCount) * period, playing: true)
    }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    setAccessibilityElement(false)
    for index in 0..<Self.barCount {
      let bar = CALayer()
      let progress = Double(index) / Double(Self.barCount - 1)
      bar.backgroundColor =
        NSColor(
          Color(
            hue: 0.68 - progress * 0.62, saturation: 0.55,
            brightness: 0.9
          ).opacity(0.6)
        ).cgColor
      layer?.addSublayer(bar)
      bars.append(bar)
    }
  }

  required init?(coder: NSCoder) { nil }

  func configure(isPlaying: Bool, reduceMotion: Bool) {
    guard self.isPlaying != isPlaying || self.reduceMotion != reduceMotion else { return }
    self.isPlaying = isPlaying
    self.reduceMotion = reduceMotion
    needsConfiguration = true
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard bounds.width > 0, bounds.height > 0,
      needsConfiguration || renderedSize != bounds.size
    else { return }
    renderedSize = bounds.size
    needsConfiguration = false
    let width = max(
      3,
      (bounds.width - CGFloat(Self.barCount - 1) * Self.barSpacing)
        / CGFloat(Self.barCount))
    let totalWidth = CGFloat(Self.barCount) * width + CGFloat(Self.barCount - 1) * Self.barSpacing
    let start = CACurrentMediaTime()
    let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (index, bar) in bars.enumerated() {
      bar.removeAnimation(forKey: Self.animationKey)
      bar.bounds = CGRect(
        x: 0, y: 0, width: width,
        height: Self.barHeight(index, phase: 0, playing: isPlaying))
      bar.position = CGPoint(
        x: (bounds.width - totalWidth) / 2 + CGFloat(index) * (width + Self.barSpacing) + width / 2,
        y: bounds.height / 2)
      bar.cornerCurve = .continuous
      bar.cornerRadius = min(width, bar.bounds.height) / 2
      if isPlaying && !reduceMotion {
        let height = CAKeyframeAnimation(keyPath: "bounds.size.height")
        height.values = Self.heightSamples[index]
        height.duration = Self.period
        height.calculationMode = .linear
        // Very short bars are horizontal capsules. An oversized fixed
        // radius would pinch them into a lens, so animate both together.
        let radius = CAKeyframeAnimation(keyPath: "cornerRadius")
        radius.values = Self.heightSamples[index].map { min(width, $0) / 2 }
        radius.duration = Self.period
        radius.calculationMode = .linear
        let animation = CAAnimationGroup()
        animation.animations = [height, radius]
        animation.duration = Self.period
        animation.repeatCount = .infinity
        animation.beginTime = bar.convertTime(start, from: nil)
        animation.timeOffset = phase
        bar.add(animation, forKey: Self.animationKey)
      }
    }
    CATransaction.commit()
  }

  static func barHeight(_ index: Int, phase: Double, playing: Bool) -> CGFloat {
    guard playing else { return 6 + CGFloat(index % 5) * 2 }
    let base = sin(phase * 2.2 + Double(index) * 0.55) * 0.5 + 0.5
    let detail = sin(phase * 5.1 + Double(index) * 1.3) * 0.5 + 0.5
    let envelope = sin(Double(index) / Double(barCount) * .pi)
    return max(5, CGFloat(base * 0.55 + detail * 0.3 + envelope * 0.15) * 90)
  }
}
