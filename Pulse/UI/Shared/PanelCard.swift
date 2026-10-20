import SwiftUI

/// Shared card chrome for expanded-Island feature panels: rounded fill
/// plus a hairline stroke.
extension View {
  func panelCard(
    fill: Color = ReUITheme.item,
    stroke: Color = ReUITheme.subtleBorder,
    radius: CGFloat = 14
  ) -> some View {
    background(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .fill(fill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .stroke(stroke, lineWidth: 1)
    )
  }
}
