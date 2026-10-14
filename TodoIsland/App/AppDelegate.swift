import AppKit
import Combine
import SwiftUI

@main
enum TodoIslandApplication {
  @MainActor
  static func main() {
    // Hidden diagnostic: runs the perl-helper transport test inside the
    // real (sandboxed) process and exits. `TodoIsland --media-harness-test`
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
  private var agentCancellables: Set<AnyCancellable> = []
  private var islandController: IslandWindowController?
  private var statusItem: NSStatusItem?
  private var settingsController: HostedWindowController<AnyView>?
  private var launchAtLoginMenuItem: NSMenuItem?

  /// Hosted unit tests boot this AppDelegate for real; their app instance
  /// would steal the live socket path (unlink + rebind) and touch the real
  /// ~/.claude config. Neither belongs in a test run.
  private static var isRunningTests: Bool {
    NSClassFromString("XCTestCase") != nil
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !Self.isRunningTests else { return }
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
      // The collapsed bar's Codex quota chip needs data before the first
      // expansion; the throttle keeps this to one fetch per five minutes.
      model.refreshAIUsage()
      islandController?.show()
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    model.markApplicationActive()
  }

  /// A queued approval or question auto-expands the island onto the agents
  /// pane (CodeIsland's default autoExpandOnPermission behavior) — pinned
  /// WITH the approval hold: the request usually lands while the user is in
  /// another app with the pointer elsewhere, and a plain pin is torn right
  /// back down by the pointer-exit suspend and the deactivation collapse.
  /// Emptying the queues releases the hold, handing the panel back to
  /// normal pinned semantics.
  private func wireAgentAutoExpansion() {
    Publishers.CombineLatest(agentStore.$permissionQueue, agentStore.$questionQueue)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] permissions, questions in
        guard let self else { return }
        if permissions.isEmpty && questions.isEmpty {
          self.model.releaseApprovalHold()
          return
        }
        guard self.model.editingReminderID == nil else { return }
        self.model.requestSidebarItem(.agents)
        self.model.pinIslandForApproval()
      }
      .store(in: &agentCancellables)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func menuWillOpen(_ menu: NSMenu) {
    LaunchAtLoginService.shared.refresh()
    launchAtLoginMenuItem?.state = LaunchAtLoginService.shared.isEnabled ? .on : .off
  }

  @objc private func openIsland() {
    islandController?.pinAndShow()
  }

  @objc private func openSettings() {
    if settingsController == nil {
      let view = AnyView(
        SettingsView { [weak self] in
          self?.islandController?.pinAndShow()
        }
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

  @objc private func toggleLaunchAtLogin() {
    let service = LaunchAtLoginService.shared
    service.setEnabled(!service.isEnabled)
    launchAtLoginMenuItem?.state = service.isEnabled ? .on : .off
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
    statusItem.button?.image = NSImage(
      systemSymbolName: "checklist",
      accessibilityDescription: L10n.text("app.name")
    )

    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(
      withTitle: L10n.text("menu.open"), action: #selector(openIsland), keyEquivalent: "")
    menu.addItem(
      withTitle: L10n.text("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
    menu.addItem(.separator())

    let launchItem = NSMenuItem(
      title: L10n.text("settings.launch-at-login"),
      action: #selector(toggleLaunchAtLogin),
      keyEquivalent: ""
    )
    launchItem.state = LaunchAtLoginService.shared.isEnabled ? .on : .off
    menu.addItem(launchItem)
    launchAtLoginMenuItem = launchItem

    menu.addItem(.separator())
    menu.addItem(
      withTitle: L10n.text("menu.about"), action: #selector(showAbout), keyEquivalent: "")
    menu.addItem(withTitle: L10n.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")

    statusItem.menu = menu
    self.statusItem = statusItem
  }
}
