import AppKit
import XCTest
@testable import Pulse

@MainActor
final class IslandPlaybackShortcutTests: XCTestCase {
  private func panel() -> IslandPanel {
    let panel = IslandPanel()
    panel.acceptsKeyInput = true
    panel.setFrame(CGRect(x: 100, y: 100, width: 300, height: 100), display: false)
    panel.makeKeyAndOrderFront(nil)
    return panel
  }

  private func space(in window: NSWindow, repeatKey: Bool = false,
    flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatKey, keyCode: 49)!
  }

  func testSpaceTogglesOncePerPressAndConsumesKeyRepeat() {
    let panel = panel()
    defer { panel.close() }
    var playing = true
    var toggles = 0
    func handle(_ event: NSEvent) -> Bool {
      IslandPlaybackShortcut.handle(event, isExpanded: true, isEditingReminder: false) {
        playing.toggle()
        toggles += 1
      }
    }
    XCTAssertTrue(handle(space(in: panel)))
    XCTAssertFalse(playing)
    for _ in 0..<8 { XCTAssertTrue(handle(space(in: panel, repeatKey: true))) }
    XCTAssertEqual(toggles, 1)
    XCTAssertTrue(handle(space(in: panel)))
    XCTAssertTrue(playing)
    XCTAssertEqual(toggles, 2)
  }

  func testTextFieldKeepsSpaceForTyping() throws {
    let panel = panel()
    defer { panel.close() }
    let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
    panel.contentView?.addSubview(field)
    panel.makeFirstResponder(field)
    let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
    XCTAssertTrue(editor.isEditable)
    XCTAssertFalse(IslandPlaybackShortcut.handle(space(in: panel),
      isExpanded: true, isEditingReminder: false) { XCTFail("Typing must not control playback") })
  }

  func testCollapsedEditorAndModifiedSpaceDoNotControlPlayback() {
    let panel = panel()
    defer { panel.close() }
    XCTAssertFalse(IslandPlaybackShortcut.handle(space(in: panel),
      isExpanded: false, isEditingReminder: false) { XCTFail() })
    XCTAssertFalse(IslandPlaybackShortcut.handle(space(in: panel),
      isExpanded: true, isEditingReminder: true) { XCTFail() })
    for flags: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
      XCTAssertFalse(IslandPlaybackShortcut.handle(space(in: panel, flags: flags),
        isExpanded: true, isEditingReminder: false) { XCTFail() })
    }
    panel.acceptsKeyInput = false
    XCTAssertFalse(IslandPlaybackShortcut.handle(space(in: panel),
      isExpanded: true, isEditingReminder: false) { XCTFail() })
  }

  func testOtherWindowsCannotTriggerIslandPlayback() {
    let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: .titled, backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    other.makeKeyAndOrderFront(nil)
    XCTAssertFalse(IslandPlaybackShortcut.handle(space(in: other),
      isExpanded: true, isEditingReminder: false) { XCTFail() })
  }
}
