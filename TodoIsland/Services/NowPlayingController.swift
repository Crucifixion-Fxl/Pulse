import Foundation
import os

/// Surface AppModel talks to, so wiring logic is testable without
/// spawning the perl helper.
@MainActor
protocol NowPlayingControlling: AnyObject {
  var isAvailable: Bool { get }
  var supportsSeeking: Bool { get }
  var onUpdate: ((NowPlayingTrack?) -> Void)? { get set }
  /// Keys with live (hardware-captured this session) templates.
  var onLiveTemplatesChanged: (Set<Int32>) -> Void { get set }
  func start()
  func refresh()
  func setPanelActive(_ active: Bool)
  func togglePlayPause()
  func play()
  func pause()
  func next()
  func previous()
  func seek(to seconds: Double)
}

/// Raw values of MediaRemote's exported CFString info keys; the helper
/// forwards them verbatim over its JSON lines.
enum NowPlayingInfoKey {
  static let title = "kMRMediaRemoteNowPlayingInfoTitle"
  static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
  static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
  static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
  static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
  static let rate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
  static let artwork = "kMRMediaRemoteNowPlayingInfoArtworkData"
  /// Wall-clock moment the ElapsedTime anchor refers to; mediaremoted does
  /// not advance elapsed between fetches — clients extrapolate from this.
  static let currentPlaybackDate = "kMRMediaRemoteNowPlayingInfoCurrentPlaybackDate"
  /// When mediaremoted fetched this dictionary — the fallback
  /// extrapolation base for players that omit CurrentPlaybackDate.
  static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
}

// MARK: - Controller

/// Reads the system Now Playing buffer through a resident /usr/bin/perl
/// child that loads the bundled MediaRemoteHelper.dylib. macOS 26 denies
/// mediaremoted's now-playing XPC to non-platform binaries ("Operation
/// not permitted"), and /usr/bin/perl — trust-cached by the OS — is
/// allowed; the helper does the MediaRemote calls from inside perl and
/// speaks JSON lines over stdio. Notification observation and the 0.5 s
/// elapsed timer live in the helper, gated by the "active" command.
@MainActor
final class NowPlayingController: NowPlayingControlling {
  static let shared = NowPlayingController()
  private nonisolated static let log = Logger(
    subsystem: "com.fxl.TodoIsland", category: "nowplaying"
  )

  private(set) var isAvailable = false
  private(set) var supportsSeeking = false

  var onUpdate: ((NowPlayingTrack?) -> Void)?
  /// Keys with live (hardware-captured this session) templates.
  var onLiveTemplatesChanged: (Set<Int32>) -> Void = { _ in }

  private var process: Process?
  /// Both pipes must outlive spawn(): releasing the Pipe objects closes
  /// their ends, killing the command channel.
  private var stdinPipe: Pipe?
  private var stdoutPipe: Pipe?
  private var desiredActive = false
  private var restartAttempts = 0
  private var lastTrack: NowPlayingTrack?
  private var lastArtworkData: Data?

  /// Minimal DynaLoader bootstrap: loads the dylib and jumps into
  /// ti_mediahelper_main.
  private nonisolated static let perlLoader = """
    use DynaLoader;
    my $dylib = shift;
    my $l = DynaLoader::dl_load_file($dylib) or die "load: ".DynaLoader::dl_error();
    my $b = DynaLoader::dl_find_symbol($l,"_bootstrap") || DynaLoader::dl_find_symbol($l,"bootstrap");
    my $m = DynaLoader::dl_find_symbol($l,"_ti_mediahelper_main") || DynaLoader::dl_find_symbol($l,"ti_mediahelper_main");
    DynaLoader::dl_install_xsub("main::bootstrap",$b);
    DynaLoader::dl_install_xsub("main::helpermain",$m);
    bootstrap();
    exit helpermain();
    """

  func start() {
    guard process == nil else { return }
    guard
      let dylib = Bundle.main.resourceURL?
        .appendingPathComponent("MediaRemoteHelper.dylib").path,
      FileManager.default.fileExists(atPath: dylib)
    else {
      Self.log.error("MediaRemoteHelper.dylib missing from bundle resources")
      return
    }
    spawn(dylib)
  }

  func refresh() {
    // Any command makes the helper re-fetch; "refresh" is the no-op one.
    send(["cmd": "refresh"])
  }

  func setPanelActive(_ active: Bool) {
    // The helper polls whenever something plays — panel visibility no
    // longer gates it (a missed "active" command froze the elapsed updates
    // before). Kept for protocol compatibility.
    desiredActive = active
  }

