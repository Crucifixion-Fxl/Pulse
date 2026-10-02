import AppKit
import ApplicationServices
import Foundation

// MediaRemoteHelper — loaded into /usr/bin/perl by Todo Island.
//
// macOS 26 gates mediaremoted's now-playing data behind the caller being a
// platform binary: third-party processes get "Operation not permitted" from
// MRMediaRemoteGetNowPlayingInfo, while /usr/bin/perl (trust-cached) is
// allowed. So Todo Island spawns perl and this dylib does the MediaRemote
// calls from inside it, speaking JSON lines over stdio:
//
//   stdout: one JSON object per line — the full now-playing info
//           dictionary (kMRMediaRemoteNowPlayingInfo* keys, values raw;
//           artwork base64, resent only when it changes).
//   stdin:  {"cmd":...} lines — toggle/play/pause/next/previous,
//           {"cmd":"seek","t":sec}, {"cmd":"active","on":bool} to gate the
//           0.5 s elapsed timer.
//
// Build with scripts/build-media-helper.sh; NOT part of the app target.
// Compiled with -swift-version 5: it is a single-threaded-logic helper
// (all state mutates on the main queue) living for one process lifetime.

@_cdecl("bootstrap")
public func bootstrap() {}

// Implicitly-unwrapped optionals: plain optional C-function-pointer storage
// trips a Swift 6.4 IRGen crash (reabstraction thunk), IUO storage does not.
private typealias GetFn = @convention(c) (
  DispatchQueue?, @escaping (@convention(block) ([String: Any]?) -> Void)
) -> Void
private typealias RegFn = @convention(c) (DispatchQueue?) -> Void
private typealias SeekFn = @convention(c) (Double) -> Void

private var handle: UnsafeMutableRawPointer?
private var getNowPlayingInfo: GetFn!
private var setElapsedTimeFn: SeekFn!

// Commands arrive as signals from the app (kill from the parent is always
// sandbox-permitted; the temp-file channel proved unreadable from inside
// the sandboxed child). Handlers only set flags; the 0.5 s tick consumes
// them — keep signal-handler work async-signal-safe.
private var pendingToggle = false
private var pendingNext = false
private var pendingPrevious = false

private func signalToggle(_ sig: Int32) { pendingToggle = true }
private func signalNext(_ sig: Int32) { pendingNext = true }
private func signalPrevious(_ sig: Int32) { pendingPrevious = true }

// Controls synthesize the keyboard media keys (NX_SYSDEFINED subtype 8) —
// the only command path 网易云音乐's CEF shell honors. Both
// MRMediaRemoteSendCommand and MRMediaRemoteSendCommandToClient are
// silently ignored by it (verified against the live player).
// Media-key control. Synthetic NX events get dropped or repurposed by
// mediaremoted's trusted-forwarding (网易云 only honors keys that look
// genuinely hardware-born), but a COPY of a REAL keyboard media event
// re-posts perfectly. So: passively tap the HID stream, template the
// user's own media-key presses, and re-post clones on demand. Synthetic
// and osascript variants remain as fallbacks before a template exists.
// Toolchain hazard: file-scope lets read as 0 and dictionary globals crash
// on lazy init in this dlopen'd dylib — hold state in a class instance
// behind a trivially-nil global instead.
private final class MediaKeyStore {
  struct Template {
    let down: CGEvent
    let up: CGEvent
    /// True when captured from real hardware this session; restored
    /// reconstructions are best-effort.
    var isLive = true
  }
  var templates: [Int32: Template] = [:]
  var poster: Process?
}
private var mediaKeyStore: MediaKeyStore?

// Templates persist across restarts: the captured events' raw integer
// fields are serialized to Application Support and re-applied onto a
// freshly constructed base event at boot, so buttons work without the
// user re-seeding after every app launch.
private func templatesFileURL() -> URL {
  FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/TodoIsland/media-keys.json")
}

