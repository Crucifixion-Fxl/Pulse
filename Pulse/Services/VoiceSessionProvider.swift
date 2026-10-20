import Foundation

/// Providers own audio capture/playback and expose normalized amplitude and TTS state.
enum VoiceSessionState: String, Decodable {
  case connecting, switching, listening, thinking, speaking, stopped
}

@MainActor
protocol VoiceSessionProvider: AnyObject {
  var onState: ((VoiceSessionState) -> Void)? { get set }
  var onLevel: ((Double, Double) -> Void)? { get set }
  var onError: ((String) -> Void)? { get set }
  func start()
  func stop()
}

@MainActor
struct VoiceProviderDescriptor: Identifiable {
  let id: String
  let title: String
  let isInstalled: () -> Bool
  let makeSession: () -> any VoiceSessionProvider
  let setupURL: URL
}

@MainActor
enum VoiceProviderRegistry {
  static let providers: [VoiceProviderDescriptor] = [
    .init(id: "xiaozhi", title: "Xiaozhi", isInstalled: { XiaozhiVoiceSession.isInstalled },
      makeSession: { XiaozhiVoiceSession() },
      setupURL: URL(string: "https://github.com/Crucifixion-Fxl/Pulse/blob/main/docs/XIAOZHI-VOICE.md")!)
  ]

  static func provider(id: String) -> VoiceProviderDescriptor {
    providers.first { $0.id == id } ?? providers[0]
  }
}

/// Sanitize amplitude once, independent of the selected transport.
enum VoiceAudioLevel {
  static func clamp(_ value: Double?) -> Double {
    guard let value, value.isFinite else { return 0 }
    return min(1, max(0, value))
  }
}
