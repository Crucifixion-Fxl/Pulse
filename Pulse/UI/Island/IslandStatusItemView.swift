import SwiftUI

/// SwiftUI owns the button gestures inside each hosting view. Recognize the
/// reorder there so a button cannot consume the drag before AppKit sees it.
@MainActor
final class HeaderDragTarget {
  weak var header: IslandStatusHeader?
  let id: String
  private var active = false
  private var anchor = CGPoint.zero

  init(id: String) { self.id = id }

  func update(_ value: DragGesture.Value) {
    guard let header, header.canDragItem(id) else { return }
    if !active {
      guard let center = header.dragAnchor(for: id) else { return }
      anchor = center
      header.beginDragging(id, at: center)
      active = true
    }
    // Global gesture translation remains stable as the hosting view itself moves.
    header.updateDragging(to: CGPoint(x: anchor.x + value.translation.width, y: anchor.y))
  }

  func finish(_ value: DragGesture.Value? = nil, cancelled: Bool = false) {
    guard active else { return }
    if !cancelled, let value { update(value) }
    header?.finishDragging(cancelled: cancelled)
    active = false
  }
}

struct HeaderDragModifier: ViewModifier {
  let target: HeaderDragTarget
  let displayID: String?
  @EnvironmentObject private var model: AppModel

  private var enabled: Bool {
    IslandRouting.effectiveState(global: model.islandState,
      activeDisplayID: model.hostDisplayID, windowDisplayID: displayID) != .collapsed
      && !(target.id == "keepAwake" && model.isKeepAwakeInputExpanded)
  }

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
        .onChanged { target.update($0) }
        .onEnded { target.finish($0) }, including: enabled ? .all : .none)
      .onDisappear { target.finish(cancelled: true) }
  }
}

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
          WeatherStatusView(store: model.weatherStore, isActive: isExpanded, isCompact: false)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity,
      alignment: item == .bot ? .center : .leading)
  }
}
