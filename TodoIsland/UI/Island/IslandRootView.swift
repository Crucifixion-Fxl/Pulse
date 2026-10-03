import AppKit
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

enum ListCreationDraftPolicy {
  static func shouldResetName(
    previousSource: ReminderSource?,
    newSource: ReminderSource?
  ) -> Bool {
    previousSource == nil && newSource != nil
  }
}

/// Destinations shown in the expanded Island sidebar. New Island features can
/// add a case here without changing the shell or window geometry.
enum IslandSidebarItem: String, CaseIterable, Identifiable {
  case reminders
  case aiUsage
  case music
  case clipboard
  case placeholder4
  case placeholder5
  case placeholder6
  case placeholder7

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .reminders: "sidebar.reminders"
    case .aiUsage: "sidebar.ai-usage"
    case .music: "sidebar.music"
    case .clipboard: "sidebar.clipboard"
    case .placeholder4, .placeholder5, .placeholder6, .placeholder7:
      "sidebar.placeholder"
    }
  }

  var symbol: String {
    switch self {
    case .reminders: "checklist"
    case .aiUsage: "sparkles"
    case .music: "music.note"
    case .clipboard: "doc.on.clipboard"
    case .placeholder4: "flag"
    case .placeholder5: "clock"
    case .placeholder6: "folder"
    case .placeholder7: "chart.bar"
    }
  }

  /// Natural height of the feature content, before the Island's top and
  /// bottom insets. The window controller uses this to keep both panes
  /// aligned with the selected sidebar feature.
  var preferredContentHeight: CGFloat {
    switch self {
    // The Reminders pane contains a six-week calendar followed by the
    // 24-week completion heatmap; the window is sized to their exact
    // natural height so no dead space trails the heatmap.
    case .reminders: IslandRootView.ScheduleMetrics.regular.remindersContentHeight
    // The AI usage pane's height is fully deterministic — hero, trend and
    // subscription cards all use fixed metrics.
    case .aiUsage: AIUsagePanelView.Metrics.contentHeight
    // Player and lyrics cards use fixed metrics matching the AI pane, so
    // the island height stays uniform across features.
    case .music: MusicPanelView.Metrics.contentHeight
    case .clipboard: ClipboardPanelView.Metrics.contentHeight
    // The stub pane is one centered line of text; keep the surface compact.
    case .placeholder4, .placeholder5, .placeholder6, .placeholder7:
      240
    }
  }
}

/// Watches mouse-downs inside the Island: a click anywhere on the hover
/// preview (even on the Task Input itself, whose field would otherwise
/// consume the click without focus in a non-key panel) pins the Island
/// first, so the same click lands in a key window and types immediately.
struct MouseDownMonitor: NSViewRepresentable {
  let handler: @MainActor @Sendable (NSEvent) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(handler: handler)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.start()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.handler = handler
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    var handler: @MainActor @Sendable (NSEvent) -> Void
    private var monitor: Any?

    init(handler: @escaping @MainActor @Sendable (NSEvent) -> Void) {
      self.handler = handler
    }

