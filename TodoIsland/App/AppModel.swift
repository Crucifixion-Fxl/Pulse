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
  /// Shared across display headers; created only when weather is mounted.
  lazy var weatherStore = WeatherStore()
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
  /// Browsing months does not move the selected day or its schedule.
  @Published private var browsedMonth: Date?
  @Published private var browsedMonthReminders: [ReminderSnapshot] = []

  var calendarMonth: Date { browsedMonth ?? selectedDay }

  var calendarReminders: [ReminderSnapshot] {
    Calendar.current.isDate(calendarMonth, equalTo: selectedDay, toGranularity: .month)
      ? monthReminders : browsedMonthReminders
  }
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
  @Published private(set) var completionUndoItems: [CompletionUndoItem] = []
  @Published private(set) var isUndoingCompletion = false
  /// Only intentional keyboard navigation scrolls the schedule. Completing
  /// a selected row must not recenter the list under the pointer.
  @Published private(set) var selectionScrollRequestID = UUID()

  struct CompletionUndoItem: Identifiable {
    let id: UUID
    let reminder: ReminderSnapshot
    let order: Int
  }

  private var completionOperations: [String: UUID] = [:]
  private var completionOrder = 0
  private var completionUndoExpiry: Task<Void, Never>?
  private let completionFeedbackDuration: Duration
  private let completionUndoDuration: Duration
  @Published private(set) var hostDisplayID: String?
  /// Sidebar pane the UI should switch to — bumped by features that
  /// auto-expand the island (e.g. an agent approval request routing to the
  /// agents pane). IslandRootView observes and syncs its local selection.
  @Published private(set) var requestedSidebarItem: IslandSidebarItem?
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
  /// Clipboard history, newest first; at most seven entries.
  @Published private(set) var clipboardItems: [ClipboardItem] = []
  /// NetEase "我喜欢的音乐"; empty until the uid is configured and the
  /// first fetch lands.
  @Published private(set) var favoriteTracks: [FavoriteTrack] = []
  @Published private(set) var favoritesState: FavoritesState = .idle

  enum FavoritesState: Equatable {
    case idle
    case unconfigured
    case loading
    case loaded
    case failed
  }
  /// Global lyric lead/lag the user nudges in the lyrics pane; positive
  /// delays lines. Persisted — source drift differs per song upload, one
  /// knob covers it.
  /// Retained for potential future use; no longer wired to the UI.
  @Published var lyricOffset: TimeInterval = 0

  enum LyricsState: Equatable {
    case idle
    case loading
    case loaded(Lyrics)
    case notFound
  }
  @Published private(set) var collapsedIslandVisibility: CollapsedIslandVisibility?
  @Published private(set) var isCollapsedIslandVisible: Bool
  /// Whose subscription quota the collapsed bar's chip shows; picked in
  /// the AI usage panel.
  @Published private(set) var collapsedQuotaVendor: AIUsageVendor
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
  private var favoriteProvider = FavoritePlaylistProvider()
  private let favoritesStore = FavoritePlaylistStore()
  private let nowPlayingController: any NowPlayingControlling
  /// Guards refreshAIUsage against refetching on every hover-select.
  private var lastAIUsageRefresh: Date?
  /// Identity whose lyrics are loaded or being fetched; elapsed/rate
  /// jitter must never re-trigger a fetch.
  private var currentLyricsIdentity: LyricsIdentity?
  private var lyricsTask: Task<Void, Never>?
  /// The single internal-player bridge is subscribed in start() and lives
  /// for the process lifetime; exposed read-only so tests can assert that
  /// collapse/suspend cycles never add duplicates.
  private(set) var internalPlayerCancellable: Set<AnyCancellable> = []
  private var refreshTask: Task<Void, Never>?
  private var scheduleTask: Task<Void, Never>?
  private var calendarTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  /// The month whose data is currently in memory; a same-month day switch
  /// reuses it instead of re-running the EventKit queries.
  private var loadedMonthInterval: DateInterval?
  /// Published so the collapsed content can react (bot-face eyes widen)
  /// while the pointer dwells on the island before it expands.
  @Published private(set) var isPointerInsideIsland = false
  private var suspendedEditingFocus: SuspendedEditingFocus?

  private enum SuspendedEditingFocus {
    case reminderEditor
  }

  private enum Keys {
    static let activeListID = "active-list-id"
    static let didInitializeLocalSource = "did-initialize-local-source"
    static let collapsedIslandVisibility = "collapsed-island-visibility"
    static let collapsedQuotaVendor = "collapsed-quota-vendor"
    static let lyricOffset = "lyric-offset"
    static let neteaseUID = "netease-uid"
    static let neteaseMusicU = "netease-music-u"
  }

  init(
    store: ReminderStore = SourceAwareReminderStore(),
    defaults: UserDefaults = .standard,
    aiUsageProvider: AIUsageProvider = DefaultAIUsageProvider(),
    lyricsService: LyricsService = LyricsService(),
    nowPlayingController: any NowPlayingControlling = NowPlayingController.shared,
    completionFeedbackDuration: Duration = .milliseconds(750),
    completionUndoDuration: Duration = .seconds(8)
  ) {
    self.store = store
    self.completionFeedbackDuration = completionFeedbackDuration
    self.completionUndoDuration = completionUndoDuration
    self.defaults = defaults
    self.aiUsageProvider = aiUsageProvider
    self.lyricsService = lyricsService
    self.nowPlayingController = nowPlayingController
    // The stay-mode onboarding was removed; a missing choice defaults to
    // always-visible (and is persisted so Settings shows the same value).
    let savedCollapsedVisibility = defaults.string(forKey: Keys.collapsedIslandVisibility)
      .flatMap(CollapsedIslandVisibility.init(rawValue:))
    let initialVisibility = savedCollapsedVisibility ?? .alwaysVisible
    collapsedIslandVisibility = initialVisibility
    if savedCollapsedVisibility == nil {
      defaults.set(initialVisibility.rawValue, forKey: Keys.collapsedIslandVisibility)
    }
    // The chip shipped showing Codex; keep that default for existing users.
    collapsedQuotaVendor = defaults.string(forKey: Keys.collapsedQuotaVendor)
      .flatMap(AIUsageVendor.init(rawValue:)) ?? .openAI
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
      let draft, !draft.normalizedTitle.isEmpty
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
    // Bridge internal player's state into the panel continuously.
    InternalPlayerService.shared.objectWillChange.sink { [weak self] _ in
      self?.syncInternalPlayer()
    }.store(in: &internalPlayerCancellable)
    InternalPlayerService.shared.onTrackEnded = { [weak self] in
      self?.skipInternal(delta: 1)
    }
    // Accessory apps don't become "active" at launch; warm the favorites
    // rail here instead of waiting for panel hover.
    Self.favoritesLog.info(
      "startup: netease-uid=\(self.neteaseUID.map(String.init) ?? "nil", privacy: .public)"
    )
    refreshFavorites()
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
      let fetchedIDs = Set(fetched.map(\.id))
      let held = reminders.filter {
        $0.listID == activeListID && completingReminderIDs.contains($0.id)
          && !fetchedIDs.contains($0.id)
      }
      reminders = ReminderSorter.sorted(fetched + held)
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

  func shiftMonth(by offset: Int) {
    let calendar = Calendar.current
    guard let start = calendar.dateInterval(of: .month, for: calendarMonth)?.start,
      let month = calendar.date(byAdding: .month, value: offset, to: start)
    else {
      return
    }
    browsedMonth = month
    browsedMonthReminders = []
    reloadBrowsedMonth()
  }

  private func reloadBrowsedMonth() {
    calendarTask?.cancel()
    let calendar = Calendar.current
    guard !calendar.isDate(calendarMonth, equalTo: selectedDay, toGranularity: .month),
      let interval = calendar.dateInterval(of: .month, for: calendarMonth)
    else { return }
    calendarTask = Task {
      let reminders = (try? await store.fetchReminders(
        dueFrom: interval.start, through: interval.end)) ?? []
      guard !Task.isCancelled,
        calendar.dateInterval(of: .month, for: calendarMonth) == interval
      else { return }
      browsedMonthReminders = reminders
    }
  }

  func selectDay(_ day: Date) {
    let calendar = Calendar.current
    let newDay = calendar.startOfDay(for: day)
    browsedMonth = nil
    calendarTask?.cancel()
    browsedMonthReminders = []
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
      // Hold completed rows in place until their checkmark feedback finishes,
      // even when a store notification reloads the schedule in the meantime.
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
    reloadBrowsedMonth()
    let navigable = keyboardNavigableReminders
    if !navigable.contains(where: { $0.id == selectedReminderID }) {
      selectedReminderID = navigable.first?.id
    }
  }

  func beginEditing(_ reminder: ReminderSnapshot) {
    guard canAccess(source: reminder.source) else { return }
    selectedReminderID = reminder.id
    hoverTask?.cancel()
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

  func complete(_ reminder: ReminderSnapshot, reduceMotion: Bool = false) {
    guard
      !reminder.isCompleted,
      canAccess(source: reminder.source),
      isKnownReminder(reminder),
      completingReminderIDs.insert(reminder.id).inserted
    else { return }

    if editingReminderID == reminder.id { cancelEditing() }
    let operation = UUID()
    completionOperations[reminder.id] = operation
    completionOrder += 1
    let order = completionOrder

    Task {
      do {
        try await store.setCompleted(true, reminderID: reminder.id)
        completionUndoItems.append(CompletionUndoItem(id: operation, reminder: reminder, order: order))
        // Save callbacks may finish out of order; undo follows the click order.
        completionUndoItems.sort { $0.order < $1.order }
        scheduleCompletionUndoExpiry()
        try await Task.sleep(for: reduceMotion ? .milliseconds(120) : completionFeedbackDuration)
        // Undo can happen during the feedback hold. Its successful write
        // must never be overwritten by an older animation's finalizer.
        guard completionOperations[reminder.id] == operation else { return }
        completionOperations.removeValue(forKey: reminder.id)
        removeCompletedReminder(id: reminder.id)
        await reload()
      } catch {
        guard completionOperations[reminder.id] == operation else { return }
        completionOperations.removeValue(forKey: reminder.id)
        completingReminderIDs.remove(reminder.id)
        present(error)
      }
    }
  }

  func undoLastCompletion() async {
    guard !isUndoingCompletion, let item = completionUndoItems.last else { return }
    isUndoingCompletion = true
    completionUndoExpiry?.cancel()
    completionOperations.removeValue(forKey: item.reminder.id)
    do {
      try await store.setCompleted(false, reminderID: item.reminder.id)
      completingReminderIDs.remove(item.reminder.id)
      completionUndoItems.removeAll { $0.id == item.id }
      await reload()
    } catch {
      // The store still holds a completed item. End its visual hold, but
      // retain this undo entry so the user can retry rather than lose it.
      removeCompletedReminder(id: item.reminder.id)
      present(error)
      await reload()
    }
    isUndoingCompletion = false
    scheduleCompletionUndoExpiry()
  }

  private func scheduleCompletionUndoExpiry() {
    completionUndoExpiry?.cancel()
    guard !completionUndoItems.isEmpty else { return }
    let duration = completionUndoDuration
    completionUndoExpiry = Task { [weak self] in
      do { try await Task.sleep(for: duration) } catch { return }
      guard let self, !self.isUndoingCompletion else { return }
      self.completionUndoItems = []
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
    selectionScrollRequestID = UUID()
  }

  func setIslandHovered(_ hovering: Bool, on displayID: String? = nil) {
    guard isPointerInsideIsland != hovering else { return }
    isPointerInsideIsland = hovering
    hoverTask?.cancel()

    if hovering {
      // With one island per display, hover names the display whose island
      // is active; hostDisplayID is the routing key the controller and the
      // per-display views agree on.
      if let displayID, displayID != hostDisplayID {
        setHostDisplayID(displayID)
      }
      guard islandState == .collapsed else { return }
      // Hover only reveals the (possibly auto-hidden) bar and resumes a
      // suspended editor — it never expands. The island opens on click.
      showCollapsedIsland()
      if suspendedEditingFocus != nil {
        pinIsland()
      }
    } else {
      schedulePointerExitCollapseIfNeeded()
    }
  }

  /// A click is sufficient evidence of entry. Mouse-entered delivery can
  /// lag behind a click (including accessibility clicks), so do not rely on
  /// hover to route the display or keep a reload from scheduling dismissal.
  func pinIslandFromSurface(on displayID: String?) {
    if let displayID { setHostDisplayID(displayID) }
    isPointerInsideIsland = true
    pinIsland()
  }

  func pinIsland() {
    hoverTask?.cancel()
    showCollapsedIsland()
    islandState = .pinned
    guard suspendedEditingFocus != nil else { return }
    suspendedEditingFocus = nil
    editingFocusRequestID = UUID()
  }

  /// True while the island was auto-opened for a pending approval: the
  /// request usually lands while the pointer is elsewhere, so pointer-exit
  /// suspension is on hold — the panel stays until the queue clears or the
  /// user closes it.
  private(set) var isHeldForApproval = false

  /// Auto-open for a pending approval: pin and hold, regardless of where
  /// the pointer is.
  func pinIslandForApproval() {
    isHeldForApproval = true
    if islandState != .pinned { pinIsland() }
  }

  /// The approval was answered — hand the panel back to normal pinned
  /// semantics (it politely closes if the pointer never arrived).
  func releaseApprovalHold() {
    guard isHeldForApproval else { return }
    isHeldForApproval = false
    schedulePointerExitCollapseIfNeeded()
  }

  /// The panel just became the key window. Focus set earlier in the pin
  /// transition could not land in a non-key window; now it can.
  func notePanelDidBecomeKey() {
    guard islandState == .pinned, editingReminderID == nil else { return }
    taskInputFocusRequestID = UUID()
  }

  func collapseIsland() {
    hoverTask?.cancel()
    isHeldForApproval = false
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

  /// Routes the island's sidebar to a pane; used with pinIsland() by
  /// auto-expansion flows.
  func requestSidebarItem(_ item: IslandSidebarItem) {
    requestedSidebarItem = item
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
  /// Picks whose quota the collapsed bar's chip shows; persisted so the
  /// choice survives relaunches.
  func setCollapsedQuotaVendor(_ vendor: AIUsageVendor) {
    guard vendor != collapsedQuotaVendor else { return }
    collapsedQuotaVendor = vendor
    defaults.set(vendor.rawValue, forKey: Keys.collapsedQuotaVendor)
  }

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
    // The internal player owns the surface while active. External
    // mediaremoted updates only pass through when the external source is
    // actually playing (which yields the internal player); a paused
    // external track must NOT steal the panel back — that caused the
    // artwork to strobe between the two.
    if InternalPlayerService.shared.isActive {
      guard let track, track.isPlaying else { return }
      InternalPlayerService.shared.stop()
    }
    nowPlaying = track
    guard let track else {
      lyricsTask?.cancel()
      currentLyricsIdentity = nil
      lyricsState = .idle
      return
    }
    guard track.lyricsIdentity != currentLyricsIdentity else { return }
    let previousIdentity = currentLyricsIdentity
    currentLyricsIdentity = track.lyricsIdentity
    fetchLyrics(for: track, previousIdentity: previousIdentity)
  }

  private func fetchLyrics(for track: NowPlayingTrack, previousIdentity: LyricsIdentity?) {
    lyricsTask?.cancel()
    guard !track.title.isEmpty else {
      lyricsState = .idle
      return
    }
    let identity = track.lyricsIdentity
    // A duration refinement still deserves a new lookup, but must not tear
    // down a running turntable for the same song while the request is pending.
    let preservesTurntable = lyricsState == .notFound
      && previousIdentity?.title == identity.title
      && previousIdentity?.artist == identity.artist
    if !preservesTurntable { lyricsState = .loading }
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

  func musicTogglePlayPause() {
    if InternalPlayerService.shared.isActive {
      InternalPlayerService.shared.togglePlayPause()
      syncInternalPlayer()
    } else {
      nowPlayingController.togglePlayPause()
    }
  }
  func musicSkipForward() { skipInternal(delta: 1) }
  func musicSkipBackward() { skipInternal(delta: -1) }

  private func skipInternal(delta: Int) {
    let service = InternalPlayerService.shared
    if service.isActive, let current = service.currentTrack,
      let idx = favoriteTracks.firstIndex(where: { $0.id == current.id })
    {
      let nextIdx = idx + delta
      let next = min(max(nextIdx, 0), favoriteTracks.count - 1)
      playFavorite(favoriteTracks[next])
    } else {
      if delta > 0 { nowPlayingController.next() } else { nowPlayingController.previous() }
    }
  }

  func musicSeek(to seconds: TimeInterval) {
    if InternalPlayerService.shared.isActive {
      InternalPlayerService.shared.seek(to: seconds)
      syncInternalPlayer()
    } else {
      nowPlayingController.seek(to: seconds)
    }
  }

  // MARK: Clipboard

  func clipboardHistoryDidChange(_ items: [ClipboardItem]) {
    clipboardItems = items
  }

  func recopyClipboardItem(_ item: ClipboardItem) {
    ClipboardHistoryService.shared.recopy(item)
  }

  // MARK: Favorites

  /// The NetEase numeric account id — the "我喜欢的音乐" playlist id equals
  /// it. Configure via: defaults write com.fxl.TodoIsland netease-uid -int <id>
  var neteaseUID: Int? {
    defaults.object(forKey: Keys.neteaseUID) as? Int
  }

  /// Browser-session cookie for the private favorites playlist
  /// (defaults key netease-music-u).
  var neteaseMusicU: String? {
    defaults.string(forKey: Keys.neteaseMusicU)
  }

  private var lastFavoritesRefresh: Date?

  func refreshFavorites() {
    guard let uid = neteaseUID else {
      favoritesState = .unconfigured
      return
    }
    let staleness = lastFavoritesRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
    guard staleness > 600 else { return }
    lastFavoritesRefresh = Date()

    if favoriteTracks.isEmpty { favoritesState = .loading }
    var provider = favoriteProvider
    provider.musicU = neteaseMusicU
    Task { @MainActor in
      if let stored = await favoritesStore.tracks(playlistID: uid), !stored.isEmpty {
        favoriteTracks = stored
        favoritesState = .loaded
      }
      Self.favoritesLog.info("fetching playlist \(uid) (cached \(self.favoriteTracks.count))")
      guard let fetched = await provider.tracks(playlistID: uid), !fetched.isEmpty else {
        Self.favoritesLog.error("playlist fetch came back empty — state .failed")
        if favoriteTracks.isEmpty { favoritesState = .failed }
        return
      }
      Self.favoritesLog.info("playlist fetched: \(fetched.count) tracks")
      favoriteTracks = fetched
      favoritesState = .loaded
      await favoritesStore.store(fetched, playlistID: uid)
    }
  }

  private nonisolated static let favoritesLog = Logger(
    subsystem: "com.fxl.TodoIsland", category: "favorites"
  )

  /// Plays through the internal AVPlayer — the panel, lyrics, and media
  /// keys all follow our own playback state.
  func playFavorite(_ track: FavoriteTrack) {
    Task { @MainActor in
      let ok = await InternalPlayerService.shared.play(track: track)
      if ok {
        syncInternalPlayer()
      }
    }
  }

  /// Bridges the internal player's state into the panel's NowPlayingTrack,
  /// overriding mediaremoted while active.
  func syncInternalPlayer() {
    let service = InternalPlayerService.shared
    guard service.isActive, let snapshot = service.nowPlayingSnapshot else {
      return
    }
    // Only push a new track when something meaningful changed (title,
    // artwork presence, playing state) — not on every elapsed tick. The
    // lyrics view extrapolates from receivedAt + rate on its own.
    if nowPlaying?.title != snapshot.title
      || nowPlaying?.isPlaying != snapshot.isPlaying
      || (nowPlaying?.artworkData == nil) != (snapshot.artworkData == nil)
    {
      nowPlaying = snapshot
      // Route through the same lyrics-fetch path as external tracks;
      // bypassing it left the previous song's lyrics on screen.
      guard snapshot.lyricsIdentity != currentLyricsIdentity else { return }
      let previousIdentity = currentLyricsIdentity
      currentLyricsIdentity = snapshot.lyricsIdentity
      fetchLyrics(for: snapshot, previousIdentity: previousIdentity)
    }
  }

  func markApplicationActive() {
    let newAuthorization = store.authorizationStatus()
    authorization = newAuthorization
    localStoreAvailability = store.localStoreAvailability
    scheduleRefresh(delay: .milliseconds(50))
    refreshAIUsage()
    refreshFavorites()
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
      guard canUseActiveList, !isHeldForApproval, editingReminderID == nil else { return }
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
        guard canUseActiveList, !isHeldForApproval, editingReminderID == nil else { return }
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
    let removedIndex = keyboardNavigableReminders.firstIndex { $0.id == id }
    reminders.removeAll { $0.id == id }
    if let index = monthReminders.firstIndex(where: { $0.id == id }) {
      monthReminders[index].isCompleted = true
    }
    undatedReminders.removeAll { $0.id == id }
    overdueReminders.removeAll { $0.id == id }
    completingReminderIDs.remove(id)

    guard selectedReminderID == id else { return }
    let remaining = keyboardNavigableReminders
    guard let removedIndex, !remaining.isEmpty else {
      selectedReminderID = nil
      return
    }
    selectedReminderID = remaining[min(removedIndex, remaining.count - 1)].id
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
