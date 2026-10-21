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
  private var isStoreAvailable = true
  private var keepAwakeEditing = false
  private var surfaceSize = CGSize.zero
  private var surfaceState: IslandPresentationState = .collapsed
  private var enabledItems = Set(ExtensionPreferences.availableStatusItems)
  private(set) var headerOrder = ExtensionPreferences.defaultHeaderOrder
  var onOrderChanged: (([String]) -> Void)?
  private var drag: (id: String, originalOrder: [String], offset: CGFloat)?
  private var itemEntries: [(id: String, view: NSView)] {
    [("quota", quota), ("bot", bot)]
      + [("additionalQuotas", additionalQuotas), ("weather", weather),
         ("keepAwake", keepAwake), ("store", store)].compactMap { id, view in
        view.map { (id, $0) }
      }
  }

  func setHeaderOrder(_ order: [String], animated: Bool = true) {
    let normalized = ExtensionPreferences.normalizedHeaderOrder(order)
    guard headerOrder != normalized else { return }
    cancelDrag()
    headerOrder = normalized
    relayout(animated: animated)
  }

  func setEnabledItems(_ items: [String], animated: Bool = true) {
    let enabled = Set(items).union(["bot"])
    guard enabledItems != enabled else { return }
    cancelDrag()
    enabledItems = enabled
    relayout(animated: animated)
  }

  private func relayout(animated: Bool) {
    guard surfaceSize != .zero else { return }
    let spring = CASpringAnimation()
    spring.mass = 1
    spring.stiffness = 380
    spring.damping = 34
    spring.duration = 0.38
    move(to: surfaceSize, state: surfaceState,
      spring: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? spring : nil,
      fromPresentation: true)
  }

  func setStoreAvailable(_ available: Bool) {
    guard isStoreAvailable != available else { return }
    isStoreAvailable = available
    store?.isHidden = !isExpanded || !available
    relayout(animated: false)
  }

  func refreshWeatherLayout() {
    guard enabledItems.contains("weather"), surfaceSize != .zero,
      weather?.frame.width != weatherWidth else { return }
    move(to: surfaceSize, state: surfaceState, spring: nil)
  }

  private var weatherWidth: CGFloat {
    let idealWidth = weather?.intrinsicContentSize.width ?? 0
    return keepAwakeEditing ? 28 : (idealWidth > 0 ? min(108, ceil(idealWidth)) : 108)
  }

  func setKeepAwakeEditing(_ editing: Bool) {
    guard keepAwakeEditing != editing else { return }
    keepAwakeEditing = editing
    relayout(animated: true)
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
      item.toolTip = L10n.text("header.drag-to-reorder")
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

  func move(to size: CGSize, state: IslandPresentationState, spring: CASpringAnimation?,
            fromPresentation: Bool = false) {
    surfaceSize = size
    surfaceState = state
    isExpanded = state != .collapsed
    if !isExpanded { cancelDrag() }
    store?.isHidden = !isExpanded || !isStoreAvailable
    quota.isHidden = !enabledItems.contains("quota")
    additionalQuotas?.isHidden = !enabledItems.contains("additionalQuotas")
    weather?.isHidden = !enabledItems.contains("weather")
    keepAwake?.isHidden = !enabledItems.contains("keepAwake")
    let inset: CGFloat = state == .collapsed ? 12 : 20
    let left = (bounds.width - size.width) / 2
    let faceSize = min(26, max(18, barHeight - 6)).rounded()
    let botX = left + size.width - inset - faceSize / 2 - 16
    var frames = [
      CGRect(x: left + inset, y: 0, width: 60, height: barHeight),
      CGRect(x: botX, y: 0, width: 32, height: barHeight)
    ]
    if additionalQuotas != nil {
      frames.append(CGRect(x: left + inset + (quota.isHidden ? 0 : 72), y: 0,
        width: 170, height: barHeight))
    }
    let storeWidth: CGFloat = store == nil || !isExpanded || !isStoreAvailable ? 0 : 28
    // Use the text's ideal width so a short city name does not leave a
    // blank tail between the weather and the store.
    let visibleWeatherWidth: CGFloat = weather == nil || !enabledItems.contains("weather") ? 0 : weatherWidth
    let weatherX = botX - storeWidth - (visibleWeatherWidth > 0 ? 6 + visibleWeatherWidth : 0)
    if weather != nil {
      frames.append(CGRect(x: weatherX, y: 0, width: visibleWeatherWidth, height: barHeight))
    }
    if keepAwake != nil {
      frames.append(CGRect(x: weatherX - (keepAwakeEditing ? 8 + 188 : 6 + 100), y: 0,
        width: keepAwakeEditing ? 188 : 100, height: barHeight))
    }
    if store != nil {
      frames.append(CGRect(x: botX - 28, y: 0, width: 24, height: barHeight))
    }
    let orderedFrames = isExpanded ? expandedFrames(left: left, right: botX + 32) : [:]
    for ((id, item), fallback) in zip(itemEntries, frames) {
      guard drag?.id != id else { continue }
      let destination = orderedFrames[id] ?? fallback
      // Surface transitions have already rebased model positions into a new
      // window envelope in prepare(). Only in-place relayouts sample presentation.
      let start = (fromPresentation ? item.layer?.presentation()?.position : nil)
        ?? item.layer?.position ?? .zero
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

  private func itemWidth(_ id: String) -> CGFloat {
    switch id {
    case "quota": 60
    case "additionalQuotas": 170
    case "keepAwake": keepAwakeEditing ? 188 : 100
    case "weather": weatherWidth
    case "store": 24
    default: 32
    }
  }

  private func gap(after id: String) -> CGFloat {
    switch id {
    case "quota", "additionalQuotas": 12
    case "store": 4
    case "keepAwake": keepAwakeEditing ? 8 : 6
    default: 6
    }
  }

  private var visibleIDs: Set<String> {
    Set(itemEntries.filter { !$0.view.isHidden }.map(\.id))
  }

  private func expandedFrames(left: CGFloat, right: CGFloat) -> [String: CGRect] {
    let split = headerOrder.firstIndex(of: "spacer")!
    let leading = headerOrder[..<split].filter { visibleIDs.contains($0) }
    let trailing = headerOrder[(split + 1)...].filter { visibleIDs.contains($0) }
    var result: [String: CGRect] = [:]
    func place(_ ids: [String], startingAt start: CGFloat) {
      var x = start
      for id in ids {
        result[id] = CGRect(x: x, y: 0, width: itemWidth(id), height: barHeight)
        x += itemWidth(id) + gap(after: id)
      }
    }
    let trailingWidth = trailing.reduce(CGFloat.zero) { $0 + itemWidth($1) + gap(after: $1) }
      - (trailing.last.map { gap(after: $0) } ?? 0)
    place(leading, startingAt: left + 20)
    place(trailing, startingAt: right - trailingWidth)
    return result
  }

  func canDragItem(_ id: String) -> Bool {
    isExpanded && visibleIDs.contains(id) && !(id == "keepAwake" && keepAwakeEditing)
  }

  func dragAnchor(for id: String) -> CGPoint? {
    guard let item = itemEntries.first(where: { $0.id == id })?.view else { return nil }
    let frame = item.layer?.presentation()?.frame ?? item.frame
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  /// Keep the live view under the pointer; animate only its neighbours.
  func beginDragging(_ id: String, at point: CGPoint) {
    guard canDragItem(id), drag == nil,
      let item = itemEntries.first(where: { $0.id == id })?.view else { return }
    let visible = item.layer?.presentation()?.frame ?? item.frame
    item.layer?.removeAnimation(forKey: "headerPosition")
    item.frame = visible
    drag = (id, headerOrder, point.x - visible.minX)
    item.layer?.zPosition = 10
  }

  func updateDragging(to point: CGPoint) {
    guard let drag, let item = itemEntries.first(where: { $0.id == drag.id })?.view else { return }
    var order = headerOrder.filter { $0 != drag.id }
    let target = order.first { id in
      if id == "spacer" { return point.x < bounds.midX }
      guard visibleIDs.contains(id), let view = itemEntries.first(where: { $0.id == id })?.view else {
        return false
      }
      return point.x < view.frame.midX
    }
    order.insert(drag.id, at: target.flatMap { order.firstIndex(of: $0) } ?? order.endIndex)
    if order != headerOrder {
      headerOrder = order
      relayout(animated: true)
    }
    item.frame.origin.x = min(max(point.x - drag.offset, 20), bounds.width - 20 - item.frame.width)
  }

  func finishDragging(cancelled: Bool = false) {
    guard let drag else { return }
    if cancelled { headerOrder = drag.originalOrder }
    self.drag = nil
    itemEntries.first(where: { $0.id == drag.id })?.view.layer?.zPosition = 0
    relayout(animated: true)
    if !cancelled, headerOrder != drag.originalOrder { onOrderChanged?(headerOrder) }
  }

  private func cancelDrag() {
    guard let drag else { return }
    headerOrder = drag.originalOrder
    itemEntries.first(where: { $0.id == drag.id })?.view.layer?.zPosition = 0
    self.drag = nil
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
    for item in isExpanded ? items : [] {
      guard (item.layer?.presentation()?.opacity ?? item.layer?.opacity ?? 0) > 0.95,
        !item.isHidden,
        item.frame.contains(localPoint) else { continue }
      return item.hitTest(localPoint) ?? item
    }
    return nil
  }
}
