import AppKit
import Combine
import Foundation
import os

enum ICloudSourceMenuState: Equatable, Sendable {
  case authorizationRequired
  case empty
  case available
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var authorization: ReminderAuthorization
  @Published private(set) var lists: [ReminderListSnapshot] = []
  @Published private(set) var reminders: [ReminderSnapshot] = []
  @Published private(set) var monthReminders: [ReminderSnapshot] = []
  @Published private(set) var undatedReminders: [ReminderSnapshot] = []
  @Published private(set) var overdueReminders: [ReminderSnapshot] = []
  @Published private(set) var recentlyCompletedReminders: [ReminderSnapshot] = []
  /// Completion heatmap derived once per data reload, not per view render.
  @Published private(set) var heatmapGrid: ReminderHeatmap.Grid = ReminderHeatmap.Grid(
    weeks: [], counts: [:])
  @Published private(set) var selectedDay: Date = Calendar.current.startOfDay(for: Date())
  @Published private(set) var islandState: IslandPresentationState = .collapsed {
    didSet {
      // Collapsing ends any date exploration — the next opening starts on
      // today instead of wherever the last sweep left the selection.
      if islandState == .collapsed, oldValue != .collapsed {
        selectDay(Calendar.current.startOfDay(for: Date()))
      }
    }
  }
  @Published private(set) var expandedContentHeight: CGFloat?
  @Published private(set) var isLoading = false
  @Published private(set) var isRequestingAccess = false
  @Published private(set) var isEditingDraftValidated = true
  @Published private(set) var completingReminderIDs: Set<String> = []
  @Published private(set) var hostDisplayID: String?
  @Published private(set) var localStoreAvailability: LocalStoreAvailability = .available
  @Published private(set) var listDeletionCandidate: ReminderListDeletionSummary?
  @Published private(set) var preferredEmptySource: ReminderSource?
  @Published var requestedListCreationSource: ReminderSource?
  @Published private(set) var editingFocusRequestID = UUID()
  /// Re-issued when the panel actually becomes key, so a Task Input focus
  /// requested mid-pin (before key status landed) can be applied for real.
  @Published private(set) var taskInputFocusRequestID = UUID()
  /// Snapshot shown by the AI usage sidebar panel; nil renders the skeleton.
  @Published private(set) var aiUsage: AIUsageSnapshot?
  /// Latest Now Playing snapshot; nil renders the music panel's empty state.
  @Published private(set) var nowPlaying: NowPlayingTrack?
  @Published private(set) var lyricsState: LyricsState = .idle
  /// Media keys with live hardware templates this session; empty after a
  /// restart until the user presses the real keys once.
  @Published var mediaKeysReady: Set<Int32> = []
  /// Global lyric lead/lag the user nudges in the lyrics pane; positive
  /// delays lines. Persisted — source drift differs per song upload, one
  /// knob covers it.
  @Published var lyricOffset: TimeInterval = 0 {
    didSet {
      guard oldValue != lyricOffset else { return }
      defaults.set(lyricOffset, forKey: Keys.lyricOffset)
    }
  }

  enum LyricsState: Equatable {
    case idle
    case loading
    case loaded(Lyrics)
    case notFound
  }
  @Published private(set) var collapsedIslandVisibility: CollapsedIslandVisibility?
  @Published private(set) var isCollapsedIslandVisible: Bool
  @Published var errorMessage: String?
  @Published var activeListID: String? {
    didSet {
      defaults.set(activeListID, forKey: Keys.activeListID)
    }
  }
  @Published var selectedReminderID: String?
  @Published var editingReminderID: String?
  @Published var draft: ReminderDraft?

  private let store: ReminderStore
  private let defaults: UserDefaults
  private let aiUsageProvider: AIUsageProvider
  private let lyricsService: LyricsService
  private let nowPlayingController: any NowPlayingControlling
  /// Guards refreshAIUsage against refetching on every hover-select.
  private var lastAIUsageRefresh: Date?
  /// Identity whose lyrics are loaded or being fetched; elapsed/rate
  /// jitter must never re-trigger a fetch.
  private var currentLyricsIdentity: LyricsIdentity?
  private var lyricsTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var scheduleTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  /// The month whose data is currently in memory; a same-month day switch
  /// reuses it instead of re-running the EventKit queries.
  private var loadedMonthInterval: DateInterval?
  private var isPointerInsideIsland = false
  private var suspendedEditingFocus: SuspendedEditingFocus?

