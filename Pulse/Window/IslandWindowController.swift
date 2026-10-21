import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Coordinates one island window per display: every screen carries a
/// permanent collapsed bar at its top center, the island on the active
/// display (AppModel.hostDisplayID) expands, and the rest stay collapsed.
/// Exactly one window ever owns key status — the active one, while pinned.
@MainActor
final class IslandWindowController: NSObject, NSWindowDelegate {
  /// The per-display island: its panel, its content, and its compositor transition.
  @MainActor private struct DisplayWindow {
    let panel: IslandPanel
    let transition: IslandTransitionView
    var visibilityGeneration = 0
  }

  private let model: AppModel
  private let agentStore: AgentSessionStore
  private let reduceMotion: () -> Bool
  private var windows: [String: DisplayWindow] = [:]
  private(set) var appliedState: IslandPresentationState?
  private(set) var appliedExpandedContentHeight: CGFloat?
  private(set) var isCollapsedSurfaceVisible = true
  private(set) var isActivationZoneActive = false
  private var cancellables: Set<AnyCancellable> = []
  private var screenObserver: NSObjectProtocol?
  private var applicationDeactivationObserver: NSObjectProtocol?
  private var pointerDisplayTimer: Timer?
  private var fullScreenTimer: Timer?
  private var wakeShortcut: AIWakeShortcut?
  private var wakeGesture = AIWakeGesture()
  private var voiceSession: (any VoiceSessionProvider)?
  private var wakeTimer: Timer?
  private var wakePanel: IslandPanel?
  private var wakeView: BlackHoleWakeView?
  private var wakeDisplayID: String?
  private var wakeGeneration = 0
  private var wakeObservers: [NSObjectProtocol] = []