  /// Commands travel as signals — kill from the sandboxed parent to its
  /// own child is always permitted, where the temp-file channel was not
  /// readable from inside the sandboxed helper.
  func togglePlayPause() { signalHelper(SIGUSR1) }
  func play() { signalHelper(SIGUSR1) }
  func pause() { signalHelper(SIGUSR1) }
  func next() { signalHelper(SIGUSR2) }
  func previous() { signalHelper(SIGINFO) }
  func seek(to seconds: Double) { send(["cmd": "seek", "t": seconds]) }

  private func signalHelper(_ signal: Int32) {
    guard let process, process.isRunning else { return }
    kill(process.processIdentifier, signal)
  }

  // MARK: - Process lifecycle

  private func spawn(_ dylibPath: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", Self.perlLoader, dylibPath]

    let stdout = Pipe()
    let stdin = Pipe()
    process.standardOutput = stdout
    process.standardError = stdout
    process.standardInput = stdin

    // Line-buffer state lives inside the closure — one reader queue.
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      var buffer = chunk
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer.subdata(in: buffer.startIndex..<newline)
        buffer.removeSubrange(buffer.startIndex...newline)
        guard !line.isEmpty else { continue }
        guard
          let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else {
          // Helper/stderr chatter — log it; it is how perl failures surface.
          let text = String(data: line, encoding: .utf8) ?? "<binary>"
          Self.log.error("helper raw: \(text.prefix(300), privacy: .public)")
          continue
        }
        // Handed from the single pipe-reader to the actor and never used
        // again here; the unsafe box is the standard escape for untyped
        // JSON payloads crossing an isolation boundary.
        nonisolated(unsafe) let payload = object
        Task { @MainActor in self.apply(payload) }
      }
    }

    process.terminationHandler = { [weak self] terminated in
      let reason = "exit(\(terminated.terminationStatus)) reason=\(terminated.terminationReason.rawValue)"
      Self.log.error("helper terminated: \(reason, privacy: .public)")
      Task { @MainActor in self?.helperDidTerminate() }
    }

    do {
      try process.run()
    } catch {
      Self.log.error("spawn perl failed: \(error.localizedDescription)")
      scheduleRestart()
      return
    }
    self.process = process
    self.stdinPipe = stdin
    self.stdoutPipe = stdout
    Self.log.debug("helper spawned (pid \(process.processIdentifier)")
  }

  private func helperDidTerminate() {
    guard process?.isRunning == false || process == nil else { return }
    Self.log.warning("helper exited; restarting with backoff")
    process = nil
    stdinPipe = nil
    stdoutPipe = nil
    isAvailable = false
    scheduleRestart()
  }

  private func scheduleRestart() {
    restartAttempts += 1
    let delay = min(0.5 * pow(2, Double(restartAttempts - 1)), 10)
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
      guard self.process == nil else { return }
      self.start()
    }
  }

  /// Commands travel through a temp file the helper drains on its 0.5 s
  /// tick; the stdin pipe proved unusable from inside perl (readability
  /// handler spin). Resolve via the TMPDIR env the child inherits, so the
  /// two sides can never diverge.
  private var commandFileURL: URL {
    let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: tmp).appendingPathComponent("TodoIslandMusic.cmd")
  }

  private func send(_ object: [String: Any]) {
    guard process?.isRunning == true,
      let data = try? JSONSerialization.data(withJSONObject: object)
    else { return }
    var line = data
    line.append(0x0A)
    let url = commandFileURL
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: line)
    }
  }

  // MARK: - Output handling

  private func apply(_ object: [String: Any]) {
    if let error = object["helperError"] as? String {
      Self.log.error("helper: \(error, privacy: .public)")
      return
    }
    if object["helperStarted"] != nil {
      isAvailable = true
      supportsSeeking = (object["seek"] as? Int) == 1
      restartAttempts = 0
      Self.log.info("helper started (seeking \(self.supportsSeeking ? "on" : "off", privacy: .public))")
      return
    }

    if let live = object["tplLive"] as? [Int] {
      onLiveTemplatesChanged(Set(live.map { Int32($0) }))
      return
    }

    var dict = object
    if let base64 = dict.removeValue(forKey: NowPlayingInfoKey.artwork) as? String {
      lastArtworkData = Data(base64Encoded: base64)
    }

    var track = Self.makeTrack(from: dict, previous: lastTrack)
    if track != nil, track?.artworkData == nil, let previous = lastTrack,
      previous.title == track?.title, previous.artist == track?.artist
    {
      // Unchanged artwork was omitted from the line; restore the copy.
      track?.artworkData = lastArtworkData
    }
    lastTrack = track
    onUpdate?(track)
  }

  // MARK: Sandboxed transport diagnostic

  /// Spawns the helper exactly as the app does, sends active:true, counts
  /// emitted lines for six seconds, logs the verdict, and exits. Run via
  /// `TodoIsland --media-harness-test`.
  nonisolated static func runSandboxedHarness() -> Never {
    let log = Logger(subsystem: "com.fxl.TodoIsland", category: "harness")
    guard
      let dylib = Bundle.main.resourceURL?
        .appendingPathComponent("MediaRemoteHelper.dylib").path
    else {
      log.error("harness: dylib missing")
      exit(1)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", perlLoader, dylib]
    let stdoutPipe = Pipe()
    let stdinPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardInput = stdinPipe
    let counter = LineCounter()
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      counter.add(chunk.filter { $0 == 0x0A }.count)
      // Echo what actually arrived so the verdict is diagnosable.
      chunk.split(separator: 0x0A).prefix(6).forEach { lineData in
        var text = String(data: Data(lineData), encoding: .utf8) ?? "<binary>"
        if text.count > 260 { text = String(text.prefix(260)) + "…" }
        var out = Data(("LINE: " + text + "\n").utf8)
        out.withUnsafeBytes { raw in
          _ = raw.baseAddress.map { fwrite($0, 1, out.count, stderr) }
        }
      }
    }
    do {
      try process.run()
    } catch {
      log.error("harness: spawn failed \(error.localizedDescription)")
      exit(1)
    }
    var line = Data(#"{"cmd":"active","on":true}"#.utf8)
    line.append(0x0A)
    try? stdinPipe.fileHandleForWriting.write(contentsOf: line)

    Thread.sleep(forTimeInterval: 6)
    let verdict = "harness: alive=\(process.isRunning) lines=\(counter.value)\n"
    log.error("harness: alive=\(process.isRunning) lines=\(counter.value)")
    // os.Logger can drop messages when the process exits immediately;
    // mirror the verdict on stderr so shell captures survive.
    fputs(verdict, stderr)
    fflush(stderr)
    exit(0)
  }

  private final class LineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
    func add(_ n: Int) {
      lock.lock()
      count += n
      lock.unlock()
    }
  }

  // MARK: Pure mapping — unit-tested with fixture dictionaries

  /// Maps a raw info dictionary (helper JSON: strings and numbers,
  /// artwork arriving as base64 data) to a NowPlayingTrack. Nil when the
  /// dictionary carries neither a title nor an artist (nothing playing).
  /// ElapsedTime is an anchor at CurrentPlaybackDate — while playing, the
  /// position is extrapolated to `now`. `previous` feeds the elapsed-
  /// advance heuristic for players that omit PlaybackRate entirely.
  nonisolated static func makeTrack(
    from info: [String: Any]?,
    previous: NowPlayingTrack? = nil,
    now: Date = Date()
  ) -> NowPlayingTrack? {
    guard let info else { return nil }
    let title = info[NowPlayingInfoKey.title] as? String ?? ""
    let artist = info[NowPlayingInfoKey.artist] as? String ?? ""
    guard !title.isEmpty || !artist.isEmpty else { return nil }

    let duration = (info[NowPlayingInfoKey.duration] as? NSNumber)?.doubleValue ?? 0
    let anchorElapsed = (info[NowPlayingInfoKey.elapsed] as? NSNumber)?.doubleValue ?? 0
    let rateNumber = info[NowPlayingInfoKey.rate] as? NSNumber
    let rate = rateNumber?.doubleValue ?? 0
    let playbackDate = (info[NowPlayingInfoKey.currentPlaybackDate] as? NSNumber)?
      .doubleValue

    var elapsed = anchorElapsed
    if rate > 0 {
      if let playbackDate {
        elapsed = anchorElapsed + max(now.timeIntervalSince1970 - playbackDate, 0) * rate
      } else if let fetchTime = (info[NowPlayingInfoKey.timestamp] as? NSNumber)?.doubleValue {
        // No playback date (some players omit it) — extrapolate from the
        // fetch timestamp instead so lyrics still track playback.
        elapsed = anchorElapsed + max(now.timeIntervalSince1970 - fetchTime, 0) * rate
      }
    }

    let isPlaying: Bool
    if let rateNumber {
      isPlaying = rate > 0
    } else if let previous, previous.title == title, previous.artist == artist {
      isPlaying = elapsed > previous.elapsed + 0.01
    } else {
      isPlaying = false
    }

    let artwork: Data?
    if let base64 = info[NowPlayingInfoKey.artwork] as? String {
      artwork = Data(base64Encoded: base64)
    } else if let data = info[NowPlayingInfoKey.artwork] as? NSData {
      artwork = Data(referencing: data)
    } else {
      artwork = nil
    }

    return NowPlayingTrack(
      title: title,
      artist: artist,
      album: info[NowPlayingInfoKey.album] as? String ?? "",
      artworkData: artwork,
      duration: duration,
      elapsed: elapsed,
      isPlaying: isPlaying,
      playbackRate: rate,
      playerBundleID: nil,
      receivedAt: now
    )
  }
}