  private enum SuspendedEditingFocus {
    case reminderEditor
  }

  private enum Keys {
    static let activeListID = "active-list-id"
    static let didInitializeLocalSource = "did-initialize-local-source"
    static let collapsedIslandVisibility = "collapsed-island-visibility"
    static let lyricOffset = "lyric-offset"
  }

  init(
    store: ReminderStore = SourceAwareReminderStore(),
    defaults: UserDefaults = .standard,
    aiUsageProvider: AIUsageProvider = SampleAIUsageProvider(),
    lyricsService: LyricsService = LyricsService(),
    nowPlayingController: any NowPlayingControlling = NowPlayingController.shared
  ) {
    self.store = store
    self.defaults = defaults
    self.aiUsageProvider = aiUsageProvider
    self.lyricsService = lyricsService
    self.nowPlayingController = nowPlayingController
    lyricOffset = defaults.object(forKey: Keys.lyricOffset) as? Double ?? 0
    // The stay-mode onboarding was removed; a missing choice defaults to
    // always-visible (and is persisted so Settings shows the same value).
    let savedCollapsedVisibility = defaults.string(forKey: Keys.collapsedIslandVisibility)
      .flatMap(CollapsedIslandVisibility.init(rawValue:))
    let initialVisibility = savedCollapsedVisibility ?? .alwaysVisible
    collapsedIslandVisibility = initialVisibility
    if savedCollapsedVisibility == nil {
      defaults.set(initialVisibility.rawValue, forKey: Keys.collapsedIslandVisibility)
    }
    isCollapsedIslandVisible = initialVisibility != .autoHide
    authorization = store.authorizationStatus()
    localStoreAvailability = store.localStoreAvailability
    if authorization == .notDetermined {
      islandState = .pinned
    }
    activeListID = defaults.string(forKey: Keys.activeListID)
    hostDisplayID = nil
    defaults.removeObject(forKey: "selected-display-id")
    defaults.removeObject(forKey: "completed-onboarding")

    store.onStoreChanged = { [weak self] in
      self?.scheduleRefresh()
    }
  }

  var activeList: ReminderListSnapshot? {
    lists.first { $0.id == activeListID }
  }

  var iCloudLists: [ReminderListSnapshot] { lists.filter { $0.source == .iCloud } }
  var localLists: [ReminderListSnapshot] { lists.filter { $0.source == .local } }
  var iCloudSourceMenuState: ICloudSourceMenuState {
    guard authorization == .fullAccess else { return .authorizationRequired }
    return iCloudLists.isEmpty ? .empty : .available
  }
  var shouldShowAuthorizationLockInHeader: Bool {
    authorization != .fullAccess && activeList == nil
  }
  var canUseActiveList: Bool {
    guard let activeList else { return false }
    return canAccess(source: activeList.source)
  }
  var usesAutoHiddenCollapsedIsland: Bool { collapsedIslandVisibility == .autoHide }
  var nextReminder: ReminderSnapshot? { reminders.first }
  var remainingCount: Int { reminders.count }
  /// Sidebar order of the Lists — the schedule groups same-List Reminders
  /// together in this order.
  var listRankByListID: [String: Int] {
    var rank: [String: Int] = [:]
    for (index, list) in lists.enumerated() {
      rank[list.id] = index
    }
    return rank
  }

  var selectedDaySchedule: ReminderSchedule.DaySchedule {
    // Overdue entries only land on the current day; the schedule decides
    // how they merge with that day's own reminders.
    ReminderSchedule.schedule(
      on: selectedDay,
      in: monthReminders + overdueReminders,
      listRank: listRankByListID
    )
  }
  /// Every Reminder the Day Schedule pane can display, in display order.
  /// Completed Reminders are not listed — completing one removes its row.
  var visibleScheduleReminders: [ReminderSnapshot] {
    let schedule = selectedDaySchedule
    return schedule.pending + undatedReminders
  }
  /// The Island Preview shows the Active List's pending reminders; the Pinned
  /// Island's Day Schedule additionally includes completed and undated ones.
  var keyboardNavigableReminders: [ReminderSnapshot] {
    islandState == .preview ? reminders : visibleScheduleReminders
  }
  var selectedReminder: ReminderSnapshot? {
    keyboardNavigableReminders.first { $0.id == selectedReminderID }
  }
  var canSaveEditingDraft: Bool {
    guard
      isEditingDraftValidated,
      let editingReminderID,
      draft != nil
    else { return false }
    if let reminder = reminders.first(where: { $0.id == editingReminderID }) {
      return canAccess(source: reminder.source)
    }
    if let reminder = visibleScheduleReminders.first(where: { $0.id == editingReminderID }) {
      return canAccess(source: reminder.source)
    }
    return false
  }

