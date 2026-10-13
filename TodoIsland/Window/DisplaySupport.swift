import AppKit
import CoreGraphics

@MainActor
enum DisplaySupport {
  static func screenContainingPointer() -> NSScreen? {
    let pointerLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(pointerLocation) }
  }

  static func fallbackScreen() -> NSScreen? {
    screenContainingPointer() ?? NSScreen.main ?? NSScreen.screens.first
  }

  static func availableDisplayIDs() -> Set<String> {
    Set(NSScreen.screens.compactMap(\.todoIslandDisplayID))
  }

  static func screen(id: String?) -> NSScreen? {
    if let id, let exact = NSScreen.screens.first(where: { $0.todoIslandDisplayID == id }) {
      return exact
    }
    return id == nil ? fallbackScreen() : nil
  }

  /// Screen metrics for a display id, cached until screen parameters
  /// change (same invalidation as the UUID cache). Body evals and the
  /// window-controller tick queried the host screen several times each;
  /// these are now dictionary hits. A nil id stays live — the fallback
  /// screen depends on pointer and focus, which must not be cached.
  static func cachedMetrics(for id: String?) -> DisplayMetrics? {
    guard let id else { return screen(id: nil).map(metrics) }
    if let cached = DisplayIDCache.metricsByID[id] { return cached }
    guard let screen = screen(id: id) else { return nil }
    let value = metrics(for: screen)
    DisplayIDCache.metricsByID[id] = value
    return value
  }

  static func metrics(for screen: NSScreen) -> DisplayMetrics {
    DisplayMetrics(
      frame: screen.frame,
      visibleFrame: screen.visibleFrame,
      safeAreaTop: screen.safeAreaInsets.top,
      auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
      auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width
    )
  }

  static func shouldHideFallbackInFullScreen(_ screen: NSScreen) -> Bool {
    guard screen.safeAreaInsets.top <= 0 else { return false }
    return FullScreenVerdictCache.verdict(for: screen) {
      scanForFullScreenCover(screen)
    }
  }

  private static func scanForFullScreenCover(_ screen: NSScreen) -> Bool {
    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
    guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber else {
      return false
    }
    let targetDisplayID = CGDirectDisplayID(screenNumber.uint32Value)
    let regularApplicationPIDs = Set(
      NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isTerminated }
        .map(\.processIdentifier))
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[CFString: Any]]
    else { return false }

    return windows.contains { window in
      guard let boundsValue = window[kCGWindowBounds] else { return false }
      let boundsDictionary = boundsValue as! CFDictionary
      guard
        let ownerPID = window[kCGWindowOwnerPID] as? pid_t,
        regularApplicationPIDs.contains(ownerPID),
        let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
        let displayID = displayContaining(bounds: bounds)
      else { return false }

      return displayID == targetDisplayID
        && abs(bounds.width - screen.frame.width) <= 2
        && abs(bounds.height - screen.frame.height) <= 2
    }
  }

  private static func displayContaining(bounds: CGRect) -> CGDirectDisplayID? {
    var displayID: CGDirectDisplayID = 0
    var count: UInt32 = 0
    let result = CGGetDisplaysWithRect(bounds, 1, &displayID, &count)
    return result == .success && count > 0 ? displayID : nil
  }
}

extension NSScreen {
  /// Every caller lives on the main actor (screen enumeration from UI code
  /// and timers); the explicit annotation keeps the UUID cache lock-free.
  @MainActor
  var todoIslandDisplayID: String? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    guard let number = deviceDescription[key] as? NSNumber else { return nil }
    return DisplayIDCache.uuidString(for: CGDirectDisplayID(number.uint32Value))
  }
}

/// Fullscreen-hide verdicts keyed by everything the scan can report on:
/// the frontmost app, the active space (generation), and the display. The
/// 1s watchdog and the 20Hz auto-hide activation-zone path both called
/// shouldHideFallbackInFullScreen, each running NSWorkspace enumeration +
/// a full CGWindowListCopyWindowInfo scan. Entering or leaving fullscreen
/// always switches the active space, and the heuristic itself targets the
/// frontmost app — so key changes cover every verdict the scan can flip,
/// and the steady state is a dictionary hit.
@MainActor
enum FullScreenVerdictCache {
  private struct Key: Hashable {
    let frontmost: String?
    let displayID: CGDirectDisplayID
    let generation: Int
  }

  private static var generation = 0
  private static var cached: [Key: Bool] = [:]
  private static var observes = false

  static func verdict(for screen: NSScreen, compute: () -> Bool) -> Bool {
    installObserversIfNeeded()
    let key = Key(
      frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      displayID: displayNumberOf(screen),
      generation: generation)
    if let cached = cached[key] { return cached }
    let value = compute()
    cached[key] = value
    return value
  }

  static func invalidate() {
    generation += 1
    cached.removeAll()
  }

  private static func displayNumberOf(_ screen: NSScreen) -> CGDirectDisplayID {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    guard let number = screen.deviceDescription[key] as? NSNumber else { return 0 }
    return CGDirectDisplayID(number.uint32Value)
  }

  private static func installObserversIfNeeded() {
    guard !observes else { return }
    observes = true
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { invalidate() }
    }
    for name in [
      NSWorkspace.activeSpaceDidChangeNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: name, object: nil, queue: .main
      ) { _ in
        MainActor.assumeIsolated { invalidate() }
      }
    }
  }
}

/// CGDirectDisplayID → UUID string, cached for the process lifetime: a
/// display's UUID is stable while it stays connected, and the cache is
/// invalidated on screen-parameter changes (unplug/replug/reconfigure).
/// The 50 ms pointer poll resolves every screen's UUID each tick, which
/// made CGDisplayCreateUUIDFromDisplayID + CFUUIDCreateString the hottest
/// calls in the idle profile. NSScreen is MainActor-isolated, so is this.
@MainActor
enum DisplayIDCache {
  private static var map: [CGDirectDisplayID: String] = [:]
  /// DisplayMetrics keyed by display UUID, invalidated together with the
  /// UUID map (any parameter change can move frames or the notch).
  static var metricsByID: [String: DisplayMetrics] = [:]
  private static var observesScreenChanges = false

  static func uuidString(for id: CGDirectDisplayID) -> String? {
    if let cached = map[id] { return cached }
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
    let string = CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    map[id] = string
    installInvalidationObserver()
    return string
  }

  static func invalidate() {
    map.removeAll()
    metricsByID.removeAll()
  }

  private static func installInvalidationObserver() {
    guard !observesScreenChanges else { return }
    observesScreenChanges = true
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        invalidate()
      }
    }
  }
}
