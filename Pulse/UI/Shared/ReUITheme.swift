import SwiftUI

/// Native equivalents of ReUI's shadcn surface tokens, shared by every
/// expanded-Island feature panel.
enum ReUITheme {
  static let panel = Color(red: 0.055, green: 0.063, blue: 0.078)
  static let item = Color(red: 0.095, green: 0.106, blue: 0.13)
  static let itemHover = Color(red: 0.135, green: 0.15, blue: 0.18)
  static let itemSelected = Color(red: 0.11, green: 0.16, blue: 0.22)
  static let border = Color.white.opacity(0.105)
  static let subtleBorder = Color.white.opacity(0.065)
  static let muted = Color.white.opacity(0.58)
}
