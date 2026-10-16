import AppKit
import SwiftUI

struct KeyboardEventMonitor: NSViewRepresentable {
  let handler: @MainActor (NSEvent) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(handler: handler)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.start()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.handler = handler
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  @MainActor
  final class Coordinator {
    var handler: @MainActor (NSEvent) -> Bool
    private var monitor: Any?

    init(handler: @escaping @MainActor (NSEvent) -> Bool) {
      self.handler = handler
    }

    func start() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        return self.handler(event) ? nil : event
      }
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// Space belongs to playback only inside the opened island, outside editors.
/// Handle it before SwiftUI buttons/list shortcuts so one press has one effect.
@MainActor
enum IslandPlaybackShortcut {
  static func handle(
    _ event: NSEvent, isExpanded: Bool, isEditingReminder: Bool,
    toggle: () -> Void
  ) -> Bool {
    guard isExpanded, !isEditingReminder, event.type == .keyDown, event.keyCode == 49,
      event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
      let panel = event.window as? IslandPanel, panel.isKeyWindow,
      panel.acceptsKeyInput, panel.attachedSheet == nil,
      NSApp.modalWindow == nil
    else { return false }
    if let editor = panel.firstResponder as? NSText, editor.isEditable { return false }
    // Consume auto-repeat without toggling back and forth while Space is held.
    if !event.isARepeat { toggle() }
    return true
  }
}