private func fieldsSnapshot(_ event: CGEvent) -> [String: Int64] {
  var out: [String: Int64] = [:]
  for f in 0..<130 {
    let v = event.getIntegerValueField(CGEventField(rawValue: UInt32(f))!)
    if v != 0 { out[String(f)] = v }
  }
  return out
}

private func rebuildEvent(fields: [String: Int64], key: Int32, down: Bool) -> CGEvent? {
  let base = NSEvent.otherEvent(
    with: .systemDefined, location: .zero,
    modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
    timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
    data1: Int(key << 16) | (down ? 0xa00 : 0xb00), data2: -1
  )
  guard let event = base?.cgEvent else { return nil }
  for (name, value) in fields {
    guard let f = UInt32(name) else { continue }
    event.setIntegerValueField(CGEventField(rawValue: f)!, value: value)
  }
  return event
}

private func persistTemplates() {
  guard let store = mediaKeyStore else { return }
  var persisted: [String: [String: [String: Int64]]] = [:]
  for (key, template) in store.templates {
    persisted[String(key)] = [
      "down": fieldsSnapshot(template.down),
      "up": fieldsSnapshot(template.up),
    ]
  }
  guard let data = try? JSONSerialization.data(withJSONObject: persisted) else {
    fputs("PERSIST serialize failed\n", stderr)
    return
  }
  let url = templatesFileURL()
  do {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    fputs("PERSIST wrote \(data.count)B to \(url.path)\n", stderr)
  } catch {
    fputs("PERSIST failed: \(error)\n", stderr)
  }
}

/// Tells the app which keys have LIVE (this-session) templates, so the
/// panel can hint at F8 seeding after a restart.
private func emitTemplates() {
  let live = mediaKeyStore.map { store in
    store.templates.filter { $0.value.isLive }.map { Int($0.key) }
  } ?? []
  emit(["tplLive": live])
}

private func restoreTemplates() {
  let url = templatesFileURL()
  guard
    let data = try? Data(contentsOf: url),
    let persisted = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: [String: Int64]]]
  else { return }
  for (name, fields) in persisted {
    guard
      let key = Int32(name),
      let downFields = fields["down"], let upFields = fields["up"],
      let down = rebuildEvent(fields: downFields, key: key, down: true),
      let up = rebuildEvent(fields: upFields, key: key, down: false)
    else { continue }
    if mediaKeyStore == nil { mediaKeyStore = MediaKeyStore() }
    mediaKeyStore?.templates[key] = .init(down: down, up: up, isLive: false)
    fputs("RESTORED template key=\(key)\n", stderr)
  }
}

private func startMediaKeyTap() {
  let mask = CGEventMask(1 << 14)  // systemDefined
  guard
    let tap = CGEvent.tapCreate(
      tap: .cghidEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: mask,
      callback: { _, _, event, _ in
        if let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 {
          let key = Int32((nsEvent.data1 >> 16) & 0xFFFF)
          let down = (nsEvent.data1 & 0xFF00) == 0xa00
          if [16, 17, 18].contains(key) {
            if mediaKeyStore == nil { mediaKeyStore = MediaKeyStore() }
            let existing = mediaKeyStore?.templates[key]
            if down {
              mediaKeyStore?.templates[key] = .init(down: event.copy()!, up: existing?.up ?? event.copy()!)
              fputs("TAP captured down key=\(key)\n", stderr)
            } else if existing != nil {
              mediaKeyStore?.templates[key] = .init(down: existing!.down, up: event.copy()!)
              fputs("TAP captured up key=\(key)\n", stderr)
              persistTemplates()
              emitTemplates()
            }
          }
        }
        return Unmanaged.passRetained(event)
      },
      userInfo: nil
    )
  else {
    fputs("media key tap create failed\n", stderr)
    return
  }
  CFRunLoopAddSource(
    CFRunLoopGetCurrent(),
    CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
    .commonModes
  )
  CGEvent.tapEnable(tap: tap, enable: true)
}

