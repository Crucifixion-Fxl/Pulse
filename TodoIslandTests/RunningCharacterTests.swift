import AppKit
import QuartzCore
import XCTest
@testable import TodoIsland

@MainActor
final class RunningCharacterTests: XCTestCase {
  func testAtlasExtractsOnlyRightRunningRowAndRejectsInvalidData() throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 768, height: 832,
      bitsPerComponent: 8, bytesPerRow: 768 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.red.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 768, height: 832))
    // Quartz draws from the bottom; atlas row 1 is 104 pixels from the top.
    context.setFillColor(NSColor.green.cgColor)
    context.fill(CGRect(x: 0, y: 624, width: 768, height: 104))
    let frames = try RunnerArtwork.runningFrames(in: XCTUnwrap(context.makeImage()))
    XCTAssertEqual(frames.count, 8)
    for frame in frames {
      XCTAssertEqual(frame.width, 96)
      XCTAssertEqual(frame.height, 104)
      let bitmap = NSBitmapImageRep(cgImage: frame)
      let color = try XCTUnwrap(bitmap.colorAt(x: 48, y: 52)?.usingColorSpace(.deviceRGB))
      XCTAssertGreaterThan(color.greenComponent, 0.9)
      XCTAssertLessThan(color.redComponent, 0.1)
    }
    XCTAssertThrowsError(try RunnerArtwork.verifiedFrames(Data("invalid image".utf8)))
    XCTAssertThrowsError(try RunnerArtwork.runningFrames(in: frames[0]))
  }

  func testNativeAnimationLoopsEveryFrameAndStopsWhenInactiveOrDetached() throws {
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: 768, height: 832,
      bitsPerComponent: 8, bytesPerRow: 768 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let frames = try RunnerArtwork.runningFrames(in: XCTUnwrap(bitmap.makeImage()))
    let view = RunnerSpriteView(frame: NSRect(x: 0, y: 0, width: 52, height: 32))
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    view.update(frames: frames, isPlaying: true)
    let animation = try XCTUnwrap(view.sprite.animation(forKey: "run") as? CAKeyframeAnimation)
    XCTAssertEqual(animation.duration, 0.8, accuracy: 0.001)
    XCTAssertEqual(animation.calculationMode, .discrete)
    XCTAssertEqual(animation.values?.count, 9, "Include the closing frame so all eight poses get equal time")
    XCTAssertEqual(animation.keyTimes, (0...8).map { NSNumber(value: Double($0) / 8) })
    XCTAssertEqual(animation.repeatCount, .infinity)
    view.update(frames: frames, isPlaying: false)
    XCTAssertNil(view.sprite.animation(forKey: "run"), "Collapsed and Reduce Motion must stop playback")
    XCTAssertNotNil(view.sprite.contents, "Reduce Motion retains a still character")
    view.update(frames: frames, isPlaying: true)
    XCTAssertNotNil(view.sprite.animation(forKey: "run"))
    view.removeFromSuperview()
    XCTAssertNil(view.sprite.animation(forKey: "run"))
  }

  func testRunnerStaysBetweenNotchAndWeatherAndFadesWithHeader() {
    let runner = NSView()
    let weather = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: NSView(), additionalQuotas: NSView(),
      weather: weather, runner: runner, barHeight: 32)
    header.settle(size: CGSize(width: 760, height: 360), state: .pinned)
    XCTAssertGreaterThan(runner.frame.minX, 480)
    XCTAssertLessThan(runner.frame.maxX, weather.frame.minX)
    XCTAssertEqual(runner.layer?.opacity, 1)
    XCTAssertEqual(runner.frame.height, 32)
    header.settle(size: CGSize(width: 340, height: 32), state: .collapsed)
    XCTAssertEqual(runner.layer?.opacity, 0)
    header.settle(size: CGSize(width: 760, height: 360), state: .pinned)
    XCTAssertEqual(runner.layer?.opacity, 1)
  }
}
