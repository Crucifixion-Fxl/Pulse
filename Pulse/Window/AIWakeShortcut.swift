import AppKit
import Carbon

/// Holds plain Space briefly before deciding whether it is text/playback or
/// an invocation. A short press is replayed exactly once; long-press repeats
/// never leak spaces into the foreground editor. Modified shortcuts pass through.
@MainActor
final class AIWakeShortcut {
  var onPress: (() -> Void)?
  var onRelease: (() -> Void)?
  var onCancel: (() -> Void)?
  private var eventTap: CFMachPort?
  private var source: CFRunLoopSource?
  private var localMonitor: Any?
  private static var capturesEscape = false
  private var pending: Timer?
  private var spaceHeld = false
  private var began = false
  private var beganAt: TimeInterval = 0
  private var mayReplay = true
  private var replay: (() -> Void)?
  private static var replayingLocal = false
  private static var installed = false
  private static let replayTag: Int64 = 0x50554C534557414B
  // Ordinary typing must not cause a flash. The remaining charge starts here.
  static let intentDelay: TimeInterval = 0.12
  var isRegistered: Bool { eventTap != nil }
  var hasGlobalPermission: Bool { AXIsProcessTrusted() }

  init(registerGlobally: Bool = true) {
    Self.installed = true
    if registerGlobally { retryGlobalRegistration() }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
      guard let self, !Self.replayingLocal,
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.replayTag else { return event }
      // Also handle accessibility-delivered events, which bypass the global tap.
      if event.keyCode == kVK_Escape, Self.capturesEscape {
        if event.type == .keyDown { self.cancelPending(); self.onCancel?() }
        return nil
      }
      if event.keyCode == kVK_Space {
        if event.type == .keyUp, self.spaceHeld { self.release(); return nil }
        guard event.type == .keyDown,
          event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) else { return event }
        if !self.spaceHeld {
          self.start { [weak self] in
            guard self != nil else { return }
            Self.replayingLocal = true
            NSApp.sendEvent(event)
            if let up = NSEvent.keyEvent(with: .keyUp, location: event.locationInWindow,
              modifierFlags: event.modifierFlags, timestamp: ProcessInfo.processInfo.systemUptime,
              windowNumber: event.windowNumber, context: nil, characters: " ",
              charactersIgnoringModifiers: " ", isARepeat: false, keyCode: UInt16(kVK_Space)) {
              NSApp.sendEvent(up)
            }
            Self.replayingLocal = false
          }
        }
        return nil
      }
      if self.shouldFlushForTyping { self.flushTyping() }
      return event
    }
  }

  /// Never prompts on startup. The explicit status-menu action requests the
  /// system permission; local Space still works without global accessibility.
  func retryGlobalRegistration() {
    guard eventTap == nil, AXIsProcessTrusted() else { return }
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
      options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let consumed = MainActor.assumeIsolated {
          let shortcut = Unmanaged<AIWakeShortcut>.fromOpaque(context).takeUnretainedValue()
          return shortcut.handle(type: type, event: event)
        }
        return consumed ? nil : Unmanaged.passUnretained(event)
      }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
    eventTap = tap
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    CGEvent.tapEnable(tap: tap, enable: true)
  }

  func requestGlobalAccess() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    retryGlobalRegistration()
  }

  private func handle(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      cancelPending()
      spaceHeld = false
      onCancel?()
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
      return false
    }
    if event.getIntegerValueField(.eventSourceUserData) == Self.replayTag { return false }
    let key = event.getIntegerValueField(.keyboardEventKeycode)
    if key == kVK_Escape, Self.capturesEscape {
      if type == .keyDown { cancelPending(); onCancel?() }
      return true
    }
    if key == kVK_Space {
      if type == .keyUp, spaceHeld { release(); return true }
      guard type == .keyDown,
        event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
      else { return false }
      if !spaceHeld, let down = event.copy() {
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        start {
          // Never insert a delayed space into a different application.
          guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
            let up = down.copy() else { return }
          down.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
          up.type = .keyUp
          up.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
          down.post(tap: .cgSessionEventTap)
          up.post(tap: .cgSessionEventTap)
        }
      }
      return true
    }
    if shouldFlushForTyping {
      // Preserve ordering for fast typing: replay the space before this key.
      flushTyping()
      if let forwarded = event.copy() {
        forwarded.setIntegerValueField(.eventSourceUserData, value: Self.replayTag)
        forwarded.post(tap: .cgSessionEventTap)
        return true
      }
    }
    return false
  }

  private func start(replay: @escaping () -> Void) {
    spaceHeld = true
    began = false
    mayReplay = !Self.capturesEscape
    self.replay = replay
    let timer = Timer(timeInterval: Self.intentDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.spaceHeld, self.replay != nil else { return }
        self.began = true
        self.beganAt = CACurrentMediaTime()
        self.onPress?()
      }
    }
    pending = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func release() {
    pending?.invalidate()
    pending = nil
    if began {
      let incomplete = CACurrentMediaTime() - beganAt < AIWakeGesture.holdDuration
      onRelease?()
      // A 150–600 ms space is still ordinary typing if the hold never woke
      // the assistant. Cancelled/second invocations deliberately replay nothing.
      if incomplete && mayReplay { replay?() }
    } else if mayReplay { replay?() }
    replay = nil
    spaceHeld = false
    began = false
  }

  private func flushTyping() {
    pending?.invalidate()
    pending = nil
    if began { onRelease?(); began = false }
    if mayReplay { replay?() }
    replay = nil
  }

  private var shouldFlushForTyping: Bool {
    spaceHeld && replay != nil && (!began || CACurrentMediaTime() - beganAt < AIWakeGesture.holdDuration)
  }

  private func cancelPending() {
    pending?.invalidate()
    pending = nil
    replay = nil
  }

  func captureEscape(_ capture: Bool) { Self.capturesEscape = capture }

  static func defersIslandAction(_ event: NSEvent) -> Bool {
    defersSpaceAction(event) || (Self.capturesEscape && event.keyCode == kVK_Escape)
  }

  static func defersSpaceAction(_ event: NSEvent) -> Bool {
    installed && event.keyCode == kVK_Space && !replayingLocal
      && event.cgEvent?.getIntegerValueField(.eventSourceUserData) != replayTag
      && event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
  }

  func resetHeldKey() {
    cancelPending()
    spaceHeld = false
    began = false
  }

  isolated deinit {
    Self.installed = false
    Self.capturesEscape = false
    pending?.invalidate()
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
  }
}
