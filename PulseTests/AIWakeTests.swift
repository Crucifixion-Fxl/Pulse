import AppKit
import XCTest

@testable import Pulse

final class AIWakeGestureTests: XCTestCase {
  func testShortPressCancelsButAFullHoldStaysAwakeAfterRelease() {
    var gesture = AIWakeGesture()
    gesture.press(at: 10)
    gesture.release(at: 10.3)
    XCTAssertEqual(gesture.phase, .idle)
    gesture.press(at: 20)
    gesture.advance(to: 20.69)
    XCTAssertEqual(gesture.phase, .charging)
    gesture.advance(to: 20.71)
    XCTAssertEqual(gesture.phase, .awake)
    gesture.release(at: 21)
    XCTAssertEqual(gesture.phase, .awake)
    gesture.press(at: 22)
    XCTAssertEqual(gesture.phase, .idle, "A second press exits without a new charge")
  }

  func testReleaseAtThresholdWorksEvenIfMainRunLoopTimerWasDelayed() {
    var gesture = AIWakeGesture()
    gesture.press(at: 0)
    gesture.release(at: 0.71)
    XCTAssertEqual(gesture.phase, .awake)
    XCTAssertFalse(gesture.isHeld)
  }

  func testRepeatAndCancelCannotRestartHeldKey() {
    var gesture = AIWakeGesture()
    gesture.press(at: 0)
    gesture.press(at: 0.5)
    gesture.advance(to: 0.71)
    XCTAssertEqual(gesture.phase, .awake, "Repeat must not reset the hold deadline")
    gesture.cancel()
    gesture.press(at: 1)
    gesture.advance(to: 2)
    XCTAssertEqual(gesture.phase, .idle)
    gesture.release(at: 2)
    gesture.press(at: 3)
    XCTAssertEqual(gesture.phase, .charging)
  }

  func testSleepResetAllowsNextPressWithoutStaleKeyUp() {
    var gesture = AIWakeGesture()
    gesture.press(at: 0)
    gesture.reset()
    gesture.press(at: 3)
    gesture.advance(to: 4)
    XCTAssertEqual(gesture.phase, .awake)
  }
}

