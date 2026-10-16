import Foundation

enum CollapsedIslandVisibility: String, CaseIterable, Equatable, Identifiable, Sendable {
  case alwaysVisible = "always-visible"
  case autoHide = "auto-hide"

  var id: Self { self }
}

enum IslandPresentationState: Equatable, Sendable {
  case collapsed
  case preview
  case pinned

  var showsAuthorizationActions: Bool {
    self != .collapsed
  }

  var motionProfile: IslandMotionProfile {
    switch self {
    case .collapsed:
      .closing
    case .preview:
      .opening
    case .pinned:
      .pinning
    }
  }
}

struct IslandMotionProfile: Equatable, Sendable {
  let response: Double
  let dampingFraction: Double

  // Let the center-out expansion remain visible for roughly half a second,
  // then settle with only a small overshoot. Click and hover openings share
  // the same weight; pinning must not turn a direct click into a snap-open.
  static let opening = IslandMotionProfile(response: 0.78, dampingFraction: 0.82)
  static let pinning = opening
  static let closing = IslandMotionProfile(response: 0.24, dampingFraction: 1.0)
}

struct IslandStateMachine: Equatable, Sendable {
  private(set) var state: IslandPresentationState = .collapsed

  mutating func pointerEntered() {
    if state == .collapsed { state = .preview }
  }

  mutating func pointerExited() {
    if state == .preview { state = .collapsed }
  }

  mutating func click() {
    state = .pinned
  }

  mutating func dismiss() {
    state = .collapsed
  }
}

/// Multi-display routing: every screen carries its own island window, but
/// the app still expands exactly one island at a time. `activeDisplayID`
/// (AppModel.hostDisplayID) names it; every other window renders — and is
/// sized as — a collapsed bar regardless of the global state.
enum IslandRouting {
  /// The presentation state a window on `windowDisplayID` should render.
  ///
  /// - The global state collapsed → everything collapsed.
  /// - A legacy window without display identity always hosts the state
  ///   (single-window compatibility).
  /// - Identified windows host the expanded state only when the active
  ///   display matches; with no active display nobody expands (the
  ///   controller maintains a non-nil active display whenever a screen
  ///   exists, so this is a safe default rather than a steady state).
  static func effectiveState(
    global: IslandPresentationState,
    activeDisplayID: String?,
    windowDisplayID: String?
  ) -> IslandPresentationState {
    guard global != .collapsed else { return .collapsed }
    guard let windowDisplayID else { return global }
    guard let activeDisplayID else { return .collapsed }
    return windowDisplayID == activeDisplayID ? global : .collapsed
  }
}
