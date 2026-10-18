import AppKit
import OSLog

/// A brief bundled cue before opening the microphone. Uses the current system
/// output, so headphones follow the same route as the ensuing conversation.
@MainActor
final class VoiceWakeSound {
  private var sound: NSSound?
  private var generation = 0
  private static let log = Logger(subsystem: "com.fxl.TodoIsland", category: "Voice")

  func play() async {
    stop()
    let token = generation
    guard let url = Bundle.main.url(forResource: "voice-wake-expand", withExtension: "wav"),
      let cue = NSSound(contentsOf: url, byReference: true) else {
      Self.log.error("Wake cue expand unavailable")
      return
    }
    cue.volume = 0.55
    cue.playbackDeviceIdentifier = nil
    sound = cue
    guard cue.play() else { sound = nil; return }
    Self.log.info("Wake cue expand started")
    // Never hold up voice setup if the output device disappears mid-cue.
    let deadline = ContinuousClock.now + .seconds(min(3, cue.duration + 1))
    while cue.isPlaying, generation == token, ContinuousClock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(25)) }
      catch { break }
    }
    guard generation == token else { return }
    stop()
    Self.log.info("Wake cue expand ended")
  }

  func stop() {
    generation += 1
    sound?.stop()
    sound = nil
  }

  isolated deinit { sound?.stop() }
}
