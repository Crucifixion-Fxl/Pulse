import XCTest

@testable import TodoIsland

/// Pure-function tests for the collapsed-island bot face schedule, in the
/// `IslandStateTests` / `DisplayGeometryTests` tradition: the calculator is
/// stateless, so every claim is reproducible from (time, inputs) alone.
final class CollapsedBotFaceTests: XCTestCase {
  private func sweep(
    from start: Double = 0,
    to end: Double = 120,
    step: Double = 0.037,
    inputs: CollapsedBotFace.Inputs,
    body: (Double, CollapsedBotFace.Expression) -> Void
  ) {
    var t = start
    while t < end {
      body(t, CollapsedBotFace.expression(at: t, inputs: inputs))
      t += step
    }
  }

  func testExpressionStaysWithinDesignBounds() {
    for isPlaying in [false, true] {
      sweep(inputs: CollapsedBotFace.Inputs(isPlaying: isPlaying, isHovered: false)) { _, e in
        XCTAssertTrue((0.03...1.0).contains(e.eyeOpen), "eyeOpen \(e.eyeOpen)")
        XCTAssertTrue((0.98...1.045).contains(e.faceScale), "faceScale \(e.faceScale)")
        XCTAssertTrue(abs(e.faceOffsetYFraction) <= 0.035, "offset \(e.faceOffsetYFraction)")
        XCTAssertTrue((-1.0...1.0).contains(e.glanceX), "glanceX \(e.glanceX)")
        XCTAssertTrue(abs(e.eyeTilt) <= 0.16, "eyeTilt \(e.eyeTilt)")
      }
    }
  }

  func testEyesSwayRatherThanSitUpright() {
    // The Grok Bot tilt: over time the tilt takes both signs and covers a
    // meaningful swing — a permanently near-zero tilt is the "vacant"
    // look this replaces.
    var minTilt: CGFloat = .infinity
    var maxTilt: CGFloat = -.infinity
    sweep(from: 0, to: 12, step: 0.05, inputs: CollapsedBotFace.Inputs(isPlaying: false, isHovered: false)) { _, e in
      minTilt = Swift.min(minTilt, e.eyeTilt)
      maxTilt = Swift.max(maxTilt, e.eyeTilt)
    }
    XCTAssertLessThan(minTilt, -0.08)
    XCTAssertGreaterThan(maxTilt, 0.08)
  }

  func testBlinkHappensButIsRare() {
    var blinked = 0
    var samples = 0
    sweep(inputs: CollapsedBotFace.Inputs(isPlaying: true, isHovered: false)) { _, e in
      samples += 1
      if e.eyeOpen < 0.5 { blinked += 1 }
    }
    XCTAssertGreaterThan(blinked, 0, "no blink observed across two minutes")
    let fraction = Double(blinked) / Double(samples)
    XCTAssertTrue((0.01...0.08).contains(fraction), "blink fraction \(fraction)")
  }

  func testBlinkScheduleIsDeterministic() {
    for t in stride(from: 0.0, to: 60, by: 0.731) {
      XCTAssertEqual(
        CollapsedBotFace.blinkOpenFraction(at: t),
        CollapsedBotFace.blinkOpenFraction(at: t))
    }
    // A known cycle: same inputs, same envelope, on every call and launch.
    let cycle = 7
    let start = 0.2 + CollapsedBotFace.noise(cycle &* 17)
      * (CollapsedBotFace.blinkCycle - CollapsedBotFace.blinkDuration - 0.6)
    let tMid = Double(cycle) * CollapsedBotFace.blinkCycle + start + 0.06
    let open = CollapsedBotFace.blinkOpenFraction(at: tMid)
    XCTAssertLessThan(open, 1.0, "expected the cycle-7 blink to be underway at \(tMid)")
    XCTAssertEqual(open, CollapsedBotFace.blinkOpenFraction(at: tMid), accuracy: 1e-12)
  }

  func testPausedStaysAwakeAndAnimated() {
    // No sleep mode: with music off the eyes hold full size apart from
    // blinks, and glances still happen.
    var sawBlink = false
    var sawGlance = false
    sweep(inputs: CollapsedBotFace.Inputs(isPlaying: false, isHovered: false)) { _, e in
      if e.eyeOpen < 0.5 { sawBlink = true }
      if e.glanceX != 0 { sawGlance = true }
    }
    XCTAssertTrue(sawBlink, "paused face never blinked")
    XCTAssertTrue(sawGlance, "paused face never glanced")
  }

