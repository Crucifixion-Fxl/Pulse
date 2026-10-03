import AppKit
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
  private var islandController: IslandWindowController?
  private var statusItem: NSStatusItem?
  private var settingsController: HostedWindowController<AnyView>?
  private var launchAtLoginMenuItem: NSMenuItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    islandController = IslandWindowController(model: model)
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
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    model.markApplicationActive()
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