  func start() async {
    authorization = store.authorizationStatus()
    await reload()
    if authorization == .notDetermined, activeList?.source != .local {
      pinIsland()
    } else if activeList?.source == .local, islandState == .pinned {
      collapseIsland()
    }
    reconcileCollapsedIslandVisibility(hideImmediately: true)
  }

  func requestAccess() async {
    guard
      authorization == .notDetermined,
      !isRequestingAccess
    else { return }
    isRequestingAccess = true
    defer { isRequestingAccess = false }

    do {
      _ = try await store.requestFullAccess()
      authorization = store.authorizationStatus()
      await reload()
    } catch {
      present(error)
      authorization = store.authorizationStatus()
    }
  }

  func reload() async {
    authorization = store.authorizationStatus()
    localStoreAvailability = store.localStoreAvailability
    isLoading = true
    defer {
      isLoading = false
      reconcileCollapsedIslandVisibility()
      schedulePointerExitCollapseIfNeeded()
    }

    do {
      let fetchedLists = try await store.fetchLists()
      localStoreAvailability = store.localStoreAvailability
      var newLists = fetchedLists.filter { canAccess(source: $0.source) }
      if authorization != .fullAccess {
        let cachedICloudLists = lists.filter { $0.source == .iCloud }
        newLists = cachedICloudLists + newLists.filter { $0.source == .local }
      }
      lists = newLists
      if newLists.contains(where: { $0.source == .local }) {
        defaults.set(true, forKey: Keys.didInitializeLocalSource)
      }
      await reloadScheduleData(force: true)

      if !newLists.contains(where: { $0.id == activeListID }) {
        if let activeListID,
          let migrated = newLists.first(where: {
            $0.source == .iCloud
              && ReminderStoreIdentity.split($0.id)?.rawID == activeListID
          })
        {
          self.activeListID = migrated.id
        } else {
          activeListID = newLists.first(where: {
            $0.source == .iCloud && canAccess(source: $0.source)
          })?.id
            ?? newLists.first(where: {
              $0.source == .local && canAccess(source: $0.source)
            })?.id
        }
      }

      guard let activeListID else {
        reminders = []
        selectedReminderID = nil
        isEditingDraftValidated = editingReminderID == nil
        return
      }
      preferredEmptySource = nil

      guard let activeList, canAccess(source: activeList.source) else {
        if editingReminderID != nil {
          isEditingDraftValidated = false
        }
        return
      }

      let fetched = try await store.fetchPendingReminders(in: activeListID)
      reminders = ReminderSorter.sorted(fetched)
      let navigable = keyboardNavigableReminders
      if !navigable.contains(where: { $0.id == selectedReminderID }) {
        selectedReminderID = navigable.first?.id
      }
      if let editingReminderID {
        isEditingDraftValidated = reminders.contains { $0.id == editingReminderID }
      } else {
        isEditingDraftValidated = true
      }
    } catch {
      present(error)
    }
  }

  func selectList(_ id: String) {
    guard let list = lists.first(where: { $0.id == id }), canAccess(source: list.source) else {
      return
    }
    activeListID = id
    preferredEmptySource = nil
    selectedReminderID = nil
    cancelEditing()
    Task { await reload() }
  }

  /// Moves the Day Schedule to another date. Crossing into a different month
  /// refetches the month's dated reminders.
  /// Creates a Pending Reminder in the chosen list, due on the given day —
  /// the Task Input beneath the schedule adds work straight onto the
  /// selected date.
  func createTask(_ title: String, on day: Date, in listID: String) {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      let list = lists.first(where: { $0.id == listID }),
      canAccess(source: list.source)
    else { return }
    let components = Calendar.current.dateComponents([.year, .month, .day], from: day)
    Task {
      do {
        try await store.createReminder(
          title: normalized, in: listID, dueComponents: components)
        await reload()
      } catch {
        present(error)
      }
    }
  }

