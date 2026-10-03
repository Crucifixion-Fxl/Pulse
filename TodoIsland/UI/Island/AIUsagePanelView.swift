import SwiftUI

/// Shared layout constants and palette for the AI usage panel and its cards.
private enum Layout {
  static let heroCardWidth: CGFloat = 264
  static let topRowHeight: CGFloat = 142
  static let chartHeight: CGFloat = 76
  static let cardSpacing: CGFloat = 10
  static let cardRadius: CGFloat = 14
  static let subscriptionCardHeight: CGFloat = 104
}

private enum Palette {
  // Brand hues live only on the vendor tiles (点缀); trend bars and quota
  // bars stay in the app's neutral white system, like the heatmap.
  static let input = Color.white.opacity(0.92)
  static let output = Color.white.opacity(0.62)
  static let cache = Color.white.opacity(0.38)
  static let warning = Color(red: 0.95, green: 0.72, blue: 0.25)
  static let danger = Color(red: 0.92, green: 0.36, blue: 0.32)
}

/// The AI usage sidebar panel: today's tokens, a half-month trend, and the
/// subscription quota cards. Renders a breathing skeleton while the first
/// fetch is in flight; a sample-data badge marks fabricated numbers until a
/// real provider takes over.
struct AIUsagePanelView: View {
  let snapshot: AIUsageSnapshot?

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hoveredTrendIndex: Int?
  @State private var heroHovered = false
  @State private var trendAppeared = false
  @State private var skeletonBreathing = false

  enum Metrics {
    /// Natural content height driving the window frame; referenced by
    /// IslandSidebarItem.preferredContentHeight.
    static let contentHeight: CGFloat = 324
  }

  var body: some View {
    Group {
      if let snapshot {
        content(snapshot)
      } else {
        skeleton
      }
    }
    .padding(.top, 2)
  }

  // MARK: Content

