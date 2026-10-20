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
  let keepAwake: NSView?
  let store: NSView?
  private var items: [NSView] { [quota, bot] + [additionalQuotas, weather, keepAwake, store].compactMap { $0 } }
  private var isExpanded = false
  private var keepAwakeEditing = false
  private var surfaceSize = CGSize.zero
  private var surfaceState: IslandPresentationState = .collapsed

  func refreshWeatherLayout() {
    guard surfaceSize != .zero, weather?.frame.width != weatherWidth else { return }
    move(to: surfaceSize, state: surfaceState, spring: nil)
  }

  private var weatherWidth: CGFloat {
    let idealWidth = weather?.intrinsicContentSize.width ?? 0
    return keepAwakeEditing ? 28 : (idealWidth > 0 ? min(108, ceil(idealWidth)) : 108)
  }

  func setKeepAwakeEditing(_ editing: Bool) {
    guard keepAwakeEditing != editing else { return }
    keepAwakeEditing = editing
    let spring = CASpringAnimation()
    spring.mass = 1
    spring.stiffness = 380
    spring.damping = 34
    spring.duration = 0.38
    move(to: surfaceSize, state: surfaceState,
      spring: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : spring)
  }
  var barHeight: CGFloat

  override var isFlipped: Bool { true }

  init(quota: NSView, bot: NSView, additionalQuotas: NSView? = nil,
       weather: NSView? = nil, keepAwake: NSView? = nil, store: NSView? = nil, barHeight: CGFloat) {
    self.quota = quota
    self.bot = bot
    self.additionalQuotas = additionalQuotas
    self.weather = weather
    self.keepAwake = keepAwake
    self.store = store
    store?.isHidden = true
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
    surfaceSize = size
    surfaceState = state
    isExpanded = state != .collapsed
    store?.isHidden = !isExpanded
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
    let storeWidth: CGFloat = store == nil || !isExpanded ? 0 : 28
    // Use the text's ideal width so a short city name does not leave a
    // blank tail between the weather and the store.
    let weatherX = botX - storeWidth - 6 - weatherWidth
    if weather != nil {
      frames.append(CGRect(x: weatherX, y: 0, width: weatherWidth, height: barHeight))
    }
    if keepAwake != nil {
      frames.append(CGRect(x: weatherX - (keepAwakeEditing ? 8 + 188 : 6 + 100), y: 0,
        width: keepAwakeEditing ? 188 : 100, height: barHeight))
    }
    if store != nil {
      frames.append(CGRect(x: botX - 28, y: 0, width: 24, height: barHeight))
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
    for extra in [additionalQuotas, weather, keepAwake].compactMap({ $0 }) {
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

  // Header controls use the same live views throughout the spring animation.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let localPoint = convert(point, from: superview)
    for item in (isExpanded ? [store, keepAwake, weather] : []).compactMap({ $0 }) {
      guard (item.layer?.presentation()?.opacity ?? item.layer?.opacity ?? 0) > 0.95,
        item.frame.contains(localPoint) else { continue }
      return item.hitTest(localPoint)
    }
    return nil
  }
}
