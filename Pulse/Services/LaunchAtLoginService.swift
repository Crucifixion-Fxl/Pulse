import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService: ObservableObject {
  static let shared = LaunchAtLoginService()

  @Published private(set) var isEnabled = false
  @Published var lastError: String?

  private init() {
    refresh()
  }

  func refresh() {
    isEnabled = SMAppService.mainApp.status == .enabled
  }

  func setEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refresh()
    } catch {
      lastError = error.localizedDescription
      refresh()
    }
  }
}
