import AppKit
import SwiftUI

@MainActor
final class HostedWindowController<Content: View>: NSWindowController {
  init(title: String, size: NSSize, rootView: Content) {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.isReleasedWhenClosed = false
    window.center()
    window.contentViewController = NSHostingController(rootView: rootView)
    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    NSApp.activate(ignoringOtherApps: true)
    showWindow(nil)
    window?.center()
    window?.makeKeyAndOrderFront(nil)
  }
}
