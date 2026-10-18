// Animation timings adapted from krishhgg/Insomnia (MIT, Krish Garg, 2026).
import SwiftUI

@MainActor
enum AwakeMotion {
  static let pupilClosedScale: CGFloat = 0.6
  static func blink(opening: Bool, reduceMotion: Bool) -> Animation {
    if reduceMotion { return .easeInOut(duration: 0.3) }
    return .spring(response: opening ? 0.95 : 0.8, dampingFraction: opening ? 0.9 : 0.95)
  }
  static func pupil(opening: Bool, reduceMotion: Bool) -> Animation {
    if reduceMotion { return .easeInOut(duration: 0.3) }
    return opening ? .spring(response: 0.5, dampingFraction: 0.6).delay(0.2) : .easeOut(duration: 0.4)
  }
}
