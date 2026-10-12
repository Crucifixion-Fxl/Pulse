import AppKit
import CoreGraphics

enum HostDisplayChangeReason: Equatable, Sendable {
  case initial
  case pointerDwell
  case disconnected
}

struct HostDisplayChange: Equatable, Sendable {
  let displayID: String?
  let reason: HostDisplayChangeReason
}

struct HostDisplayTracker: Equatable, Sendable {
  private(set) var hostDisplayID: String?
  private var candidateDisplayID: String?
  private var candidateSince: TimeInterval?
  let dwellInterval: TimeInterval

  init(hostDisplayID: String? = nil, dwellInterval: TimeInterval = 0.35) {
    self.hostDisplayID = hostDisplayID
    self.dwellInterval = dwellInterval
  }

  mutating func observe(
    pointerDisplayID: String?,
    fallbackDisplayID: String?,
    availableDisplayIDs: Set<String>,
    locksHostDisplay: Bool,
    now: TimeInterval
  ) -> HostDisplayChange? {
    let pointerDisplayID = pointerDisplayID.flatMap {
      availableDisplayIDs.contains($0) ? $0 : nil
    }
    let fallbackDisplayID = fallbackDisplayID.flatMap {
      availableDisplayIDs.contains($0) ? $0 : nil
    }

    guard !availableDisplayIDs.isEmpty else {
      resetCandidate()
      guard hostDisplayID != nil else { return nil }
      hostDisplayID = nil
      return HostDisplayChange(displayID: nil, reason: .disconnected)
    }

    guard let hostDisplayID else {
      let destination = pointerDisplayID ?? fallbackDisplayID ?? availableDisplayIDs.sorted().first
      self.hostDisplayID = destination
      resetCandidate()
      return HostDisplayChange(displayID: destination, reason: .initial)
    }

    guard availableDisplayIDs.contains(hostDisplayID) else {
      let destination = pointerDisplayID ?? fallbackDisplayID ?? availableDisplayIDs.sorted().first
      self.hostDisplayID = destination
      resetCandidate()
      return HostDisplayChange(displayID: destination, reason: .disconnected)
    }

    guard !locksHostDisplay else {
      resetCandidate()
      return nil
    }

    guard let pointerDisplayID, pointerDisplayID != hostDisplayID else {
      resetCandidate()
      return nil
    }

    if candidateDisplayID != pointerDisplayID {
      candidateDisplayID = pointerDisplayID
      candidateSince = now
      return nil
    }

    guard let candidateSince, now - candidateSince >= dwellInterval else { return nil }
    self.hostDisplayID = pointerDisplayID
    resetCandidate()
    return HostDisplayChange(displayID: pointerDisplayID, reason: .pointerDwell)
  }

  private mutating func resetCandidate() {
    candidateDisplayID = nil
    candidateSince = nil
  }
}

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