@MainActor
final class BlackHoleWakeViewTests: XCTestCase {
  func testBlackCoreHasDenseMonochromeParticlesOutsideAndFeatheredEdges() throws {
    let view = BlackHoleWakeView(size: CGSize(width: 340, height: 32), radius: 18, reduceMotion: true)
    view.begin()
    view.awaken()
    let width = Int(ceil(view.bounds.width))
    let height = Int(ceil(view.bounds.height))
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    // Match AppKit's flipped view coordinates when rendering offscreen.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    try XCTUnwrap(view.layer).render(in: context)
    let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let core = view.coreFrame
    for y in 8..<(Int(core.height) - 8) {
      for x in (Int(core.minX) + 24)..<(Int(core.maxX) - 24) {
        let offset = (y * width + x) * 4
        XCTAssertEqual(pixels[offset + 3], 255, "The center must remain opaque")
        XCTAssertEqual(pixels[offset], 0, "The core stays empty and deep black")
        XCTAssertEqual(pixels[offset + 1], 0)
        XCTAssertEqual(pixels[offset + 2], 0)
      }
    }
    var externalSpecks = 0
    var whiteRimPixels = 0
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        XCTAssertEqual(pixels[offset], pixels[offset + 1], "Particles must remain monochrome")
        XCTAssertEqual(pixels[offset + 1], pixels[offset + 2])
        if y > Int(core.maxY), pixels[offset] > 20 { externalSpecks += 1 }
        if y > Int(core.maxY) + 50 {
          XCTAssertLessThanOrEqual(pixels[offset], 1, "No detached particles below the surrounding band")
        }
        if x > Int(core.minX) + 30, x < Int(core.maxX) - 30,
          y >= Int(core.maxY), y < Int(core.maxY) + 35 {
          XCTAssertGreaterThan(pixels[offset + 3], 210, "Dark atmosphere must cover the full particle band")
          if y <= Int(core.maxY) + 2, pixels[offset] > 60 { whiteRimPixels += 1 }
        }
        if x < 2 || x >= width - 2 || y >= height - 2 {
          XCTAssertLessThanOrEqual(pixels[offset + 3], 2, "The cloud must fade out before the panel edge at \(x),\(y)")
        }
      }
    }
    XCTAssertGreaterThan(whiteRimPixels, 100, "A soft white rim must follow the lower silhouette")
    XCTAssertGreaterThan(externalSpecks, 500, "Reference calls for a dense external cloud, not a few stars")
  }

  func testUnfoldAndInterruptedReturnKeepWindowFixedAndNeverRetractAtStart() async throws {
    let original = CGSize(width: 340, height: 32)
    let view = BlackHoleWakeView(size: original, radius: 18, reduceMotion: false)
    let panel = IslandPanel()
    panel.setFrame(CGRect(origin: CGPoint(x: 400, y: 600), size: view.bounds.size), display: false)
    panel.contentView = view
    panel.orderFrontRegardless()
    defer { panel.close() }
    try await Task.sleep(for: .milliseconds(40))
    let frame = panel.frame
    XCTAssertGreaterThan(frame.width, original.width)
    XCTAssertGreaterThan(frame.height, original.height)
    XCTAssertEqual(view.presentedWidth, original.width, accuracy: 0.5)
    view.begin()
    var previous = original.width
    for _ in 0..<12 {
      try await Task.sleep(for: .milliseconds(16))
      let width = view.presentedWidth
      XCTAssertGreaterThanOrEqual(width, previous - 0.5)
      XCTAssertLessThanOrEqual(width, view.awakenedWidth + 0.5)
      XCTAssertEqual(panel.frame, frame, "Animation must never resize the native window per frame")
      previous = width
    }
    XCTAssertGreaterThan(previous, original.width + 10)
    view.dismiss()
    XCTAssertEqual(view.presentedWidth, previous, accuracy: 3,
      "Reversal must begin at the presented width, not the original or final width")
    try await Task.sleep(for: .milliseconds(480))
    XCTAssertEqual(view.presentedWidth, original.width, accuracy: 0.5)
    XCTAssertEqual(panel.frame, frame)
  }

  func testDarkHaloNeverDropsOutDuringChargeAndAwakening() async throws {
    let view = BlackHoleWakeView(size: CGSize(width: 340, height: 32), radius: 18, reduceMotion: false)
    let panel = IslandPanel()
    panel.setFrame(CGRect(origin: CGPoint(x: 400, y: 600), size: view.bounds.size), display: false)
    panel.contentView = view
    panel.orderFrontRegardless()
    defer { panel.close() }
    // The first raster is the dark atmosphere, beneath the dust and white rim.
    func atmosphere(in layer: CALayer) -> CALayer? {
      if layer.contents != nil { return layer }
      return layer.sublayers?.compactMap { atmosphere(in: $0) }.first
    }
    let halo = try XCTUnwrap(atmosphere(in: XCTUnwrap(view.layer)))
    func presentedOpacity() -> Float {
      var opacity: Float = 1
      var node: CALayer? = halo
      while let layer = node {
        opacity *= (layer.presentation() ?? layer).opacity
        node = layer.superlayer
      }
      return opacity
    }
    try await Task.sleep(for: .milliseconds(40))
    view.begin()
    var previous: Float = 0
    for sample in 0..<100 {
      try await Task.sleep(for: .milliseconds(20))
      if sample == 34 { view.awaken() }
      let opacity = presentedOpacity()
      XCTAssertGreaterThanOrEqual(opacity, previous - 0.025,
        "The black halo must reveal continuously, never blink off or pulse with particles (sample \(sample))")
      previous = opacity
    }
    XCTAssertGreaterThan(previous, 0.99)
    view.dismiss()
    for _ in 0..<25 {
      try await Task.sleep(for: .milliseconds(20))
      let opacity = presentedOpacity()
      XCTAssertLessThanOrEqual(opacity, previous + 0.025, "Dismissal must fade out without a second reveal")
      previous = opacity
    }
    XCTAssertLessThan(previous, 0.01)
  }

  func testReduceMotionOmitsContinuousParticleAnimations() async throws {
    let view = BlackHoleWakeView(size: CGSize(width: 340, height: 32), radius: 18, reduceMotion: true)
    view.begin()
    view.awaken()
    func repeatingAnimations(in layer: CALayer) -> Int {
      let own = (layer.animationKeys() ?? []).filter {
        (layer.animation(forKey: $0)?.repeatCount ?? 0) > 1
      }.count
      return own + (layer.sublayers ?? []).reduce(0) { $0 + repeatingAnimations(in: $1) }
    }
    XCTAssertEqual(repeatingAnimations(in: try XCTUnwrap(view.layer)), 0)
  }
}

@MainActor
final class AIWakeShortcutTests: XCTestCase {
  func testShortSpaceTypesOnceAndLongSpaceNeverLeaksRepeatsIntoEditor() async throws {
    let panel = IslandPanel()
    panel.acceptsKeyInput = true
    panel.setFrame(CGRect(x: 200, y: 300, width: 300, height: 80), display: false)
    let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 80))
    panel.contentView = editor
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(editor)
    defer { panel.close() }
    // Synthetic local events must not mix with the user's physical keyboard.
    let shortcut = AIWakeShortcut(registerGlobally: false)
    var starts = 0
    var releases = 0
    shortcut.onPress = { starts += 1 }
    shortcut.onRelease = { releases += 1 }
    func send(_ type: NSEvent.EventType, repeatKey: Bool = false) {
      let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
        context: nil, characters: " ", charactersIgnoringModifiers: " ",
        isARepeat: repeatKey, keyCode: 49)!
      NSApp.sendEvent(event)
    }
    send(.keyDown)
    send(.keyUp)
    XCTAssertEqual(editor.string, " ")
    XCTAssertEqual(starts, 0, "An ordinary space must not flash the wake UI")
    send(.keyDown)
    let chargeDeadline = ContinuousClock.now + .milliseconds(500)
    while starts == 0, ContinuousClock.now < chargeDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(starts, 1, "The intent timer must begin the incomplete charge")
    send(.keyUp)
    XCTAssertEqual(editor.string, "  ", "Releasing an incomplete charge must still type a normal space")
    send(.keyDown)
    try await Task.sleep(for: .milliseconds(900))
    for _ in 0..<8 { send(.keyDown, repeatKey: true) }
    send(.keyUp)
    XCTAssertEqual(starts, 2)
    XCTAssertEqual(releases, 2)
    XCTAssertEqual(editor.string, "  ", "Holding Space must not type a row of spaces")
    withExtendedLifetime(shortcut) {}
  }
}
