import SwiftUI

enum IslandStatusItem: String, CaseIterable {
  case quota
  case additionalQuotas
  case bot
  case weather
  case keepAwake
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

  var body: some View {
    Group {
      if model.canUseActiveList, model.extensionPreferences.statusItems.contains(item.rawValue) {
        switch item {
        case .quota:
          if let subscription = model.aiUsage?.subscriptions.first(where: {
            $0.vendor == model.collapsedQuotaVendor
          }) {
            CollapsedQuotaChipView(subscription: subscription)
          }
        case .additionalQuotas:
          HStack(spacing: 16) {
            ForEach([AIUsageVendor.openAI, .zhipuGLM, .anthropic]
              .filter { $0 != model.collapsedQuotaVendor }, id: \.self) { vendor in
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
          CollapsedBotFaceView(
            size: min(26, max(18, barHeight - 6)).rounded(),
            faceColor: model.collapsedQuotaVendor.accent,
            isPlaying: model.nowPlaying?.isPlaying == true,
            isHovered: model.isPointerInsideIsland,
            isAlert: agentStore.hasPending,
            activity: CollapsedBotState.activity(in: agentStore.sessions),
            isAnimated: !reduceMotion && (model.isCollapsedIslandVisible || isExpanded),
            character: model.extensionPreferences.bot)
        case .keepAwake:
          KeepAwakeStatusView(store: model.keepAwakeStore, isActive: isExpanded)
        case .weather:
          WeatherStatusView(store: model.weatherStore, isActive: isExpanded, isCompact: model.isKeepAwakeInputExpanded)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity,
      alignment: item == .bot ? .center : .leading)
  }
}
