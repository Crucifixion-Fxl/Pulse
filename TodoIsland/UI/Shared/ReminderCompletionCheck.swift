import SwiftUI

/// Fill first, then draw the check. A small settling pulse keeps feedback
/// local to the control, so successive completions don't scatter particles.
struct ReminderCompletionCheck: View {
  let isCompleted: Bool
  let size: CGFloat
  let accent: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var fill: CGFloat = 0
  @State private var stroke: CGFloat = 0

  var body: some View {
    ZStack {
      Circle().strokeBorder(accent, lineWidth: 1.4)
        .opacity(1 - fill)
      Circle().fill(Color.green)
        .scaleEffect(0.7 + 0.3 * fill)
        .opacity(fill)
      CheckStroke()
        .trim(from: 0, to: stroke)
        .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        .padding(size * 0.24)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
    .onChange(of: isCompleted, initial: true) { _, completed in
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
        fill = completed ? 1 : 0
      }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(completed ? 0.08 : 0)) {
        stroke = completed ? 1 : 0
      }
    }
  }
}

private struct CheckStroke: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY * 0.86))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.14))
    }
  }
}
