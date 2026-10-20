import SwiftUI

/// Vendor quota chip for the collapsed island bar's left end: a progress
/// ring around the vendor mark with the product label and used percentage
/// stacked beside it. Reads like a watch-face complication — identity from
/// the logo, state from the ring color and fill, no extra words needed at
/// a glance. Which vendor it shows is picked in the AI usage panel.
struct CollapsedQuotaChipView: View {
  let subscription: AISubscription
  var label: String? = nil
  var showsSampleBadge = false

  private var vendorLabel: String { label ?? subscription.vendor.chipLabel }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var appeared = false

  private static let ringSize: CGFloat = 20
  private static let ringLineWidth: CGFloat = 2.5
  private static let logoSize: CGFloat = 10

  /// Same semantic palette as the AI usage panel's quota bars: neutral
  /// white until 80%, amber past it, red past 95%.
  private var tint: Color {
    switch subscription.quota.status {
    case .normal: .white.opacity(0.92)
    case .warning: Color(red: 0.95, green: 0.72, blue: 0.25)
    case .danger: Color(red: 0.92, green: 0.36, blue: 0.32)
    }
  }

  /// The chip shows what is LEFT (额度), not what is spent: a fresh quota
  /// reads 100% and the ring drains as it is consumed. Status colors stay
  /// driven by the used fraction (amber past 80%, red past 95%).
  private var percentText: String {
    "\(Int(((1 - subscription.quota.fraction) * 100).rounded()))%"
  }

  var body: some View {
    HStack(spacing: 5) {
      ZStack {
        Circle()
          .stroke(.white.opacity(0.14), lineWidth: Self.ringLineWidth)
        Circle()
          .trim(
            from: 0,
            to: appeared || reduceMotion ? 1 - subscription.quota.fraction : 0
          )
          .stroke(tint, style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
        Image(subscription.vendor.iconName)
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .frame(width: Self.logoSize, height: Self.logoSize)
          .foregroundStyle(.white.opacity(0.85))
      }
      .frame(width: Self.ringSize, height: Self.ringSize)

      VStack(alignment: .leading, spacing: 0) {
        Text(vendorLabel)
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.white)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          Text(percentText)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText())
          if subscription.isStale {
            Image(systemName: "clock.arrow.circlepath")
              .font(.system(size: 8))
              .help(Text("ai.quota.stale"))
          }
          if showsSampleBadge, subscription.isSample {
            Text("island.quota.demo")
              .font(.system(size: 7, weight: .medium))
              .foregroundStyle(.white.opacity(0.5))
          }
        }
      }
    }
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.smooth(duration: 0.35)) { appeared = true }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text(
        String(
          format: L10n.text("island.quota.accessibility"),
          vendorLabel,
          Int((subscription.quota.fraction * 100).rounded()))))
    .accessibilityValue(subscription.isStale ? L10n.text("ai.quota.stale") : (showsSampleBadge && subscription.isSample ? L10n.text("ai.sample-data") : ""))
  }
}
