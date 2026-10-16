import AppKit
import QuartzCore
import SwiftUI

struct RunningCharacterView: View {
  @ObservedObject var store: RunnerArtworkStore
  let isActive: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    RunnerSprite(frames: store.frames, isPlaying: isActive && !reduceMotion)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .task(id: isActive) {
        if isActive { await store.loadIfNeeded() }
      }
  }
}

private struct RunnerSprite: NSViewRepresentable {
  let frames: [CGImage]
  let isPlaying: Bool

  func makeNSView(context: Context) -> RunnerSpriteView { RunnerSpriteView() }

  func updateNSView(_ view: RunnerSpriteView, context: Context) {
    view.update(frames: frames, isPlaying: isPlaying)
  }

  static func dismantleNSView(_ view: RunnerSpriteView, coordinator: ()) {
    view.update(frames: [], isPlaying: false)
  }
}

/// Core Animation advances the decoded frames without a SwiftUI timer or
/// per-frame layout. Unrelated quota/weather updates never restart the run.
@MainActor
final class RunnerSpriteView: NSView {
  let sprite = CALayer()
  private var frames: [CGImage] = []
  private var shouldPlay = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    sprite.contentsGravity = .resizeAspect
    sprite.magnificationFilter = .linear
    sprite.minificationFilter = .trilinear
    layer?.addSublayer(sprite)
  }

  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let height = max(0, bounds.height - 2)
    sprite.frame = CGRect(x: (bounds.width - height * 96 / 104) / 2, y: 1,
      width: height * 96 / 104, height: height)
    CATransaction.commit()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncPlayback()
  }

  func update(frames next: [CGImage], isPlaying: Bool) {
    let changed = frames.count != next.count || frames.first !== next.first
    if changed {
      frames = next
      sprite.removeAnimation(forKey: "run")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      sprite.contents = next.first
      CATransaction.commit()
    }
    shouldPlay = isPlaying
    syncPlayback()
  }

  private func syncPlayback() {
    guard shouldPlay, window != nil, frames.count == RunnerArtwork.frameCount else {
      sprite.removeAnimation(forKey: "run")
      return
    }
    guard sprite.animation(forKey: "run") == nil else { return }
    let animation = CAKeyframeAnimation(keyPath: "contents")
    animation.values = frames + [frames[0]]
    animation.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
    animation.calculationMode = .discrete
    animation.duration = Double(frames.count) * RunnerArtwork.frameInterval
    animation.repeatCount = .infinity
    sprite.add(animation, forKey: "run")
  }
}