  private func content(_ snapshot: AIUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: Layout.cardSpacing) {
      header(isSample: snapshot.isSample)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Layout.cardSpacing) {
          todayCard(snapshot.today)
          trendCard(snapshot.days)
        }
        VStack(alignment: .leading, spacing: Layout.cardSpacing) {
          todayCard(snapshot.today)
          trendCard(snapshot.days)
        }
      }
      subscriptionsSection(snapshot)
    }
    .onAppear { beginTrendReveal() }
  }

  private func header(isSample: Bool) -> some View {
    HStack(spacing: 8) {
      Text("ai.title")
        .font(.system(size: 13, weight: .semibold))
      Spacer(minLength: 0)
      if isSample {
        Text("ai.sample-data")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
          .padding(.horizontal, 6)
          .padding(.vertical, 2.5)
          .background(Capsule(style: .continuous).fill(.white.opacity(0.07)))
          .overlay(
            Capsule(style: .continuous).stroke(ReUITheme.subtleBorder, lineWidth: 1)
          )
          .accessibilityLabel(Text("ai.sample-data"))
      }
    }
  }

  // MARK: Today

  private func todayCard(_ today: AIUsageDay?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("ai.today.title")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ReUITheme.muted)

      Text(AIUsageFormat.grouped(today?.totalTokens ?? 0))
        .font(.system(size: 27, weight: .bold, design: .rounded))
        .monospacedDigit()
        .minimumScaleFactor(0.75)
        .lineLimit(1)
        .foregroundStyle(.white)
        .shadow(
          color: heroHovered ? .white.opacity(0.45) : .clear,
          radius: heroHovered ? 10 : 0
        )
        .scaleEffect(heroHovered && !reduceMotion ? 1.03 : 1)

      VStack(alignment: .leading, spacing: 5) {
        breakdownRow(color: Palette.input, key: "ai.today.input", value: today?.inputTokens ?? 0)
        breakdownRow(color: Palette.output, key: "ai.today.output", value: today?.outputTokens ?? 0)
        breakdownRow(color: Palette.cache, key: "ai.today.cache", value: today?.cacheTokens ?? 0)
      }
      .padding(.top, 2)
    }
    .padding(12)
    .frame(
      width: Layout.heroCardWidth, height: Layout.topRowHeight, alignment: .topLeading
    )
    .panelCard(
      fill: heroHovered ? ReUITheme.itemHover : ReUITheme.item,
      stroke: heroHovered ? .white.opacity(0.16) : ReUITheme.subtleBorder
    )
    .contentShape(Rectangle())
    .onHover { inside in
      withAnimation(.easeOut(duration: 0.15)) { heroHovered = inside }
    }
    .animation(.easeOut(duration: 0.15), value: heroHovered)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("ai.today.title"))
    .accessibilityValue(Text(AIUsageFormat.grouped(today?.totalTokens ?? 0)))
  }

  private func breakdownRow(color: Color, key: LocalizedStringKey, value: Int) -> some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 4, height: 4)
      Text(key)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
      Spacer(minLength: 0)
      Text(AIUsageFormat.grouped(value))
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
    }
  }

  // MARK: Trend

  private func trendCard(_ days: [AIUsageDay]) -> some View {
    let weekMax = max(days.map(\.totalTokens).max() ?? 1, 1)
    let weekTotal = days.reduce(0) { $0 + $1.totalTokens }

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text("ai.trend.title")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
        Spacer(minLength: 0)
        Text(
          String(
            format: L10n.text("ai.trend.week-total"),
            AIUsageFormat.compactTokens(weekTotal)
          )
        )
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
      }

      HStack(alignment: .bottom, spacing: 4) {
        ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
          TrendColumn(
            day: day,
            index: index,
            count: days.count,
            weekMax: weekMax,
            appeared: trendAppeared,
            hoveredIndex: $hoveredTrendIndex,
            reduceMotion: reduceMotion
          )
        }
      }
      .frame(height: Layout.chartHeight, alignment: .bottom)

      HStack(spacing: 4) {
        ForEach(days) { day in
          Text(AIUsageFormat.weekdayShort(day.day))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(ReUITheme.muted)
            .frame(maxWidth: .infinity)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
      }
    }
    .padding(12)
    .frame(height: Layout.topRowHeight, alignment: .top)
    .panelCard()
  }

  /// One trend column on the cold-to-warm half-month spectrum: the older
  /// the bar, the cooler its hue; today sits at the warm end. Hovering
  /// lifts and brightens the bar and shows the value tooltip.
  private struct TrendColumn: View {
    let day: AIUsageDay
    let index: Int
    let count: Int
    let weekMax: Int
    let appeared: Bool
    @Binding var hoveredIndex: Int?
    let reduceMotion: Bool

    @State private var isHovering = false

    private var isToday: Bool { index == count - 1 }
    private var tint: Color {
      let progress = count <= 1 ? 1 : Double(index) / Double(count - 1)
      return Color(hue: 0.68 - progress * 0.62, saturation: 0.62, brightness: 0.95)
    }

    var body: some View {
      let ratio = CGFloat(day.totalTokens) / CGFloat(weekMax)
      let naturalHeight = max(4, Layout.chartHeight * ratio)
      let hoverLift: CGFloat = isHovering && !reduceMotion ? 5 : 0
      let revealHeight = appeared || reduceMotion ? naturalHeight : 4

      VStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
          .fill(
            isToday
              ? AnyShapeStyle(
                LinearGradient(
                  colors: [tint.opacity(0.75), tint],
                  startPoint: .top, endPoint: .bottom
                )
              )
              : AnyShapeStyle(tint.opacity(isHovering ? 0.95 : 0.55))
          )
          .shadow(
            color: isToday || isHovering ? tint.opacity(isToday ? 0.45 : 0.55) : .clear,
            radius: isHovering ? 7 : 4, y: 1
          )
          .frame(height: revealHeight + hoverLift)
          .frame(maxHeight: .infinity, alignment: .bottom)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .onHover { inside in
        withAnimation(.easeOut(duration: 0.15)) {
          isHovering = inside
          hoveredIndex = inside ? index : nil
        }
      }
      .overlay(alignment: .top) {
        if hoveredIndex == index {
          Text(
            String(
              format: L10n.text("ai.trend.tooltip"),
              day.day.formatted(date: .abbreviated, time: .omitted),
              AIUsageFormat.compactTokens(day.totalTokens)
            )
          )
          .font(.system(size: 10.5, weight: .medium))
          .lineLimit(1)
          .padding(.horizontal, 7)
          .padding(.vertical, 3.5)
          .background(Capsule(style: .continuous).fill(Color(white: 0.16)))
          .overlay(
            Capsule(style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1)
          )
          .foregroundStyle(.white)
          .fixedSize()
          .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
          .offset(y: -10)
          .transition(.opacity)
          .zIndex(2)
        }
      }
    }
  }

  private func beginTrendReveal() {
    guard !trendAppeared else { return }
    if reduceMotion {
      trendAppeared = true
    } else {
      withAnimation(.smooth(duration: 0.35)) {
        trendAppeared = true
      }
    }
  }

  // MARK: Subscriptions

  private func subscriptionsSection(_ snapshot: AIUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("ai.subscriptions.title")
        .font(.system(size: 12.5, weight: .semibold))

      HStack(spacing: Layout.cardSpacing) {
        ForEach(snapshot.subscriptions) { subscription in
          SubscriptionCard(subscription: subscription)
        }
      }
    }
  }

  // MARK: Skeleton

  /// Placeholder shapes matching the content layout so the window frame is
  /// stable while the first fetch is in flight.
  private var skeleton: some View {
    VStack(alignment: .leading, spacing: Layout.cardSpacing) {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(.white.opacity(0.05))
        .frame(width: 92, height: 13)

      HStack(alignment: .top, spacing: Layout.cardSpacing) {
        RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
          .fill(.white.opacity(0.05))
          .frame(width: Layout.heroCardWidth, height: Layout.topRowHeight)
        RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
          .fill(.white.opacity(0.05))
          .frame(height: Layout.topRowHeight)
          .frame(maxWidth: .infinity)
      }

      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(.white.opacity(0.05))
        .frame(width: 148, height: 12)

      HStack(spacing: Layout.cardSpacing) {
        ForEach(0..<3, id: \.self) { _ in
          RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
            .fill(.white.opacity(0.05))
            .frame(height: Layout.subscriptionCardHeight)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .opacity(skeletonBreathing ? 0.55 : 1)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
        skeletonBreathing = true
      }
    }
  }
}

