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
    Lyrics(timedLines: [(0,"A little room to breathe"), (18,"A little time to dream"),
      (35,"Let the quiet carry you"), (55,"Into something new"), (80,"One small step at a time")])
  }
}
@MainActor final class Story: ObservableObject {
  @Published var scene = 0
  let titles = ["Make room for your day.", "Keep your agents in sight.", "Stay in the rhythm.", "Pick up where you copied."]
  let subtitles = ["Your calendar, reminders and progress — one glance away.",
    "See active sessions and requests without leaving your flow.",
    "Now Playing, playback controls and lyrics beside your work.",
    "Recent text and images, ready to copy again."]
}
struct Showcase: View {
  @ObservedObject var story: Story
  let model: AppModel
  let agents: AgentSessionStore
  var body: some View {
    ZStack {
      Color(red: 0.045, green: 0.055, blue: 0.09)
      RadialGradient(colors: [Color.blue.opacity(0.2), .clear], center: .topLeading, startRadius: 10, endRadius: 700)
      RadialGradient(colors: [Color.purple.opacity(0.17), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 600)
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Image(nsImage: NSImage(contentsOfFile: CommandLine.arguments[1] + "/docs/images/pulse-icon.png")!)
            .resizable().frame(width: 42, height: 42)
          Text("Pulse").font(.system(size: 28, weight: .bold))
          Spacer()
          Text("ONE NATIVE macOS ISLAND").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.white.opacity(0.55))
        }.padding(.horizontal, 44).padding(.top, 26)
        Text(story.titles[story.scene]).font(.system(size: 36, weight: .bold)).padding(.top, 21)
        Text(story.subtitles[story.scene]).font(.system(size: 16)).foregroundStyle(.white.opacity(0.62)).padding(.top, 8)
        ZStack(alignment: .top) {
          RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.025))
          VStack(spacing: 0) {
            HStack {
              Text("●  ●  ●").font(.system(size: 9)).foregroundStyle(.white.opacity(0.25))
              Spacer()
            }.padding(.horizontal, 14).frame(height: 25)
            Spacer()
          }
          IslandRootView().environmentObject(model).environmentObject(agents)
            .frame(width: 760, height: 420)
            .scaleEffect(1.13, anchor: .top)
            .frame(width: 860, height: 475, alignment: .top)
        }.frame(width: 920, height: 475).padding(.top, 23)
        HStack(spacing: 12) {
          ForEach(Array(["Reminders", "Agents + quotas", "Music", "Clipboard"].enumerated()), id: \.offset) { index, title in
            HStack(spacing: 7) {
              Circle().fill(index == story.scene ? Color.cyan : Color.white.opacity(0.18)).frame(width: 5, height: 5)
              Text(title).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(.white.opacity(index == story.scene ? 1 : 0.42))
              .padding(.horizontal, 15).padding(.vertical, 9)
              .background(.white.opacity(index == story.scene ? 0.08 : 0.025), in: Capsule())
          }
        }.padding(.top, 15)
        Text("Actual Pulse views · Fictional demo data · No personal content")
          .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).padding(.top, 13)
        Spacer(minLength: 0)
      }
    }.foregroundStyle(.white).frame(width: 1000, height: 770).preferredColorScheme(.dark)
  }
}
@main @MainActor struct Render {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
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
    let story = Story()
    let host = NSHostingView(rootView: Showcase(story: story, model: model, agents: agents))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 770), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    Task { @MainActor in
      await model.reload()
      model.pinIsland()
      model.setIslandHovered(true)
      model.refreshAIUsage()
      model.nowPlayingDidChange(NowPlayingTrack(title: "Quiet Orbit", artist: "Pulse Demo", album: "Focus Sessions", artworkData: nil,
        duration: 180, elapsed: 37, isPlaying: false, playbackRate: 0))
      model.clipboardHistoryDidChange([
        ClipboardItem(id: UUID(), kind: .text, text: "Small ideas.\nThoughtful details.\nA little progress every day.", capturedAt: Date(), contentHash: 1),
        ClipboardItem(id: UUID(), kind: .text, text: "https://example.com/design-notes", capturedAt: Date().addingTimeInterval(-120), contentHash: 2),
        ClipboardItem(id: UUID(), kind: .text, text: "# Weekend ideas\n\nVisit a bookstore\nTry a new recipe\nGo for a long walk", capturedAt: Date().addingTimeInterval(-300), contentHash: 3)
      ])
      var images: [CGImage] = []
      for (i, pane) in [IslandSidebarItem.reminders, .agents, .music, .clipboard].enumerated() {
        story.scene = i
        model.requestSidebarItem(pane)
        try? await Task.sleep(for: .seconds(2.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = bitmap.cgImage!
        images.append(image)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("scene-\(i).png"))
        precondition(model.canUseActiveList && model.islandState == .pinned)
        print("Rendered \(pane.rawValue): \(image.width)x\(image.height)")
      }
      let dest = CGImageDestinationCreateWithURL(output.appendingPathComponent("pulse-overview.gif") as CFURL, UTType.gif.identifier as CFString, images.count, nil)!
      CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
      for image in images { CGImageDestinationAddImage(dest, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 4.0]] as CFDictionary) }
      precondition(CGImageDestinationFinalize(dest))
      // A single contact sheet for readers who prefer a non-animated preview.
      let context = CGContext(data: nil, width: 2000, height: 1540, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.interpolationQuality = .high
      for (i, image) in images.enumerated() {
        context.draw(image, in: CGRect(x: (i % 2) * 1000, y: (1 - i / 2) * 770, width: 1000, height: 770))
      }
      let still = CGImageDestinationCreateWithURL(output.appendingPathComponent("pulse-overview.png") as CFURL,
        UTType.png.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(still, context.makeImage()!, nil)
      precondition(CGImageDestinationFinalize(still))
      defaults.removePersistentDomain(forName: suite)
      print("PASS: four production view scenes; synthetic inputs only; looping GIF saved")
      app.terminate(nil)
    }
    app.run()
  }
}
