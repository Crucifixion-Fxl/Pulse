import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// This standalone renderer uses production views with in-memory, fictional data.
// It never starts AppDelegate, EventKit, agent discovery or clipboard monitoring.
@MainActor final class DemoReminders: ReminderStore {
  var onStoreChanged: (() -> Void)?
  let day = Calendar.current.startOfDay(for: Date())
  var items: [ReminderSnapshot] = []
  init() {
    let titles = ["Sketch the next idea", "Review the prototype", "Take a walk", "Read a chapter"]
    items = titles.enumerated().map { i, title in
      var due = Calendar.current.dateComponents([.year, .month, .day], from: day)
      due.hour = [9, 11, 16, 20][i]; due.minute = 0
      return ReminderSnapshot(id: "demo-\(i)", listID: "demo", title: title,
        dueDateComponents: due, priority: .none, isRecurring: false)
    }
  }
  func authorizationStatus() -> ReminderAuthorization { .fullAccess }
  func requestFullAccess() async throws -> Bool { true }
  func fetchLists() async throws -> [ReminderListSnapshot] {
    [ReminderListSnapshot(id: "demo", title: "My day", accent: .fallback)]
  }
  func fetchPendingReminders(in listID: String) async throws -> [ReminderSnapshot] { items.filter { !$0.isCompleted } }
  func fetchReminders(dueFrom: Date, through: Date) async throws -> [ReminderSnapshot] { items }
  func fetchUndatedPendingReminders() async throws -> [ReminderSnapshot] { [] }
  func fetchOverduePendingReminders(before date: Date) async throws -> [ReminderSnapshot] { [] }
  func fetchCompletedReminders(completedFrom date: Date) async throws -> [ReminderSnapshot] {
    (1...160).filter { $0 % 7 != 0 && $0 % 5 != 0 }.map { i in
      let date = Calendar.current.date(byAdding: .day, value: -i, to: day)!
      return ReminderSnapshot(id: "history-\(i)", listID: "demo", title: "Daily reading",
        dueDateComponents: nil, priority: .none, isRecurring: false, isCompleted: true, completionDate: date)
    }
  }
  func createReminder(title: String, in listID: String, dueComponents: DateComponents?) async throws {}
  func updateReminder(id: String, from draft: ReminderDraft) async throws {}
  func setCompleted(_ completed: Bool, reminderID: String) async throws {
    if let i = items.firstIndex(where: { $0.id == reminderID }) { items[i].isCompleted = completed }
  }
  func deleteReminder(id: String) async throws {}
}
@MainActor final class DemoPlayback: NowPlayingControlling {
  var isAvailable = true
  var supportsSeeking = true
  var onUpdate: ((NowPlayingTrack?) -> Void)?
  var onLiveTemplatesChanged: (Set<Int32>) -> Void = { _ in }
  func start() {}; func refresh() {}; func setPanelActive(_ active: Bool) {}
  func togglePlayPause() {}; func play() {}; func pause() {}; func next() {}; func previous() {}; func seek(to seconds: Double) {}
}
struct DemoLyrics: LyricsProvider {
  func fetchLyrics(title: String, artist: String, duration: TimeInterval) async -> Lyrics? {
    Lyrics(timedLines: [(0,"Room to breathe"), (18,"Time to dream"),
      (35,"Quietly, we go"), (55,"Into something new"), (80,"One step at a time")])
  }
}
@main @MainActor struct Render {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let repository = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let suite = "PulseReadmeDemo-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = DemoReminders()
    let model = AppModel(store: store, defaults: defaults, aiUsageProvider: SampleAIUsageProvider(),
      lyricsService: LyricsService(providers: [DemoLyrics()]), nowPlayingController: DemoPlayback())
    model.extensionPreferences.statusItems = ["quota", "bot"]
    let agents = AgentSessionStore()
    for (id, source, name, tool) in [("demo-codex", "codex", "demo-app", "Edit"), ("demo-claude", "claude", "demo-site", "Read")] {
      for event in ["SessionStart", "UserPromptSubmit", "PreToolUse"] {
        let json: [String: Any] = ["hook_event_name": event, "session_id": id, "_source": source,
          "cwd": "/demo/\(name)", "tool_name": tool, "tool_input": ["file_path": "src/Welcome.swift"]]
        agents.apply(HookEvent(from: try! JSONSerialization.data(withJSONObject: json))!)
      }
    }
    let host = NSHostingView(rootView: IslandRootView().environmentObject(model).environmentObject(agents).preferredColorScheme(.dark))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    Task { @MainActor in
      await model.reload()
      model.pinIsland()
      model.setIslandHovered(true)
      model.refreshAIUsage()
      let cover = try! Data(contentsOf: repository.appendingPathComponent("docs/images/pulse-icon.png"))
      model.nowPlayingDidChange(NowPlayingTrack(title: "Quiet Orbit", artist: "Pulse Demo", album: "Focus Sessions", artworkData: cover,
        duration: 180, elapsed: 37, isPlaying: true, playbackRate: 1))
      model.clipboardHistoryDidChange([
        ClipboardItem(id: UUID(), kind: .text, text: "Small ideas.\nThoughtful details.\nA little progress every day.", capturedAt: Date(), contentHash: 1),
        ClipboardItem(id: UUID(), kind: .text, text: "https://example.com/design-notes", capturedAt: Date().addingTimeInterval(-120), contentHash: 2),
        ClipboardItem(id: UUID(), kind: .text, text: "# Weekend ideas\n\nVisit a bookstore\nTry a new recipe\nGo for a long walk", capturedAt: Date().addingTimeInterval(-300), contentHash: 3)
      ])
      var images: [CGImage] = []
      for (i, pane) in [IslandSidebarItem.reminders, .agents, .music, .clipboard].enumerated() {
        model.requestSidebarItem(pane)
        try? await Task.sleep(for: .seconds(2.4))
        if pane == .music {
          model.seedReadmeMusic()
          try? await Task.sleep(for: .milliseconds(150))
        }
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = bitmap.cgImage!
        images.append(image)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("scene-\(i).png"))
        precondition(model.canUseActiveList && model.islandState == .pinned)
        print("Rendered \(pane.rawValue): \(image.width)x\(image.height)")
      }
      defaults.removePersistentDomain(forName: suite)
      print("PASS: four production UI snapshots captured with fictional data")
      app.terminate(nil)
    }
    app.run()
  }
}
