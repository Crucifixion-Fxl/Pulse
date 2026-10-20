import AppKit

final class IslandPanel: NSPanel {
  var acceptsKeyInput = false

  override var canBecomeKey: Bool { acceptsKeyInput }
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
      backing: .buffered,
      defer: false
    )

    isFloatingPanel = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    isMovableByWindowBackground = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    level = .mainMenu + 3
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    animationBehavior = .none
    acceptsMouseMovedEvents = true
    contentView?.wantsLayer = true
    contentView?.layer?.backgroundColor = NSColor.clear.cgColor
  }
}
