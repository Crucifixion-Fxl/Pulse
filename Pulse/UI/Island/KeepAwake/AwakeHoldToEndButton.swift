// Adapted from krishhgg/Insomnia's HoldToEndButton (MIT, Krish Garg, 2026).
import SwiftUI

struct AwakeHoldToEndButton: View {
  let reduceMotion: Bool
  let action: () -> Void
  @State private var progress: CGFloat = 0
  @State private var holding = false
  @State private var pressed = false
  @State private var holdTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      Circle().stroke(.white.opacity(0.14), lineWidth: 1.4)
      Circle().trim(from: 0, to: progress)
        .stroke(Color(red: 0.56, green: 0.62, blue: 0.76), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        .rotationEffect(.degrees(-90))
      Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(0.85))
    }
    .frame(width: 16, height: 16)
    .scaleEffect(holding && !reduceMotion ? 1.12 : 1)
    .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.6), value: holding)
    .frame(width: 18, height: 24).contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !pressed { pressed = true; begin() }
        else if holding, hypot(value.translation.width, value.translation.height) > 12 { release() }
      }
      .onEnded { _ in pressed = false; release() })
    .help(L10n.text("awake.hold-end"))
    .accessibilityLabel(L10n.text("awake.stop"))
    .accessibilityHint(L10n.text("awake.hold-end"))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { action() }
    .onDisappear { holdTask?.cancel(); holdTask = nil }
  }

  private func begin() {
    holding = true
    withAnimation(.linear(duration: 0.6)) { progress = 1 }
    holdTask?.cancel()
    holdTask = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
      guard !Task.isCancelled, holding else { return }
      holding = false
      action()
      withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
    }
  }
  private func release() {
    holdTask?.cancel(); holdTask = nil; holding = false
    withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
  }
}
