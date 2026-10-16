import SwiftUI

enum IslandStatusItem: CaseIterable {
  case quota
  case additionalQuotas
  case bot
  case additionalBots
}

/// Mounted once per display so quota and bot animations survive opening.
struct IslandStatusItemView: View {
  let item: IslandStatusItem
  let displayID: String?
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var agentStore: AgentSessionStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var barHeight: CGFloat {
    DisplaySupport.cachedMetrics(for: displayID ?? model.hostDisplayID)
      .map { DisplayGeometryCalculator.statusHeaderHeight(for: $0) } ?? 32
  }

  private var isExpanded: Bool {
    IslandRouting.effectiveState(global: model.islandState,
      activeDisplayID: model.hostDisplayID, windowDisplayID: displayID) != .collapsed
  }

  private var additionalVendors: [AIUsageVendor] {
    [AIUsageVendor.openAI, .zhipuGLM, .anthropic].filter { $0 != model.collapsedQuotaVendor }
  }

  var body: some View {
    Group {
      if model.canUseActiveList {
        switch item {
        case .quota:
          if let subscription = model.aiUsage?.subscriptions.first(where: {
            $0.vendor == model.collapsedQuotaVendor
          }) {
            CollapsedQuotaChipView(subscription: subscription)
          }
        case .additionalQuotas:
          HStack(spacing: 16) {
            ForEach(additionalVendors, id: \.self) { vendor in
              if let subscription = model.aiUsage?.subscriptions.first(where: { $0.vendor == vendor }) {
                CollapsedQuotaChipView(subscription: subscription,
                  label: vendor == .anthropic ? "Anthropic" : nil,
                  showsSampleBadge: true)
                  .fixedSize(horizontal: true, vertical: false)
              }
            }
          }
          .accessibilityHidden(!isExpanded)
        case .bot:
          bot(for: model.collapsedQuotaVendor, isPrimary: true)
        case .additionalBots:
          HStack(spacing: 12) {
            ForEach(additionalVendors, id: \.self) { vendor in
              bot(for: vendor, isPrimary: false).frame(width: 32)
            }
          }
          .accessibilityHidden(!isExpanded)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity,
      alignment: item == .bot ? .center : .leading)
  }

  private func bot(for vendor: AIUsageVendor, isPrimary: Bool) -> some View {
    let sessions = isPrimary && !isExpanded ? agentStore.sessions
      : agentStore.sessions.filter { CollapsedBotState.vendor(for: $0.value) == vendor }
    let hasPending = isPrimary && !isExpanded ? agentStore.hasPending
      : agentStore.permissionQueue.contains { sessions[$0.sessionId] != nil }
        || agentStore.questionQueue.contains { sessions[$0.sessionId] != nil }
    let label = vendor == .anthropic ? "Anthropic" : vendor.chipLabel
    return ZStack {
      CollapsedBotFaceView(
        size: min(26, max(18, barHeight - 6)).rounded(),
        faceColor: vendor.accent,
        isPlaying: model.nowPlaying?.isPlaying == true,
        isHovered: model.isPointerInsideIsland,
        isAlert: hasPending,
        activity: CollapsedBotState.activity(in: sessions),
        isAnimated: !reduceMotion && (isExpanded || (isPrimary && model.isCollapsedIslandVisible)))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("\(label) Bot"))
    .help(label)
  }
}
