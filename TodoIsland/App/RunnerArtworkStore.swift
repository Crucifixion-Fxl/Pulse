import Combine
import CoreGraphics
import Foundation
import os

@MainActor
final class RunnerArtworkStore: ObservableObject {
  @Published private(set) var frames: [CGImage] = []
  private var inFlight: Task<[CGImage], Error>?
  private var lastAttempt: Date?
  private static let log = Logger(subsystem: "com.fxl.TodoIsland", category: "runner")

  func loadIfNeeded() async {
    guard frames.isEmpty else { return }
    if let inFlight {
      _ = try? await inFlight.value
      return
    }
    guard lastAttempt.map({ Date().timeIntervalSince($0) >= 120 }) ?? true else { return }
    lastAttempt = Date()
    let task = Task.detached(priority: .utility) { try await RunnerArtwork.load() }
    inFlight = task
    defer { inFlight = nil }
    do {
      frames = try await task.value
      Self.log.info("Runner artwork ready: \(self.frames.count) frames")
    } catch {
      Self.log.error("Runner artwork unavailable: \(String(describing: error), privacy: .public)")
    }
  }
}
