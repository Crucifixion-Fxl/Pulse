import AppKit
import Combine
import SwiftUI
import os

@main
enum PulseApplication {
  @MainActor
  static func main() {
    // Hidden diagnostic: runs the perl-helper transport test inside the
    // real (sandboxed) process and exits. `Pulse --media-harness-test`
    if CommandLine.arguments.contains("--media-harness-test") {
      NowPlayingController.runSandboxedHarness()
    }
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let model = AppModel()
  private let agentStore = AgentSessionStore()
  private var agentServer: AgentHookServer?
  private var aiUsageTimer: Timer?
  private var agentCancellables: Set<AnyCancellable> = []
  private var islandController: IslandWindowController?
  private var statusItem: NSStatusItem?
  private var settingsController: HostedWindowController<AnyView>?

  /// Hosted unit tests boot this AppDelegate for real; their app instance
  /// would steal the live socket path (unlink + rebind) and touch the real
  /// ~/.claude config. Neither belongs in a test run.
  private static var isRunningTests: Bool {
    NSClassFromString("XCTestCase") != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !Self.isRunningTests else { return }
    model.keepAwakeStore.observe()
    // The agent-status socket must be listening before any CLI fires a
    // hook at it (upstream CodeIsland starts the server the same way).
    let server = AgentHookServer(store: agentStore)
    server.start()
    agentServer = server
    wireAgentAutoExpansion()
    // Stage the bridge binary and (re)install CLI hooks — self-repairing on
    // every launch, exactly like upstream CodeIsland.
    Task { @MainActor in
      _ = AgentHookConfigInstaller().installAll(bundle: .main)
    }

    // Render cached quota with the bot on the first frame, then refresh without
    // waiting for reminder authorization/list loading.
    Logger(subsystem: "com.fxl.TodoIsland", category: "startup")
      .notice("quota ready before window=\(self.model.aiUsage != nil, privacy: .public)")
    model.refreshAIUsage()
    islandController = IslandWindowController(model: model, agentStore: agentStore)
    configureStatusItem()

    // Now Playing observer lives for the process lifetime; elapsed polling
    // is gated on the music panel being visible.
    let nowPlaying = NowPlayingController.shared
    nowPlaying.onUpdate = { [weak model] track in
      model?.nowPlayingDidChange(track)
    }
    nowPlaying.onLiveTemplatesChanged = { [weak model] keys in
      model?.mediaKeysReady = keys
    }
    nowPlaying.start()

    let clipboard = ClipboardHistoryService.shared
    clipboard.onItemsChanged = { [weak model] items in
      model?.clipboardHistoryDidChange(items)
    }
    clipboard.start()

    Task {
      await model.start()
      islandController?.show()
    }
    aiUsageTimer = Timer.scheduledTimer(withTimeInterval: AppModel.aiUsagePollingInterval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.model.refreshAIUsage()
      }
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    model.markApplicationActive()
    islandController?.refreshWakeShortcut()
  }

  func applicationWillTerminate(_ notification: Notification) {
    aiUsageTimer?.invalidate()
    islandController?.stopVoice()
    model.keepAwakeStore.shutdown()
  }

  /// A queued approval or question auto-expands the island onto the agents
  /// pane (CodeIsland's default autoExpandOnPermission behavior) — pinned
  /// WITH the approval hold: the request usually lands while the user is in
  /// another app with the pointer elsewhere, and a plain pin is torn right
  /// back down by the pointer-exit suspend and the deactivation collapse.
  /// Emptying the queues releases the hold, handing the panel back to
  /// normal pinned semantics.
  ///
  /// No editing guard: a suspended editor (island collapsed mid-edit) would
  /// otherwise silently swallow every approval — invisible prompts are
  /// worse than a pane switch, and the editor's draft survives it.
  private func wireAgentAutoExpansion() {
    Publishers.CombineLatest(agentStore.$permissionQueue, agentStore.$questionQueue)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] permissions, questions in
        guard let self else { return }
        if permissions.isEmpty && questions.isEmpty {
          self.model.releaseApprovalHold()
          return
        }
        self.model.requestSidebarItem(.agents)
        self.model.pinIslandForApproval()
        Self.logExpansion(
          "sink fired: pending=\(permissions.count)p/\(questions.count)q "
            + "pinned=\(self.model.islandState == .pinned) hold=\(self.model.isHeldForApproval) "
            + "host=\(self.model.hostDisplayID ?? "nil")")
      }
      .store(in: &agentCancellables)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Companion to the store's routing log — one line per auto-expansion so
  /// panel-lifecycle questions are answerable from the same file.
  nonisolated private static func logExpansion(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] auto-expand: \(message)\n"
    let path = "/tmp/doisland-agents-activity.log"
    if let handle = FileHandle(forWritingAtPath: path) {
      handle.seekToEndOfFile()
      handle.write(Data(line.utf8))
      handle.closeFile()
    } else {
      FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
  }

  func menuWillOpen(_ menu: NSMenu) {
    islandController?.refreshWakeShortcut()
  }

  @objc private func openIsland() {
    islandController?.pinAndShow()
  }

  @objc private func openSettings() {
    if settingsController == nil {
      let view = AnyView(
        SettingsView(
          openIsland: { [weak self] in self?.islandController?.pinAndShow() },
          enableGlobalWake: { [weak self] in
            self?.islandController?.enableGlobalWakeShortcut()
          }
        )
        .environmentObject(model)
      )
      settingsController = HostedWindowController(
        title: L10n.text("settings.title"),
        size: NSSize(width: 520, height: 455),
        rootView: view
      )
    }
    settingsController?.present()
  }

  @objc private func previewAIWake() {
    islandController?.previewAIWake()
  }

  @objc private func showAbout() {
    let alert = NSAlert()
    alert.messageText = L10n.text("app.name")
    alert.informativeText = L10n.text("about.detail")
    alert.icon = NSApp.applicationIconImage
    alert.addButton(withTitle: L10n.text("common.ok"))
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func configureStatusItem() {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let icon = NSImage(named: "PulseStatus")
    icon?.size = NSSize(width: 18, height: 18)
    icon?.isTemplate = true
    icon?.accessibilityDescription = L10n.text("app.name")
    statusItem.button?.image = icon

    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(
      withTitle: L10n.text("menu.open"), action: #selector(openIsland), keyEquivalent: "")
    menu.addItem(
      withTitle: L10n.text("wake.menu"), action: #selector(previewAIWake), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: L10n.text("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
    menu.addItem(
      withTitle: L10n.text("menu.about"), action: #selector(showAbout), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: L10n.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")

    statusItem.menu = menu
    self.statusItem = statusItem
  }
}