  func selectDay(_ day: Date) {
    let calendar = Calendar.current
    let newDay = calendar.startOfDay(for: day)
    guard newDay != calendar.startOfDay(for: selectedDay) else { return }
    selectedDay = newDay
    scheduleTask?.cancel()
    scheduleTask = Task { await reloadScheduleData() }
  }

  /// Refreshes the schedule caches. Undated, overdue, and completion
  /// history never depend on the selected day, and a same-month day switch
  /// reuses the month already in memory — so a plain selection change skips
  /// all four EventKit queries. `force` re-queries after the store (or the
  /// selected month) actually changed.
  private func reloadScheduleData(force: Bool = false) async {
    let calendar = Calendar.current
    guard let interval = calendar.dateInterval(of: .month, for: selectedDay) else {
      monthReminders = []
      undatedReminders = []
      overdueReminders = []
      recentlyCompletedReminders = []
      heatmapGrid = ReminderHeatmap.Grid(weeks: [], counts: [:])
      loadedMonthInterval = nil
      return
    }
    if force || loadedMonthInterval != interval {
      var dated =
        (try? await store.fetchReminders(dueFrom: interval.start, through: interval.end)) ?? []
      var undated = (try? await store.fetchUndatedPendingReminders()) ?? []
      var overdue = (try? await store.fetchOverduePendingReminders(before: interval.start)) ?? []
      let completedRecently =
        (try? await store.fetchCompletedReminders(
          completedFrom: calendar.date(
            byAdding: .day, value: -180, to: calendar.startOfDay(for: Date())
          ) ?? Date())) ?? []
      guard !Task.isCancelled else { return }
      // Rows mid-celebration stay visible: the backend already marked them
      // completed, but their confetti is still playing.
      let celebrating = completingReminderIDs
      if !celebrating.isEmpty {
        func keepPending(_ reminders: [ReminderSnapshot]) -> [ReminderSnapshot] {
          reminders.map { reminder in
            var reminder = reminder
            if celebrating.contains(reminder.id) { reminder.isCompleted = false }
            return reminder
          }
        }
        dated = keepPending(dated)
        overdue = keepPending(overdue)
        undated = keepPending(undated)
        // Completed undated/overdue Reminders drop out of the pending-only
        // fetches — carry them over from the previous lists until the
        // celebration ends.
        let undatedIDs = Set(undated.map(\.id))
        undated += undatedReminders.filter {
          celebrating.contains($0.id) && !undatedIDs.contains($0.id)
        }
        let overdueIDs = Set(overdue.map(\.id))
        overdue += overdueReminders.filter {
          celebrating.contains($0.id) && !overdueIDs.contains($0.id)
        }
      }
      monthReminders = dated
      undatedReminders = ReminderSorter.sorted(undated, listRank: listRankByListID)
      overdueReminders = overdue
      recentlyCompletedReminders = completedRecently
      heatmapGrid = ReminderHeatmap.grid(in: completedRecently)
      loadedMonthInterval = interval
    }
    let navigable = keyboardNavigableReminders
    if !navigable.contains(where: { $0.id == selectedReminderID }) {
      selectedReminderID = navigable.first?.id
    }
  }

  func beginEditing(_ reminder: ReminderSnapshot) {
    guard canAccess(source: reminder.source) else { return }
    selectedReminderID = reminder.id
    editingReminderID = reminder.id
    draft = ReminderDraft(reminder: reminder)
    isEditingDraftValidated = true
  }

  func cancelEditing() {
    editingReminderID = nil
    draft = nil
    isEditingDraftValidated = true
  }

  func saveEditing() {
    guard let id = editingReminderID, let draft else { return }
    guard isEditingDraftValidated else { return }
    guard
      let reminder = reminders.first(where: { $0.id == id })
        ?? visibleScheduleReminders.first(where: { $0.id == id })
    else {
      errorMessage = ReminderStoreError.reminderNotFound.localizedDescription
      return
    }
    guard canAccess(source: reminder.source) else { return }
    guard !draft.normalizedTitle.isEmpty else {
      errorMessage = ReminderStoreError.emptyTitle.localizedDescription
      return
    }

    Task {
      do {
        try await store.updateReminder(id: id, from: draft)
        if editingReminderID == id, self.draft == draft {
          cancelEditing()
        }
        await reload()
      } catch {
        present(error)
      }
    }
  }

