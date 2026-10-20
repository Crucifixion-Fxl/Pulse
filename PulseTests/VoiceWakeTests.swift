import AppKit
import XCTest
@testable import Pulse

@MainActor
final class VoiceWakeTests: XCTestCase {
  func testVoiceEnvelopeAttacksQuicklyAndReleasesWithoutMovingCoreOrParticles() throws {
    let view = BlackHoleWakeView(size: CGSize(width: 340, height: 32), radius: 18, reduceMotion: false)
    view.awaken()
    let core = view.coreFrame
    let bounds = view.bounds
    let width = view.presentedWidth
    view.setVoiceLevel(input: 1, output: 0)
    let attack = view.voiceEnergy
    XCTAssertGreaterThan(attack, 0.4)
    XCTAssertLessThan(attack, 0.6)
    view.setVoiceLevel(input: 0, output: 0)
    XCTAssertGreaterThan(view.voiceEnergy, attack * 0.8, "Decay should not snap to silence")
    for _ in 0..<60 { view.setVoiceLevel(input: 0, output: 0) }
    XCTAssertLessThan(view.voiceEnergy, 0.002)
    view.setVoiceLevel(input: 0, output: 1)
    XCTAssertGreaterThan(view.voiceEnergy, 0.4, "Actual speaker output must drive the same rim")
    XCTAssertEqual(view.coreFrame, core)
    XCTAssertEqual(view.bounds, bounds)
    XCTAssertEqual(view.presentedWidth, width)
  }

  func testMalformedAudioLevelsNeverReachCoreAnimation() {
    XCTAssertEqual(XiaozhiVoiceSession.clamp(.nan), 0)
    XCTAssertEqual(XiaozhiVoiceSession.clamp(.infinity), 0)
    XCTAssertEqual(XiaozhiVoiceSession.clamp(-1), 0)
    XCTAssertEqual(XiaozhiVoiceSession.clamp(3), 1)
    let view = BlackHoleWakeView(size: CGSize(width: 340, height: 32), radius: 18, reduceMotion: true)
    view.setVoiceLevel(input: .nan, output: .infinity)
    XCTAssertEqual(view.voiceEnergy, 0)
  }

  func testStateAndErrorHaveVisibleAccessibleFeedback() {
    let view = BlackHoleWakeView(size: CGSize(width: 340, height: 32), radius: 18, reduceMotion: false)
    view.setVoiceState(.listening)
    XCTAssertTrue(view.accessibilityLabel()?.contains("Esc") == true)
    view.setVoiceError("microphone")
    XCTAssertEqual(view.accessibilityLabel(), L10n.text("voice.error.microphone"))
  }
}