// MARK: - Subscription card

private struct SubscriptionCard: View {
  let subscription: AISubscription

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false
  @State private var barAppeared = false

  private var accent: Color { subscription.id.accent }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      vendorRow

      QuotaBar(
        fraction: barAppeared || reduceMotion ? subscription.quota.fraction : 0,
        tint: barTint
      )
      .frame(height: 5)

      metaRow

      HStack(spacing: 3) {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 8, weight: .semibold))
        resetLabel
      }
      .foregroundStyle(ReUITheme.muted)
    }
    .padding(11)
    .frame(height: Layout.subscriptionCardHeight, alignment: .top)
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelCard(stroke: isHovering ? .white.opacity(0.16) : ReUITheme.subtleBorder)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
    }
    .onAppear {
      if reduceMotion {
        barAppeared = true
      } else {
        withAnimation(.smooth(duration: 0.3).delay(0.12)) { barAppeared = true }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilitySummary)
  }

  private var vendorRow: some View {
    HStack(spacing: 8) {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(accent.opacity(0.16))
        .frame(width: 26, height: 26)
        .overlay(
          Image(subscription.id.iconName)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 15, height: 15)
            .foregroundStyle(accent)
        )

      VStack(alignment: .leading, spacing: 1) {
        Text(LocalizedStringKey(subscription.id.localizedKey))
          .font(.system(size: 12.5, weight: .semibold))
          .lineLimit(1)
        Text(subscription.planName)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
  }

  private var barTint: Color {
    switch subscription.quota.status {
    case .normal: .white.opacity(0.92)
    case .warning: Palette.warning
    case .danger: Palette.danger
    }
  }

  private var metaRow: some View {
    HStack(spacing: 4) {
      Text(
        String(
          format: L10n.text("ai.quota.used-of"),
          AIUsageFormat.grouped(subscription.quota.used),
          AIUsageFormat.grouped(subscription.quota.limit)
        )
        + " "
        + L10n.text(subscription.quota.unit.localizedKey)
      )
      .font(.system(size: 10.5, weight: .medium))
      .foregroundStyle(ReUITheme.muted)
      .lineLimit(1)
      .minimumScaleFactor(0.8)

      Spacer(minLength: 2)

      Text("\(Int((subscription.quota.fraction * 100).rounded()))%")
        .font(.system(size: 10.5, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(barTint)
    }
  }

  @ViewBuilder
  private var resetLabel: some View {
    if let days = AIUsageFormat.days(until: subscription.resetsAt), days > 1 {
      Text(String(format: L10n.text("ai.quota.reset.days"), days))
        .font(.system(size: 9.5, weight: .medium))
    } else if let days = AIUsageFormat.days(until: subscription.resetsAt), days == 1 {
      Text("ai.quota.reset.tomorrow")
        .font(.system(size: 9.5, weight: .medium))
    } else {
      Text("ai.quota.reset.today")
        .font(.system(size: 9.5, weight: .medium))
    }
  }

  private var accessibilitySummary: Text {
    let percent = Int((subscription.quota.fraction * 100).rounded())
    let usedOf = String(
      format: L10n.text("ai.quota.used-of"),
      AIUsageFormat.grouped(subscription.quota.used),
      AIUsageFormat.grouped(subscription.quota.limit)
    )
    return Text(
      "\(L10n.text(subscription.id.localizedKey)), \(subscription.planName), \(usedOf), \(percent)%"
    )
  }
}

// MARK: - Quota bar

/// Track-plus-fill capsule bar; the fill keeps a 4pt minimum so an unused
/// quota still shows a bead, matching the old per-list progress idiom.
private struct QuotaBar: View {
  let fraction: Double
  let tint: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule(style: .continuous)
          .fill(.white.opacity(0.10))
        Capsule(style: .continuous)
          .fill(tint)
          .frame(width: max(4, proxy.size.width * fraction))
      }
    }
  }
}

// MARK: - Vendor presentation

private extension AIUsageVendor {
  /// Official brand mark bundled as a template vector in the asset
  /// catalog; rendered small on the tile and tinted with `accent`.
  var iconName: String {
    switch self {
    case .zhipuGLM: "VendorZAI"
    case .anthropic: "VendorClaude"
    case .openAI: "VendorOpenAI"
    }
  }

  /// Tile-only brand tint: Zhipu's official blue (#1F63EC, lifted for the
  /// dark surface), Claude's terracotta (#D97757), and neutral white for
  /// OpenAI — its brand is monochrome.
  var accent: Color {
    switch self {
    case .zhipuGLM: Color(red: 0.28, green: 0.53, blue: 1.00)
    case .anthropic: Color(red: 0.85, green: 0.47, blue: 0.34)
    case .openAI: .white
    }
  }
}
