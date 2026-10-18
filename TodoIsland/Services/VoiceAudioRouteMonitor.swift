import CoreAudio
import Foundation

/// CoreAudio's live defaults, unlike PortAudio's cached device enumeration,
/// notify us when headphones connect or the user chooses another audio route.
@MainActor
final class VoiceAudioRouteMonitor {
  private var listener: AudioObjectPropertyListenerBlock?
  private let selectors = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice]
  private var debounce: Task<Void, Never>?

  func start(onChange: @escaping @MainActor () -> Void) {
    stop()
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self, self.listener != nil else { return }
        self.debounce?.cancel()
        self.debounce = Task {
          try? await Task.sleep(for: .milliseconds(450))
          guard !Task.isCancelled else { return }
          onChange()
        }
      }
    }
    listener = block
    for selector in selectors {
      var address = AudioObjectPropertyAddress(mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
  }

  func stop() {
    debounce?.cancel()
    debounce = nil
    guard let listener else { return }
    for selector in selectors {
      var address = AudioObjectPropertyAddress(mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
    self.listener = nil
  }

  isolated deinit { stop() }
}
