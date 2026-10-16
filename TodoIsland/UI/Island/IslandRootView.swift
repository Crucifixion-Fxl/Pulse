import AppKit
import SwiftUI

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
  case agents
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
    case .agents: "sidebar.agents"
    case .music: "sidebar.music"
    case .clipboard: "sidebar.clipboard"
    case .placeholder4, .placeholder5, .placeholder6, .placeholder7:
      "sidebar.placeholder"
    }
  }

  var symbol: String {
    switch self {
    case .reminders: "checklist"
    case .agents: "person.2.fill"
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
    case .agents: AgentsPanelView.Metrics.contentHeight
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

struct IslandRootView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var agentStore: AgentSessionStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var editorTitleFocused: Bool
  @State private var reminderPendingDeletion: ReminderSnapshot?
  @State private var selectedSidebarItem: IslandSidebarItem = .reminders
  @State private var hoveredSidebarItem: IslandSidebarItem?
  /// True only inside the launch-time pane prewarm window.
  @State private var isPrewarmingPanes = false
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
  @FocusState private var newTaskFocused: Bool

  private var isPinned: Bool { model.islandState == .pinned }

  /// Identity of the display this island window lives on — injected by the
  /// window controller (one island per display). nil keeps the legacy
  /// single-window behavior of always hosting the active state.
  let displayID: String?
  let usesCompositorTransitions: Bool

  init(displayID: String? = nil, usesCompositorTransitions: Bool = false) {
    self.displayID = displayID
    self.usesCompositorTransitions = usesCompositorTransitions
  }

  /// What this window should render: the global state only when the active
  /// island is on this display; every other window stays a collapsed bar.
  private var effectiveState: IslandPresentationState {
    IslandRouting.effectiveState(
      global: model.islandState,
      activeDisplayID: model.hostDisplayID,
      windowDisplayID: displayID)
  }

  var body: some View {
    GeometryReader { proxy in
      let surfaceSize = IslandAnimatedSurfaceLayout.surfaceSize(
        windowSize: proxy.size,
        targetSize: islandSurfaceSize
      )

      ZStack(alignment: .top) {
        if effectiveState == .collapsed {
          collapsedContent
            .transition(
              .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)),
                removal: .opacity.combined(with: .scale(scale: 1.04, anchor: .top))
              )
            )
        } else {
          // Expanded-only chrome rides the branch: event monitors, dialogs,
          // and the height-measurement pipeline exist solely on the one
          // window hosting the expanded surface, so per-display windows
          // never multiply global monitors or fight over one alert.
          expandedContent
            .allowsHitTesting(model.editingReminderID == nil)
            .accessibilityHidden(model.editingReminderID != nil)
            .overlay {
              if let draft = model.draft, model.editingReminderID != nil {
                ZStack {
                  Color.black.opacity(0.48)
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)
                  reminderEditor(draft)
                    .frame(width: 400)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .task {
                      newTaskFocused = false
                      await Task.yield()
                      editorTitleFocused = true
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
              }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.editingReminderID)
            .transition(
              .opacity.combined(with: .scale(scale: 0.965, anchor: .top))
            )
            .background(KeyboardEventMonitor(handler: handleKeyEvent))
            .background(
              MouseDownMonitor { event in
                if model.islandState == .preview {
                  model.pinIsland()
                }
              }
            )
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
              if id != nil {
                newTaskFocused = false
                editorTitleFocused = true
              }
            }
            .onChange(of: model.editingFocusRequestID) { _, _ in
              Task { @MainActor in editorTitleFocused = true }
            }
            .onChange(of: effectiveState) { _, state in
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
              if state == .pinned, selectedSidebarItem == .reminders, model.editingReminderID == nil {
                newTaskFocused = true
              }
            }
            .onChange(of: model.taskInputFocusRequestID) { _, _ in
              guard model.islandState == .pinned, selectedSidebarItem == .reminders,
                model.editingReminderID == nil else { return }
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
      .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
      .background(alignment: .top) {
        if effectiveState == .collapsed, isPrewarmingPanes {
          // A background does not contribute its 760pt ideal width to the
          // collapsed bar. A ZStack sibling pushes the live bot offscreen.
          prewarmPanes
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
      }
      .background(.black)
      .clipShape(islandShape)
      .contentShape(Rectangle())
      .onHover { hovering in
        model.setIslandHovered(hovering, on: displayID)
      }
      .onAppear { syncRequestedSidebarItem() }
      .onChange(of: model.requestedSidebarItem) { _, _ in syncRequestedSidebarItem() }
      .task {
        // Prewarm the panes once, invisibly, shortly after launch: the
        // first real expansion otherwise pays the whole cold SwiftUI cost
        // (type resolution, first layout, first CA commit) inside the pop
        // animation — the "first expansion is janky" complaint. The hidden
        // copy is removed after a beat so nothing keeps ticking.
        try? await Task.sleep(for: .seconds(0.8))
        isPrewarmingPanes = true
        try? await Task.sleep(for: .seconds(1.2))
        isPrewarmingPanes = false
      }
      .onTapGesture {
        // Only a hover preview becomes pinned from a surface tap. This keeps
        // controls inside a pinned surface, including the setup close button,
        // from being re-pinned by the parent gesture after they act.
        // Tapping the collapsed bar opens directly too — no hover wait.
        if effectiveState == .preview || effectiveState == .collapsed {
          model.pinIslandFromSurface(on: displayID)
        }
      }
      .animation(surfaceAnimation, value: effectiveState)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }

  private var islandShape: IslandSurfaceShape {
    // The native compositor owns the silhouette even while settled.
    // Changing SwiftUI's clip to the expanded shoulders at the old bar
    // size would pull both edges inward before the queued spring starts.
    if usesCompositorTransitions {
      return IslandSurfaceShape(shoulderInset: 0, topShoulderDepth: 0, bottomRadius: 0)
    }
    return IslandSurfaceShape(
      shoulderInset: effectiveState == .collapsed ? 0 : 8,
      topShoulderDepth: effectiveState == .collapsed ? 0 : expandedTopShoulderDepth,
      bottomRadius: effectiveState == .collapsed
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
          // Mirrors the face on the right end: the Codex quota chip takes
          // the left end with the same 12pt corner-clearing inset.
          Color.clear
            .frame(width: collapsedSideWidth)
            .overlay(alignment: .leading) {
              collapsedQuotaChip.padding(.leading, 12)
            }
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
          // The bot character sits at the island's right end. The 12pt
          // trailing inset keeps it clear of the rounded corner cap so it
          // never crosses the surface outline. Pending agent requests turn
          // it red and angry (see CollapsedBotFaceView.isAlert) — no bell.
          collapsedBotFace
            .padding(.trailing, 12)
            .frame(width: collapsedSideWidth, alignment: .trailing)
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
      HStack(spacing: 0) {
        collapsedQuotaChip
          .padding(.leading, 12)
        Spacer(minLength: 0)
        collapsedBotFace
          .padding(.trailing, 12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(collapsedAccessibilityLabel)
    }
  }

  /// Warm the default reminders pane and the agents approval destination.
  /// The expanded session retains its own pair; this launch copy is temporary.
  private var prewarmPanes: some View {
    ZStack {
      remindersFeatureContent
      AgentsPanelView()
        .environment(\.agentPanelActive, false)
    }
    .frame(width: 760, height: 380, alignment: .top)
    .clipped()
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
    .animation(reduceMotion ? nil : .bouncy(duration: 0.35, extraBounce: 0.2),
      value: selectedSidebarItem)
  }

  /// Applies a pending pane request from an auto-expansion flow. Lives at
  /// the always-mounted surface level (plus an onAppear catch-up): a
  /// listener on the expanded-only branch misses requests that land while
  /// collapsed — exactly the first approval's situation — so the panel
  /// would open on whatever pane was last selected.
  private func syncRequestedSidebarItem() {
    guard let item = model.requestedSidebarItem, item != selectedSidebarItem else { return }
    // selectSidebar (not a bare assignment) so auto-expansion flows get the
    // pane's side effects too — the agents pane's quota refresh, the music
    // pane's activity sync.
    selectSidebar(item)
  }

  /// Switches the active sidebar feature with the liquid transition.
  private func selectSidebar(_ item: IslandSidebarItem) {
    guard selectedSidebarItem != item else { return }
    selectedSidebarItem = item
    if item != .reminders { newTaskFocused = false }
    if item == .agents {
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
    Group {
      switch selectedSidebarItem {
      case .reminders, .agents:
        // Both destinations keep their controls and scroll position mounted.
        // Other features keep their own natural size and lifecycle.
        ZStack(alignment: .top) {
          remindersFeatureContent
            .transaction { $0.animation = nil }
            .opacity(selectedSidebarItem == .reminders ? 1 : 0)
            .allowsHitTesting(selectedSidebarItem == .reminders)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(selectedSidebarItem != .reminders)
          AgentsPanelView()
            .environment(\.agentPanelActive, selectedSidebarItem == .agents)
            .transaction { $0.animation = nil }
            .opacity(selectedSidebarItem == .agents ? 1 : 0)
            .allowsHitTesting(selectedSidebarItem == .agents)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(selectedSidebarItem != .agents)
        }
      case .music:
        MusicPanelView().transition(.opacity)
      case .clipboard:
        ClipboardPanelView().transition(.opacity)
      case .placeholder4, .placeholder5, .placeholder6, .placeholder7:
        placeholderFeatureContent.transition(.opacity)
      }
    }
    // Only the indicator springs; content opacity settles without overshoot.
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedSidebarItem)
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
        .animation(reduceMotion ? nil : .smooth(duration: 0.19), value: model.calendarMonth)
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
    let grid = MonthCalendar(containing: model.calendarMonth, calendar: calendar)
    let counts = ReminderSchedule.dayCounts(in: model.calendarReminders, calendar: calendar)
    let today = calendar.startOfDay(for: Date())

    return VStack(alignment: .leading, spacing: 2) {
      VStack(spacing: 3) {
      HStack(spacing: 8) {
        monthNavigationButton(offset: -1, metrics: metrics)
        Text(grid.monthTitle)
          .font(.system(size: metrics.titleSize, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(maxWidth: .infinity, alignment: .center)
        monthNavigationButton(offset: 1, metrics: metrics)
      }
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

  private func monthNavigationButton(offset: Int, metrics: ScheduleMetrics) -> some View {
    Button {
      model.shiftMonth(by: offset)
    } label: {
      Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(ReUITheme.muted)
        .frame(width: 28, height: metrics.titleSize * 1.4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(offset < 0 ? "上个月" : "下个月")
    .accessibilityLabel(offset < 0 ? "上个月" : "下个月")
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
    count(model.calendarReminders)
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
    case .agents:
      contentHeight = model.canUseActiveList
        ? sharedPrimaryPaneHeight : AgentsPanelView.Metrics.contentHeight
    case .music, .clipboard, .placeholder4,
      .placeholder5, .placeholder6, .placeholder7:
      contentHeight = selectedSidebarItem.preferredContentHeight
    case .reminders:
      if model.canUseActiveList {
        contentHeight = sharedPrimaryPaneHeight
      } else if model.authorization == .fullAccess {
        contentHeight = 185
      } else {
        contentHeight = 220
      }
    }
    model.updateExpandedContentHeight(contentHeight)
  }

  /// A few points of font-metric rounding (321 vs 324 on macOS) must not
  /// launch a second, snapshot-based window transition during a tab fade.
  private var sharedPrimaryPaneHeight: CGFloat {
    max(calendarPaneIdealHeight > 0
      ? calendarPaneIdealHeight : IslandSidebarItem.reminders.preferredContentHeight,
      AgentsPanelView.Metrics.contentHeight)
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
    VStack(spacing: 6) {
      // Keep the scroll container mounted through the final completion.
      // The last row can finish its exit before the empty state fades in.
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          LazyVStack(spacing: 0) {
            ForEach(schedule.pending) { reminder in
              scheduleRow(reminder, metrics: metrics)
            }
            ForEach(undated) { reminder in
              scheduleRow(reminder, metrics: metrics)
                .padding(.top, reminder.id == undated.first?.id ? 3 : 0)
            }
          }
          .padding(.top, 14)
          .padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: model.selectionScrollRequestID) { _, _ in
          guard let id = model.selectedReminderID else { return }
          withAnimation(reduceMotion ? nil : .smooth(duration: 0.22, extraBounce: 0)) {
            proxy.scrollTo(id, anchor: .center)
          }
        }
        .onChange(of: model.selectedDay) { _, _ in
          if let id = model.visibleScheduleReminders.first?.id {
            proxy.scrollTo(id, anchor: .top)
          }
        }
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
      .overlay {
        if schedule.pending.isEmpty && undated.isEmpty {
          emptyDaySchedule
            .transition(.opacity)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if let item = model.completionUndoItems.last {
          completionUndoFeedback(item)
            .padding(.bottom, 3)
            .transition(.opacity)
        }
      }
      .animation(
        reduceMotion ? nil : .smooth(duration: 0.3, extraBounce: 0),
        value: model.visibleScheduleReminders.map(\.id)
      )
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.16),
        value: model.completionUndoItems.isEmpty
      )
      newTaskInput
    }
  }

  private func completionUndoFeedback(_ item: AppModel.CompletionUndoItem) -> some View {
    HStack(spacing: 7) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
      Text(String(format: L10n.text("reminder.completed-feedback"), item.reminder.title))
        .foregroundStyle(ReUITheme.muted)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Button {
        Task { await model.undoLastCompletion() }
      } label: {
        Text("reminder.undo-completion")
          .fontWeight(.semibold)
          .foregroundStyle(.white)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.white.opacity(0.08), in: Capsule())
      }
      .buttonStyle(.plain)
      .disabled(model.isUndoingCompletion)
      .accessibilityLabel(Text(String(
        format: L10n.text("reminder.undo-completion.accessibility"), item.reminder.title)))
      .help(L10n.text("reminder.undo-completion.help"))
    }
    .font(.system(size: 10.5, weight: .medium))
    .padding(.leading, 9)
    .padding(.trailing, 4)
    .padding(.vertical, 4)
    .background(ReUITheme.panel, in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private func scheduleRow(
    _ reminder: ReminderSnapshot,
    metrics: ScheduleMetrics
  ) -> some View {
    dayRow(reminder, metrics: metrics)
      .frame(height: metrics.rowPitch)
      .id(reminder.id)
      .transition(.opacity)
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
        model.complete(reminder, reduceMotion: reduceMotion)
      } label: {
        ReminderCompletionCheck(
          isCompleted: isCompleting, size: metrics.rowGlyphSize, accent: accentColor)
      }
      .buttonStyle(.plain)
      .disabled(isCompleting)
      .accessibilityLabel(
        Text(String(
          format: L10n.text("reminder.complete"),
          reminder.title)))

      VStack(alignment: .leading, spacing: 1) {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(reminder.title)
            .font(.system(size: metrics.rowTitleSize, weight: .medium))
            .strikethrough(isCompleting, color: .white.opacity(0.45))
            .opacity(isCompleting ? 0.45 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isCompleting)
            .lineLimit(1)
          if let overdue = overdueDateLabel(for: reminder) {
            Text(overdue)
              .font(.system(size: metrics.rowDetailSize))
              .foregroundStyle(.red)
              .padding(.horizontal, 4)
              .padding(.vertical, 1)
              .background(
                Capsule(style: .continuous).fill(Color.red.opacity(0.12))
              )
              .overlay(
                Capsule(style: .continuous).stroke(Color.red.opacity(0.28), lineWidth: 0.5)
              )
              .offset(y: 1)
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
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "square.and.pencil")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(accentColor)
          .frame(width: 30, height: 30)
          .background(accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        Text("editor.edit-reminder")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Button { model.cancelEditing() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 24, height: 24)
            .background(.white.opacity(0.045), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("common.cancel"))
      }

      TextField(
        L10n.text("editor.title.placeholder"),
        text: Binding(
          get: { model.draft?.title ?? "" },
          set: { model.draft?.title = $0 }
        )
      )
      .font(.system(size: 16, weight: .medium))
      .textFieldStyle(.plain)
      .accessibilityLabel(L10n.text("editor.title.placeholder"))
      .focused($editorTitleFocused)
      .onSubmit { if model.canSaveEditingDraft { model.saveEditing() } }
      .padding(.horizontal, 12)
      .frame(height: 44)
      .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(editorTitleFocused ? accentColor.opacity(0.6) : .white.opacity(0.08), lineWidth: 1)
      }

      VStack(spacing: 10) {
        HStack(spacing: 8) {
          Label(L10n.text("editor.due-date"), systemImage: "calendar")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
          Spacer()
          Toggle("", isOn: Binding(
            get: { model.draft?.hasDueDate ?? false },
            set: { model.draft?.hasDueDate = $0 }
          ))
          .labelsHidden()
          .accessibilityLabel(L10n.text("editor.due-date"))
          .toggleStyle(.switch)
          .controlSize(.mini)
          .tint(accentColor)
        }
        if draft.hasDueDate {
          HStack(spacing: 8) {
            DatePicker(
              L10n.text("editor.due-date"),
              selection: Binding(
                get: { model.draft?.dueDate ?? Date() },
                set: { model.draft?.dueDate = $0 }
              ),
              displayedComponents: draft.includesTime ? [.date, .hourAndMinute] : [.date]
            )
            .labelsHidden()
            .controlSize(.small)
            Spacer(minLength: 0)
            Toggle(L10n.text("editor.time"), isOn: Binding(
              get: { model.draft?.includesTime ?? false },
              set: { model.draft?.includesTime = $0 }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.65))
          }
          .transition(.opacity)
        }
      }
      .padding(12)
      .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: draft.hasDueDate)

      HStack(spacing: 12) {
        Label(L10n.text("editor.priority"), systemImage: "flag")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white.opacity(0.6))
        HStack(spacing: 3) {
          ForEach([ReminderPriority.none, .low, .medium, .high], id: \.self) { priority in
            priorityOption(priority, selectedPriority: draft.priority)
          }
        }
        .padding(3)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
      }

      Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

      HStack(spacing: 8) {
        Button { model.cancelEditing() } label: {
          HStack(spacing: 6) {
            Text("common.cancel")
            Text("esc")
              .font(.system(size: 9, weight: .medium, design: .monospaced))
              .foregroundStyle(.white.opacity(0.3))
          }
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.62))
          .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("common.cancel"))
        Spacer()
        Button { model.saveEditing() } label: {
          HStack(spacing: 10) {
            Text("common.save")
            Image(systemName: "return").font(.system(size: 10, weight: .medium))
          }
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.black.opacity(0.85))
          .padding(.horizontal, 15)
          .frame(height: 30)
          .background(accentColor, in: RoundedRectangle(cornerRadius: 8))
          .opacity(model.canSaveEditingDraft ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSaveEditingDraft)
      }
    }
    .padding(20)
    .background {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(LinearGradient(
          colors: [Color(red: 0.11, green: 0.12, blue: 0.14), ReUITheme.panel],
          startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(LinearGradient(
          colors: [.white.opacity(0.16), .white.opacity(0.045)],
          startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
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
          .stroke(isSelected ? color.opacity(0.26) : .clear, lineWidth: 1)
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
    DisplaySupport.cachedMetrics(for: displayID ?? model.hostDisplayID)?.hasPhysicalNotch ?? false
  }

  private var hostPhysicalNotchWidth: CGFloat {
    DisplaySupport.cachedMetrics(for: displayID ?? model.hostDisplayID)?.physicalNotchWidth ?? 0
  }

  private var expandedTopShoulderDepth: CGFloat { 8 }

  private var collapsedSideWidth: CGFloat {
    max(0, (islandSurfaceSize.width - hostPhysicalNotchWidth) / 2)
  }

  private var collapsedBotFace: some View {
    CollapsedBotFaceView(
      size: collapsedFaceSize,
      faceColor: model.collapsedQuotaVendor.accent,
      isPlaying: model.nowPlaying?.isPlaying == true,
      isHovered: model.isPointerInsideIsland,
      isAlert: agentStore.hasPending,
      activity: CollapsedBotState.activity(in: agentStore.sessions),
      isAnimated: collapsedFaceIsAnimated)
  }

  /// Quota chip at the collapsed bar's left end; the vendor is picked in
  /// the AI usage panel (Codex by default). Hidden until the first fetch.
  @ViewBuilder
  private var collapsedQuotaChip: some View {
    if let subscription = model.aiUsage?.subscriptions.first(where: {
      $0.vendor == model.collapsedQuotaVendor
    }) {
      CollapsedQuotaChipView(subscription: subscription)
    }
  }

  /// Face diameter for the collapsed bar: as large as the 3:1 eyes allow,
  /// clamped so bounce + bob never exceed the bar height on any Mac
  /// (notch safeAreaTop 38–48; non-notch bar 30).
  private var collapsedFaceSize: CGFloat {
    min(26, max(18, islandSurfaceSize.height - 6)).rounded()
  }

  /// The timeline only runs on a visible surface without Reduce Motion;
  /// SwiftUI cannot see the auto-hidden panel's window alpha, so the gate
  /// has to be explicit to keep the 30 Hz redraws from ticking invisibly.
  private var collapsedFaceIsAnimated: Bool {
    model.isCollapsedIslandVisible && !reduceMotion
  }

  private var expandedContentTopInset: CGFloat {
    guard let metrics = DisplaySupport.cachedMetrics(for: displayID ?? model.hostDisplayID) else { return 16 }
    return max(16, metrics.safeAreaTop + 6)
  }

  private var islandSurfaceSize: CGSize {
    guard let metrics = DisplaySupport.cachedMetrics(for: displayID ?? model.hostDisplayID) else {
      return .zero
    }
    return DisplayGeometryCalculator.geometry(
      for: metrics,
      expandedContentHeight: model.expandedContentHeight
    )
      .size(for: effectiveState)
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
    guard !reduceMotion, !usesCompositorTransitions else { return nil }
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
    // A retained, invisible reminder pane must not consume typing or list
    // shortcuts while the user interacts with another destination.
    guard selectedSidebarItem == .reminders else {
      if event.keyCode == 53 {
        model.collapseIsland()
        return true
      }
      return false
    }
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

    // While the editor is open, list navigation and quick-add shortcuts
    // must not act on the dimmed content behind the card.
    if model.editingReminderID != nil {
      if event.keyCode == 53 {
        model.cancelEditing()
        return true
      }
      return false
    }

    if event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "n"
    {
      newTaskFocused = true
      return true
    }

    let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
    if isEditingText { return false }
    if event.modifierFlags.contains(.command),
      !event.modifierFlags.contains(.shift),
      event.charactersIgnoringModifiers?.lowercased() == "z",
      !model.completionUndoItems.isEmpty
    {
      Task { await model.undoLastCompletion() }
      return true
    }
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
        model.complete(selected, reduceMotion: reduceMotion)
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
