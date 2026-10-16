import AppKit
import QuartzCore
import SwiftUI

/// A one-point light rail in the existing header/content gap. Static once
/// settled; only the opening and closing transitions animate its width.
@MainActor
final class IslandHeaderDivider: CAGradientLayer {
  override init() {
    super.init()
    startPoint = CGPoint(x: 0, y: 0.5)
    endPoint = CGPoint(x: 1, y: 0.5)
    locations = [0, 0.12, 0.36, 0.5, 0.64, 0.88, 1]
    colors = [
      NSColor.clear.cgColor,
      NSColor.white.withAlphaComponent(0.10).cgColor,
      NSColor(calibratedRed: 0.40, green: 0.80, blue: 1, alpha: 0.48).cgColor,
      NSColor(calibratedRed: 0.83, green: 0.91, blue: 1, alpha: 0.76).cgColor,
      NSColor(calibratedRed: 0.66, green: 0.59, blue: 1, alpha: 0.48).cgColor,
      NSColor.white.withAlphaComponent(0.10).cgColor,
      NSColor.clear.cgColor
    ]
    shadowColor = NSColor(calibratedRed: 0.48, green: 0.70, blue: 1, alpha: 1).cgColor
    shadowOpacity = 0.5
    shadowRadius = 3
    shadowOffset = .zero
    opacity = 0
  }

  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { nil }

  func freeze(shiftX: CGFloat) {
    let visible = presentation() ?? self
    let visibleBounds = visible.bounds
    let visiblePosition = visible.position
    let visibleOpacity = visible.opacity
    removeAllAnimations()
    bounds = visibleBounds
    position = CGPoint(x: visiblePosition.x + shiftX, y: visiblePosition.y)
    opacity = visibleOpacity
  }

  func move(width: CGFloat, centerX: CGFloat, y: CGFloat, expanded: Bool,
    spring: CASpringAnimation?) {
    let oldWidth = bounds.width
    let oldOpacity = presentation()?.opacity ?? opacity
    removeAllAnimations()
    bounds = CGRect(x: 0, y: 0, width: expanded ? max(0, width - 40) : 0, height: 1)
    position = CGPoint(x: centerX, y: y)
    opacity = expanded ? 1 : 0
    guard let spring, let unfold = spring.copy() as? CASpringAnimation else { return }
    unfold.keyPath = "bounds.size.width"
    unfold.fromValue = oldWidth
    unfold.toValue = bounds.width
    add(unfold, forKey: "dividerWidth")
    let reveal = CABasicAnimation(keyPath: "opacity")
    reveal.fromValue = oldOpacity
    reveal.toValue = opacity
    reveal.beginTime = spring.beginTime + (expanded ? 0.08 : 0)
    reveal.duration = expanded ? 0.22 : 0.10
    reveal.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    reveal.fillMode = .backwards
    add(reveal, forKey: "dividerReveal")
  }
}

/// Uses the same styling in standalone SwiftUI previews.
struct IslandHeaderDividerView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer = IslandHeaderDivider()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    nsView.layer?.opacity = 1
  }
}
