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

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .reminders: "sidebar.reminders"
    }
  }

  var symbol: String {
    switch self {
    case .reminders: "checklist"
    }
  }
}

struct IslandRootView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var editorTitleFocused: Bool
  @State private var reminderPendingDeletion: ReminderSnapshot?
  @State private var selectedSidebarItem: IslandSidebarItem = .reminders
  @State private var hoveredSidebarItem: IslandSidebarItem?
  @State private var hoveredReminderID: String?

  private var isPinned: Bool { model.islandState == .pinned }

  /// Native equivalents of ReUI's shadcn surface tokens.
  private enum ReUITheme {
    static let panel = Color(red: 0.055, green: 0.063, blue: 0.078)
    static let item = Color(red: 0.095, green: 0.106, blue: 0.13)
    static let itemHover = Color(red: 0.135, green: 0.15, blue: 0.18)
    static let itemSelected = Color(red: 0.11, green: 0.16, blue: 0.22)
    static let border = Color.white.opacity(0.105)
    static let subtleBorder = Color.white.opacity(0.065)
    static let muted = Color.white.opacity(0.58)
  }

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
        if !isPinned { model.pinIsland() }
      }
      .background(KeyboardEventMonitor(handler: handleKeyEvent))
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
        }
      }
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
    if hostDisplayHasNotch {
      HStack(spacing: 0) {
        HStack(spacing: 4) {
          if model.canUseActiveList {
            sourceGlyph
          } else {
            Image(systemName: model.authorization == .fullAccess ? "list.bullet" : "lock.fill")
          }
          Text(model.activeList?.title ?? L10n.text("list.none"))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(width: collapsedSideWidth, alignment: .leading)
        .clipped()

        // Reserve the camera housing; all visible content stays outside it.
        Color.clear.frame(width: hostPhysicalNotchWidth)

        Group {
          if model.canUseActiveList {
            remainingCountRing
          } else {
            Image(systemName: model.authorization == .fullAccess ? "list.bullet" : "lock.fill")
          }
        }
        .padding(.trailing, 12)
        .frame(width: collapsedSideWidth, alignment: .trailing)
      }
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.white)
      .frame(maxHeight: .infinity)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(collapsedAccessibilityLabel)
    } else if !model.canUseActiveList {
      HStack(spacing: 8) {
        Image(systemName: model.authorization == .fullAccess ? "list.bullet" : "lock.fill")
        Text(model.authorization == .fullAccess ? "list.none" : "island.locked")
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(maxHeight: .infinity)
      .accessibilityLabel(
        Text(model.authorization == .fullAccess ? "list.none" : "island.locked.accessibility"))
    } else {
      HStack(alignment: .center, spacing: 8) {
        sourceGlyph
          .frame(width: 18, height: 18, alignment: .center)
        Text(model.activeList?.title ?? L10n.text("list.none"))
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(height: 18, alignment: .center)
        Spacer(minLength: 4)
        remainingCountRing
      }
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            selectedSidebarItem = item
          }
        } label: {
          Image(systemName: item.symbol)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .shadow(
              color: hoveredSidebarItem == item ? .white.opacity(0.82) : .clear,
              radius: hoveredSidebarItem == item ? 4.8 : 0
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
          hoveredSidebarItem = isHovering ? item : nil
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

  @ViewBuilder
  private var expandedFeatureContent: some View {
    switch selectedSidebarItem {
    case .reminders:
      if model.needsCollapsedIslandVisibilityChoice {
        initialSetupContent
      } else if model.canUseActiveList {
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
  }

  private var initialSetupContent: some View {
    VStack(spacing: 7) {
      Image(systemName: "macwindow")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(accentColor)

      VStack(spacing: 2.5) {
        Text("setup.visibility.title")
          .font(.system(size: 14.04, weight: .semibold))
        Text("setup.visibility.detail")
          .font(.system(size: 11.88))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      HStack(spacing: 6) {
        visibilityCard(
          .alwaysVisible,
          titleKey: "setup.visibility.always-visible",
          detailKey: "setup.visibility.always-visible.detail",
          symbol: "eye.fill"
        )
        visibilityCard(
          .autoHide,
          titleKey: "setup.visibility.auto-hide",
          detailKey: "setup.visibility.auto-hide.detail",
          symbol: "eye.slash.fill"
        )
      }

      Text("setup.visibility.choose-first")
        .font(.system(size: 10.8))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(10)
  }

  private func visibilityCard(
    _ visibility: CollapsedIslandVisibility,
    titleKey: LocalizedStringKey,
    detailKey: LocalizedStringKey,
    symbol: String
  ) -> some View {
    Button {
      model.setCollapsedIslandVisibility(visibility)
    } label: {
      VStack(spacing: 4) {
        Image(systemName: symbol)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(accentColor)
        Text(titleKey)
          .font(.system(size: 14.04, weight: .semibold))
          .foregroundStyle(.primary)
        Text(detailKey)
          .font(.system(size: 10.8))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 112)
      .padding(.horizontal, 5)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(.white.opacity(0.075))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  // MARK: Day Schedule (expanded content area)

  private var calendarDayContent: some View {
    let schedule = model.selectedDaySchedule
    let undated = model.undatedReminders
    let metrics = ScheduleMetrics.regular

    return HStack(alignment: .top, spacing: metrics.paneSpacing) {
      monthCalendarPane(
        schedule: schedule,
        undated: undated,
        undatedCompleted: model.completedUndatedToday,
        metrics: metrics)
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: metrics.paneWidth, alignment: .top)

      daySchedulePane(schedule: schedule, undated: undated, metrics: metrics)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Keeps the row cards clear of the surface's right edge.
        .padding(.trailing, 6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// One metric set serves both expanded states: the hover preview opens at
  /// the full pinned size, so there is no second, smaller layout.
  private struct ScheduleMetrics {
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
      paneWidth: 232,
      paneSpacing: 12,
      titleSize: 14,
      weekdaySize: 11,
      daySize: 12.5,
      circleSize: 22,
      cellMinHeight: 28,
      cellStackSpacing: 2,
      weekSpacing: 2,
      dotSize: 3.5,
      dayTitleSize: 14,
      rowPitch: 38,
      headerBottomPadding: 8,
      rowTitleSize: 12.5,
      rowDetailSize: 10.5,
      rowGlyphSize: 15,
      paneTopPadding: 8
    )
  }

  private func monthCalendarPane(
    schedule: ReminderSchedule.DaySchedule,
    undated: [ReminderSnapshot],
    undatedCompleted: [ReminderSnapshot],
    metrics: ScheduleMetrics
  ) -> some View {
    let calendar = Calendar.current
    let grid = MonthCalendar(containing: model.selectedDay, calendar: calendar)
    let counts = ReminderSchedule.dayCounts(in: model.monthReminders, calendar: calendar)
    let today = calendar.startOfDay(for: Date())

    return VStack(spacing: 0) {
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
      }

      Spacer(minLength: 8)

      heatmapSection(metrics: metrics)

      Spacer(minLength: 8)

      dayProgressSection(
        schedule: schedule,
        undated: undated,
        undatedCompleted: undatedCompleted,
        metrics: metrics)
    }
  }

  /// GitHub-style contribution grid: one square per day, tinted by how many
  /// Reminders were completed that day. The squares stretch so the grid
  /// spans exactly the calendar pane's width.
  private func heatmapSection(metrics: ScheduleMetrics) -> some View {
    let grid = ReminderHeatmap.grid(in: model.recentlyCompletedReminders)
    let gap: CGFloat = 1.2
    let side = (metrics.paneWidth - gap * CGFloat(ReminderHeatmap.defaultWeekCount - 1))
      / CGFloat(ReminderHeatmap.defaultWeekCount)
    return HStack(alignment: .top, spacing: gap) {
      ForEach(grid.weeks.indices, id: \.self) { column in
        VStack(spacing: gap) {
          ForEach(0..<7, id: \.self) { row in
            let day = grid.weeks[column][row]
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
              .fill(heatmapColor(count: day.flatMap { grid.counts[$0] } ?? 0, isActive: day != nil))
              .frame(width: side, height: side)
          }
        }
      }
    }
    .frame(width: metrics.paneWidth, alignment: .leading)
  }

  private func heatmapColor(count: Int, isActive: Bool) -> Color {
    guard isActive else { return Color.white.opacity(0.05) }
    switch count {
    case 0: return Color.white.opacity(0.10)
    case 1: return accentColor.opacity(0.35)
    case 2: return accentColor.opacity(0.60)
    case 3: return accentColor.opacity(0.85)
    default: return accentColor
    }
  }

  private struct DayProgressRow: Identifiable {
    let list: ReminderListSnapshot
    let total: Int
    let completed: Int
    var id: String { list.id }
  }

  /// Per-list completion progress for the selected day, mirroring the rows
  /// shown in the Day Schedule.
  private func dayProgressSection(
    schedule: ReminderSchedule.DaySchedule,
    undated: [ReminderSnapshot],
    undatedCompleted: [ReminderSnapshot],
    metrics: ScheduleMetrics
  ) -> some View {
    // Undated reminders form the day's standing pool, so they count toward
    // the day's progress: pending ones as remaining work, ones completed
    // today as done.
    let rows = dayProgressRows(
      schedule: schedule,
      undatedPending: undated,
      undatedCompleted: undatedCompleted)
    return VStack(alignment: .leading, spacing: 6) {
      ForEach(rows) { row in
        let accent = listAccent(for: row.list)
        let fraction = row.total > 0 ? Double(row.completed) / Double(row.total) : 0
        let isComplete = row.completed == row.total
        VStack(alignment: .leading, spacing: 2.5) {
          HStack(spacing: 3) {
            Circle().fill(accent).frame(width: 3.5, height: 3.5)
            Text(row.list.title)
              .font(.system(size: metrics.rowDetailSize, weight: .medium))
              .foregroundStyle(.white.opacity(0.85))
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 4)
            Text("\(Int((fraction * 100).rounded()))%")
              .font(.system(size: metrics.rowDetailSize, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(isComplete ? Color.green : ReUITheme.muted)
          }
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Capsule(style: .continuous).fill(Color.white.opacity(0.10))
              Capsule(style: .continuous)
                .fill(isComplete ? Color.green : accent)
                .frame(width: max(4, proxy.size.width * fraction))
            }
          }
          .frame(height: 8)
        }
      }
    }
  }

  private func dayProgressRows(
    schedule: ReminderSchedule.DaySchedule,
    undatedPending: [ReminderSnapshot],
    undatedCompleted: [ReminderSnapshot]
  ) -> [DayProgressRow] {
    var counts: [String: (total: Int, completed: Int)] = [:]
    for reminder in schedule.pending + schedule.completed + undatedPending + undatedCompleted {
      let entry = counts[reminder.listID] ?? (0, 0)
      counts[reminder.listID] = reminder.isCompleted
        ? (entry.total + 1, entry.completed + 1)
        : (entry.total + 1, entry.completed)
    }
    return counts.compactMap { listID, count in
      guard let list = model.lists.first(where: { $0.id == listID }) else { return nil }
      return DayProgressRow(list: list, total: count.total, completed: count.completed)
    }
    .sorted { $0.list.title.localizedStandardCompare($1.list.title) == .orderedAscending }
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
    let dayCounts = counts[calendar.startOfDay(for: dayDate)] ?? ReminderSchedule.DayCounts()

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
            if isSelected {
              Circle().fill(accentColor)
            } else if isToday {
              Circle().strokeBorder(accentColor.opacity(0.75), lineWidth: 1)
            }
          }
        // Accent marks days with pending items; gray means only completed
        // ones remain on that date.
        Circle()
          .fill(dayCounts.pending > 0 ? accentColor : Color.white.opacity(0.42))
          .frame(width: metrics.dotSize, height: metrics.dotSize)
          .opacity(dayCounts.isEmpty ? 0 : 1)
      }
      .frame(maxWidth: .infinity, minHeight: metrics.cellMinHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(dayDate, style: .date))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func dayCellTextColor(isSelected: Bool, isToday: Bool, isInMonth: Bool) -> Color {
    if isSelected { return .black }
    if isToday { return accentColor }
    return isInMonth ? .white.opacity(0.85) : .white.opacity(0.3)
  }

  @ViewBuilder
  private func daySchedulePane(
    schedule: ReminderSchedule.DaySchedule,
    undated: [ReminderSnapshot],
    metrics: ScheduleMetrics
  ) -> some View {
    if schedule.pending.isEmpty && schedule.completed.isEmpty && undated.isEmpty {
      emptyDaySchedule
    } else {
      // No day title or section headers: the calendar already shows the
      // selected date, completed rows are struck through and muted, and
      // undated rows carry their own tag.
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          LazyVStack(spacing: 0) {
            ForEach(schedule.pending) { reminder in
              dayRowWithEditor(reminder, isCompleted: false, metrics: metrics)
            }

            ForEach(schedule.completed) { reminder in
              dayRowWithEditor(reminder, isCompleted: true, metrics: metrics)
                .padding(.top, reminder.id == schedule.completed.first?.id ? 3 : 0)
            }

            ForEach(undated) { reminder in
              dayRowWithEditor(reminder, isCompleted: false, metrics: metrics)
                .padding(.top, reminder.id == undated.first?.id ? 3 : 0)
            }
          }
          .padding(.vertical, 2)
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
  }

  @ViewBuilder
  private func dayRowWithEditor(
    _ reminder: ReminderSnapshot,
    isCompleted: Bool,
    metrics: ScheduleMetrics
  ) -> some View {
    dayRow(reminder, isCompleted: isCompleted, metrics: metrics)
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
    isCompleted: Bool,
    metrics: ScheduleMetrics
  ) -> some View {
    let isCompleting = model.completingReminderIDs.contains(reminder.id)
    let isSelected = model.selectedReminderID == reminder.id
    let isHovered = hoveredReminderID == reminder.id

    return HStack(spacing: 5) {
      Button {
        if isCompleted {
          model.reopen(reminder)
        } else {
          model.complete(reminder)
        }
      } label: {
        Image(systemName: circleSymbol(isCompleted: isCompleted, isCompleting: isCompleting))
          .font(.system(size: metrics.rowGlyphSize, weight: .medium))
          .foregroundStyle(circleColor(isCompleted: isCompleted, isCompleting: isCompleting))
      }
      .buttonStyle(.plain)
      .disabled(isCompleting)
      .accessibilityLabel(
        Text(String(
          format: L10n.text(isCompleted ? "reminder.reopen" : "reminder.complete"),
          reminder.title)))

      VStack(alignment: .leading, spacing: 1) {
        Text(reminder.title)
          .font(.system(size: metrics.rowTitleSize, weight: .medium))
          .strikethrough(isCompleted, color: .white.opacity(0.4))
          .foregroundStyle(isCompleted ? ReUITheme.muted : .primary)
          .lineLimit(1)
        if let overdue = overdueDateLabel(for: reminder, isCompleted: isCompleted) {
          Text(overdue)
            .font(.system(size: metrics.rowDetailSize))
            .foregroundStyle(.red)
        } else if let time = dueTimeLabel(for: reminder) {
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

      if !isCompleted && reminder.priority != .none {
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

  private func circleSymbol(isCompleted: Bool, isCompleting: Bool) -> String {
    if isCompleting { return isCompleted ? "circle" : "checkmark.circle.fill" }
    return isCompleted ? "checkmark.circle.fill" : "circle"
  }

  private func circleColor(isCompleted: Bool, isCompleting: Bool) -> Color {
    if isCompleting { return isCompleted ? ReUITheme.muted : .green }
    return isCompleted ? ReUITheme.muted : accentColor
  }

  /// Carried-over rows show how old the reminder is, in red, instead of a
  /// due time.
  private func overdueDateLabel(for reminder: ReminderSnapshot, isCompleted: Bool) -> String? {
    guard !isCompleted, reminder.dueDateComponents != nil else { return nil }
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
    VStack(spacing: 6) {
      Image(systemName: "lock.shield.fill")
        .font(.system(size: 20.4))
        .foregroundStyle(accentColor)
      Text("permission.required")
        .font(.system(size: 14.04, weight: .semibold))
      Text("permission.required.detail")
        .font(.system(size: 11.88))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Text("permission.privacy")
        .font(.system(size: 10.8))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if model.islandState.showsAuthorizationActions {
        if model.isRequestingAccess {
          ProgressView()
            .controlSize(.small)
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
          .tint(accentColor)

        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(12)
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
    return DisplayGeometryCalculator.geometry(for: DisplaySupport.metrics(for: screen))
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
    guard isPinned else { return false }

    if model.needsCollapsedIslandVisibilityChoice {
      guard event.keyCode == 53 else { return false }
      model.collapseIsland()
      return true
    }

    let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
    if event.keyCode == 53 {
      if model.editingReminderID != nil {
        model.cancelEditing()
      } else {
        model.collapseIsland()
      }
      return true
    }
    if isEditingText { return false }

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
