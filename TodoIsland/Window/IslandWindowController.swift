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
  /// The per-display island: its panel, its content, and its own spring.
  @MainActor private struct DisplayWindow {
    let panel: IslandPanel
    let spring = IslandFrameSpring()
    var visibilityGeneration = 0
  }

  private let model: AppModel
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

  init(model: AppModel) {
    self.model = model
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
          self?.model.isRequestingAccess == false
        else { return }
        self?.model.collapseIsland()
      }
    }

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
  }

  isolated deinit {
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    if let applicationDeactivationObserver {
      NotificationCenter.default.removeObserver(applicationDeactivationObserver)
    }
    pointerDisplayTimer?.invalidate()
    fullScreenTimer?.invalidate()
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
        rootView: AnyView(IslandRootView(displayID: id).environmentObject(model))
      )
      hostingView.wantsLayer = true
      // The panel frame is driven per-frame by the spring; skipping intrinsic
      // size syncing keeps each resize pass cheap.
      hostingView.sizingOptions = []
      hostingView.layer?.backgroundColor = NSColor.clear.cgColor
      panel.contentView = hostingView
      let initiallyVisible = model.islandState != .collapsed || model.isCollapsedIslandVisible
      panel.alphaValue = initiallyVisible ? 1 : 0
      panel.ignoresMouseEvents = !initiallyVisible
      windows[id] = DisplayWindow(panel: panel)
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
  private func applyAll(
    state: IslandPresentationState,
    activeDisplayID: String?,
    expandedContentHeight: CGFloat?,
    animated: Bool
  ) {
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
    if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let motion = state.motionProfile
      window.spring.animate(
        on: panel,
        from: panel.frame,
        to: frame,
        response: motion.response,
        dampingFraction: motion.dampingFraction
      ) { [panel] interpolated in
        // Coalesce drawing into the normal vsync update instead of forcing a
        // synchronous display inside the display-link tick.
        panel.setFrame(interpolated, display: false)
      }
    } else {
      window.spring.settle(at: frame)
      panel.setFrame(frame, display: true)
    }

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
    for id in windows.keys {
      applyWindow(
        IslandRouting.effectiveState(
          global: model.islandState,
          activeDisplayID: model.hostDisplayID,
          windowDisplayID: id),
        on: id,
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
    // spring was interrupted mid-flight by fast hover in/out, snap it back
    // instead of leaving a stale wide surface on screen.
    if state == .collapsed, !window.spring.isRunning {
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
        window.spring.settle(at: frame)
        panel.setFrame(frame, display: true)
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
      model.islandState == .collapsed,
      model.usesAutoHiddenCollapsedIsland,
      !NSWorkspace.shared.isVoiceOverEnabled
    else { return }

    let pointer = NSEvent.mouseLocation
    for (id, window) in windows where window.panel.isVisible {
      guard let screen = DisplaySupport.screen(id: id) else { continue }
      // The window may be mid-flight — much larger than the bar while the
      // collapse spring settles. Gate the activation zone on the settled bar
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
