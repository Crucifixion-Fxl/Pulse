import AVFoundation
import Foundation
import OSLog

/// One wake invocation owns one child process and its audio devices. The bound
/// account remains in Application Support; no credentials cross the stdio pipe.
@MainActor
final class XiaozhiVoiceSession {
  enum State: String, Decodable { case connecting, switching, listening, thinking, speaking, stopped }
  struct Event: Decodable {
    let type: String
    var state: State?
    var input: Double?
    var output: Double?
    var code: String?
    var inputDevice: String?
    var outputDevice: String?
  }

  var onState: ((State) -> Void)?
  var onLevel: ((Double, Double) -> Void)?
  var onError: ((String) -> Void)?
  private var process: Process?
  private var input: Pipe?
  private var output: Pipe?
  private var buffer = Data()
  private var generation = 0
  private var active = false
  private let audioRoutes = VoiceAudioRouteMonitor()
  private var startupTimeout: Task<Void, Never>?
  private static let log = Logger(subsystem: "com.fxl.TodoIsland", category: "Voice")

  func start() {
    guard !active else { return }
    active = true
    generation += 1
    let token = generation
    onState?(.connecting)
    Task { [weak self] in
      let allowed: Bool
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized: allowed = true
      case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
      default: allowed = false
      }
      guard let self, self.active, self.generation == token else { return }
      guard allowed else { self.fail("microphone"); return }
      self.launch(token: token)
    }
  }

  private func launch(token: Int) {
    let base = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/PulseVoice", isDirectory: true)
    let runtime = base.appendingPathComponent("py-xiaozhi", isDirectory: true)
    let python = runtime.appendingPathComponent(".venv/bin/python")
    guard FileManager.default.isExecutableFile(atPath: python.path),
      let bridge = Bundle.main.url(forResource: "xiaozhi_voice_bridge", withExtension: "py") else {
      fail("not_installed"); return
    }
    let child = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    child.executableURL = python
    child.arguments = ["-u", bridge.path, runtime.path, base.appendingPathComponent("data").path]
    child.currentDirectoryURL = runtime
    var environment = ProcessInfo.processInfo.environment
    environment["PYTHONUNBUFFERED"] = "1"
    environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    child.environment = environment
    child.standardInput = stdin
    child.standardOutput = stdout
    child.standardError = FileHandle.nullDevice
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task { @MainActor [weak self] in
        guard let self, self.generation == token else { return }
        self.receive(data)
      }
    }
    child.terminationHandler = { [weak self] child in
      Task { @MainActor [weak self] in
        guard let self, self.generation == token, self.active else { return }
        Self.log.info("Voice worker exited status=\(child.terminationStatus)")
        self.fail("disconnected")
      }
    }
    process = child
    input = stdin
    output = stdout
    do {
      try child.run()
      audioRoutes.start { [weak self] in
        guard let self, self.generation == token, self.active,
          let handle = self.input?.fileHandleForWriting else { return }
        do { try handle.write(contentsOf: Data("{\"type\":\"route_changed\"}\n".utf8)) }
        catch { self.fail("audio") }
      }
      Self.log.info("Voice worker started pid=\(child.processIdentifier)")
      startupTimeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled, let self, self.generation == token else { return }
        self.fail("timeout")
      }
    } catch { fail("unavailable") }
  }

  private func receive(_ data: Data) {
    buffer.append(data)
    // Only small, newline-delimited state and amplitude messages are accepted.
    guard buffer.count < 64 * 1024 else { fail("protocol"); return }
    while let end = buffer.firstIndex(of: 10) {
      let line = buffer.prefix(upTo: end)
      buffer.removeSubrange(...end)
      guard let event = try? JSONDecoder().decode(Event.self, from: line) else { continue }
      switch event.type {
      case "state":
        guard let state = event.state else { continue }
        if state == .listening { startupTimeout?.cancel(); startupTimeout = nil }
        if state == .stopped { stop(); return }
        Self.log.info("Voice state=\(state.rawValue, privacy: .public)")
        onState?(state)
      case "route":
        Self.log.info("Voice route input=\(event.inputDevice ?? "?", privacy: .private) output=\(event.outputDevice ?? "?", privacy: .private)")
      case "level":
        onLevel?(Self.clamp(event.input), Self.clamp(event.output))
      case "error":
        fail(event.code ?? "unavailable")
        return
      default: break
      }
    }
  }

  static func clamp(_ value: Double?) -> Double {
    guard let value, value.isFinite else { return 0 }
    return min(1, max(0, value))
  }

  private func fail(_ code: String) {
    Self.log.error("Voice failure=\(code, privacy: .public)")
    stop()
    onError?(code)
  }

  func stop() {
    audioRoutes.stop()
    generation += 1
    active = false
    startupTimeout?.cancel()
    startupTimeout = nil
    output?.fileHandleForReading.readabilityHandler = nil
    try? input?.fileHandleForWriting.close()
    let child = process
    child?.terminationHandler = nil
    if let child, child.isRunning {
      child.terminate()
      // A stuck decoder cannot keep recording after the wake surface closes.
      Task.detached {
        try? await Task.sleep(for: .seconds(2))
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
      }
    }
    process = nil
    input = nil
    output = nil
    buffer.removeAll(keepingCapacity: false)
    onLevel?(0, 0)
    Self.log.info("Voice stop requested")
  }

  isolated deinit {
    audioRoutes.stop()
    startupTimeout?.cancel()
    output?.fileHandleForReading.readabilityHandler = nil
    try? input?.fileHandleForWriting.close()
    if let process, process.isRunning { process.terminate() }
  }
}
