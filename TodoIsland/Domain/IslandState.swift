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

  // The reference surface expands with a single elastic wobble before
  // settling, and closes without overshoot.
  static let opening = IslandMotionProfile(response: 0.5, dampingFraction: 0.68)
  static let pinning = IslandMotionProfile(response: 0.44, dampingFraction: 0.75)
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