    func start() {
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        _ = self?.handler(event)
        return event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// Reports the month-calendar pane's natural height from layout so the
/// window can be sized to the real content instead of an estimate.
private struct CalendarPaneHeightKey: PreferenceKey {
  nonisolated(unsafe) static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// A heatmap cell's coordinates in the contribution grid.
private struct HeatmapCellPosition: Equatable {
  let column: Int
  let row: Int
}

/// One scheduled confetti burst, anchored in the schedule pane's space.
private struct ScheduledConfetti: Identifiable {
  let id = UUID()
  let center: CGPoint
}

struct IslandRootView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var editorTitleFocused: Bool
  @State private var reminderPendingDeletion: ReminderSnapshot?
  @State private var selectedSidebarItem: IslandSidebarItem = .reminders
  @State private var hoveredSidebarItem: IslandSidebarItem?
  @State private var hoveredReminderID: String?
  @State private var newTaskTitle = ""
  /// nil means the Active List; the picker in the Task Input overrides it.
  @State private var newTaskListID: String?
  /// Natural height of the month-calendar pane as measured in layout; drives
  /// the window height so the heatmap never clips and never leaves slack.
  @State private var calendarPaneIdealHeight: CGFloat = 0
  /// Shared geometry space for the liquid sidebar indicator.
  @Namespace private var sidebarNS
  /// Heatmap cell (grid column, weekday row) currently under the pointer.
  @State private var heatmapHoverCell: HeatmapCellPosition?
  /// Day-row frames in the schedule pane space, keyed by Reminder id —
  /// used to anchor the completion confetti at the clicked check.
  @State private var rowFrames: [String: CGRect] = [:]
  @State private var confettiBursts: [ScheduledConfetti] = []
  @FocusState private var newTaskFocused: Bool

  private var isPinned: Bool { model.islandState == .pinned }

  var body: some View {
    GeometryReader { proxy in
      let surfaceSize = IslandAnimatedSurfaceLayout.surfaceSize(
        windowSize: proxy.size,
        targetSize: islandSurfaceSize
      )

      ZStack(alignment: .top) {
        if model.islandState == .collapsed {
          collapsedContent
            .transition(
              .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                removal: .opacity.combined(with: .scale(scale: 1.04, anchor: .top))
              )
            )
        } else {
          expandedContent
            .transition(
              .opacity.combined(with: .scale(scale: 0.965, anchor: .top))
            )
        }
      }
      .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
      .background(.black)
      .clipShape(islandShape)
      .contentShape(Rectangle())
      .onHover { hovering in
        model.setIslandHovered(hovering)
      }
      .onTapGesture {
        // Only a hover preview becomes pinned from a surface tap. This keeps
        // controls inside a pinned surface, including the setup close button,
        // from being re-pinned by the parent gesture after they act.
        if model.islandState == .preview { model.pinIsland() }
      }
      .background(KeyboardEventMonitor(handler: handleKeyEvent))
      .background(
        MouseDownMonitor { event in
          if model.islandState == .preview {
            model.pinIsland()
          }
        }
      )
      .animation(surfaceAnimation, value: model.islandState)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .confirmationDialog(
        L10n.text("delete.title"),
        isPresented: Binding(
          get: { reminderPendingDeletion != nil },
          set: { if !$0 { reminderPendingDeletion = nil } }
        )
      ) {
        Button(L10n.text("delete.confirm"), role: .destructive) {
          if let reminderPendingDeletion { model.delete(reminderPendingDeletion) }
          reminderPendingDeletion = nil
        }
        Button(L10n.text("common.cancel"), role: .cancel) {
          reminderPendingDeletion = nil
        }
      } message: {
        Text(reminderPendingDeletion?.title ?? "")
      }
      .alert(
        L10n.text("error.title"),
        isPresented: Binding(
          get: { model.errorMessage != nil },
          set: { if !$0 { model.errorMessage = nil } }
        )
      ) {
        Button(L10n.text("common.ok")) { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
      .onChange(of: model.editingReminderID) { _, id in
        if id != nil { editorTitleFocused = true }
      }
      .onChange(of: model.editingFocusRequestID) { _, _ in
        Task { @MainActor in editorTitleFocused = true }
      }
      .onChange(of: model.islandState) { _, state in
        if state == .collapsed {
          hoveredSidebarItem = nil
          hoveredReminderID = nil
          editorTitleFocused = false
          newTaskFocused = false
        }
        // A pinned island is the typing surface: put the caret straight
        // into the Task Input so the first keystroke lands there. When the
        // click that pinned the Island is still in flight, the panel has
        // not become key yet and this request cannot land — the
        // taskInputFocusRequestID handler below re-issues it when it can.
        if state == .pinned, model.editingReminderID == nil {
          newTaskFocused = true
        }
      }
      .onChange(of: model.taskInputFocusRequestID) { _, _ in
        guard model.islandState == .pinned, model.editingReminderID == nil else { return }
        // Pass through false first: the pin already left the state true,
        // and re-asserting true alone would not re-issue the focus request.
        newTaskFocused = false
        Task { @MainActor in newTaskFocused = true }
      }
      .onAppear {
        updateExpandedContentHeight()
        syncMusicPanelActivity()
      }
      .onChange(of: selectedSidebarItem) { _, _ in updateExpandedContentHeight() }
      .onChange(of: model.islandState) { _, _ in syncMusicPanelActivity() }
      // Height must track exactly what expandedFeatureContent branches on.
      // canUseActiveList (not lists.count) is the real gate: it also flips
      // when the local store becomes available or the active list changes,
      // neither of which necessarily changes lists.count.
      .onChange(of: model.canUseActiveList) { _, _ in updateExpandedContentHeight() }
      .onChange(of: model.authorization) { _, _ in updateExpandedContentHeight() }
      .onPreferenceChange(CalendarPaneHeightKey.self) { height in
        guard height.isFinite, height > 0, calendarPaneIdealHeight != height else { return }
        calendarPaneIdealHeight = height
      }
      .onChange(of: calendarPaneIdealHeight) { _, _ in updateExpandedContentHeight() }
    }
  }

  private var islandShape: IslandSurfaceShape {
    IslandSurfaceShape(
      shoulderInset: model.islandState == .collapsed ? 0 : 8,
      topShoulderDepth: model.islandState == .collapsed ? 0 : expandedTopShoulderDepth,
      bottomRadius: model.islandState == .collapsed
        ? (hostDisplayHasNotch ? 14 : 18)
        : 36
    )
  }

  @ViewBuilder
  private var collapsedContent: some View {
    // With the feature expansion the collapsed bar no longer shows the
    // active-list title or the pending-count ring — the surface stays an
    // empty capsule (still hover-expandable). Recovery states keep their
    // lock/empty hints until replacement content lands.
    if hostDisplayHasNotch {
      HStack(spacing: 0) {
        if model.canUseActiveList {
          Color.clear.frame(width: collapsedSideWidth)
        } else {
          HStack(spacing: 4) {
            Image(systemName: model.authorization == .fullAccess ? "list.bullet" : "lock.fill")
            Text(model.authorization == .fullAccess ? "list.none" : "island.locked")
              .lineLimit(1)
          }
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.leading, 12)
          .padding(.trailing, 6)
          .frame(width: collapsedSideWidth, alignment: .leading)
          .clipped()
        }

        // Reserve the camera housing; all visible content stays outside it.
        Color.clear.frame(width: hostPhysicalNotchWidth)

        if model.canUseActiveList {
          Color.clear.frame(width: collapsedSideWidth)
        } else {
          Image(systemName: model.authorization == .fullAccess ? "list.bullet" : "lock.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.trailing, 12)
            .frame(width: collapsedSideWidth, alignment: .trailing)
        }
      }
      .frame(maxHeight: .infinity)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(collapsedAccessibilityLabel)
    } else if !model.canUseActiveList {
      HStack(spacing: 8) {
        Image(systemName: model.authorization == .fullAccess ? "list.bullet" : "lock.fill")
        Text(model.authorization == .fullAccess ? "list.none" : "island.locked")
          .lineLimit(1)
      }
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, 14)
      .accessibilityLabel(
        Text(model.authorization == .fullAccess ? "list.none" : "island.locked.accessibility"))
    } else {
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(collapsedAccessibilityLabel)
    }
  }

  private var expandedContent: some View {
    HStack(spacing: 0) {
      expandedSidebar
        .frame(width: 28)
        .frame(maxHeight: .infinity, alignment: .top)

      expandedFeatureContent
        .font(.system(size: 14.04))
        .controlSize(.mini)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .foregroundStyle(.white)
    // Wider than the shoulder inset so trailing content clears the concave
    // side edges of the surface shape.
    .padding(.horizontal, 12)
    .padding(.top, expandedContentTopInset)
    .padding(.bottom, 7)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var expandedSidebar: some View {
    VStack(spacing: 3) {
      ForEach(IslandSidebarItem.allCases) { item in
        Button {
          selectSidebar(item)
        } label: {
          Image(systemName: item.symbol)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(selectedSidebarItem == item ? .white : ReUITheme.muted)
            .frame(width: 24, height: 24)
            .background {
              // Liquid indicator: flows between icons as the pointer
              // slides across the sidebar.
              if selectedSidebarItem == item {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(.white.opacity(0.14))
                  .matchedGeometryEffect(id: "sidebar-glow", in: sidebarNS)
              }
            }
            .shadow(
              color: hoveredSidebarItem == item ? .white.opacity(0.82) : .clear,
              radius: hoveredSidebarItem == item ? 4.8 : 0
            )
        }
        .buttonStyle(.plain)
        .zIndex(selectedSidebarItem == item ? 1 : 0)
        .onHover { isHovering in
          hoveredSidebarItem = isHovering ? item : nil
          // Hover selects directly — no click needed.
          if isHovering, selectedSidebarItem != item {
            selectSidebar(item)
          }
        }
        .accessibilityLabel(item.title)
        .help(item.title)
        .accessibilityAddTraits(selectedSidebarItem == item ? .isSelected : [])
      }

      Spacer(minLength: 0)
    }
    .padding(.top, 4)
    .padding(.bottom, 2)
    .padding(.horizontal, 0)
  }

  /// Switches the active sidebar feature with the liquid transition.
  private func selectSidebar(_ item: IslandSidebarItem) {
    withAnimation(reduceMotion ? nil : .bouncy(duration: 0.35, extraBounce: 0.2)) {
      selectedSidebarItem = item
    }
    if item == .aiUsage {
      model.refreshAIUsage()
    }
    if item == .music {
      model.refreshFavorites()
    }
    syncMusicPanelActivity()
  }

  /// Elapsed-time polling runs only while the expanded island actually
  /// shows the music panel. Re-selected items never re-fire selectSidebar
  /// on re-expansion, so every visibility input reconciles here instead.
  private func syncMusicPanelActivity() {
    let active = model.islandState != .collapsed && selectedSidebarItem == .music
    model.setMusicPanelActive(active)
  }

  @ViewBuilder
  private var expandedFeatureContent: some View {
    switch selectedSidebarItem {
    case .reminders:
      remindersFeatureContent.transition(.opacity)
    case .aiUsage:
      AIUsagePanelView(snapshot: model.aiUsage).transition(.opacity)
    case .music:
      MusicPanelView().transition(.opacity)
    case .clipboard:
      ClipboardPanelView().transition(.opacity)
    case .placeholder4, .placeholder5, .placeholder6, .placeholder7:
      placeholderFeatureContent.transition(.opacity)
    }
  }

  @ViewBuilder
  private var remindersFeatureContent: some View {
    if model.canUseActiveList {
      // Both expanded states show the month calendar plus the Day
      // Schedule; the preview picks tighter metrics for its shorter
      // surface.
      calendarDayContent
    } else if model.authorization == .fullAccess {
      noListsContent
    } else {
      lockedContent
    }
  }

  /// Stub pane for the not-yet-built sidebar features.
  private var placeholderFeatureContent: some View {
    Text("sidebar.placeholder.detail")
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(ReUITheme.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  // MARK: Day Schedule (expanded content area)

  private var calendarDayContent: some View {
    let schedule = model.selectedDaySchedule
    let undated = model.undatedReminders
    let metrics = ScheduleMetrics.regular

    return HStack(alignment: .top, spacing: metrics.paneSpacing) {
      // fixedSize keeps the pane at its natural (unclipped, unstretched)
      // height so the background reader reports the true content height.
      monthCalendarPane(schedule: schedule, metrics: metrics)
        .fixedSize(horizontal: false, vertical: true)
        .animation(
          reduceMotion ? nil : .smooth(duration: 0.19),
          value: model.selectedDay
        )
        .frame(width: metrics.paneWidth, alignment: .top)
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: CalendarPaneHeightKey.self, value: geo.size.height)
          }
        )

      daySchedulePane(schedule: schedule, undated: undated, metrics: metrics)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Keeps the row cards clear of the surface's right edge.
        .padding(.trailing, 6)
    }
    // The panes share one height — the calendar pane's measured ideal — so
    // the Task Input's bottom edge lands exactly on the heatmap's bottom row.
    .frame(maxWidth: .infinity, alignment: .top)
    .frame(height: resolvedPaneHeight, alignment: .top)
  }

  /// The calendar pane's measured height once reported, else the metrics
  /// estimate for the first layout pass.
  private var resolvedPaneHeight: CGFloat {
    let measured = calendarPaneIdealHeight
    return measured > 0 ? measured : selectedSidebarItem.preferredContentHeight
  }

  /// One metric set serves both expanded states: the hover preview opens at
  /// the full pinned size, so there is no second, smaller layout.
  /// Internal so the sidebar's content height and tests can derive from it.
  struct ScheduleMetrics {
    let paneWidth: CGFloat
    let paneSpacing: CGFloat
    let titleSize: CGFloat
    let weekdaySize: CGFloat
    let daySize: CGFloat
    let circleSize: CGFloat
    let cellMinHeight: CGFloat
    let cellStackSpacing: CGFloat
    let weekSpacing: CGFloat
    let dotSize: CGFloat
    let dotSpacing: CGFloat
    let maxDayDots: Int
    let dayTitleSize: CGFloat
    let rowPitch: CGFloat
    let headerBottomPadding: CGFloat
    let rowTitleSize: CGFloat
    let rowDetailSize: CGFloat
    let rowGlyphSize: CGFloat
    /// Drops the month title so its center sits on the first schedule row's
    /// text center, keeping both panes' tops on one line.
    let paneTopPadding: CGFloat

    static let regular = ScheduleMetrics(
      paneWidth: 248,
      paneSpacing: 14,
      titleSize: 16,
      weekdaySize: 12.5,
      daySize: 14.5,
      circleSize: 26,
      cellMinHeight: 32,
      cellStackSpacing: 2,
      weekSpacing: 1,
      dotSize: 4,
      dotSpacing: 2,
      maxDayDots: 4,
      dayTitleSize: 14,
      rowPitch: 38,
      headerBottomPadding: 8,
      rowTitleSize: 12.5,
      rowDetailSize: 10.5,
      rowGlyphSize: 15,
      paneTopPadding: 2
    )

    /// Vertical gap between heatmap squares; kept here so the computed
    /// content height matches the grid heatmapSection draws.
    static let heatmapGap: CGFloat = 1.4

    /// Natural height of the calendar pane: month-title header, weekday row,
    /// the six-week grid, and the completion heatmap directly beneath. The
    /// window is sized to this, so the heatmap stays fully visible with no
    /// dead space below it.
    var remindersContentHeight: CGFloat {
      let weekRowCount = MonthCalendar.totalDayCount / 7
      let weekCount = CGFloat(weekRowCount)
      let gap = Self.heatmapGap
      let heatmapSide = (paneWidth - gap * CGFloat(ReminderHeatmap.defaultWeekCount - 1))
        / CGFloat(ReminderHeatmap.defaultWeekCount)
      let heatmapHeight: CGFloat = CGFloat(7) * heatmapSide + gap * CGFloat(6)
      // The month title and weekday symbols render in Chinese; PingFang's
      // line box is ≈1.4× the point size.
      let titleLine: CGFloat = titleSize * 1.4
      let weekdayLine: CGFloat = weekdaySize * 1.4
      let cellHeight = max(cellMinHeight, circleSize + cellStackSpacing + dotSize)
      let weekGrid = weekCount * cellHeight + CGFloat(weekRowCount - 1) * weekSpacing
      // title→weekday→grid gaps inside the inner VStack, plus the 2pt gap
      // above the heatmap, plus a line-metric rounding guard.
      let stackGaps: CGFloat = 8 + 4
      return paneTopPadding + titleLine + headerBottomPadding
        + weekdayLine + weekGrid + stackGaps + heatmapHeight
    }
  }

  private func monthCalendarPane(
    schedule: ReminderSchedule.DaySchedule,
    metrics: ScheduleMetrics
  ) -> some View {
    let calendar = Calendar.current
    let grid = MonthCalendar(containing: model.selectedDay, calendar: calendar)
    let counts = ReminderSchedule.dayCounts(in: model.monthReminders, calendar: calendar)
    let today = calendar.startOfDay(for: Date())

    return VStack(alignment: .leading, spacing: 2) {
      VStack(spacing: 3) {
      Text(grid.monthTitle)
        .font(.system(size: metrics.titleSize, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, metrics.headerBottomPadding)
        .padding(.top, metrics.paneTopPadding)

      HStack(spacing: 0) {
        ForEach(grid.weekdaySymbols, id: \.self) { symbol in
          Text(symbol)
            .font(.system(size: metrics.weekdaySize, weight: .medium))
            .foregroundStyle(ReUITheme.muted)
            .frame(maxWidth: .infinity)
        }
      }

      VStack(spacing: metrics.weekSpacing) {
        ForEach(0..<(MonthCalendar.totalDayCount / 7), id: \.self) { week in
          HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { weekday in
              if let day = grid.day(at: week * 7 + weekday) {
                calendarDayCell(day, today: today, counts: counts, metrics: metrics)
              }
            }
          }
        }
      }
      .overlay(alignment: .topLeading) {
        if let selection = selectionCellPosition(in: grid, calendar: calendar) {
          selectionBead(at: selection, metrics: metrics)
        }
      }
      }
      .id(grid.monthTitle)
      .transition(.opacity)

      // Keep completion history directly under the month grid.
      heatmapSection(metrics: metrics)
    }
  }

  private func calendarDayCell(
    _ day: MonthCalendar.Day,
    today: Date,
    counts: [Date: ReminderSchedule.DayCounts],
    metrics: ScheduleMetrics
  ) -> some View {
    let calendar = Calendar.current
    let dayDate = day.date
    let isSelected = calendar.isDate(dayDate, inSameDayAs: model.selectedDay)
    let isToday = calendar.isDateInToday(dayDate)
    let dayKey = calendar.startOfDay(for: dayDate)
    let dayCounts = counts[dayKey] ?? ReminderSchedule.DayCounts()
    let dayDotColors = listDotColors(for: dayKey, today: today, calendar: calendar)

    return Button {
      model.selectDay(dayDate)
    } label: {
      VStack(spacing: metrics.cellStackSpacing) {
        Text("\(calendar.component(.day, from: dayDate))")
          .font(.system(size: metrics.daySize, weight: isSelected || isToday ? .semibold : .regular))
          .foregroundStyle(
            dayCellTextColor(isSelected: isSelected, isToday: isToday, isInMonth: day.isInMonth)
          )
          .frame(width: metrics.circleSize, height: metrics.circleSize)
          .background {
            if isToday && !isSelected {
              Circle().strokeBorder(accentColor.opacity(0.75), lineWidth: 1)
            }
          }
        // One dot per List with pending items on that date, in the List's
        // own accent colour; gray means only completed ones remain.
        HStack(spacing: metrics.dotSpacing) {
          if dayDotColors.isEmpty {
            Circle()
              .fill(Color.white.opacity(0.42))
              .frame(width: metrics.dotSize, height: metrics.dotSize)
          } else {
            ForEach(dayDotColors.prefix(metrics.maxDayDots).indices, id: \.self) { index in
              Circle()
                .fill(dayDotColors[index])
                .frame(width: metrics.dotSize, height: metrics.dotSize)
            }
          }
        }
        .frame(height: metrics.dotSize)
        .opacity(dayDotColors.isEmpty && dayCounts.completed == 0 ? 0 : 1)
      }
      .frame(maxWidth: .infinity, minHeight: metrics.cellMinHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(dayDate, style: .date))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// The selected day's grid coordinates: week row and weekday column.
  private func selectionCellPosition(
    in grid: MonthCalendar,
    calendar: Calendar
  ) -> (week: Int, weekday: Int)? {
    for week in 0..<(MonthCalendar.totalDayCount / 7) {
      for weekday in 0..<7 {
        if let day = grid.day(at: week * 7 + weekday),
          calendar.isDate(day.date, inSameDayAs: model.selectedDay)
        {
          return (week, weekday)
        }
      }
    }
    return nil
  }

  /// The selection bead lives as a single grid-level overlay: switching
  /// days only changes its offset, so the spring animates a real position
  /// move — the bead always slides, and always draws above the numbers.
  private func selectionBead(
    at cell: (week: Int, weekday: Int),
    metrics: ScheduleMetrics
  ) -> some View {
    let cellWidth: CGFloat = metrics.paneWidth / 7
    let weekPitch: CGFloat = metrics.cellMinHeight + metrics.weekSpacing
    let beadSize: CGFloat = metrics.circleSize
    // Centre on the day-number frame (cell top half), not the whole cell —
    // the number is what the bead wraps.
    let beadX: CGFloat = CGFloat(cell.weekday) * cellWidth + cellWidth / 2 - beadSize / 2
    let beadY: CGFloat = CGFloat(cell.week) * weekPitch
      + metrics.circleSize / 2 - beadSize / 2
    return Circle()
      .fill(
        LinearGradient(
          colors: [accentColor.opacity(0.34), accentColor.opacity(0.58)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay {
        Circle()
          .fill(.white.opacity(0.3))
          .frame(width: beadSize * 0.3, height: beadSize * 0.2)
          .blur(radius: 1.2)
          .offset(x: -beadSize * 0.17, y: -beadSize * 0.22)
      }
      .shadow(color: accentColor.opacity(0.4), radius: 7, x: 0, y: 1)
      .frame(width: beadSize, height: beadSize)
      .offset(x: beadX, y: beadY)
  }

  private func dayCellTextColor(isSelected: Bool, isToday: Bool, isInMonth: Bool) -> Color {
    // White keeps the number readable through the translucent bead.
    if isSelected { return .white }
    if isToday { return accentColor }
    return isInMonth ? .white.opacity(0.85) : .white.opacity(0.3)
  }

  /// Fires a confetti burst at the row's checkmark when a Reminder is
  /// completed. Skipped under Reduce Motion.
  private func triggerConfetti(for reminderID: String, glyphSize: CGFloat) {
    guard !reduceMotion, let frame = rowFrames[reminderID] else { return }
    confettiBursts.append(
      ScheduledConfetti(
        center: CGPoint(x: frame.minX + glyphSize / 2, y: frame.midY)
      )
    )
  }

  /// Per-List dot colours for one day: one accent dot per List that has
  /// pending items there, ordered like the Lists themselves. Overdue items
  /// count toward today, matching the Day Schedule.
  private func listDotColors(for dayKey: Date, today: Date, calendar: Calendar) -> [Color] {
    var pendingByList: [String: Int] = [:]
    func count(_ reminders: [ReminderSnapshot]) {
      for reminder in reminders where !reminder.isCompleted {
        guard let due = reminder.dueDate(in: calendar),
          calendar.isDate(due, inSameDayAs: dayKey)
        else { continue }
        pendingByList[reminder.listID, default: 0] += 1
      }
    }
    count(model.monthReminders)
    if dayKey == today { count(model.overdueReminders) }

    guard !pendingByList.isEmpty else { return [] }
    return model.lists.compactMap { list in
      pendingByList[list.id] == nil ? nil : listAccent(for: list)
    }
  }

  private var newTaskTargetList: ReminderListSnapshot? {
    if let newTaskListID, let list = model.lists.first(where: { $0.id == newTaskListID }) {
      return list
    }
    return model.activeList
  }

  /// Compact Task Input: pick a list, type a title, Enter creates a Pending
  /// Reminder due on the selected date. Focus stays for consecutive entry.
  private var newTaskInput: some View {
    HStack(spacing: 7) {
      TextField(
        "task.add.placeholder",
        text: $newTaskTitle,
        axis: .horizontal
      )
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .frame(maxWidth: .infinity)
      .focused($newTaskFocused)
      .onSubmit { submitNewTask() }
      .accessibilityLabel(Text("task.add.accessibility"))

      Divider()
        .frame(height: 16)
        .overlay(ReUITheme.subtleBorder)

      newTaskListPicker

      Button(action: submitNewTask) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(newTaskTitle.isEmpty ? ReUITheme.muted : accentColor)
      }
      .buttonStyle(.plain)
      .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .frame(width: 22, height: 22)
      .accessibilityLabel(Text("task.add.submit"))
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .onTapGesture {
      newTaskFocused = true
    }
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(ReUITheme.item)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(
          newTaskFocused ? accentColor.opacity(0.72) : ReUITheme.border,
          lineWidth: 1
        )
    )
  }

  /// Chooses which Reminder List a new task lands in.
  private var newTaskListPicker: some View {
    let list = newTaskTargetList
    let accent = list.map(listAccent) ?? accentColor
    return Menu {
      ForEach(model.lists) { candidate in
        Button {
          newTaskListID = candidate.id
        } label: {
          if candidate.id == list?.id {
            Label(candidate.title, systemImage: "checkmark")
          } else {
            Text(candidate.title)
          }
        }
      }
    } label: {
      HStack(spacing: 2.5) {
        Circle().fill(accent).frame(width: 4, height: 4)
        Text(list?.title ?? L10n.text("list.none"))
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
      }
      .padding(.horizontal, 4)
      .frame(height: 22)
      .background(Capsule(style: .continuous).fill(accent.opacity(0.16)))
      .contentShape(Capsule())
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel(Text("task.add.list"))
  }

  private func submitNewTask() {
    let title = newTaskTitle
    guard let list = newTaskTargetList,
      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    model.createTask(title, on: model.selectedDay, in: list.id)
    newTaskTitle = ""
  }

  /// Mirrors expandedFeatureContent's branching exactly — the window must
  /// be sized for whichever content is actually on screen. The measured
  /// pane height belongs to the calendar alone; other items use their
  /// declared height.
  private func updateExpandedContentHeight() {
    let contentHeight: CGFloat
    switch selectedSidebarItem {
    case .aiUsage, .music, .clipboard, .placeholder4,
      .placeholder5, .placeholder6, .placeholder7:
      contentHeight = selectedSidebarItem.preferredContentHeight
    case .reminders:
      if model.canUseActiveList {
        let measured = calendarPaneIdealHeight
        contentHeight = measured > 0 ? measured : IslandSidebarItem.reminders.preferredContentHeight
      } else if model.authorization == .fullAccess {
        contentHeight = 185
      } else {
        contentHeight = 220
      }
    }
    model.updateExpandedContentHeight(contentHeight)
  }

  /// GitHub-style contribution grid: one square per day, tinted by how many
  /// Reminders were completed that day. The squares stretch so the grid
  /// spans exactly the calendar pane's width.
  private func heatmapSection(metrics: ScheduleMetrics) -> some View {
    // Derived once per data reload in AppModel; rebuilding it here would
    // rescan every completion on each render.
    let grid = model.heatmapGrid
    let gap = ScheduleMetrics.heatmapGap
    let side = (metrics.paneWidth - gap * CGFloat(ReminderHeatmap.defaultWeekCount - 1))
      / CGFloat(ReminderHeatmap.defaultWeekCount)
    return HStack(alignment: .top, spacing: gap) {
      ForEach(grid.weeks.indices, id: \.self) { column in
        VStack(spacing: gap) {
          ForEach(0..<7, id: \.self) { row in
            let day = grid.weeks[column][row]
            let count = day.flatMap { grid.counts[$0] } ?? 0
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
              .fill(heatmapColor(count: count, isActive: day != nil))
              .frame(width: side, height: side)
              .contentShape(Rectangle())
              .onHover { inside in
                guard day != nil else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                  heatmapHoverCell = inside
                    ? HeatmapCellPosition(column: column, row: row)
                    : nil
                }
              }
          }
        }
        // The count bubble floats right above the hovered cell; anchoring
        // it to the column keeps it centred without measuring text width.
        .overlay(alignment: .top) {
          if let hovered = heatmapHoverCell, hovered.column == column,
            let day = grid.weeks[column][hovered.row]
          {
            let count = grid.counts[day] ?? 0
            Text(heatmapCellTooltip(day: day, count: count))
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
              .offset(y: CGFloat(hovered.row) * (side + gap) - 24)
              .transition(.opacity)
              .zIndex(2)
          }
        }
      }
    }
    .frame(width: metrics.paneWidth, alignment: .leading)
  }

  /// Hover tooltip: the day's completion count. Only cells representing a
  /// real date get one; trailing future cells stay silent.
  private func heatmapCellTooltip(day: Date?, count: Int) -> String {
    guard let day else { return "" }
    let dateText = day.formatted(date: .abbreviated, time: .omitted)
    return String(format: L10n.text("heatmap.cell.tooltip"), dateText, count)
  }

  private func heatmapColor(count: Int, isActive: Bool) -> Color {
    guard isActive else { return Color.white.opacity(0.05) }
    switch count {
    case 0: return Color.white.opacity(0.14)
    case 1: return accentColor.opacity(0.35)
    case 2: return accentColor.opacity(0.60)
    case 3: return accentColor.opacity(0.85)
    default: return accentColor
    }
  }

  @ViewBuilder
  private func daySchedulePane(
    schedule: ReminderSchedule.DaySchedule,
    undated: [ReminderSnapshot],
    metrics: ScheduleMetrics
  ) -> some View {
    // The Task Input is pinned to the pane's bottom corner; the schedule
    // scrolls in the space above it. Completed Reminders are not listed —
    // once checked, a row disappears.
    VStack(spacing: 6) {
      if schedule.pending.isEmpty && undated.isEmpty {
        emptyDaySchedule
      } else {
        // No day title or section headers: the calendar already shows the
        // selected date, and undated rows carry their own tag.
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          LazyVStack(spacing: 0) {
            ForEach(schedule.pending) { reminder in
              dayRowWithEditor(reminder, metrics: metrics)
            }

            ForEach(undated) { reminder in
              dayRowWithEditor(reminder, metrics: metrics)
                .padding(.top, reminder.id == undated.first?.id ? 3 : 0)
            }
          }
          // Reserve bands matching the top/bottom fade overlays, so the
          // first and last rows sit outside them when the list is at rest.
          .padding(.top, 14)
          .padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: model.selectedReminderID) { _, id in
          guard let id else { return }
          withAnimation(reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0)) {
            proxy.scrollTo(id, anchor: .center)
          }
        }
        .animation(
          reduceMotion ? nil : .smooth(duration: 0.26, extraBounce: 0),
          value: model.visibleScheduleReminders.map(\.id)
        )
      }
      .clipped()
      .overlay(alignment: .top) {
        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
          .frame(height: 14)
          .allowsHitTesting(false)
      }
        .overlay(alignment: .bottom) {
          LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            .frame(height: 18)
            .allowsHitTesting(false)
        }
      }

      newTaskInput
    }
    .coordinateSpace(name: "daySchedule")
    .overlay {
      ForEach(confettiBursts) { burst in
        ConfettiBurstView(center: burst.center)
          .allowsHitTesting(false)
          .task {
            try? await Task.sleep(for: .seconds(1))
            confettiBursts.removeAll { $0.id == burst.id }
          }
      }
    }
  }

  @ViewBuilder
  private func dayRowWithEditor(
    _ reminder: ReminderSnapshot,
    metrics: ScheduleMetrics
  ) -> some View {
    dayRow(reminder, metrics: metrics)
      .frame(height: metrics.rowPitch)
      .id(reminder.id)
      .transition(.opacity.combined(with: .move(edge: .top)))

    if model.editingReminderID == reminder.id, let draft = model.draft {
      reminderEditor(draft)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 4)
        .id("editor-\(reminder.id)")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
  }

  private var emptyDaySchedule: some View {
    VStack(spacing: 3) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 18))
        .foregroundStyle(accentColor)
      Text("calendar.empty-day")
        .font(.system(size: 14.04, weight: .semibold))
      Text("calendar.empty-day.detail")
        .font(.system(size: 11.88))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(8)
  }

  private func dayRow(
    _ reminder: ReminderSnapshot,
    metrics: ScheduleMetrics
  ) -> some View {
    let isCompleting = model.completingReminderIDs.contains(reminder.id)
    let isSelected = model.selectedReminderID == reminder.id
    let isHovered = hoveredReminderID == reminder.id

    return HStack(spacing: 5) {
      Button {
        triggerConfetti(for: reminder.id, glyphSize: metrics.rowGlyphSize)
        model.complete(reminder)
      } label: {
        Image(systemName: isCompleting ? "checkmark.circle.fill" : "circle")
          .font(.system(size: metrics.rowGlyphSize, weight: .medium))
          .foregroundStyle(isCompleting ? Color.green : accentColor)
      }
      .buttonStyle(.plain)
      .disabled(isCompleting)
      .background(
        GeometryReader { geo in
          let frame = geo.frame(in: .named("daySchedule"))
          Color.clear
            .onAppear { rowFrames[reminder.id] = frame }
            .onChange(of: frame) { _, newFrame in
              rowFrames[reminder.id] = newFrame
            }
        }
      )
      .accessibilityLabel(
        Text(String(
          format: L10n.text("reminder.complete"),
          reminder.title)))

      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          Text(reminder.title)
            .font(.system(size: metrics.rowTitleSize, weight: .medium))
            .lineLimit(1)
          if let overdue = overdueDateLabel(for: reminder) {
            Text(overdue)
              .font(.system(size: metrics.rowDetailSize))
              .foregroundStyle(.red)
          }
        }
        if let time = dueTimeLabel(for: reminder) {
          Text(time)
            .font(.system(size: metrics.rowDetailSize))
            .foregroundStyle(ReUITheme.muted)
        }
      }

      Spacer(minLength: 4)

      listTag(for: reminder, metrics: metrics)
      if reminder.dueDateComponents == nil {
        undatedTag(metrics: metrics)
      }

      if reminder.priority != .none {
        Image(systemName: prioritySymbol(reminder.priority))
          .font(.system(size: metrics.rowDetailSize))
          .padding(.horizontal, 4.5)
          .padding(.vertical, 1.5)
          .background(Capsule(style: .continuous).fill(priorityColor(reminder.priority).opacity(0.14)))
          .overlay(Capsule(style: .continuous).stroke(priorityColor(reminder.priority).opacity(0.28), lineWidth: 1))
          .foregroundStyle(priorityColor(reminder.priority))
          .accessibilityLabel(priorityLabel(reminder.priority))
      }

      if isPinned {
        Menu {
          Button(L10n.text("reminder.edit")) { model.beginEditing(reminder) }
          Divider()
          Button(L10n.text("reminder.delete"), role: .destructive) {
            reminderPendingDeletion = reminder
          }
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 11, height: 11)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(Text(String(format: L10n.text("reminder.actions"), reminder.title)))
      }
    }
    .padding(.horizontal, 5.5)
    .padding(.vertical, 4)
    .background {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .fill(rowFill(isSelected: isSelected, isHovered: isHovered))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(isSelected ? accentColor.opacity(0.62) : ReUITheme.subtleBorder, lineWidth: 1)
    }
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0),
      value: isSelected
    )
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.12),
      value: isHovered
    )
    .onHover { hovering in
      hoveredReminderID = hovering ? reminder.id : (hoveredReminderID == reminder.id ? nil : hoveredReminderID)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      guard isPinned else { return }
      model.selectedReminderID = reminder.id
    }
    .onTapGesture(count: 2) {
      guard isPinned else { return }
      model.beginEditing(reminder)
    }
    .accessibilityElement(children: .contain)
  }

  /// The owning Reminder List as a colored capsule so the Day Schedule can
  /// aggregate across lists without losing provenance.
  @ViewBuilder
  private func listTag(for reminder: ReminderSnapshot, metrics: ScheduleMetrics) -> some View {
    if let list = model.lists.first(where: { $0.id == reminder.listID }) {
      let accent = listAccent(for: list)
      HStack(spacing: 2.5) {
        Circle().fill(accent).frame(width: 3.5, height: 3.5)
        Text(list.title)
          .font(.system(size: metrics.rowDetailSize, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 4.5)
      .padding(.vertical, 1.5)
      .background(Capsule(style: .continuous).fill(accent.opacity(0.14)))
      .overlay(Capsule(style: .continuous).stroke(accent.opacity(0.28), lineWidth: 1))
      .foregroundStyle(accent)
      .accessibilityLabel(Text(list.title))
    }
  }

  /// Marks reminders that have no Due Date, mirroring the Undated section.
  private func undatedTag(metrics: ScheduleMetrics) -> some View {
    Text("calendar.undated")
      .font(.system(size: metrics.rowDetailSize, weight: .medium))
      .lineLimit(1)
      .padding(.horizontal, 4.5)
      .padding(.vertical, 1.5)
      .background(Capsule(style: .continuous).fill(Color.white.opacity(0.07)))
      .overlay(Capsule(style: .continuous).stroke(ReUITheme.subtleBorder, lineWidth: 1))
      .foregroundStyle(ReUITheme.muted)
  }

  private func listAccent(for list: ReminderListSnapshot) -> Color {
    Color(
      .sRGB,
      red: list.accent.red,
      green: list.accent.green,
      blue: list.accent.blue,
      opacity: list.accent.alpha
    )
  }

  private func overdueDateLabel(for reminder: ReminderSnapshot) -> String? {
    guard reminder.dueDateComponents != nil else { return nil }
    let calendar = Calendar.current
    guard let due = reminder.dueDate(in: calendar),
      calendar.startOfDay(for: due) < calendar.startOfDay(for: model.selectedDay)
    else { return nil }
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("Md")
    return formatter.string(from: due)
  }

  private func dueTimeLabel(for reminder: ReminderSnapshot) -> String? {
    guard reminder.dueDateComponents?.hour != nil,
      let date = reminder.dueDate(in: .current)
    else { return nil }
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private func shiftDay(_ delta: Int) {
    guard
      let target = Calendar.current.date(byAdding: .day, value: delta, to: model.selectedDay)
    else { return }
    model.selectDay(target)
  }

  private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
    if isSelected { return ReUITheme.itemSelected }
    if isHovered { return ReUITheme.itemHover }
    return ReUITheme.item
  }

  private func reminderEditor(_ draft: ReminderDraft) -> some View {
    VStack(alignment: .leading, spacing: 5.5) {
      HStack(spacing: 4) {
        ZStack {
          Circle().fill(accentColor.opacity(0.18))
          Image(systemName: "pencil")
            .font(.system(size: 12.96, weight: .semibold))
            .foregroundStyle(accentColor)
        }
        .frame(width: 14, height: 14)

        Text("editor.edit-reminder")
          .font(.system(size: 12.96).weight(.semibold))

        Spacer()
      }

      HStack(spacing: 4.5) {
        Image(systemName: "text.cursor")
          .font(.system(size: 11.88))
          .foregroundStyle(editorTitleFocused ? accentColor : .secondary)
        TextField(
          L10n.text("editor.title.placeholder"),
          text: Binding(
            get: { model.draft?.title ?? "" },
            set: { model.draft?.title = $0 }
          )
        )
        .textFieldStyle(.plain)
        .focused($editorTitleFocused)
        .onSubmit { model.saveEditing() }
      }
      .padding(.horizontal, 5.5)
      .frame(height: 38)
      .background {
        RoundedRectangle(cornerRadius: 10)
          .fill(.white.opacity(editorTitleFocused ? 0.09 : 0.06))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            editorTitleFocused ? accentColor.opacity(0.75) : .white.opacity(0.09),
            lineWidth: editorTitleFocused ? 1.25 : 1
          )
      }

      VStack(spacing: 4) {
        HStack(spacing: 5) {
          ZStack {
            RoundedRectangle(cornerRadius: 8)
              .fill(draft.hasDueDate ? accentColor.opacity(0.18) : .white.opacity(0.06))
            Image(systemName: "calendar")
              .font(.system(size: 14.04, weight: .medium))
              .foregroundStyle(draft.hasDueDate ? accentColor : .secondary)
          }
          .frame(width: 30, height: 30)

          Text("editor.due-date")
            .font(.system(size: 12.96).weight(.medium))

          Spacer()

          Toggle(
            "",
            isOn: Binding(
              get: { model.draft?.hasDueDate ?? false },
              set: { model.draft?.hasDueDate = $0 }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .tint(accentColor)
        }

        if draft.hasDueDate {
          Divider().overlay(.white.opacity(0.08))

          HStack(spacing: 5) {
            DatePicker(
              "",
              selection: Binding(
                get: { model.draft?.dueDate ?? Date() },
                set: { model.draft?.dueDate = $0 }
              ),
              displayedComponents: draft.includesTime
                ? [.date, .hourAndMinute] : [.date]
            )
            .labelsHidden()
            .controlSize(.small)

            Spacer()

            Toggle(
              L10n.text("editor.time"),
              isOn: Binding(
                get: { model.draft?.includesTime ?? false },
                set: { model.draft?.includesTime = $0 }
              )
            )
            .toggleStyle(.checkbox)
            .controlSize(.small)
          }
          .transition(.opacity.combined(with: .move(edge: .top)))
        }
      }
      .padding(.horizontal, 5)
      .padding(.vertical, 4)
      .background {
        RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.04))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.08), lineWidth: 1)
      }
      .animation(
        reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0),
        value: draft.hasDueDate
      )

      HStack(spacing: 4.5) {
        Label(L10n.text("editor.priority"), systemImage: "flag")
          .font(.system(size: 11.88).weight(.semibold))
          .foregroundStyle(.secondary)

        HStack(spacing: 5) {
          ForEach(
            [ReminderPriority.none, .low, .medium, .high],
            id: \.self
          ) { priority in
            priorityOption(priority, selectedPriority: draft.priority)
          }
        }
      }

      HStack(spacing: 4.5) {
        Spacer()
        Button(L10n.text("common.cancel")) { model.cancelEditing() }
          .buttonStyle(.bordered)
          .controlSize(.regular)

        Button(L10n.text("common.save")) { model.saveEditing() }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
          .tint(accentColor)
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canSaveEditingDraft)
      }
    }
    .padding(6.5)
    .background {
      RoundedRectangle(cornerRadius: 14)
        .fill(ReUITheme.panel)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(accentColor.opacity(0.34), lineWidth: 1)
    }
  }

  private func priorityOption(
    _ priority: ReminderPriority,
    selectedPriority: ReminderPriority
  ) -> some View {
    let isSelected = priority == selectedPriority
    let color = priority == .none ? accentColor : priorityColor(priority)
    let symbol = priority == .none ? "minus" : prioritySymbol(priority)

    return Button {
      model.draft?.priority = priority
    } label: {
      HStack(spacing: 2) {
        Image(systemName: symbol)
          .font(.system(size: 9.72, weight: .bold))
        priorityLabel(priority)
          .font(.system(size: 11.88).weight(.medium))
      }
      .foregroundStyle(isSelected ? color : .secondary)
      .frame(maxWidth: .infinity)
      .frame(height: 28)
      .background {
        RoundedRectangle(cornerRadius: 8)
          .fill(isSelected ? color.opacity(0.16) : .white.opacity(0.035))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(isSelected ? color.opacity(0.65) : .white.opacity(0.07), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.18, extraBounce: 0),
      value: isSelected
    )
  }

  private var lockedContent: some View {
    VStack(spacing: 10) {
      Image(systemName: "lock.shield.fill")
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(accentColor)
      Text("permission.required")
        .font(.system(size: 18, weight: .semibold))
      Text("permission.required.detail")
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 390)
      Text("permission.privacy")
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 390)
      if model.islandState.showsAuthorizationActions {
        if model.isRequestingAccess {
          ProgressView()
            .controlSize(.regular)
            .tint(accentColor)
        } else {
          Button(
            L10n.text(
              model.authorization == .notDetermined
                ? "permission.allow"
                : "permission.open-settings")
          ) {
            if model.authorization == .notDetermined {
              Task { await model.requestAccess() }
            } else {
              SystemSettings.openRemindersPrivacy()
            }
          }
          .buttonStyle(.borderedProminent)
          .font(.system(size: 13.5, weight: .semibold))
          .controlSize(.large)
          .tint(accentColor)

        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }

  private var noListsContent: some View {
    VStack(spacing: 5) {
      Image(systemName: "list.bullet")
        .font(.system(size: 18))
        .foregroundStyle(accentColor)
      Text("list.no-icloud").font(.system(size: 14.04, weight: .semibold))
      Text("list.no-icloud.detail")
        .font(.system(size: 11.88))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if isPinned {
        VStack(spacing: 4) {
          Button("list.new-icloud") {
            model.requestNewList(source: .iCloud)
          }
          .buttonStyle(.borderedProminent)
          .tint(accentColor)
          HStack(spacing: 5) {
            Button("list.open-reminders") {
              SystemSettings.openReminders()
            }
            Button("list.check-again") {
              Task { await model.reload() }
            }
          }
        }
        .padding(.top, 2)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(10)
  }

  private var accentColor: Color {
    let accent = model.activeList?.accent ?? .fallback
    return Color(
      .sRGB, red: accent.red, green: accent.green, blue: accent.blue, opacity: accent.alpha)
  }

  @ViewBuilder
  private var sourceGlyph: some View {
    if let source = model.activeList?.source {
      Image(systemName: source.symbolName)
        .accessibilityHidden(true)
    }
  }

  private var hostDisplayHasNotch: Bool {
    guard let screen = DisplaySupport.screen(id: model.hostDisplayID) else { return false }
    return DisplaySupport.metrics(for: screen).hasPhysicalNotch
  }

  private var hostPhysicalNotchWidth: CGFloat {
    guard let screen = DisplaySupport.screen(id: model.hostDisplayID) else { return 0 }
    return DisplaySupport.metrics(for: screen).physicalNotchWidth
  }

  private var expandedTopShoulderDepth: CGFloat { 8 }

  private var collapsedSideWidth: CGFloat {
    max(0, (islandSurfaceSize.width - hostPhysicalNotchWidth) / 2)
  }

  private var expandedContentTopInset: CGFloat {
    guard let screen = DisplaySupport.screen(id: model.hostDisplayID) else { return 16 }
    return max(16, DisplaySupport.metrics(for: screen).safeAreaTop + 6)
  }

  private var islandSurfaceSize: CGSize {
    guard let screen = DisplaySupport.screen(id: model.hostDisplayID) else { return .zero }
    return DisplayGeometryCalculator.geometry(
      for: DisplaySupport.metrics(for: screen),
      expandedContentHeight: model.expandedContentHeight
    )
      .size(for: model.islandState)
  }

  private var collapsedAccessibilityLabel: Text {
    Text(
      String(
        format: L10n.text("island.collapsed.accessibility"),
        model.activeList?.title ?? L10n.text("list.none"),
        model.remainingCount))
  }

  private var remainingCountRing: some View {
    ZStack(alignment: .center) {
      Circle()
        .stroke(.green, lineWidth: 3)
      Text("\(model.remainingCount)")
        .font(.system(size: 9, weight: .black, design: .rounded))
        .foregroundStyle(.green)
        .monospacedDigit()
        .contentTransition(.numericText())
        .minimumScaleFactor(0.7)
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    .frame(width: 18, height: 18)
    .animation(
      reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0),
      value: model.remainingCount
    )
  }

  private var surfaceAnimation: Animation? {
    guard !reduceMotion else { return nil }
    let motion = model.islandState.motionProfile
    return .spring(
      response: motion.response,
      dampingFraction: motion.dampingFraction,
      blendDuration: 0.04
    )
  }

  private func prioritySymbol(_ priority: ReminderPriority) -> String {
    switch priority {
    case .high: "exclamationmark.3"
    case .medium: "exclamationmark.2"
    case .low: "exclamationmark"
    case .none: ""
    }
  }

  private func priorityColor(_ priority: ReminderPriority) -> Color {
    switch priority {
    case .high: .red
    case .medium: .orange
    case .low: .yellow
    case .none: .secondary
    }
  }

  private func priorityLabel(_ priority: ReminderPriority) -> Text {
    switch priority {
    case .high: Text("priority.high")
    case .medium: Text("priority.medium")
    case .low: Text("priority.low")
    case .none: Text("priority.none")
    }
  }

  private func handleKeyEvent(_ event: NSEvent) -> Bool {
    // Typing while the hover preview shows pins the island and routes the
    // caret into the Task Input — the preview surface can't take keys.
    if model.islandState == .preview, event.type == .keyDown,
      event.charactersIgnoringModifiers?.isEmpty == false,
      event.modifierFlags.isDisjoint(with: [.command, .control, .option])
    {
      model.pinIsland()
      newTaskFocused = true
    }

    guard isPinned else { return false }

    if event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "n"
    {
      newTaskFocused = true
      return true
    }

    let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
    if event.keyCode == 53, model.editingReminderID != nil {
      model.cancelEditing()
      return true
    }
    if isEditingText { return false }
    if event.keyCode == 53 {
      model.collapseIsland()
      return true
    }

    switch event.keyCode {
    case 125:
      model.moveSelection(1)
      return true
    case 126:
      model.moveSelection(-1)
      return true
    case 123:
      shiftDay(-1)
      return true
    case 124:
      shiftDay(1)
      return true
    case 36:
      if let selected = model.selectedReminder {
        model.beginEditing(selected)
        return true
      }
    case 49:
      if let selected = model.selectedReminder {
        triggerConfetti(
          for: selected.id,
          glyphSize: ScheduleMetrics.regular.rowGlyphSize
        )
        model.complete(selected)
        return true
      }
    case 51, 117:
      if let selected = model.selectedReminder {
        reminderPendingDeletion = selected
        return true
      }
    default:
      break
    }
    return false
  }
}

/// A one-shot confetti burst: a handful of coloured paper scraps explode
/// from `center`, spin while flying outward, and fade as they land.
private struct ConfettiBurstView: View {
  let center: CGPoint

  @State private var launched = false

  private let particles: [Particle]

  init(center: CGPoint) {
    self.center = center
    let palette: [Color] = [.green, .cyan, .orange, .pink, .yellow, .white]
    particles = (0..<18).map { _ in
      Particle(
        angle: Double.random(in: 0..<(2 * .pi)),
        distance: CGFloat.random(in: 30...72),
        size: CGSize(width: CGFloat.random(in: 3...5), height: CGFloat.random(in: 5...9)),
        color: palette.randomElement() ?? .green,
        spin: Double.random(in: -260...260)
      )
    }
  }

  var body: some View {
    ZStack {
      ForEach(particles) { particle in
        RoundedRectangle(cornerRadius: 1)
          .fill(particle.color)
          .frame(width: particle.size.width, height: particle.size.height)
          .rotationEffect(.degrees(launched ? particle.spin : 0))
          .offset(
            x: launched ? cos(particle.angle) * particle.distance : 0,
            y: launched ? sin(particle.angle) * particle.distance : 0
          )
          .opacity(launched ? 0 : 1)
      }
    }
    .position(center)
    .allowsHitTesting(false)
    .onAppear {
      withAnimation(.easeOut(duration: 0.75)) {
        launched = true
      }
    }
  }

  private struct Particle: Identifiable {
    let id = UUID()
    let angle: Double
    let distance: CGFloat
    let size: CGSize
    let color: Color
    let spin: Double
  }
}
