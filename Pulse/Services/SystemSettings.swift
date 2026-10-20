import AppKit

enum SystemSettings {
  @MainActor
  static func openRemindersPrivacy() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
    else { return }
    NSWorkspace.shared.open(url)
  }

  @MainActor
  static func openReminders() {
    guard
      let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.reminders")
    else { return }

    NSWorkspace.shared.openApplication(
      at: applicationURL,
      configuration: NSWorkspace.OpenConfiguration()
    )
  }
}
