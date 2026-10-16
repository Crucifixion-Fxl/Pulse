import AppKit
import Combine
import Foundation
import os

@MainActor
final class RunnerArtworkStore: ObservableObject {
  @Published private(set) var clip: RunnerArtwork.Clip?
  private var inFlight: Task<RunnerArtwork.Clip, Error>?
  private var requestedID: String?
  private var dayTimer: Timer?
  private var observers: [AnyCancellable] = []
  private static let log = Logger(subsystem: "com.fxl.TodoIsland", category: "runner")

  init() {
    for notification in [NSNotification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                         NSNotification.Name("NSSystemClockDidChangeNotification")] {
      NotificationCenter.default.publisher(for: notification)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in Task { @MainActor in await self?.loadIfNeeded() } }
        .store(in: &observers)
    }
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in Task { @MainActor in await self?.loadIfNeeded() } }
      .store(in: &observers)
  }

  isolated deinit { dayTimer?.invalidate(); inFlight?.cancel() }

  func loadIfNeeded() async {
    scheduleNextDay()
    await refresh(for: Date())
  }

  /// Explicit date/calendar also lets tests cross midnight without changing the Mac clock.
  func refresh(for date: Date, calendar: Calendar = .autoupdatingCurrent) async {
    guard let character = RunnerArtwork.character(on: date, calendar: calendar) else { return }
    guard requestedID != character.id || clip?.character.id != character.id else { return }
    if requestedID == character.id, let inFlight {
      _ = try? await inFlight.value
      return
    }
    inFlight?.cancel()
    requestedID = character.id
    let task = Task.detached(priority: .utility) { try RunnerArtwork.load(character) }
    inFlight = task
    do {
      let loaded = try await task.value
      guard requestedID == character.id, !task.isCancelled else { return }
      clip = loaded
      inFlight = nil
      Self.log.info("Daily character ready: \(character.id, privacy: .public), \(loaded.frames.count) frames")
    } catch {
      guard requestedID == character.id else { return }
      inFlight = nil
      requestedID = nil
      Self.log.error("Daily character unavailable: \(String(describing: error), privacy: .public)")
    }
  }

  private func scheduleNextDay() {
    dayTimer?.invalidate()
    let timer = Timer(fire: RunnerArtwork.nextDay(after: Date()).addingTimeInterval(0.1), interval: 0, repeats: false) {
      [weak self] _ in Task { @MainActor in await self?.loadIfNeeded() }
    }
    dayTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
}
