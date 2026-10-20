import Foundation

/// No sudoers rule or unrestricted privileged helper. Each session requires
/// macOS authorization and grants a fixed deadline to a root-owned launch job.
@MainActor
protocol KeepAwakeControlling {
  func begin(seconds: Int) async throws -> Date
  func requestStop()
  func status() -> String?
}

enum KeepAwakeError: LocalizedError {
  case unavailable, authorization(String), invalidDuration
  var errorDescription: String? {
    switch self {
    case .unavailable: return L10n.text("awake.error.unavailable")
    case .invalidDuration: return L10n.text("awake.error.duration")
    case .authorization(let detail):
      return detail.contains("-128") ? L10n.text("awake.error.cancelled") : L10n.text("awake.error.authorization")
    }
  }
}

@MainActor
final class KeepAwakeService: KeepAwakeControlling {
  static let maximumSeconds = 24 * 3600
  private let uid = getuid()
  private var requestURL: URL?
  private var base: String { "/Library/Application Support/Pulse/KeepAwake-\(uid)" }
  private var label: String { "com.fxl.Pulse.KeepAwake.\(uid)" }

  func begin(seconds: Int) async throws -> Date {
    guard (60...Self.maximumSeconds).contains(seconds) else { throw KeepAwakeError.invalidDuration }
    guard let source = Bundle.main.url(forResource: "KeepAwakeWatchdog", withExtension: "sh"),
      let watchdog = try? String(contentsOf: source, encoding: .utf8) else { throw KeepAwakeError.unavailable }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PulseKeepAwake-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let request = directory.appendingPathComponent("request")
    try Data("running".utf8).write(to: request, options: .atomic)
    requestURL = request
    let installer = Self.installer(watchdog: watchdog, base: base, label: label,
      request: request.path, pid: getpid(), uid: uid, seconds: seconds)
    do {
      let command = "/bin/sh -c " + Self.shellQuote(installer)
      let appleScript = "do shell script \(Self.appleScriptQuote(command)) with administrator privileges with prompt \(Self.appleScriptQuote(L10n.text("awake.authorization")))"
      try await Self.authorize(appleScript)
      let contents = try String(contentsOfFile: base + "/config", encoding: .utf8)
      guard let epoch = contents.split(separator: "\n").first.flatMap({ Double($0) }) else {
        throw KeepAwakeError.unavailable
      }
      return Date(timeIntervalSince1970: epoch)
    } catch {
      requestStop()
      throw error
    }
  }

  func requestStop() {
    if let requestURL { try? Data("stop".utf8).write(to: requestURL, options: .atomic) }
  }

  func status() -> String? {
    try? String(contentsOfFile: base + "/status", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Only trusted bundle content and shell-quoted values enter the installer.
  /// The root job never executes code from the app bundle after authorization.
  static func installer(watchdog: String, base: String, label: String, request: String,
                        pid: pid_t, uid: uid_t, seconds: Int) -> String {
    let plistPath = "/Library/LaunchDaemons/\(label).plist"
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Label</key><string>\(label)</string>
    <key>ProgramArguments</key><array><string>/bin/sh</string><string>\(base)/watchdog.sh</string><string>\(base)</string><string>\(label)</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>5</integer>
    <key>ProcessType</key><string>Background</string>
    </dict></plist>
    """
    return """
    set -eu
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    # Match process identity across the user locale and launchd environment.
    LC_ALL=C
    export LC_ALL
    base=\(shellQuote(base))
    plist=\(shellQuote(plistPath))
    # Refuse symlinks or writable ancestors before any privileged file write.
    for dir in '/Library' '/Library/Application Support' '/Library/Application Support/Pulse' "$base"; do
      [ ! -L "$dir" ] || exit 71
      if [ ! -e "$dir" ]; then mkdir -m 755 "$dir"; fi
      [ -d "$dir" ] && [ "$(/usr/bin/stat -f '%u' "$dir")" = 0 ] || exit 72
      mode=$(/usr/bin/stat -f '%Lp' "$dir")
      [ $((0$mode & 0022)) -eq 0 ] || exit 73
      # ACLs must not provide a second write path into the helper hierarchy.
      [ "$(/bin/ls -lde "$dir" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] || exit 74
    done
    [ ! -L "$plist" ] || exit 75
    [ ! -f "$base/owned" ] || exit 76
    /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
    umask 022
    printf '%s' \(shellQuote(watchdog)) > "$base/watchdog.sh"
    chmod 644 "$base/watchdog.sh"
    deadline=$(( $(/bin/date +%s) + \(seconds) ))
    started=$(/bin/ps -p \(pid) -o lstart=)
    [ -n "$started" ] || exit 77
    printf '%s\\n' "$deadline" '\(pid)' '\(uid)' "$started" \(shellQuote(request)) > "$base/config"
    printf '%s\\n' armed > "$base/status"
    printf '%s' \(shellQuote(plist)) > "$plist"
    chmod 644 "$plist"
    /bin/launchctl bootstrap system "$plist"
    """
  }

  static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  static func appleScriptQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n") + "\""
  }

  private static func authorize(_ script: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = FileHandle.nullDevice
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      process.terminationHandler = { process in
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 { continuation.resume() }
        else { continuation.resume(throwing: KeepAwakeError.authorization(error)) }
      }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
  }
}
