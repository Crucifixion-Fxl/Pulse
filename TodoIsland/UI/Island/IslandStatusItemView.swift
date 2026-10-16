import SwiftUI

enum IslandStatusItem: CaseIterable {
  case quota
  case bot
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
        case .bot:
          CollapsedBotFaceView(
            size: min(26, max(18, barHeight - 6)).rounded(),
            faceColor: model.collapsedQuotaVendor.accent,
            isPlaying: model.nowPlaying?.isPlaying == true,
            isHovered: model.isPointerInsideIsland,
            isAlert: agentStore.hasPending,
            activity: CollapsedBotState.activity(in: agentStore.sessions),
            isAnimated: !reduceMotion && (model.isCollapsedIslandVisible
              || IslandRouting.effectiveState(global: model.islandState,
                activeDisplayID: model.hostDisplayID, windowDisplayID: displayID) != .collapsed))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity,
      alignment: item == .quota ? .leading : .center)
  }
}
