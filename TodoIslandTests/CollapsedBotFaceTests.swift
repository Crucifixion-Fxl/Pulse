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

  func testAwakeExpressionStaysWithinDesignBounds() {
    sweep(inputs: CollapsedBotFace.Inputs(isPlaying: true, isHovered: false)) { _, e in
      XCTAssertTrue((0.03...1.0).contains(e.eyeOpen), "eyeOpen \(e.eyeOpen)")
      XCTAssertTrue((0.99...1.04).contains(e.faceScale), "faceScale \(e.faceScale)")
      XCTAssertTrue(abs(e.faceOffsetYFraction) <= 0.035, "offset \(e.faceOffsetYFraction)")
      XCTAssertTrue((-1.0...1.0).contains(e.glanceX), "glanceX \(e.glanceX)")
    }
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

  func testDozingSquintsAndNeverBlinksOrGlances() {
    sweep(inputs: CollapsedBotFace.Inputs(isPlaying: false, isHovered: false)) { _, e in
      XCTAssertEqual(e.eyeOpen, 0.3)
      XCTAssertEqual(e.glanceX, 0)
      XCTAssertEqual(e.lookY, 0)
    }
  }

  func testDozingBreathesDeeperThanAwake() {
    func peakToPeak(_ inputs: CollapsedBotFace.Inputs) -> CGFloat {
      var min: CGFloat = .infinity
      var max: CGFloat = -.infinity
      sweep(from: 0, to: 10, step: 0.05, inputs: inputs) { _, e in
        min = Swift.min(min, e.faceOffsetYFraction)
        max = Swift.max(max, e.faceOffsetYFraction)
      }
      return max - min
    }
    let dozing = peakToPeak(CollapsedBotFace.Inputs(isPlaying: false, isHovered: false))
    let awake = peakToPeak(CollapsedBotFace.Inputs(isPlaying: true, isHovered: false))
    XCTAssertGreaterThan(dozing, awake * 2)
  }

  func testHoverOverridesIdleMotion() {
    for isPlaying in [false, true] {
      sweep(inputs: CollapsedBotFace.Inputs(isPlaying: isPlaying, isHovered: true)) { _, e in
        XCTAssertEqual(e.eyeOpen, 1.25)
        XCTAssertEqual(e.lookY, -0.8)
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
    }
  }
}
