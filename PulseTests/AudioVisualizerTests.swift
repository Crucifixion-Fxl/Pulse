import XCTest

@testable import Pulse

final class AudioVisualizerTests: XCTestCase {
  @MainActor
  func testPlaybackPauseAndReduceMotionControlCompositorAnimations() throws {
    let view = AudioVisualizerView(frame: CGRect(x: 0, y: 0, width: 500, height: 140))
    view.configure(isPlaying: true, reduceMotion: false)
    view.layout()
    XCTAssertEqual(view.bars.count, 24)
    for bar in view.bars {
      let animation = try XCTUnwrap(bar.animation(forKey: AudioVisualizerView.animationKey))
      XCTAssertEqual(animation.duration, AudioVisualizerView.period)
      XCTAssertEqual(animation.repeatCount, .infinity)
      XCTAssertEqual(bar.position.y, 70)
    }

    view.configure(isPlaying: false, reduceMotion: false)
    view.layout()
    for (index, bar) in view.bars.enumerated() {
      XCTAssertNil(bar.animation(forKey: AudioVisualizerView.animationKey))
      XCTAssertEqual(bar.bounds.height, 6 + CGFloat(index % 5) * 2)
      XCTAssertEqual(bar.cornerRadius, min(bar.bounds.width, bar.bounds.height) / 2)
    }

    view.configure(isPlaying: true, reduceMotion: true)
    view.layout()
    XCTAssertTrue(view.bars.allSatisfy { $0.animationKeys()?.isEmpty != false })

    view.configure(isPlaying: true, reduceMotion: false)
    view.layout()
    XCTAssertTrue(
      view.bars.allSatisfy { $0.animation(forKey: AudioVisualizerView.animationKey) != nil })
  }

  @MainActor
  func testUnchangedUpdatesDoNotRestartAnimationsAndResizeRepositionsBars() throws {
    let view = AudioVisualizerView(frame: CGRect(x: 0, y: 0, width: 500, height: 140))
    view.configure(isPlaying: true, reduceMotion: false)
    view.layout()
    let first = try XCTUnwrap(view.bars[0].animation(forKey: AudioVisualizerView.animationKey))
    view.configure(isPlaying: true, reduceMotion: false)
    view.layout()
    XCTAssertEqual(
      view.bars[0].animation(forKey: AudioVisualizerView.animationKey)?.beginTime, first.beginTime)
    view.setFrameSize(CGSize(width: 236, height: 100))
    view.layout()
    XCTAssertEqual(view.bars[0].frame.minX, 0, accuracy: 0.001)
    XCTAssertEqual(try XCTUnwrap(view.bars.last).frame.maxX, 236, accuracy: 0.001)
    XCTAssertTrue(view.bars.allSatisfy { $0.position.y == 50 })
  }

  @MainActor
  func testLoopAndInterpolationPreserveOriginalWaveform() {
    for index in 0..<24 {
      let values = AudioVisualizerView.heightSamples[index]
      XCTAssertEqual(values.first!, values.last!, accuracy: 0.000001, "No jump at loop boundary")
      for frame in 0..<AudioVisualizerView.sampleCount {
        let t =
          (Double(frame) + 0.5) / Double(AudioVisualizerView.sampleCount)
          * AudioVisualizerView.period
        let base = sin(t * 2.2 + Double(index) * 0.55) * 0.5 + 0.5
        let detail = sin(t * 5.1 + Double(index) * 1.3) * 0.5 + 0.5
        let envelope = sin(Double(index) / 24 * .pi)
        let expected = max(5, (base * 0.55 + detail * 0.3 + envelope * 0.15) * 90)
        XCTAssertEqual((values[frame] + values[frame + 1]) / 2, expected, accuracy: 0.6)
      }
    }
  }
}