  func complete(_ reminder: ReminderSnapshot) {
    guard
      canAccess(source: reminder.source),
      isKnownReminder(reminder),
      completingReminderIDs.insert(reminder.id).inserted
    else { return }

    if editingReminderID == reminder.id {
      cancelEditing()
    }

    Task {
      do {
        try await store.setCompleted(true, reminderID: reminder.id)
        // Hold the row until the confetti finishes, then let it fade while
        // the rows below slide up.
        try await Task.sleep(for: .milliseconds(750))
        removeCompletedReminder(id: reminder.id)
        await reload()
      } catch {
        completingReminderIDs.remove(reminder.id)
        present(error)
      }
    }
  }

  private func isKnownReminder(_ reminder: ReminderSnapshot) -> Bool {
    reminders.contains(where: { $0.id == reminder.id })
      || visibleScheduleReminders.contains(where: { $0.id == reminder.id })
  }

  func delete(_ reminder: ReminderSnapshot) {
    guard canAccess(source: reminder.source) else { return }
    Task {
      do {
        try await store.deleteReminder(id: reminder.id)
        await reload()
      } catch {
        present(error)
      }
    }
  }

  func requestNewList(source: ReminderSource = .iCloud) {
    requestedListCreationSource = source
    pinIsland()
  }

  func cancelListCreation() {
    requestedListCreationSource = nil
  }

  @discardableResult
  func createList(title: String, source: ReminderSource) async -> Bool {
    guard source == .local || authorization == .fullAccess else {
      errorMessage = ReminderStoreError.operationUnsupported.localizedDescription
      return false
    }

    do {
      let list = try await store.createList(title: title, source: source)
      if source == .local {
        defaults.set(true, forKey: Keys.didInitializeLocalSource)
      }
      requestedListCreationSource = nil
      await reload()
      activeListID = lists.contains(where: { $0.id == list.id }) ? list.id : activeListID
      if activeListID == list.id {
        preferredEmptySource = nil
        selectedReminderID = nil
        reminders = []
      }
      return activeListID == list.id
    } catch {
      present(error)
      return false
    }
  }

  @discardableResult
  func renameList(_ list: ReminderListSnapshot, title: String) async -> Bool {
    guard list.source == .local else { return false }
    do {
      try await store.renameList(id: list.id, title: title)
      await reload()
      return true
    } catch {
      present(error)
      return false
    }
  }

  func prepareListDeletion(_ list: ReminderListSnapshot) async {
    guard list.source == .local else { return }
    do {
      listDeletionCandidate = try await store.deletionSummary(forListID: list.id)
    } catch {
      present(error)
    }
  }

  func cancelListDeletion() {
    listDeletionCandidate = nil
  }

  func confirmListDeletion(_ candidate: ReminderListDeletionSummary) async {
    if listDeletionCandidate?.list.id == candidate.list.id {
      listDeletionCandidate = nil
    }
    do {
      try await store.deleteList(id: candidate.list.id)
      if activeListID == candidate.list.id {
        activeListID = nil
        preferredEmptySource = candidate.list.source
      }
      await reload()
    } catch {
      present(error)
    }
  }

  func useLocal() async {
    pinIsland()
    guard localStoreAvailability == .available else {
      errorMessage = ReminderStoreError.localStoreUnavailable.localizedDescription
      return
    }

    if let list = localLists.first {
      defaults.set(true, forKey: Keys.didInitializeLocalSource)
      selectList(list.id)
      return
    }

    if !defaults.bool(forKey: Keys.didInitializeLocalSource) {
      _ = await createList(title: "Todo Island", source: .local)
    } else {
      requestNewList(source: .local)
    }
  }

  func retryLocalStore() async {
    await store.retryLocalStore()
    localStoreAvailability = store.localStoreAvailability
    await reload()
  }

  func showLocalDataInFinder() {
    guard case let .unavailable(_, dataURL) = localStoreAvailability, let dataURL else { return }
    let target = FileManager.default.fileExists(atPath: dataURL.path)
      ? dataURL : dataURL.deletingLastPathComponent()
    NSWorkspace.shared.activateFileViewerSelecting([target])
  }

  func moveSelection(_ delta: Int) {
    let navigable = keyboardNavigableReminders
    guard !navigable.isEmpty else { return }
    let currentIndex = navigable.firstIndex { $0.id == selectedReminderID } ?? 0
    let nextIndex = min(max(currentIndex + delta, 0), navigable.count - 1)
    selectedReminderID = navigable[nextIndex].id
  }

