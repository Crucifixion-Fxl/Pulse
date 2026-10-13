import SwiftUI

// MARK: - Expression math

/// Pure expression math for the collapsed-island bot face. Every value is a
/// deterministic function of (time, inputs) — no timers, no view state — so
/// frames are stable across redraws and the schedule is unit-testable, the
/// same philosophy as `AudioVisualizer`.
enum CollapsedBotFace {
  struct Inputs: Equatable, Sendable {
    var isPlaying: Bool
    var isHovered: Bool
  }

  struct Expression: Equatable, Sendable {
    /// 1 open, 1.25 hover-widened; dips only inside the blink envelope.
    var eyeOpen: CGFloat
    /// -1...1, unit of the max glance shift.
    var glanceX: CGFloat
    /// Eye rotation in radians — the Grok Bot trick: slanted capsules that
    /// sway slowly and lean into glances are what read as "alive"; perfectly
    /// upright circles read as vacant.
    var eyeTilt: CGFloat
    /// -1...1, negative = up (hover lift).
    var lookY: CGFloat
    /// Beat/breath squash applied to the whole face.
    var faceScale: CGFloat
    /// Vertical bob as a fraction of the face size.
    var faceOffsetYFraction: CGFloat
  }

  // Timing, in seconds.
  static let blinkCycle = 3.4
  static let blinkDuration = 0.22
  static let glanceCycle = 5.3
  static let beatBPM = 118.0

  static func expression(at t: TimeInterval, inputs: Inputs) -> Expression {
    let glance = glanceUnit(at: t)
    if inputs.isHovered {
      return Expression(
        eyeOpen: 1.25, glanceX: 0, eyeTilt: 0, lookY: -0.8, faceScale: 1,
        faceOffsetYFraction: 0)
    }
    // No sleep mode: the face stays awake whether or not music plays —
    // playback only adds the beat bounce. The eyes never change size
    // except for the momentary blink envelope.
    let beat = inputs.isPlaying ? beatPulse(at: t) : 0
    let breath = CGFloat(sin(2 * .pi * t / 3.9))
    // Grok Bot motion language: a slow tilt sway plus a lean into the
    // current glance is what reads as "curious and alive".
    let tilt = 0.10 * CGFloat(sin(2 * .pi * t / 5.7)) + 0.05 * glance
    return Expression(
      eyeOpen: blinkOpenFraction(at: t),
      glanceX: glance,
      eyeTilt: tilt,
      lookY: 0,
      faceScale: 1 + 0.03 * beat + 0.012 * breath,
      faceOffsetYFraction: 0.012 * breath)
  }

  /// The single frame rendered under Reduce Motion or on a hidden surface.
  static func staticExpression(isPlaying: Bool) -> Expression {
    Expression(
      eyeOpen: 1, glanceX: 0, eyeTilt: 0.06, lookY: 0, faceScale: 1,
      faceOffsetYFraction: 0)
  }

  /// Deterministic 0..<1 noise: the same index always maps to the same
  /// value, so blink/glance schedules are reproducible in tests.
  static func noise(_ index: Int) -> Double {
    let x = Double(index &+ 1) * 0.618_033_988_749_895
    return x - x.rounded(.down)
  }

  /// Eye openness with the blink envelope: cosine-eased close (0.12 s) then
  /// open (0.10 s), bottoming at 0.04 so a hairline slit always remains —
  /// cleaner than a full vanish at 26 pt. ~25% of cycles skip the blink.
  static func blinkOpenFraction(at t: TimeInterval) -> CGFloat {
    let cycle = Int(t / blinkCycle)
    if noise(cycle &* 31) < 0.25 { return 1 }
    let start = 0.2 + noise(cycle &* 17) * (blinkCycle - blinkDuration - 0.6)
    let local = t - Double(cycle) * blinkCycle - start
    guard local >= 0, local < blinkDuration else { return 1 }
    let closeDuration = 0.12
    let floorOpen = 0.04
    let open: Double
    if local < closeDuration {
      open = floorOpen + (1 - floorOpen) * 0.5 * (1 + cos(.pi * local / closeDuration))
    } else {
      open = floorOpen + (1 - floorOpen)
        * 0.5 * (1 - cos(.pi * (local - closeDuration) / (blinkDuration - closeDuration)))
    }
    return CGFloat(open)
  }

