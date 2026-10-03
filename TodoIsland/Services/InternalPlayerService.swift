import AVFoundation
import Foundation
import os

/// Plays NetEase stream URLs directly through AVPlayer. When active, the
/// panel's now-playing comes from here instead of mediaremoted, and media
/// keys control this player rather than sending template clones.
@MainActor
final class InternalPlayerService: NSObject, ObservableObject {
  static let shared = InternalPlayerService()

  private static let log = Logger(
    subsystem: "com.fxl.TodoIsland", category: "internal-player"
  )

  // MARK: - Published state

  @Published private(set) var currentTrack: FavoriteTrack?
  @Published private(set) var isPlaying = false
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var isBuffering = false

  /// Fires when the current track ends (auto-advance hook).
  var onTrackEnded: (() -> Void)?

  // MARK: - Private

  private var player: AVPlayer?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var session = URLSession.shared

  /// True while the internal player owns the panel (a track is loaded).
  var isActive: Bool { currentTrack != nil }

  // MARK: - Playback

  /// Fetches the stream URL and starts playing. `nil` on failure (VIP-only
  /// track, network error, etc.).
  func play(track: FavoriteTrack) async -> Bool {
    Self.log.info("playing \(track.name, privacy: .public)")
    isBuffering = true
    currentTrack = track

    guard let url = await streamURL(for: track.id) else {
      Self.log.error("no stream URL for \(track.id)")
      isBuffering = false
      currentTrack = nil
      return false
    }

    let item = AVPlayerItem(url: url)
    if player == nil {
      player = AVPlayer(playerItem: item)
    } else {
      player?.replaceCurrentItem(with: item)
    }
    installObservers()
    player?.play()
    isPlaying = true
    isBuffering = false
    return true
  }

  func togglePlayPause() {
    guard let player else { return }
    if player.timeControlStatus == .playing {
      player.pause()
      isPlaying = false
    } else {
      player.play()
      isPlaying = true
    }
  }

  func pause() {
    player?.pause()
    isPlaying = false
  }

  func resume() {
    player?.play()
    isPlaying = true
  }

  func seek(to seconds: Double) {
    let target = CMTime(seconds: seconds, preferredTimescale: 600)
    player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func stop() {
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    removeObservers()
    currentTrack = nil
    isPlaying = false
    duration = 0
    elapsed = 0
  }

  /// The NowPlayingTrack the panel should render while we're active.
  var nowPlayingSnapshot: NowPlayingTrack? {
    guard let track = currentTrack else { return nil }
    return NowPlayingTrack(
      title: track.name,
      artist: track.artist,
      album: "",
      artworkData: nil,
      duration: duration,
      elapsed: elapsed,
      isPlaying: isPlaying,
      playbackRate: isPlaying ? 1 : 0,
      playerBundleID: "com.fxl.TodoIsland.internal"
    )
  }

  // MARK: - Stream URL fetch

  private func streamURL(for id: Int) async -> URL? {
    guard let url = URL(string: "https://music.163.com/api/song/enhance/player/url") else {
      return nil
    }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
    request.setValue("NMTID=0", forHTTPHeaderField: "Cookie")
    request.setValue(
      "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"
    )
    let body = "ids=%5B\(id)%5D&br=320000"
    request.httpBody = body.data(using: .utf8)

    guard
      let (data, _) = try? await session.data(for: request),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = json["data"] as? [[String: Any]],
      let first = items.first,
      let urlString = first["url"] as? String,
      let streamURL = URL(string: urlString),
      (first["code"] as? Int) == 200
    else { return nil }
    return streamURL
  }

  // MARK: - Observers

  private func installObservers() {
    removeObservers()
    let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
    timeObserver = player?.addPeriodicTimeObserver(
      forInterval: interval, queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.elapsed = time.seconds
        if let duration = self.player?.currentItem?.duration.seconds,
          duration.isFinite, duration > 0
        {
          self.duration = duration
        }
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: player?.currentItem, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.isPlaying = false
        self?.onTrackEnded?()
      }
    }
  }

  private func removeObservers() {
    if let timeObserver {
      player?.removeTimeObserver(timeObserver)
    }
    timeObserver = nil
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    endObserver = nil
  }

}