private func postMediaKey(_ key: Int32) {
  if let template = mediaKeyStore?.templates[key] {
    fputs("POST key=\(key) via captured template pair\n", stderr)
    // Restored clones carry the capture-time timestamp; mediaremoted's
    // genuineness check rejects stale ones intermittently. Refresh both
    // clones' timestamps from a freshly minted event before posting.
    let freshStamp = CGEvent(
      keyboardEventSource: CGEventSource(stateID: .hidSystemState),
      virtualKey: 0, keyDown: true
    )?.timestamp
    for down in [true, false] {
      let base = down ? template.down : template.up
      guard let clone = base.copy() else { continue }
      if let freshStamp { clone.timestamp = freshStamp }
      clone.post(tap: .cghidEventTap)
      if down { usleep(60000) }
    }
    return
  }

  // No template yet (user hasn't pressed that key since launch) — try a
  // platform-binary post via osascript.
  fputs("POST key=\(key) via osascript (no template)\n", stderr)
  let script = """
    ObjC.import('AppKit');ObjC.import('CoreGraphics');
    function post(down){const ev=$.NSEvent['otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:'](14,$.NSMakePoint(0,0),down?0xa00:0xb00,0,0,$(),8,(\(key)<<16)|(down?0xa00:0xb00),-1);$.CGEventPost(0,ev.CGEvent)}
    post(true);for(let i=0;i<20000000;i++){}post(false);
    """
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  task.arguments = ["-l", "JavaScript", "-e", script]
  task.standardOutput = FileHandle.nullDevice
  task.standardError = FileHandle.nullDevice
  do {
    try task.run()
    if mediaKeyStore == nil { mediaKeyStore = MediaKeyStore() }
    mediaKeyStore?.poster = task
  } catch {
    fputs("POST spawn osascript failed: \(error)\n", stderr)
  }
}

private var lastInfo: [String: Any] = [:]
private var lastArtworkBase64: String?
private var elapsedTimer: DispatchSourceTimer?
/// Polling defaults ON: elapsed updates must never depend on a command
/// arriving. The "active" command can still gate it for future power
/// saving, but nothing breaks when it doesn't.
private var active = true

@_cdecl("ti_mediahelper_main")
public func mediaHelperMain() -> Int32 {
  setvbuf(stdout, nil, _IOLBF, 0)

  handle = dlopen(
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY
  )
  guard let handle else {
    emit(["helperError": "dlopen failed: \(String(cString: dlerror()))"])
    return 1
  }

  if let p = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
    getNowPlayingInfo = unsafeBitCast(p, to: GetFn.self)
  }
  if let p = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
    setElapsedTimeFn = unsafeBitCast(p, to: SeekFn.self)
  }
  guard getNowPlayingInfo != nil else {
    emit(["helperError": "GetNowPlayingInfo missing"])
    return 1
  }

  if let p = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
    let register = unsafeBitCast(p, to: RegFn.self)
    register(DispatchQueue.main)
  }
  for name in [
    "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
  ] {
    NotificationCenter.default.addObserver(
      forName: Notification.Name(name), object: nil, queue: .main
    ) { _ in
      refresh()
    }
  }

  startElapsedTimer()
  fputs("AXTRUSTED=\(AXIsProcessTrusted())\n", stderr)
  restoreTemplates()
  startMediaKeyTap()
  emitTemplates()
  signal(SIGUSR1, signalToggle)
  signal(SIGUSR2, signalNext)
  signal(SIGINFO, signalPrevious)
  emit(["helperStarted": 1, "seek": setElapsedTimeFn != nil ? 1 : 0])
  refresh()
  RunLoop.main.run()
  return 0
}

// MARK: - Output