  func setIslandHovered(_ hovering: Bool) {
    guard isPointerInsideIsland != hovering else { return }
    isPointerInsideIsland = hovering
    hoverTask?.cancel()

    if hovering {
      guard islandState == .collapsed else { return }
      showCollapsedIsland()
      if suspendedEditingFocus != nil {
        pinIsland()
        return
      }
      hoverTask = Task {
        try? await Task.sleep(for: .milliseconds(200))
        guard
          !Task.isCancelled,
          isPointerInsideIsland,
          islandState == .collapsed
        else { return }
        islandState = .preview
      }
    } else {
      schedulePointerExitCollapseIfNeeded()
    }
  }

  func pinIsland() {
    hoverTask?.cancel()
    showCollapsedIsland()
    islandState = .pinned
    guard suspendedEditingFocus != nil else { return }
    suspendedEditingFocus = nil
    editingFocusRequestID = UUID()
  }

  /// The panel just became the key window. Focus set earlier in the pin
  /// transition could not land in a non-key window; now it can.
  func notePanelDidBecomeKey() {
    guard islandState == .pinned, editingReminderID == nil else { return }
    taskInputFocusRequestID = UUID()
  }

  func collapseIsland() {
    hoverTask?.cancel()
    suspendedEditingFocus = nil
    isPointerInsideIsland = false
    if editingReminderID == nil
      || reminders.first(where: { $0.id == editingReminderID }).map({ canAccess(source: $0.source) })
        == true
    {
      cancelEditing()
    }
    islandState = .collapsed
    reconcileCollapsedIslandVisibility(hideImmediately: true)
  }

  func setCollapsedIslandVisibility(_ visibility: CollapsedIslandVisibility) {
    guard collapsedIslandVisibility != visibility else { return }
    collapsedIslandVisibility = visibility
    defaults.set(visibility.rawValue, forKey: Keys.collapsedIslandVisibility)

    switch visibility {
    case .alwaysVisible:
      showCollapsedIsland()
    case .autoHide:
      reconcileCollapsedIslandVisibility()
    }
  }

  func setHostDisplayID(_ displayID: String?) {
    hostDisplayID = displayID
  }

  func updateExpandedContentHeight(_ height: CGFloat) {
    guard height.isFinite, height > 0 else { return }
    let measuredHeight = ceil(height)
    guard expandedContentHeight != measuredHeight else { return }
    expandedContentHeight = measuredHeight
  }

  /// Refreshes the AI usage panel on panel selection and app activation;
  /// throttled to five minutes so hover-selecting the sidebar icon doesn't
  /// refetch. Stale data is kept when a fetch fails.
  func refreshAIUsage() {
    let staleness = lastAIUsageRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
    guard aiUsage == nil || staleness > 300 else { return }
    lastAIUsageRefresh = Date()
    Task { @MainActor in
      if let snapshot = try? await aiUsageProvider.fetchUsage() {
        aiUsage = snapshot
      }
    }
  }

  // MARK: Music

  /// Entry point for NowPlayingController updates (wired in AppDelegate).
  func nowPlayingDidChange(_ track: NowPlayingTrack?) {
    nowPlaying = track
    guard let track else {
      lyricsTask?.cancel()
      currentLyricsIdentity = nil
      lyricsState = .idle
      return
    }
    guard track.lyricsIdentity != currentLyricsIdentity else { return }
    currentLyricsIdentity = track.lyricsIdentity
    fetchLyrics(for: track)
  }

  private func fetchLyrics(for track: NowPlayingTrack) {
    lyricsTask?.cancel()
    guard !track.title.isEmpty else {
      lyricsState = .idle
      return
    }
    lyricsState = .loading
    let identity = track.lyricsIdentity
    lyricsTask = Task { @MainActor in
      let found = await lyricsService.lyrics(
        title: track.title, artist: track.artist, duration: track.duration
      )
      guard !Task.isCancelled, identity == currentLyricsIdentity else { return }
      lyricsState = found.map { .loaded($0) } ?? .notFound
      Self.logLyricsOutcome(
        title: track.title, artist: track.artist, found: found != nil
      )
    }
  }

  private nonisolated static let lyricsLog = os.Logger(
    subsystem: "com.fxl.TodoIsland", category: "lyrics"
  )