  func testPlaybackAddsBeatBounce() {
    func peakToPeak(_ inputs: CollapsedBotFace.Inputs) -> CGFloat {
      var min: CGFloat = .infinity
      var max: CGFloat = -.infinity
      sweep(from: 0, to: 10, step: 0.05, inputs: inputs) { _, e in
        min = Swift.min(min, e.faceScale)
        max = Swift.max(max, e.faceScale)
      }
      return max - min
    }
    let playing = peakToPeak(CollapsedBotFace.Inputs(isPlaying: true, isHovered: false))
    let paused = peakToPeak(CollapsedBotFace.Inputs(isPlaying: false, isHovered: false))
    XCTAssertGreaterThan(playing, paused * 2)
  }

  func testHoverOverridesIdleMotion() {
    for isPlaying in [false, true] {
      sweep(inputs: CollapsedBotFace.Inputs(isPlaying: isPlaying, isHovered: true)) { _, e in
        XCTAssertEqual(e.eyeOpen, 1.25)
        XCTAssertEqual(e.lookY, -0.8)
        XCTAssertEqual(e.eyeTilt, 0)
        XCTAssertEqual(e.faceScale, 1)
        XCTAssertEqual(e.faceOffsetYFraction, 0)
        XCTAssertEqual(e.glanceX, 0)
      }
    }
  }

  func testBeatPulseIsPeriodicAndBounded() {
    for t in stride(from: 0.0, to: 20, by: 1.37) {
      let value = CollapsedBotFace.beatPulse(at: t)
      XCTAssertTrue((0...1).contains(value), "beat \(value)")
      XCTAssertEqual(
        value,
        CollapsedBotFace.beatPulse(at: t + 2 * 60 / CollapsedBotFace.beatBPM),
        accuracy: 1e-9)
    }
    // The thump must actually reach near 1 somewhere in a beat.
    var maxValue: CGFloat = 0
    for t in stride(from: 0.0, to: 60 / CollapsedBotFace.beatBPM, by: 0.005) {
      maxValue = Swift.max(maxValue, CollapsedBotFace.beatPulse(at: t))
    }
    XCTAssertGreaterThan(maxValue, 0.7)
  }

  func testNoiseIsDeterministicAndInRange() {
    for n in 0..<1000 {
      let value = CollapsedBotFace.noise(n)
      XCTAssertTrue((0..<1).contains(value), "noise(\(n)) = \(value)")
      XCTAssertEqual(value, CollapsedBotFace.noise(n))
    }
    XCTAssertNotEqual(CollapsedBotFace.noise(1), CollapsedBotFace.noise(2))
  }

  func testStaticExpressionIsMotionless() {
    for isPlaying in [false, true] {
      let e = CollapsedBotFace.staticExpression(isPlaying: isPlaying)
      XCTAssertEqual(e.eyeOpen, 1)
      XCTAssertEqual(e.faceScale, 1)
      XCTAssertEqual(e.faceOffsetYFraction, 0)
      XCTAssertEqual(e.glanceX, 0)
      XCTAssertEqual(e.lookY, 0)
      // A touch of resting tilt keeps even the static frame from staring.
      XCTAssertEqual(e.eyeTilt, 0.06)
    }
  }

  // MARK: - Alert flood

  func testAlertEnvelopeEndpointsAndMonotonicity() {
    // Engaging: 0 at the flip, 1 once the rise has settled.
    XCTAssertEqual(CollapsedBotFace.alertUnit(elapsed: 0, engaging: true), 0)
    XCTAssertEqual(CollapsedBotFace.alertUnit(elapsed: 99, engaging: true), 1)
    // Draining: starts full, ends clean.
    XCTAssertEqual(CollapsedBotFace.alertUnit(elapsed: 0, engaging: false), 1)
    XCTAssertEqual(CollapsedBotFace.alertUnit(elapsed: 99, engaging: false), 0)
    // Negative elapsed (anchor fractionally after the timeline tick) clamps.
    XCTAssertEqual(CollapsedBotFace.alertUnit(elapsed: -0.4, engaging: true), 0)
    XCTAssertEqual(CollapsedBotFace.alertUnit(elapsed: -0.4, engaging: false), 1)

    var prev: CGFloat = -1
    // Sweeps run past the duration: float step accumulation can skip the
    // exact endpoint, and clamped values past it keep the monotonicity
    // claim honest.
    for t in stride(from: 0.0, through: CollapsedBotFace.alertRiseDuration + 0.2, by: 0.04) {
      let u = CollapsedBotFace.alertUnit(elapsed: t, engaging: true)
      XCTAssertTrue((0...1).contains(u), "rise \(t): \(u)")
      XCTAssertGreaterThanOrEqual(u, prev)
      prev = u
    }
    XCTAssertEqual(prev, 1, accuracy: 0.001, "rise must complete")

    prev = 2
    for t in stride(from: 0.0, through: CollapsedBotFace.alertFallDuration + 0.2, by: 0.04) {
      let u = CollapsedBotFace.alertUnit(elapsed: t, engaging: false)
      XCTAssertTrue((0...1).contains(u), "drain \(t): \(u)")
      XCTAssertLessThanOrEqual(u, prev)
      prev = u
    }
    XCTAssertEqual(prev, 0, accuracy: 0.001, "drain must complete")
  }

