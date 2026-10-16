import Foundation

enum CollapsedBotState: String, CaseIterable, Sendable {
  case idle, sleeping, waking, listening, thinking, searching, working

  /// Model identity wins over the client: Claude Code can run GLM.
  static func vendor(for session: AgentSessionSnapshot) -> AIUsageVendor? {
    let model = session.model?.lowercased() ?? ""
    if model.contains("glm") { return .zhipuGLM }
    if model.contains("claude") { return .anthropic }
    if model.contains("gpt") || model.contains("codex") { return .openAI }
    if session.isCodex { return .openAI }
    if session.isClaude { return .anthropic }
    return nil
  }

  /// Prefer the latest active session, rather than an arbitrary dictionary
  /// entry. Waiting requests keep their separate, higher-priority red alert.
  static func activity(in sessions: [String: AgentSessionSnapshot]) -> Self {
    let active = sessions.filter { $0.value.status == .running || $0.value.status == .processing }
      .sorted {
        if $0.value.lastActivity == $1.value.lastActivity { return $0.key < $1.key }
        return $0.value.lastActivity > $1.value.lastActivity
      }.first?.value
    guard let active else { return .idle }
    guard active.status == .running else { return .thinking }
    let tool = active.currentTool?.lowercased() ?? ""
    if ["search", "grep", "glob", "find", "web__run"].contains(where: tool.contains) {
      return .searching
    }
    return .working
  }
}

/// One clock for automatic sleep, the one-shot wake sequence and interrupted
/// pose transitions. It never changes the bot's layout frame or adds timers.
struct CollapsedBotAnimation {
  struct Context: Equatable {
    var activity: CollapsedBotState = .idle
    var isPlaying = false
    var isHovered = false
    var isAlert = false

    var requestedState: CollapsedBotState {
      if isAlert { return .idle }
      return isHovered ? .listening : activity
    }
  }

  static let sleepDelay: TimeInterval = 45
  static let wakeDuration: TimeInterval = 1.6
  static let transitionDuration: TimeInterval = 0.32

  private(set) var context: Context
  private var startedAt: TimeInterval
  private var wakeStartedAt: TimeInterval?
  private var transitionFrom: CollapsedBotFace.Expression?
  private var transitionAt: TimeInterval

  init(context: Context = Context(), at time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
    self.context = context
    startedAt = time
    transitionAt = time
  }

  mutating func update(_ next: Context, at time: TimeInterval) {
    guard next != context else { return }
    let previousState = state(at: time)
    let previousPose = expression(at: time)
    context = next
    startedAt = time
    if next.isAlert {
      wakeStartedAt = nil
    } else if previousState == .sleeping && next.requestedState != .sleeping {
      wakeStartedAt = time
    } else if previousState != .waking {
      wakeStartedAt = nil
    }
    transitionFrom = previousPose
    transitionAt = time
  }

  func state(at time: TimeInterval) -> CollapsedBotState {
    if let wakeStartedAt, time - wakeStartedAt < Self.wakeDuration { return .waking }
    if canSleep && time - startedAt >= Self.sleepDelay { return .sleeping }
    return context.requestedState
  }

  private var canSleep: Bool {
    context.requestedState == .idle && !context.isPlaying && !context.isAlert
  }

  func expression(at time: TimeInterval) -> CollapsedBotFace.Expression {
    let state = state(at: time)
    let elapsed = max(0, time - (wakeStartedAt ?? startedAt))
    func pose(_ state: CollapsedBotState) -> CollapsedBotFace.Expression {
      CollapsedBotFace.expression(at: time, inputs: .init(
        isPlaying: context.isPlaying, isHovered: false, state: state, stateElapsed: elapsed))
    }
    var target = pose(state)
    if state == .sleeping && canSleep {
      target = .blend(pose(.idle), target, progress: (time - startedAt - Self.sleepDelay) / 1.1)
    } else if state == .waking, wakeStartedAt != nil {
      target = .blend(target, pose(context.requestedState),
        progress: (elapsed - Self.wakeDuration + 0.35) / 0.35)
    }
    if let transitionFrom {
      return .blend(transitionFrom, target,
        progress: (time - transitionAt) / Self.transitionDuration)
    }
    return target
  }
}

extension CollapsedBotFace.Expression {
  static func blend(_ from: Self, _ to: Self, progress: Double) -> Self {
    let p = CGFloat(min(1, max(0, progress)))
    let eased = p * p * (3 - 2 * p)
    func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
    return Self(eyeOpen: mix(from.eyeOpen, to.eyeOpen), glanceX: mix(from.glanceX, to.glanceX),
      eyeTilt: mix(from.eyeTilt, to.eyeTilt), lookY: mix(from.lookY, to.lookY),
      faceScale: mix(from.faceScale, to.faceScale),
      faceOffsetYFraction: mix(from.faceOffsetYFraction, to.faceOffsetYFraction),
      angryTilt: mix(from.angryTilt, to.angryTilt),
      eyeWidthScale: mix(from.eyeWidthScale, to.eyeWidthScale),
      faceRotation: mix(from.faceRotation, to.faceRotation))
  }
}