  private static func logLyricsOutcome(title: String, artist: String, found: Bool) {
    lyricsLog.info(
      "lyrics \(found ? "found" : "not found", privacy: .public) for \(title, privacy: .public) — \(artist, privacy: .public)"
    )
  }

  /// Sidebar activity gate for elapsed-time polling; idempotent under
  /// hover-repeat.
  func setMusicPanelActive(_ active: Bool) {
    nowPlayingController.setPanelActive(active)
  }

  var nowPlayingSupportsSeeking: Bool { nowPlayingController.supportsSeeking }

  func musicTogglePlayPause() { nowPlayingController.togglePlayPause() }
  func musicSkipForward() { nowPlayingController.next() }
  func musicSkipBackward() { nowPlayingController.previous() }
  func musicSeek(to seconds: TimeInterval) { nowPlayingController.seek(to: seconds) }

  func markApplicationActive() {
    let newAuthorization = store.authorizationStatus()
    authorization = newAuthorization
    localStoreAvailability = store.localStoreAvailability
    scheduleRefresh(delay: .milliseconds(50))
    refreshAIUsage()
    if newAuthorization != .fullAccess,
      let editingReminderID,
      reminders.first(where: { $0.id == editingReminderID })?.source == .iCloud
    {
      isEditingDraftValidated = false
    }
  }

  private func scheduleRefresh(delay: Duration = .milliseconds(250)) {
    refreshTask?.cancel()
    refreshTask = Task {
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await reload()
    }
  }

  private func schedulePointerExitCollapseIfNeeded() {
    guard !isPointerInsideIsland else { return }

    let delay: Duration
    switch islandState {
    case .collapsed:
      guard canAutoHideCollapsedIsland else { return }
      delay = .milliseconds(200)
    case .preview:
      delay = .milliseconds(500)
    case .pinned:
      guard canUseActiveList else { return }
      delay = .milliseconds(200)
    }

    hoverTask?.cancel()
    hoverTask = Task {
      try? await Task.sleep(for: delay)
      guard
        !Task.isCancelled,
        !isPointerInsideIsland
      else { return }

      switch islandState {
      case .collapsed:
        guard canAutoHideCollapsedIsland else { return }
        isCollapsedIslandVisible = false
      case .preview:
        collapseIsland()
      case .pinned:
        guard canUseActiveList else { return }
        suspendPinnedIsland()
      }
    }
  }

  private func suspendPinnedIsland() {
    if editingReminderID != nil, draft != nil {
      suspendedEditingFocus = .reminderEditor
    } else {
      suspendedEditingFocus = nil
    }

    islandState = .collapsed
    reconcileCollapsedIslandVisibility(hideImmediately: true)
  }

  private var canAutoHideCollapsedIsland: Bool {
    usesAutoHiddenCollapsedIsland && canUseActiveList
  }

  private func showCollapsedIsland() {
    hoverTask?.cancel()
    isCollapsedIslandVisible = true
  }

  private func reconcileCollapsedIslandVisibility(hideImmediately: Bool = false) {
    guard islandState == .collapsed else {
      isCollapsedIslandVisible = true
      return
    }

    guard canAutoHideCollapsedIsland else {
      isCollapsedIslandVisible = true
      return
    }

    guard !isPointerInsideIsland else {
      isCollapsedIslandVisible = true
      return
    }

    if hideImmediately {
      hoverTask?.cancel()
      isCollapsedIslandVisible = false
    } else {
      schedulePointerExitCollapseIfNeeded()
    }
  }

  private func removeCompletedReminder(id: String) {
    let removedIndex = reminders.firstIndex { $0.id == id }
    reminders.removeAll { $0.id == id }
    if let index = monthReminders.firstIndex(where: { $0.id == id }) {
      monthReminders[index].isCompleted = true
    }
    undatedReminders.removeAll { $0.id == id }
    completingReminderIDs.remove(id)

    guard selectedReminderID == id else { return }
    guard let removedIndex, !reminders.isEmpty else {
      selectedReminderID = nil
      return
    }
    selectedReminderID = reminders[min(removedIndex, reminders.count - 1)].id
  }

  private func present(_ error: Error) {
    errorMessage = error.localizedDescription
  }

  private func canAccess(source: ReminderSource) -> Bool {
    switch source {
    case .iCloud: authorization == .fullAccess
    case .local: localStoreAvailability == .available
    }
  }
}