  func testFullAlertScowlsNarrowsAndSettles() {
    let mad = CollapsedBotFace.Inputs(isPlaying: true, isHovered: false, alertUnit: 1)
    sweep(inputs: mad) { _, e in
      XCTAssertEqual(e.angryTilt, CollapsedBotFace.alertEyeTilt)
      // Narrowed to 70% of the calm eyes (blink slit included), scowl
      // tilt dominates the sway, and the beat bounce is damped out.
      XCTAssertTrue((0.027...0.72).contains(e.eyeOpen), "eyeOpen \(e.eyeOpen)")
      XCTAssertTrue(
        abs(e.eyeTilt) <= 0.16 * 0.5 + 0.001, "sway not quieted: \(e.eyeTilt)")
      XCTAssertTrue((0.9965...1.014).contains(e.faceScale), "faceScale \(e.faceScale)")
    }
  }

  func testAlertBlendsSmoothlyFromCalm() {
    // At every blend level the scowl stays bounded; halfway the eyes are
    // already leaning and narrowing.
    let calm = CollapsedBotFace.Inputs(isPlaying: false, isHovered: false)
    let half = CollapsedBotFace.Inputs(isPlaying: false, isHovered: false, alertUnit: 0.5)
    var calmMaxOpen: CGFloat = 0
    sweep(inputs: calm) { _, e in calmMaxOpen = Swift.max(calmMaxOpen, e.eyeOpen) }
    var halfMaxOpen: CGFloat = 0
    var halfMaxTilt: CGFloat = 0
    sweep(inputs: half) { _, e in
      halfMaxOpen = Swift.max(halfMaxOpen, e.eyeOpen)
      halfMaxTilt = Swift.max(halfMaxTilt, e.angryTilt)
    }
    XCTAssertEqual(halfMaxOpen, calmMaxOpen * 0.85, accuracy: 1e-9)
    XCTAssertEqual(halfMaxTilt, CollapsedBotFace.alertEyeTilt * 0.5, accuracy: 1e-9)
  }

  func testZeroAlertLeavesExpressionUntouched() {
    // The blend must be the identity at 0 — the calm face is byte-for-byte
    // what it was before the alert state existed.
    for t in stride(from: 0.0, to: 20, by: 0.317) {
      XCTAssertEqual(
        CollapsedBotFace.expression(
          at: t, inputs: CollapsedBotFace.Inputs(isPlaying: true, isHovered: false, alertUnit: 0)),
        CollapsedBotFace.expression(
          at: t, inputs: CollapsedBotFace.Inputs(isPlaying: true, isHovered: false)))
      XCTAssertEqual(
        CollapsedBotFace.expression(
          at: t, inputs: CollapsedBotFace.Inputs(isPlaying: false, isHovered: true, alertUnit: 0)),
        CollapsedBotFace.expression(
          at: t, inputs: CollapsedBotFace.Inputs(isPlaying: false, isHovered: true)))
    }
  }

  func testStaticAlertFrameScowlsFully() {
    let e = CollapsedBotFace.staticExpression(isPlaying: false, alert: true)
    XCTAssertEqual(e.angryTilt, CollapsedBotFace.alertEyeTilt)
    XCTAssertEqual(e.eyeOpen, 0.7, accuracy: 1e-9)
    XCTAssertEqual(e.eyeTilt, 0.06 * 0.5, accuracy: 1e-9)
    // Without alert the static frame is exactly the legacy one.
    XCTAssertEqual(
      CollapsedBotFace.staticExpression(isPlaying: false, alert: false).angryTilt, 0)
  }
}