  init(
    model: AppModel, agentStore: AgentSessionStore = AgentSessionStore(),
    reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  ) {
    self.model = model
    self.agentStore = agentStore
    self.reduceMotion = reduceMotion
    super.init()

    syncWindows()
    applyAll(
      state: model.islandState,
      activeDisplayID: model.hostDisplayID,
      expandedContentHeight: model.expandedContentHeight,
      animated: false)

    // @Published delivers during willSet, so each sink carries its NEW
    // value explicitly; every other property read here is already current.
    model.$islandState
      .removeDuplicates()
      .sink { [weak self] state in
        self?.applyAll(
          state: state,
          activeDisplayID: self?.model.hostDisplayID,
          expandedContentHeight: self?.model.expandedContentHeight,
          animated: true)
      }
      .store(in: &cancellables)

    // The active display routing key changes which window expands.
    model.$hostDisplayID
      .removeDuplicates()
      .sink { [weak self] id in
        self?.applyAll(
          state: self?.model.islandState ?? .collapsed,
          activeDisplayID: id,
          expandedContentHeight: self?.model.expandedContentHeight,
          animated: true)
      }
      .store(in: &cancellables)

    model.$isCollapsedIslandVisible
      .removeDuplicates()
      .sink { [weak self] _ in
        self?.updateAllVisibility(animated: true)
      }
      .store(in: &cancellables)

    model.$expandedContentHeight
      .removeDuplicates()
      .sink { [weak self] height in
        self?.applyAll(
          state: self?.model.islandState ?? .collapsed,
          activeDisplayID: self?.model.hostDisplayID,
          expandedContentHeight: height,
          animated: true)
      }
      .store(in: &cancellables)

    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.finishWakeImmediately()
        self.syncWindows()
        self.applyAll(
          state: self.model.islandState,
          activeDisplayID: self.model.hostDisplayID,
          expandedContentHeight: self.model.expandedContentHeight,
          animated: false)
      }
    }

    applicationDeactivationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: NSApp,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard
          self?.model.islandState == .pinned,
          self?.model.isRequestingAccess == false,
          self?.model.isKeepAwakeControlsPresented == false,
          self?.model.isExtensionStorePresented == false,
          // An approval-held panel outlives focus fights: the request
          // lands while the user is in another app, and the key-window
          // steal-and-return would otherwise collapse it instantly.
          self?.model.isHeldForApproval != true,
          self?.wakePanel == nil
        else { return }
        self?.model.collapseIsland()
      }
    }

    model.$isKeepAwakeInputExpanded.removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] editing in
        guard let self else { return }
        for window in self.windows.values {
          window.transition.statusHeader?.setKeepAwakeEditing(editing)
        }
      }.store(in: &cancellables)

    model.$extensionPreferences.removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] preferences in
        guard let self else { return }
        for window in self.windows.values {
          window.transition.statusHeader?.setEnabledItems(preferences.statusItems)
          window.transition.statusHeader?.setHeaderOrder(preferences.orderedHeaderItems)
        }
      }.store(in: &cancellables)

    model.weatherStore.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        guard let self else { return }
        for window in self.windows.values {
          window.transition.statusHeader?.refreshWeatherLayout()
        }
      }.store(in: &cancellables)

    model.objectWillChange
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in
        guard let self else { return }
        for window in self.windows.values {
          window.transition.statusHeader?.setStoreAvailable(self.model.canUseActiveList)
        }
      }.store(in: &cancellables)

    // The pointer poll exists for one job now: auto-hide activation zones
    // on every display's settled bar. Hover on a visible bar arrives via
    // the surface's own .onHover.
    pointerDisplayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.refreshActivationZoneHover()
      }
    }

    fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateAllVisibility(animated: false) }
    }
    installWakeShortcut()
  }

  isolated deinit {
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    if let applicationDeactivationObserver {
      NotificationCenter.default.removeObserver(applicationDeactivationObserver)
    }
    pointerDisplayTimer?.invalidate()
    fullScreenTimer?.invalidate()
    wakeTimer?.invalidate()
    for observer in wakeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    wakePanel?.close()
    for window in windows.values {
      window.panel.delegate = nil
      window.panel.close()
    }
  }

  // MARK: Window lifecycle

  /// Mirrors NSScreen.screens: creates a window per new display, closes
  /// the windows of displays that went away, and keeps the active display
  /// naming a live window (pointer ?? main ?? first as the fallback).
  private func syncWindows() {
    let screens = NSScreen.screens
    let live = Set(screens.compactMap(\.todoIslandDisplayID))

    let removed = windows.keys.filter { !live.contains($0) }
    for id in removed {
      let window = windows.removeValue(forKey: id)
      window?.panel.delegate = nil
      window?.panel.close()
    }

    for screen in screens {
      guard let id = screen.todoIslandDisplayID, windows[id] == nil else { continue }
      let panel = IslandPanel()
      panel.delegate = self
      let hostingView = NSHostingView(
        rootView: AnyView(
          IslandRootView(displayID: id, usesCompositorTransitions: true)
            .environmentObject(model)
            .environmentObject(agentStore))
      )
      hostingView.wantsLayer = true
      // Content is laid out at its destination once; the wrapper owns the
      // temporary compositor animation and window envelope.
      hostingView.sizingOptions = []
      hostingView.layer?.backgroundColor = NSColor.clear.cgColor
      var dragTargets: [HeaderDragTarget] = []
      func dragTarget(_ id: String) -> HeaderDragTarget {
        let target = HeaderDragTarget(id: id)
        dragTargets.append(target)
        return target
      }
      func statusItem(_ item: IslandStatusItem) -> NSView {
        let host = NSHostingView(rootView: IslandStatusItemView(item: item, displayID: id)
          .modifier(HeaderDragModifier(target: dragTarget(item.rawValue), displayID: id))
          .environmentObject(model).environmentObject(agentStore))
        host.sizingOptions = item == .weather ? [.intrinsicContentSize] : []
        return host
      }
      let header = IslandStatusHeader(quota: statusItem(.quota), bot: statusItem(.bot),
        additionalQuotas: statusItem(.additionalQuotas),
        weather: statusItem(.weather), keepAwake: statusItem(.keepAwake),
        store: NSHostingView(rootView: ExtensionStoreButton(displayID: id)
          .modifier(HeaderDragModifier(target: dragTarget("store"), displayID: id))
          .environmentObject(model)),
        barHeight: DisplayGeometryCalculator.statusHeaderHeight(for: DisplaySupport.metrics(for: screen)))
      let transition = IslandTransitionView(content: hostingView, statusHeader: header)
      header.setStoreAvailable(model.canUseActiveList)
      header.setEnabledItems(model.extensionPreferences.statusItems, animated: false)
      header.setHeaderOrder(model.extensionPreferences.orderedHeaderItems, animated: false)
      header.onOrderChanged = { [weak model] order in
        model?.extensionPreferences.setHeaderOrder(order)
      }
      for target in dragTargets { target.header = header }
      panel.contentView = transition
      let initiallyVisible = model.islandState != .collapsed || model.isCollapsedIslandVisible
      panel.alphaValue = initiallyVisible ? 1 : 0
      panel.ignoresMouseEvents = !initiallyVisible
      windows[id] = DisplayWindow(panel: panel, transition: transition)
    }

    guard !live.isEmpty else { return }
    if let activeID = model.hostDisplayID, windows[activeID] != nil { return }
    let fallback =
      DisplaySupport.screenContainingPointer()?.todoIslandDisplayID
      ?? NSScreen.main?.todoIslandDisplayID
      ?? screens.first?.todoIslandDisplayID
    if let fallback {
      model.setHostDisplayID(fallback)
    }
  }

  // MARK: State routing

  /// Routes the global state to every window: non-active windows first,
  /// then the active one (so the test mirrors describe the expanded
  /// surface deterministically), then the single key-window handoff.
  /// Companion to the store's routing log — pane/window lifecycle lines so
  /// expansion timing is answerable from the same file.
  nonisolated private static func logLifecycle(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let path = "/tmp/doisland-agents-activity.log"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      handle.closeFile()
    } else {
      FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
  }

  private func applyAll(
    state: IslandPresentationState,
    activeDisplayID: String?,
    expandedContentHeight: CGFloat?,
    animated: Bool
  ) {
    // The wake surface temporarily owns presentation, never the selected page
    // or draft. Apply the latest model state when it gives the surface back.
    guard wakePanel == nil else { return }
    let activeID = activeDisplayID
    for id in windows.keys where id != activeID {
      applyWindow(
        IslandRouting.effectiveState(
          global: state, activeDisplayID: activeID, windowDisplayID: id),
        on: id,
        expandedContentHeight: expandedContentHeight,
        animated: animated)
    }

    if let activeID, windows[activeID] != nil {
      let activeState = IslandRouting.effectiveState(
        global: state, activeDisplayID: activeID, windowDisplayID: activeID)
      appliedState = activeState
      appliedExpandedContentHeight = expandedContentHeight
      applyWindow(
        activeState, on: activeID, expandedContentHeight: expandedContentHeight,
        animated: animated)
    } else {
      appliedState = .collapsed
      appliedExpandedContentHeight = expandedContentHeight
    }

    // Exactly one window ever owns key status. Entering pin activates the
    // app and makes the active panel key; leaving pin resigns whichever
    // island panel holds key (at most one) once, globally.
    if state == .pinned, let activeID, let window = windows[activeID] {
      Self.logLifecycle("expand begin (active=\(activeID))")
      NSApp.activate(ignoringOtherApps: true)
      window.panel.makeKeyAndOrderFront(nil)
    } else if state != .pinned {
      for window in windows.values where window.panel.isKeyWindow {
        window.panel.resignKey()
        NSApp.deactivate()
      }
    }
  }

  private func applyWindow(
    _ state: IslandPresentationState,
    on id: String,
    expandedContentHeight: CGFloat?,
    animated: Bool
  ) {
    guard let window = windows[id] else { return }
    let panel = window.panel
    guard let metrics = DisplaySupport.cachedMetrics(for: id) else {
      panel.orderOut(nil)
      return
    }

    let geometry = DisplayGeometryCalculator.geometry(
      for: metrics, expandedContentHeight: expandedContentHeight)
    let frame = NSRect(
      origin: geometry.origin(for: state, in: metrics), size: geometry.size(for: state))

    panel.acceptsKeyInput = state == .pinned
    window.transition.statusHeader?.barHeight = DisplayGeometryCalculator.statusHeaderHeight(for: metrics)
    window.transition.transition(
      to: frame, state: state,
      collapsedRadius: metrics.hasPhysicalNotch ? 14 : 18,
      animated: animated && !reduceMotion(),
      deferUntilNextRunLoop: animated)

    if state != .pinned {
      panel.orderFrontRegardless()
    }
    updateVisibility(
      of: window, state: state, displayID: id, expandedContentHeight: expandedContentHeight,
      animated: animated)
  }

  // MARK: Visibility

  func show() {
    syncWindows()
    applyAll(
      state: model.islandState,
      activeDisplayID: model.hostDisplayID,
      expandedContentHeight: model.expandedContentHeight,
      animated: false)
  }

  /// Status-menu entry point: pin the island on the display the pointer is
  /// on (main display as the fallback), as if it had been hovered there.
  func pinAndShow() {
    if let id =
      DisplaySupport.screenContainingPointer()?.todoIslandDisplayID
      ?? NSScreen.main?.todoIslandDisplayID
    {
      model.setHostDisplayID(id)
    }
    model.pinIsland()
    NSApp.activate(ignoringOtherApps: true)
    if let activeID = model.hostDisplayID {
      windows[activeID]?.panel.makeKeyAndOrderFront(nil)
    }
  }

  private func updateAllVisibility(animated: Bool) {
    // Visibility polls must never reapply geometry: a nonanimated request
    // cancels an in-flight spring, even when its destination is unchanged.
    // State/height/display subscriptions own geometry; the collapsed-frame
    // watchdog below still repairs displaced, settled windows.
    for (id, window) in windows {
      updateVisibility(
        of: window,
        state: IslandRouting.effectiveState(
          global: model.islandState,
          activeDisplayID: model.hostDisplayID,
          windowDisplayID: id),
        displayID: id,
        expandedContentHeight: model.expandedContentHeight,
        animated: animated)
    }
  }

  private func updateVisibility(
    of window: DisplayWindow,
    state: IslandPresentationState,
    displayID: String,
    expandedContentHeight: CGFloat?,
    animated: Bool
  ) {
    guard displayID != wakeDisplayID else { return }
    let panel = window.panel
    guard let screen = DisplaySupport.screen(id: displayID) else {
      panel.orderOut(nil)
      return
    }

    if state != .pinned && DisplaySupport.shouldHideFallbackInFullScreen(screen) {
      panel.orderOut(nil)
      return
    }

    // Watchdog: a collapsed island must sit exactly on the bar frame. If a
    // transition was interrupted mid-flight by fast hover in/out, snap it back
    // instead of leaving a stale wide surface on screen.
    if state == .collapsed, !window.transition.isRunning {
      let metrics = DisplaySupport.metrics(for: screen)
      let geometry = DisplayGeometryCalculator.geometry(
        for: metrics,
        expandedContentHeight: expandedContentHeight
      )
      let frame = NSRect(
        origin: geometry.origin(for: .collapsed, in: metrics),
        size: geometry.collapsedSize
      )
      if abs(panel.frame.width - frame.width) > 1
        || abs(panel.frame.height - frame.height) > 1
        || abs(panel.frame.midX - frame.midX) > 1
      {
        window.transition.transition(
          to: frame, state: .collapsed,
          collapsedRadius: metrics.hasPhysicalNotch ? 14 : 18, animated: false)
      }
    }

    // Pinned ordering is coordinated once in applyAll's key handoff.
    if !panel.isVisible, state != .pinned {
      panel.orderFrontRegardless()
    }

    applySurfaceVisibility(
      displayID,
      visible: shouldShowSurface(state: state),
      animated: animated && state == .collapsed
    )
  }

  private func shouldShowSurface(state: IslandPresentationState) -> Bool {
    state != .collapsed
      || model.isCollapsedIslandVisible
      || NSWorkspace.shared.isVoiceOverEnabled
  }

  private func applySurfaceVisibility(_ id: String, visible: Bool, animated: Bool) {
    guard let window = windows[id] else { return }
    let panel = window.panel
    windows[id]?.visibilityGeneration += 1
    let generation = (windows[id]?.visibilityGeneration ?? 0)
    if id == model.hostDisplayID {
      isCollapsedSurfaceVisible = visible
      isActivationZoneActive = !visible && model.islandState == .collapsed
    }
    panel.ignoresMouseEvents = !visible

    let targetAlpha: CGFloat = visible ? 1 : 0
    guard abs(panel.alphaValue - targetAlpha) > 0.001 else {
      panel.alphaValue = targetAlpha
      return
    }

    guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      panel.alphaValue = targetAlpha
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(
        name: visible ? .easeOut : .easeIn
      )
      panel.animator().alphaValue = targetAlpha
    } completionHandler: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        guard self.windows[id]?.visibilityGeneration == generation else { return }
        panel.alphaValue = targetAlpha
      }
    }
  }

  // MARK: Activation zones (auto-hide)

  /// Auto-hide wake zones live on every display's settled bar: whichever
  /// bar contains the pointer wakes the island there.
  private func refreshActivationZoneHover() {
    guard
      wakePanel == nil,
      model.islandState == .collapsed,
      model.usesAutoHiddenCollapsedIsland,
      !NSWorkspace.shared.isVoiceOverEnabled
    else { return }

    let pointer = NSEvent.mouseLocation
    for (id, window) in windows where window.panel.isVisible {
      guard let screen = DisplaySupport.screen(id: id) else { continue }
      // The window may be mid-flight — much larger than the bar while the
      // collapse transition settles. Gate the activation zone on the settled bar
      // frame, never the animating one.
      let metrics = DisplaySupport.metrics(for: screen)
      let geometry = DisplayGeometryCalculator.geometry(
        for: metrics,
        expandedContentHeight: model.expandedContentHeight
      )
      let settledBarFrame = CGRect(
        origin: geometry.origin(for: .collapsed, in: metrics),
        size: geometry.collapsedSize
      )
      guard settledBarFrame.contains(pointer) else { continue }
      // The full-screen window scan is expensive; run it only when the
      // pointer actually sits in the activation zone.
      guard !DisplaySupport.shouldHideFallbackInFullScreen(screen) else { continue }
      model.setIslandHovered(true, on: id)
      return
    }
    model.setIslandHovered(false)
  }

  // MARK: NSWindowDelegate

  // MARK: AI wake presentation

  private func installWakeShortcut() {
    let shortcut = AIWakeShortcut()
    shortcut.onPress = { [weak self] in self?.wakeKeyPressed() }
    shortcut.onRelease = { [weak self] in self?.wakeKeyReleased() }
    shortcut.onCancel = { [weak self] in self?.dismissWake() }
    wakeShortcut = shortcut
    Self.logLifecycle("wake shortcut registered=\(shortcut.isRegistered) accessibility=\(shortcut.hasGlobalPermission)")
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                 NSWorkspace.sessionDidResignActiveNotification] {
      wakeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.finishWakeImmediately() }
      })
    }
  }

  func refreshWakeShortcut() {
    guard let shortcut = wakeShortcut else { return }
    shortcut.retryGlobalRegistration()
    Self.logLifecycle("wake shortcut registered=\(shortcut.isRegistered) accessibility=\(shortcut.hasGlobalPermission)")
  }
  func enableGlobalWakeShortcut() { wakeShortcut?.requestGlobalAccess() }

  /// A discoverable preview is also available without keyboard permissions.
  func previewAIWake() {
    guard wakePanel == nil else { dismissWake(); return }
    wakeKeyPressed()
    let token = wakeGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + AIWakeGesture.holdDuration + 0.02) { [weak self] in
      guard let self, self.wakeGeneration == token else { return }
      self.wakeKeyReleased()
    }
  }

  private func wakeKeyPressed() {
    guard !(wakePanel != nil && wakeGesture.phase == .idle) else { return }
    wakeGesture.press(at: CACurrentMediaTime())
    if wakeGesture.phase == .idle { dismissWake(); return }
    guard wakePanel == nil else { return }
    guard let id = DisplaySupport.screenContainingPointer()?.todoIslandDisplayID ?? model.hostDisplayID,
      let display = windows[id], let screen = DisplaySupport.screen(id: id),
      !DisplaySupport.shouldHideFallbackInFullScreen(screen) else {
      wakeGesture.reset()
      return
    }
    wakeGeneration += 1
    let token = wakeGeneration
    let surface = display.transition.presentedSurfaceBounds ?? display.transition.bounds
    let sourceFrame = display.panel.convertToScreen(display.transition.convert(surface, to: nil))
    let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let view = BlackHoleWakeView(size: surface.size,
      radius: surface.height > 60 ? 36 : (screen.safeAreaInsets.top > 0 ? 14 : 18),
      reduceMotion: reduced, effect: model.extensionPreferences.wakeEffect)
    let panel = IslandPanel()
    panel.title = L10n.text("wake.title")
    panel.acceptsKeyInput = true
    panel.level = .mainMenu + 4
    panel.ignoresMouseEvents = true
    // NSWindow resizes a newly assigned contentView to its current frame.
    // Establish the envelope first; assigning it to a zero-sized panel would
    // erase the view's geometry before the frame below could read it.
    panel.setFrame(CGRect(x: sourceFrame.midX - view.bounds.width / 2,
      y: sourceFrame.maxY - view.bounds.height, width: view.bounds.width, height: view.bounds.height),
      display: false)
    panel.contentView = view
    panel.alphaValue = 0
    wakeDisplayID = id
    wakePanel = panel
    wakeView = view
    // Invalidate a pending visibility completion before hiding the source.
    windows[id]?.visibilityGeneration += 1
    display.panel.ignoresMouseEvents = true
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduced ? 0.1 : 0.2
      panel.animator().alphaValue = 1
      display.panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      Task { @MainActor in
        guard self?.wakeGeneration == token else { return }
        display.panel.orderOut(nil)
      }
    }
    view.begin()
    wakeShortcut?.captureEscape(true)
    Self.logLifecycle("wake charging display=\(id) width=\(surface.width)")
    wakeTimer = Timer.scheduledTimer(withTimeInterval: AIWakeGesture.holdDuration, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.wakeGeneration == token else { return }
        self.wakeGesture.advance(to: CACurrentMediaTime())
        if self.wakeGesture.phase == .awake {
          self.activateWakeVoice()
          self.wakePanel?.makeKeyAndOrderFront(nil)
          Self.logLifecycle("wake awake")
        }
      }
    }
  }

  private func wakeKeyReleased() {
    wakeTimer?.invalidate()
    wakeTimer = nil
    wakeGesture.release(at: CACurrentMediaTime())
    if wakeGesture.phase == .idle { dismissWake() }
    else if wakeGesture.phase == .awake {
      activateWakeVoice()
      wakePanel?.makeKeyAndOrderFront(nil)
    }
  }

  private func activateWakeVoice() {
    guard let view = wakeView, !view.isAwake else { return }
    view.awaken()
    let voiceSession = VoiceProviderRegistry.provider(id: model.extensionPreferences.voiceProviderID).makeSession()
    self.voiceSession = voiceSession
    voiceSession.onState = { [weak view] in view?.setVoiceState($0) }
    voiceSession.onLevel = { [weak view] in view?.setVoiceLevel(input: $0, output: $1) }
    voiceSession.onError = { [weak view] in view?.setVoiceError($0) }
    voiceSession.start()
  }

  func stopVoice() { voiceSession?.stop() }

  private func dismissWake() {
    voiceSession?.stop()
    wakeGesture.cancel()
    wakeTimer?.invalidate()
    wakeTimer = nil
    guard let panel = wakePanel else { return }
    wakeGeneration += 1
    let token = wakeGeneration
    wakeView?.dismiss()
    // Keep the source covered until the black core has nearly returned to
    // its starting width. Status contents then reappear without a size jump.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self, self.wakeGeneration == token else { return }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        panel.animator().alphaValue = 0
        if let id = self.wakeDisplayID, let source = self.windows[id] {
          let state = IslandRouting.effectiveState(global: self.model.islandState,
            activeDisplayID: self.model.hostDisplayID, windowDisplayID: id)
          source.panel.animator().alphaValue = self.shouldShowSurface(state: state) ? 1 : 0
          source.panel.orderFrontRegardless()
        }
      } completionHandler: { [weak self] in
        Task { @MainActor in
          guard let self, self.wakeGeneration == token else { return }
          self.finishWakeImmediately(resetInput: false)
        }
      }
    }
  }

  private func finishWakeImmediately(resetInput: Bool = true) {
    voiceSession?.stop()
    wakeGeneration += 1
    wakeTimer?.invalidate()
    wakeTimer = nil
    if resetInput {
      wakeGesture.reset()
      wakeShortcut?.resetHeldKey()
    } else { wakeGesture.cancel() }
    wakeShortcut?.captureEscape(false)
    guard let panel = wakePanel else { return }
    panel.orderOut(nil)
    panel.close()
    wakePanel = nil
    wakeView = nil
    wakeDisplayID = nil
    applyAll(state: model.islandState, activeDisplayID: model.hostDisplayID,
      expandedContentHeight: model.expandedContentHeight, animated: false)
    Self.logLifecycle("wake restored")
  }

  func windowDidResignKey(_ notification: Notification) {
    // SwiftUI menus temporarily take key status from the panel. The pinned Island
    // closes when the application deactivates, not during an in-app menu handoff.
  }

  func windowDidBecomeKey(_ notification: Notification) {
    // A click on the hover preview pins the Island mid-mouse-down, while key
    // status is still in flight; the caret lands only once the panel is key.
    // Hopped to a Task because becoming key can happen synchronously inside
    // makeKeyAndOrderFront, before the model's islandState assignment (which
    // triggered it) has finished writing .pinned.
    Task { @MainActor in model.notePanelDidBecomeKey() }
  }
}
