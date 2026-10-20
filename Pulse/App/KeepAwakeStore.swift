import Combine
import Foundation

@MainActor
final class KeepAwakeStore: ObservableObject {
  @Published private(set) var phase: KeepAwakePhase = .idle
  @Published private(set) var session: KeepAwakeSession?
  @Published private(set) var now = Date()
  @Published private(set) var messageKey: String?
  private let controller: any KeepAwakeControlling
  private let clock: () -> Date
  private var timer: Timer?
  private var stoppedForHeat = false

  init(controller: (any KeepAwakeControlling)? = nil, clock: @escaping () -> Date = Date.init) {
    self.controller = controller ?? KeepAwakeService()
    self.clock = clock
  }

  isolated deinit { timer?.invalidate() }

  var countdown: String { session?.countdown(at: now) ?? "00:00" }

  func observe() {
    guard timer == nil else { return }
    // A previous process's root job owns restoration after a crash/restart.
    if ["active", "armed", "starting", "restoring", "restore-failed"].contains(controller.status() ?? "") {
      phase = .recoveryRequired
      messageKey = "awake.recovering"
    }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
  }

  func start(minutes: Int) async {
    guard phase == .idle else { return }
    guard (1...1440).contains(minutes) else { messageKey = "awake.error.duration"; return }
    phase = .authorizing
    messageKey = nil
    stoppedForHeat = false
    do {
      let deadline = try await controller.begin(seconds: minutes * 60)
      session = KeepAwakeSession(deadline: deadline)
      now = clock()
      phase = .starting
      poll()
    } catch {
      session = nil
      if ["starting", "active", "restoring", "restore-failed"].contains(controller.status() ?? "") {
        phase = .recoveryRequired
        messageKey = "awake.recovering"
      } else {
        phase = .idle
        messageKey = (error as? KeepAwakeError).map {
          if case .authorization(let detail) = $0, detail.contains("-128") { return "awake.error.cancelled" }
          return "awake.error.authorization"
        } ?? "awake.error.unavailable"
      }
    }
  }

  func stop() {
    guard phase == .active || phase == .starting || phase == .recoveryRequired else { return }
    controller.requestStop()
    phase = .stopping
    messageKey = nil
  }

  func shutdown() { controller.requestStop(); timer?.invalidate(); timer = nil }

  func poll(thermalCritical: Bool? = nil) {
    guard phase != .idle, phase != .authorizing else { return }
    now = clock()
    let overheated = thermalCritical ?? (ProcessInfo.processInfo.thermalState == .critical)
    if overheated, phase == .active || phase == .starting {
      stoppedForHeat = true
      stop()
    }
    if let session, session.remaining(at: now) <= 0, phase == .active || phase == .starting { stop() }
    let status = controller.status()
    switch status {
    case "active":
      if phase == .starting { phase = .active }
    case "armed", "starting": break
    case "restoring": phase = .stopping
    case "restore-failed":
      phase = .recoveryRequired
      messageKey = "awake.error.restore"
    case "expired", "stopped", "owner-exited", "interrupted", "unsupported", "conflict",
         "start-failed", "low-battery", "battery-unavailable":
      let result = status ?? "interrupted"
      phase = .idle
      session = nil
      messageKey = stoppedForHeat ? "awake.ended.heat" : "awake.ended.\(result)"
    default:
      // An absent/unreadable journal never means successful restoration.
      phase = .recoveryRequired
      messageKey = "awake.error.status"
    }
  }
}
