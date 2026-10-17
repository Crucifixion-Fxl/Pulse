import AppKit
import XCTest

@testable import TodoIsland

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
  func testAwakeSurfaceIsOpaqueBlackWithOnlyMonochromeStars() throws {
    let view = BlackHoleWakeView(size: CGSize(width: 340, height: 32), radius: 18, reduceMotion: true)
    view.begin()
    view.awaken()
    let width = Int(ceil(view.bounds.width))
    let height = Int(ceil(view.bounds.height))
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    try XCTUnwrap(view.layer).render(in: context)
    let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    var black = 0
    var stars = 0
    // Exclude only the rounded corners, not a transparent effects margin.
    for y in 8..<(height - 8) {
      for x in 24..<(width - 24) {
        let offset = (y * width + x) * 4
        XCTAssertEqual(pixels[offset + 3], 255, "The entire interior must be opaque")
        XCTAssertEqual(pixels[offset], pixels[offset + 1], "No colored light")
        XCTAssertEqual(pixels[offset + 1], pixels[offset + 2])
        if pixels[offset] < 8 { black += 1 } else { stars += 1 }
      }
    }
    XCTAssertGreaterThan(black, (height - 16) * (width - 48) * 9 / 10)
    XCTAssertGreaterThan(stars, 20, "The black surface must contain visible star points")
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

  func testReduceMotionOmitsContinuousParticleAndOrbitAnimations() async throws {
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
    let shortcut = AIWakeShortcut()
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
    try await Task.sleep(for: .milliseconds(160))
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
