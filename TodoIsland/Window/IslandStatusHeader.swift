import AppKit
import QuartzCore

/// Live status items sit above the content snapshots and travel with the
/// silhouette. The original quota and bot stay opaque; extra vendors fade
/// in after the expanding left wing has room for them.
@MainActor
final class IslandStatusHeader: NSView {
  let quota: NSView
  let bot: NSView
  let additionalQuotas: NSView?
  let weather: NSView?
  private var items: [NSView] { [quota, bot] + [additionalQuotas, weather].compactMap { $0 } }
  private var isExpanded = false
  var barHeight: CGFloat

  override var isFlipped: Bool { true }

  init(quota: NSView, bot: NSView, additionalQuotas: NSView? = nil,
       weather: NSView? = nil, barHeight: CGFloat) {
    self.quota = quota
    self.bot = bot
    self.additionalQuotas = additionalQuotas
    self.weather = weather
    self.barHeight = barHeight
    super.init(frame: .zero)
    wantsLayer = true
    layer?.zPosition = 2
    for item in items {
      item.wantsLayer = true
      addSubview(item)
    }
  }

  required init?(coder: NSCoder) { nil }

  var presentedItemFrames: [CGRect] {
    items.map { $0.layer?.presentation()?.frame ?? $0.frame }
  }

  /// Rebase the visible positions into the resized transparent envelope,
  /// preserving continuity even when an opening or closing is interrupted.
  func prepare(envelope: CGSize, shiftX: CGFloat) {
    let frames = presentedItemFrames
    frame = CGRect(origin: .zero, size: envelope)
    for (item, visible) in zip(items, frames) {
      item.layer?.removeAnimation(forKey: "headerPosition")
      item.frame = visible.offsetBy(dx: shiftX, dy: 0)
    }
  }

  func move(to size: CGSize, state: IslandPresentationState, spring: CASpringAnimation?) {
    isExpanded = state != .collapsed
    let inset: CGFloat = state == .collapsed ? 12 : 20
    let left = (bounds.width - size.width) / 2
    let faceSize = min(26, max(18, barHeight - 6)).rounded()
    let botX = left + size.width - inset - faceSize / 2 - 16
    var frames = [
      CGRect(x: left + inset, y: 0, width: 60, height: barHeight),
      CGRect(x: botX, y: 0, width: 32, height: barHeight)
    ]
    if additionalQuotas != nil {
      frames.append(CGRect(x: left + inset + 72, y: 0, width: 170, height: barHeight))
    }
    if weather != nil {
      frames.append(CGRect(x: botX - 164, y: 0, width: 156, height: barHeight))
    }
    for (item, destination) in zip(items, frames) {
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
    for extra in [additionalQuotas, weather].compactMap({ $0 }) {
      reveal(extra, state: state, spring: spring)
    }
  }

  private func reveal(_ item: NSView, state: IslandPresentationState, spring: CASpringAnimation?) {
    guard let layer = item.layer else { return }
    let opacity = layer.presentation()?.opacity ?? layer.opacity
    layer.removeAnimation(forKey: "headerReveal")
    let target: Float = state == .collapsed ? 0 : 1
    layer.opacity = target
    if let spring {
      let reveal = CABasicAnimation(keyPath: "opacity")
      reveal.fromValue = opacity
      reveal.toValue = target
      // Wait until the left wing clears the physical notch before revealing
      // the extra vendors; hide promptly when that wing folds back in.
      reveal.beginTime = spring.beginTime + (state == .collapsed ? 0 : 0.24)
      reveal.duration = state == .collapsed ? 0.08 : 0.18
      reveal.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      reveal.fillMode = .backwards
      layer.add(reveal, forKey: "headerReveal")
    }
  }

  func settle(size: CGSize, state: IslandPresentationState) {
    frame = CGRect(origin: .zero, size: size)
    move(to: size, state: state, spring: nil)
  }

  // Only the weather chip is interactive; the rest remains surface chrome.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let localPoint = convert(point, from: superview)
    guard isExpanded, let weather,
      (weather.layer?.presentation()?.opacity ?? weather.layer?.opacity ?? 0) > 0.95,
      weather.frame.contains(localPoint) else { return nil }
    return weather.hitTest(localPoint)
  }
}