  /// Side-glance unit: cosine ramp in (0.2 s), hold (0.9 s), ramp out
  /// (0.2 s). ~35% of cycles skip; the side alternates pseudo-randomly.
  static func glanceUnit(at t: TimeInterval) -> CGFloat {
    let cycle = Int(t / glanceCycle)
    if noise(cycle &* 23) < 0.35 { return 0 }
    let side: Double = noise(cycle &* 13) < 0.5 ? -1 : 1
    let ramp = 0.2
    let hold = 0.9
    let total = ramp * 2 + hold
    let start = 0.4 + noise(cycle &* 29) * (glanceCycle - total - 0.4)
    let local = t - Double(cycle) * glanceCycle - start
    guard local >= 0, local < total else { return 0 }
    let unit: Double
    if local < ramp {
      unit = 0.5 * (1 - cos(.pi * local / ramp))
    } else if local < ramp + hold {
      unit = 1
    } else {
      unit = 0.5 * (1 + cos(.pi * (local - ramp - hold) / ramp))
    }
    return CGFloat(side * unit)
  }

  /// Simulated beat pulse in 0...1: a per-beat thump plus a half-tempo
  /// shimmer (layered sines, like `AudioVisualizer.barHeight`). Both terms
  /// are commensurate with the beat, so the whole curve has period
  /// `2 * 60 / beatBPM`.
  static func beatPulse(at t: TimeInterval) -> CGFloat {
    let beats = t * beatBPM / 60
    let frac = beats - beats.rounded(.down)
    let thump = pow(max(0, sin(.pi * frac)), 3)
    let shimmer = 0.5 + 0.5 * sin(.pi * beats + 0.7)
    return CGFloat(min(1, max(0, thump * 0.85 + 0.18 * shimmer)))
  }
}

// MARK: - View

/// The animated bot character shown in the collapsed island bar: a white
/// face and two solid-black slanted capsule eyes (Grok Bot style — roughly
/// 3:1 pills) that sway, lean into glances, blink, and ride the beat — no
/// mouth, no brows, no sleep mode, flat coloring. The tilt is the life of
/// it: perfectly upright eyes read as vacant, swaying ones read as curious.
struct CollapsedBotFaceView: View {
  /// Face diameter in points; the caller derives it from the bar height.
  let size: CGFloat
  /// Follows the selected quota vendor — white for Codex, Claude's
  /// terracotta, GLM's blue — so the character carries the chip's identity.
  var faceColor: Color = .white
  let isPlaying: Bool
  let isHovered: Bool
  /// false under Reduce Motion or while the surface is hidden — renders one
  /// static frame instead of subscribing to the 30 Hz timeline.
  let isAnimated: Bool

  static let eyeColor = Color(red: 0.090, green: 0.090, blue: 0.100)

  var body: some View {
    Group {
      if isAnimated {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
          face(CollapsedBotFace.expression(
            at: timeline.date.timeIntervalSinceReferenceDate,
            inputs: CollapsedBotFace.Inputs(isPlaying: isPlaying, isHovered: isHovered)))
        }
      } else {
        face(CollapsedBotFace.staticExpression(isPlaying: isPlaying))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)  // decorative; the container keeps its label
  }

  private func face(_ e: CollapsedBotFace.Expression) -> some View {
    let m = Metrics(size: size)
    return ZStack {
      Circle().fill(faceColor)
      eye(e, side: -1, m: m)
      eye(e, side: 1, m: m)
    }
    .scaleEffect(e.faceScale)
    .offset(y: e.faceOffsetYFraction * size)
  }

  private func eye(_ e: CollapsedBotFace.Expression, side: CGFloat, m: Metrics) -> some View {
    Capsule(style: .continuous)
      .fill(Self.eyeColor)
      .frame(width: m.eyeWidth, height: max(1, m.eyeHeight * e.eyeOpen))
      .rotationEffect(.radians(e.eyeTilt))
      .position(
        x: size / 2 + side * m.eyeCenterX + e.glanceX * m.glanceShift,
        y: m.eyeCenterY + e.lookY * m.lookLift)
  }

  /// All geometry as fractions of the face size, so one constant set works
  /// for the 26 pt notch face and the 24 pt pill face alike.
  private struct Metrics {
    let size: CGFloat
    /// Grok Bot proportions: a 3:1 vertical pill (their render script uses
    /// length 18 / width 5.2 ≈ 3.5:1; 3:1 holds up better at 24 pt).
    var eyeWidth: CGFloat { size * 0.14 }
    var eyeHeight: CGFloat { size * 0.346 }
    var eyeCenterX: CGFloat { size * 0.175 }
    var eyeCenterY: CGFloat { size * 0.48 }
    var glanceShift: CGFloat { size * 0.07 }
    var lookLift: CGFloat { size * 0.08 }
  }
}
