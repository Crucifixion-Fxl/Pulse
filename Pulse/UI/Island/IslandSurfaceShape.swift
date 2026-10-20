import SwiftUI

/// Full-width top lip with concave shoulders that flow inward into the sides.
/// All coordinates come from the current animated bounds, preserving symmetry.
struct IslandSurfaceShape: Shape {
  var shoulderInset: CGFloat
  var topShoulderDepth: CGFloat
  var bottomRadius: CGFloat

  var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
    get { AnimatablePair(shoulderInset, AnimatablePair(topShoulderDepth, bottomRadius)) }
    set {
      shoulderInset = newValue.first
      topShoulderDepth = newValue.second.first
      bottomRadius = newValue.second.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let inset = min(max(0, shoulderInset), rect.width / 4)
    let depth = min(max(0, topShoulderDepth), rect.height / 2)
    let left = rect.minX + inset
    let right = rect.maxX - inset
    let radius = min(max(0, bottomRadius), min((right - left) / 2, rect.height - depth))
    let k: CGFloat = 0.5522848
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addCurve(
      to: CGPoint(x: right, y: rect.minY + depth),
      control1: CGPoint(x: rect.maxX - inset * k, y: rect.minY),
      control2: CGPoint(x: right, y: rect.minY + depth * (1 - k))
    )
    path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
    path.addCurve(
      to: CGPoint(x: right - radius, y: rect.maxY),
      control1: CGPoint(x: right, y: rect.maxY - radius * (1 - k)),
      control2: CGPoint(x: right - radius * (1 - k), y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
    path.addCurve(
      to: CGPoint(x: left, y: rect.maxY - radius),
      control1: CGPoint(x: left + radius * (1 - k), y: rect.maxY),
      control2: CGPoint(x: left, y: rect.maxY - radius * (1 - k))
    )
    // Mirror the right-hand straight edge before reversing its shoulder curve.
    path.addLine(to: CGPoint(x: left, y: rect.minY + depth))
    path.addCurve(
      to: CGPoint(x: rect.minX, y: rect.minY),
      control1: CGPoint(x: left, y: rect.minY + depth * (1 - k)),
      control2: CGPoint(x: rect.minX + inset * k, y: rect.minY)
    )
    path.closeSubpath()
    return path
  }
}
