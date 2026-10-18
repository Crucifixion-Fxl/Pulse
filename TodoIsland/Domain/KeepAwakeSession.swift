import Foundation

struct KeepAwakeSession: Equatable, Sendable {
  let deadline: Date

  func remaining(at date: Date) -> TimeInterval { max(0, deadline.timeIntervalSince(date)) }

  func countdown(at date: Date) -> String {
    let seconds = Int(remaining(at: date).rounded(.up))
    if seconds >= 3600 {
      return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

enum KeepAwakePhase: Equatable, Sendable {
  case idle, authorizing, starting, active, stopping, recoveryRequired

  var isBusy: Bool { self == .authorizing || self == .starting || self == .stopping }
  var hasLease: Bool { self != .idle }
}
