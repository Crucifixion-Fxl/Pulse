import Foundation

/// A visual invocation, deliberately independent of agent sessions and microphone capture.
struct AIWakeGesture {
  enum Phase: Equatable { case idle, charging, awake }
  static let holdDuration: TimeInterval = 0.7
  private(set) var phase: Phase = .idle
  private(set) var isHeld = false
  private var pressedAt: TimeInterval = 0

  mutating func press(at time: TimeInterval) {
    guard !isHeld else { return }
    isHeld = true
    if phase == .awake {
      phase = .idle
    } else {
      pressedAt = time
      phase = .charging
    }
  }

  mutating func advance(to time: TimeInterval) {
    if isHeld, phase == .charging, time - pressedAt >= Self.holdDuration {
      phase = .awake
    }
  }

  mutating func release(at time: TimeInterval) {
    advance(to: time)
    isHeld = false
    if phase == .charging { phase = .idle }
  }

  mutating func cancel() {
    phase = .idle
    // Keep the held latch until key-up: repeats cannot reopen a cancelled invocation.
  }

  mutating func reset() {
    phase = .idle
    isHeld = false
  }
}
