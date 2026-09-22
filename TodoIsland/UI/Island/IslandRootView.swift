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
  @FocusState private var listNameFocused: Bool
  @State private var reminderPendingDeletion: ReminderSnapshot?
  @State private var listPendingRename: ReminderListSnapshot?
  @State private var listNameDraft = ""
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
      .confirmationDialog(
        L10n.text("list.delete.title"),
        isPresented: Binding(
          get: { model.listDeletionCandidate != nil },
          set: { if !$0 { model.cancelListDeletion() } }
        )
      ) {
        if let candidate = model.listDeletionCandidate {
          Button(L10n.text("list.delete.confirm"), role: .destructive) {
            Task { await model.confirmListDeletion(candidate) }
          }
        }
        Button(L10n.text("common.cancel"), role: .cancel) {
          model.cancelListDeletion()
        }
      } message: {
        if let candidate = model.listDeletionCandidate {
          Text(
            String(
              format: L10n.text("list.delete.detail"),
              candidate.list.title,
              candidate.pendingCount,
              candidate.completedCount
            ))
        }
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
      .onChange(of: model.requestedListCreationSource) { previousSource, source in
        guard source != nil else { return }
        listPendingRename = nil
        if ListCreationDraftPolicy.shouldResetName(
          previousSource: previousSource,
          newSource: source
        ) {
          listNameDraft = ""
        }
        Task { @MainActor in listNameFocused = true }
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

      listManagementMenu
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
      } else if model.requestedListCreationSource != nil {
        listCreationForm
      } else if listPendingRename != nil {
        listRenameForm
      } else if model.canUseActiveList {
        // Both expanded states show the month calendar plus the Day
        // Schedule; the preview picks tighter metrics for its shorter
        // surface.
        calendarDayContent
      } else if model.preferredEmptySource == .local,
        model.localStoreAvailability == .available
      {
        localEmptyContent
      } else if case .unavailable = model.localStoreAvailability,
        model.authorization == .fullAccess
      {
        localStoreUnavailableContent
      } else if model.authorization == .fullAccess {
        noListsContent
      } else {
        lockedContent
      }
    }
  }

  /// List switching and management lives at the bottom of the sidebar rail
  /// since the expanded layout no longer has a header row.
  private var listManagementMenu: some View {
    Menu {
      listMenuContent
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.75))
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .accessibilityLabel(Text("list.switch"))
    .disabled(model.needsCollapsedIslandVisibilityChoice)
  }

  @ViewBuilder
  private var listMenuContent: some View {
    Section(L10n.text("source.icloud")) {
      switch model.iCloudSourceMenuState {
      case .available:
        ForEach(model.iCloudLists) { list in
          listSelectionButton(list)
        }
      case .authorizationRequired:
        Button {
          restoreICloudAccess()
        } label: {
          Label(
            L10n.text(
              model.authorization == .notDetermined
                ? "permission.allow" : "permission.open-settings"),
            systemImage: "lock.open"
          )
        }
      case .empty:
        Button {
          model.requestNewList(source: .iCloud)
        } label: {
          Label(L10n.text("list.new-icloud"), systemImage: "plus")
        }
        Button {
          Task { await model.reload() }
        } label: {
          Label(L10n.text("list.check-again"), systemImage: "arrow.clockwise")
        }
        Button {
          SystemSettings.openReminders()
        } label: {
          Label(L10n.text("list.open-reminders"), systemImage: "list.bullet")
        }
      }
    }

    Section(L10n.text("source.local")) {
      ForEach(model.localLists) { list in
        Menu(list.title) {
          Button {
            model.selectList(list.id)
          } label: {
            Label(
              list.id == model.activeListID
                ? L10n.text("list.active") : L10n.text("list.open"),
              systemImage: list.id == model.activeListID ? "checkmark" : "arrow.right"
            )
          }
          Button(L10n.text("list.rename")) {
            model.cancelListCreation()
            listPendingRename = list
            listNameDraft = list.title
            Task { @MainActor in listNameFocused = true }
          }
          Divider()
          Button(L10n.text("list.delete"), role: .destructive) {
            Task { await model.prepareListDeletion(list) }
          }
        }
      }
      if model.localLists.isEmpty {
        Button {
          Task { await model.useLocal() }
        } label: {
          Label(L10n.text("source.use-local"), systemImage: "desktopcomputer")
        }
      }
    }

    Divider()
    Button {
      listPendingRename = nil
      model.requestNewList()
    } label: {
      Label(L10n.text("list.new"), systemImage: "plus")
    }
  }

  private func listSelectionButton(_ list: ReminderListSnapshot) -> some View {
    Button {
      model.selectList(list.id)
    } label: {
      if list.id == model.activeListID {
        Label(list.title, systemImage: "checkmark")
      } else {
        Text(list.title)
      }
    }
    .disabled(list.source == .iCloud && model.authorization != .fullAccess)
  }

  private func restoreICloudAccess() {
    if model.authorization == .notDetermined {
      Task { await model.requestAccess() }
    } else {
      SystemSettings.openRemindersPrivacy()
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
    let metrics = scheduleMetrics

    return HStack(alignment: .top, spacing: metrics.paneSpacing) {
      monthCalendarPane(metrics: metrics)
        .frame(width: metrics.paneWidth, alignment: .top)

      daySchedulePane(schedule: schedule, undated: undated, metrics: metrics)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// The hover preview and the pinned island share one calendar layout; the
  /// preview's shorter surface uses tighter metrics instead of a second
  /// layout path.
  private var scheduleMetrics: ScheduleMetrics {
    model.islandState == .preview ? .compact : .regular
  }

  private struct ScheduleMetrics {
    let paneWidth: CGFloat
    let paneSpacing: CGFloat
    let titleSize: CGFloat
    let stepperSide: CGFloat
    let weekdaySize: CGFloat
    let daySize: CGFloat
    let circleSize: CGFloat
    let cellMinHeight: CGFloat
    let cellStackSpacing: CGFloat
    let weekSpacing: CGFloat
    let dotSize: CGFloat
    let dayTitleSize: CGFloat
    let rowPitch: CGFloat

    static let regular = ScheduleMetrics(
      paneWidth: 216,
      paneSpacing: 12,
      titleSize: 14,
      stepperSide: 18,
      weekdaySize: 11,
      daySize: 12.5,
      circleSize: 24,
      cellMinHeight: 30,
      cellStackSpacing: 2,
      weekSpacing: 2,
      dotSize: 3.5,
      dayTitleSize: 14,
      rowPitch: 46
    )

    static let compact = ScheduleMetrics(
      paneWidth: 190,
      paneSpacing: 10,
      titleSize: 12.5,
      stepperSide: 16,
      weekdaySize: 9.5,
      daySize: 11,
      circleSize: 19,
      cellMinHeight: 22,
      cellStackSpacing: 1.5,
      weekSpacing: 1.5,
      dotSize: 3,
      dayTitleSize: 12.5,
      rowPitch: 44
    )
  }

  private func monthCalendarPane(metrics: ScheduleMetrics) -> some View {
    let calendar = Calendar.current
    let grid = MonthCalendar(containing: model.selectedDay, calendar: calendar)
    let counts = ReminderSchedule.dayCounts(in: model.monthReminders, calendar: calendar)
    let today = calendar.startOfDay(for: Date())

    return VStack(spacing: 3) {
      HStack(spacing: 3) {
        Text(grid.monthTitle)
          .font(.system(size: metrics.titleSize, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Spacer(minLength: 2)
        monthStepper(metrics: metrics, labelKey: "calendar.previous-month", systemName: "chevron.left") {
          shiftMonth(-1)
        }
        monthStepper(metrics: metrics, labelKey: "calendar.next-month", systemName: "chevron.right") {
          shiftMonth(1)
        }
      }

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
    .padding(.top, 2)
  }

  private func monthStepper(
    metrics: ScheduleMetrics,
    labelKey: LocalizedStringKey,
    systemName: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: metrics.weekdaySize, weight: .bold))
        .foregroundStyle(.white.opacity(0.7))
        .frame(width: metrics.stepperSide, height: metrics.stepperSide)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(labelKey))
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
      VStack(alignment: .leading, spacing: 0) {
        Text(dayScheduleTitle(for: schedule.date))
          .font(.system(size: metrics.dayTitleSize, weight: .semibold))
          .lineLimit(1)
          .padding(.top, 2)
          .padding(.bottom, 3)

        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
              ForEach(schedule.pending) { reminder in
                dayRowWithEditor(reminder, isCompleted: false, metrics: metrics)
              }

              if !schedule.completed.isEmpty {
                daySectionHeader("calendar.completed")
                ForEach(schedule.completed) { reminder in
                  dayRowWithEditor(reminder, isCompleted: true, metrics: metrics)
                }
              }

              if !undated.isEmpty {
                daySectionHeader("calendar.undated")
                ForEach(undated) { reminder in
                  dayRowWithEditor(reminder, isCompleted: false, metrics: metrics)
                }
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
  }

  @ViewBuilder
  private func dayRowWithEditor(
    _ reminder: ReminderSnapshot,
    isCompleted: Bool,
    metrics: ScheduleMetrics
  ) -> some View {
    dayRow(reminder, isCompleted: isCompleted)
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

  private func daySectionHeader(_ titleKey: LocalizedStringKey) -> some View {
    HStack(spacing: 3) {
      Text(titleKey)
        .font(.system(size: 10.8, weight: .semibold))
        .foregroundStyle(ReUITheme.muted)
      Spacer()
    }
    .padding(.top, 5)
    .padding(.bottom, 2)
    .accessibilityAddTraits(.isHeader)
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

  private func dayRow(_ reminder: ReminderSnapshot, isCompleted: Bool) -> some View {
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
          .font(.system(size: 17.5, weight: .medium))
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
          .font(.system(size: 14.04, weight: .medium))
          .strikethrough(isCompleted, color: .white.opacity(0.4))
          .foregroundStyle(isCompleted ? ReUITheme.muted : .primary)
          .lineLimit(1)
        if let time = dueTimeLabel(for: reminder) {
          Text(time)
            .font(.system(size: 11.4))
            .foregroundStyle(ReUITheme.muted)
        }
      }

      Spacer(minLength: 4)

      listTag(for: reminder)

      if !isCompleted && reminder.priority != .none {
        Image(systemName: prioritySymbol(reminder.priority))
          .font(.system(size: 11.88))
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
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
  private func listTag(for reminder: ReminderSnapshot) -> some View {
    if let list = model.lists.first(where: { $0.id == reminder.listID }) {
      let accent = listAccent(for: list)
      HStack(spacing: 2.5) {
        Circle().fill(accent).frame(width: 4, height: 4)
        Text(list.title)
          .font(.system(size: 10.5, weight: .medium))
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Capsule(style: .continuous).fill(accent.opacity(0.14)))
      .overlay(Capsule(style: .continuous).stroke(accent.opacity(0.28), lineWidth: 1))
      .foregroundStyle(accent)
      .accessibilityLabel(Text(list.title))
    }
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

  private func dayScheduleTitle(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return L10n.text("date.today") }
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate("MMMd EEEE")
    return formatter.string(from: date)
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

  private func shiftMonth(_ delta: Int) {
    guard
      let target = Calendar.current.date(byAdding: .month, value: delta, to: model.selectedDay)
    else { return }
    model.selectDay(target)
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

  private var listCreationForm: some View {
    VStack(alignment: .leading, spacing: 6.5) {
      HStack(spacing: 5.5) {
        ZStack {
          Circle().fill(accentColor.opacity(0.18))
          Image(systemName: "list.bullet.badge.plus")
            .font(.system(size: 16.2, weight: .semibold))
            .foregroundStyle(accentColor)
        }
        .frame(width: 36, height: 36)

        VStack(alignment: .leading, spacing: 1) {
          Text("list.new")
            .font(.system(size: 14.04, weight: .semibold))
          Text("list.new.detail")
            .font(.system(size: 11.88))
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 3.5) {
        Text("list.name")
          .font(.system(size: 11.88).weight(.semibold))
          .foregroundStyle(.secondary)

        HStack(spacing: 4.5) {
          Image(systemName: "text.cursor")
            .font(.system(size: 11.88))
            .foregroundStyle(listNameFocused ? accentColor : .secondary)
          TextField(L10n.text("list.name.placeholder"), text: $listNameDraft)
            .textFieldStyle(.plain)
            .focused($listNameFocused)
            .onSubmit { createListFromForm() }
        }
        .padding(.horizontal, 5.5)
        .frame(height: 39)
        .background {
          RoundedRectangle(cornerRadius: 11)
            .fill(.white.opacity(listNameFocused ? 0.09 : 0.065))
        }
        .overlay {
          RoundedRectangle(cornerRadius: 11)
            .stroke(
              listNameFocused ? accentColor.opacity(0.75) : .white.opacity(0.10),
              lineWidth: listNameFocused ? 1.25 : 1
            )
        }
      }

      VStack(alignment: .leading, spacing: 3.5) {
        Text("list.source")
          .font(.system(size: 11.88).weight(.semibold))
          .foregroundStyle(.secondary)

        HStack(spacing: 5) {
          listSourceOption(.iCloud)
          listSourceOption(.local)
        }
      }

      if model.requestedListCreationSource == .iCloud, model.authorization != .fullAccess {
        Label("list.icloud-permission-required", systemImage: "exclamationmark.circle.fill")
          .font(.system(size: 11.88))
          .foregroundStyle(.orange)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      HStack(spacing: 5) {
        Spacer()
        Button(L10n.text("common.cancel")) {
          model.cancelListCreation()
          listNameDraft = ""
        }
        .buttonStyle(.bordered)
        .controlSize(.large)

        Button(L10n.text("list.create")) { createListFromForm() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(accentColor)
          .keyboardShortcut(.defaultAction)
          .disabled(
            listNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || (model.requestedListCreationSource == .iCloud
                && model.authorization != .fullAccess)
          )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 11)
    .padding(.vertical, 8.5)
  }

  private func listSourceOption(_ source: ReminderSource) -> some View {
    let isSelected = model.requestedListCreationSource == source
    let titleKey = source == .iCloud ? "source.icloud" : "source.local"
    let detailKey = source == .iCloud ? "source.icloud.detail" : "source.local.detail"

    return Button {
      model.requestedListCreationSource = source
    } label: {
      HStack(spacing: 4.5) {
        ZStack {
          RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? accentColor.opacity(0.18) : .white.opacity(0.06))
          Image(systemName: source.symbolName)
            .font(.system(size: 15.12, weight: .medium))
            .foregroundStyle(isSelected ? accentColor : .secondary)
        }
        .frame(width: 30, height: 30)

        VStack(alignment: .leading, spacing: 0.5) {
          Text(L10n.text(titleKey))
            .font(.system(size: 12.96).weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(L10n.text(detailKey))
            .font(.system(size: 10.8))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 1)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15.12, weight: .medium))
          .foregroundStyle(isSelected ? accentColor : .white.opacity(0.18))
      }
      .padding(.horizontal, 5)
      .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 12)
          .fill(isSelected ? accentColor.opacity(0.10) : .white.opacity(0.035))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(
            isSelected ? accentColor.opacity(0.65) : .white.opacity(0.09),
            lineWidth: isSelected ? 1.25 : 1
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var listRenameForm: some View {
    VStack(spacing: 7) {
      Label(L10n.text("list.rename"), systemImage: "pencil")
        .font(.system(size: 14.04, weight: .semibold))
      Text(listPendingRename?.title ?? "")
        .font(.system(size: 11.88))
        .foregroundStyle(.secondary)
      TextField(L10n.text("list.name.placeholder"), text: $listNameDraft)
        .textFieldStyle(.roundedBorder)
        .focused($listNameFocused)
        .onSubmit { renameListFromForm() }
      HStack {
        Button(L10n.text("common.cancel")) {
          listPendingRename = nil
          listNameDraft = ""
        }
        Button(L10n.text("common.save")) { renameListFromForm() }
          .keyboardShortcut(.defaultAction)
          .disabled(listNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(12)
  }

  private func createListFromForm() {
    guard let source = model.requestedListCreationSource else { return }
    let title = listNameDraft
    Task {
      if await model.createList(title: title, source: source) {
        listNameDraft = ""
      }
    }
  }

  private func renameListFromForm() {
    guard let list = listPendingRename else { return }
    let title = listNameDraft
    Task {
      if await model.renameList(list, title: title) {
        listPendingRename = nil
        listNameDraft = ""
      }
    }
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

          if case .available = model.localStoreAvailability {
            Button {
              Task { await model.useLocal() }
            } label: {
              Label(L10n.text("source.use-local"), systemImage: "desktopcomputer")
            }
            .buttonStyle(.bordered)
          } else {
            HStack {
              Button("local-store.retry") {
                Task { await model.retryLocalStore() }
              }
              Button("local-store.show-in-finder") {
                model.showLocalDataInFinder()
              }
            }
          }
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
          HStack(spacing: 5) {
            Button("list.new-icloud") {
              model.requestNewList(source: .iCloud)
            }
            Button("source.use-local") {
              Task { await model.useLocal() }
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
          }
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

  private var localEmptyContent: some View {
    VStack(spacing: 6) {
      Image(systemName: "desktopcomputer")
        .font(.system(size: 18))
        .foregroundStyle(accentColor)
      Text("list.no-local").font(.system(size: 14.04, weight: .semibold))
      Text("list.no-local.detail")
        .font(.system(size: 11.88))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      if isPinned {
        Button("list.new-local") {
          model.requestNewList(source: .local)
        }
        .buttonStyle(.borderedProminent)
        .tint(accentColor)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(10)
  }

  private var localStoreUnavailableContent: some View {
    VStack(spacing: 6) {
      Image(systemName: "externaldrive.badge.exclamationmark")
        .font(.system(size: 19.2))
        .foregroundStyle(.orange)
      Text("local-store.unavailable").font(.system(size: 14.04, weight: .semibold))
      if case let .unavailable(message, _) = model.localStoreAvailability {
        Text(message)
          .font(.system(size: 11.88))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      if isPinned {
        HStack {
          Button("local-store.retry") {
            Task { await model.retryLocalStore() }
          }
          .buttonStyle(.borderedProminent)
          Button("local-store.show-in-finder") {
            model.showLocalDataInFinder()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(12)
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
      } else if model.requestedListCreationSource != nil {
        model.cancelListCreation()
      } else if listPendingRename != nil {
        listPendingRename = nil
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
