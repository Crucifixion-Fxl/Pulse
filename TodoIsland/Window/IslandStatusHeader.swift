import AppKit
import QuartzCore

/// Live status items sit above the content snapshots. Only their positions
/// animate, using the silhouette's spring and clock; they never crossfade.
@MainActor
final class IslandStatusHeader: NSView {
  let quota: NSView
  let bot: NSView
  var barHeight: CGFloat

  override var isFlipped: Bool { true }

  init(quota: NSView, bot: NSView, barHeight: CGFloat) {
    self.quota = quota
    self.bot = bot
    self.barHeight = barHeight
    super.init(frame: .zero)
    wantsLayer = true
    layer?.zPosition = 2
    for item in [quota, bot] {
      item.wantsLayer = true
      addSubview(item)
    }
  }

  required init?(coder: NSCoder) { nil }

  var presentedItemFrames: [CGRect] {
    [quota, bot].map { $0.layer?.presentation()?.frame ?? $0.frame }
  }

  /// Rebase the visible positions into the resized transparent envelope,
  /// preserving continuity even when an opening or closing is interrupted.
  func prepare(envelope: CGSize, shiftX: CGFloat) {
    let frames = presentedItemFrames
    frame = CGRect(origin: .zero, size: envelope)
    for (item, visible) in zip([quota, bot], frames) {
      item.layer?.removeAnimation(forKey: "headerPosition")
      item.frame = visible.offsetBy(dx: shiftX, dy: 0)
    }
  }

  func move(to size: CGSize, state: IslandPresentationState, spring: CASpringAnimation?) {
    let inset: CGFloat = state == .collapsed ? 12 : 20
    let left = (bounds.width - size.width) / 2
    let faceSize = min(26, max(18, barHeight - 6)).rounded()
    let frames = [
      CGRect(x: left + inset, y: 0, width: 60, height: barHeight),
      CGRect(x: left + size.width - inset - faceSize / 2 - 16,
        y: 0, width: 32, height: barHeight)
    ]
    for (item, destination) in zip([quota, bot], frames) {
      let start = item.layer?.position ?? .zero
      item.frame = destination
      guard let layer = item.layer else { continue }
      layer.removeAnimation(forKey: "headerPosition")
      if let spring, let movement = spring.copy() as? CASpringAnimation {
        movement.keyPath = "position"
        movement.fromValue = NSValue(point: start)
        movement.toValue = NSValue(point: layer.position)
        layer.add(movement, forKey: "headerPosition")
      }
    }
  }

  func settle(size: CGSize, state: IslandPresentationState) {
    frame = CGRect(origin: .zero, size: size)
    move(to: size, state: state, spring: nil)
  }

  // Decorative chrome must not swallow the surface's click/hover routing.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