private func refresh() {
  // The callback arrives on the queue we pass (main); the body runs inline —
  // an extra DispatchQueue.main.async hop would never drain while perl owns
  // the main RunLoop.
  getNowPlayingInfo(DispatchQueue.main) { info in
    var dict: [String: Any] = [:]
    for (rawKey, rawValue) in info ?? [:] {
      // Keep only JSON-representable values; mediaremote also packs NSDate
      // and other NSData blobs the app does not read.
      switch rawValue {
      case let value as String:
        dict[rawKey] = value
      case let value as NSNumber:
        dict[rawKey] = value
      case let value as NSDate:
        dict[rawKey] = value.timeIntervalSince1970
      default:
        break
      }
    }

    if let artwork = (info?["kMRMediaRemoteNowPlayingInfoArtworkData"] as? NSData) {
      let base64 = artwork.base64EncodedString()
      if base64 != lastArtworkBase64 {
        lastArtworkBase64 = base64
        dict["kMRMediaRemoteNowPlayingInfoArtworkData"] = base64
      }
      // Unchanged artwork stays omitted; the app keeps its last copy.
    } else {
      lastArtworkBase64 = nil
    }

    lastInfo = dict
    emit(dict)
  }
}

private func emit(_ object: [String: Any]) {
  guard JSONSerialization.isValidJSONObject(object),
    let data = try? JSONSerialization.data(withJSONObject: object)
  else { return }
  data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    if let base = raw.baseAddress {
      fwrite(base, 1, data.count, stdout)
    }
  }
  fputc(0x0A, stdout)
  fflush(stdout)
}

// MARK: - Elapsed timer

private func startElapsedTimer() {
  let timer = DispatchSource.makeTimerSource(queue: .main)
  timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
  timer.setEventHandler {
    // Consume signalled commands first.
    if pendingToggle {
      pendingToggle = false
      fputs("GOT sig=toggle\n", stderr)
      postMediaKey(16)
    }
    if pendingNext {
      pendingNext = false
      fputs("GOT sig=next\n", stderr)
      postMediaKey(17)
    }
    if pendingPrevious {
      pendingPrevious = false
      fputs("GOT sig=previous\n", stderr)
      postMediaKey(18)
    }
    drainCommands()
    // Unconditional: 网易云 may omit PlaybackRate entirely, and gating on
    // rate froze the elapsed updates for exactly that player. One XPC per
    // tick is negligible; mediaremoted computes elapsed per fetch.
    refresh()
  }
  timer.resume()
  elapsedTimer = timer
}

// MARK: - Commands

// Commands arrive via a temp file the app appends to; the 0.5 s tick
// drains it. stdin proved unreliable in this embedded context: a never-
// written pipe put Foundation's readabilityHandler into an empty-chunk
// spin that burned a full core.
private var commandFilePath: String {
  let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
  return (tmp as NSString).appendingPathComponent("TodoIslandMusic.cmd")
}

private func drainCommands() {
  guard
    let data = FileManager.default.contents(atPath: commandFilePath),
    !data.isEmpty
  else { return }
  fputs("DRAIN \(data.count)B path=\(commandFilePath)\n", stderr)
  // Truncate via FileHandle — FileManager.createFile is a no-op on an
  // existing file and silently left commands queued forever.
  if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: commandFilePath)) {
    defer { try? handle.close() }
    try? handle.truncate(atOffset: 0)
  }
  for lineData in data.split(separator: 0x0A) {
    let object = (try? JSONSerialization.jsonObject(with: Data(lineData))) as? [String: Any]
    guard let cmd = object?["cmd"] as? String else { continue }
    handleCommand(cmd, object ?? [:])
  }
}

private func handleCommand(_ cmd: String, _ payload: [String: Any]) {
  // Diagnostics: surfaces in the app's "helper raw" log lines.
  fputs("GOT cmd=\(cmd)\n", stderr)
  switch cmd {
  case "toggle", "play", "pause":
    postMediaKey(16)
  case "next":
    postMediaKey(17)
  case "previous":
    postMediaKey(18)
  case "seek":
    if let seconds = payload["t"] as? Double { setElapsedTimeFn(seconds) }
  case "active":
    active = payload["on"] as? Bool ?? true
  default:
    break
  }
  refresh()
}
