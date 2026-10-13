// Ported from wxtsky/CodeIsland (MIT License) — see TodoIsland/ThirdParty/CODEISLAND-LICENSE.txt
// (Sources/CodeIslandBridge/main.swift + the CLIProcessResolver / EventNormalizer /
// ProcArgsParser parts of CodeIslandCore, adapted for doisland)
//
// doisland adaptations (kept deliberately small):
// • Invoked directly as `<path>/agent-bridge [--source <source>] [--event <Event>]`
//   — no codeisland-hook.sh nc wrapper.
// • Socket: $DOISLAND_AGENTS_SOCKET_PATH, else /tmp/doisland-agents-<uid>.sock
//   (mirrors TodoIsland/Agents/Core/AgentSocketPath.swift).
// • Skip env renamed CODEISLAND_SKIP → DOISLAND_AGENTS_SKIP.
// • Dropped upstream integrations that doisland has no counterpart for: Grok /
//   Hermes / Antigravity / cmux / Herdr / Superset / Orca payloads, the Antigravity
//   pre-written decision, the Codex-Desktop ancestry bundle probe, and `_via_plugin`
//   marking. Ancestry-based source inference + `_ppid` resolution are kept.
// • Terminal environment is additionally captured in an `_env` dict so the GUI
//   app (which does not inherit the terminal's env) can resolve focus targets.
// • debugLog only writes when DOISLAND_AGENTS_DEBUG is set (raw prompts must not
//   land on disk by default); DOISLAND_BRIDGE_LOG relocates the file.
//
// Builds standalone: swiftc -swift-version 5 -O helpers/AgentHookBridge/main.swift

import Foundation
import Darwin

// MARK: - Global Safety Net

// Never let a broken pipe kill the bridge — just fail the write silently
signal(SIGPIPE, SIG_IGN)

// Hard deadline: if anything hangs beyond this, bail out cleanly.
// Non-blocking events keep an 8s alarm through the response wait; blocking
// (permission/question) events disarm it right before the long recv, since
// those legitimately wait for user interaction.
signal(SIGALRM) { _ in
    _exit(0)  // immediate, no cleanup — we're stuck anyway
}

// MARK: - Helper Functions

func debugLog(_ message: String) {
    let env = ProcessInfo.processInfo.environment
    guard env["DOISLAND_AGENTS_DEBUG"] != nil || env["DOISLAND_BRIDGE_LOG"] != nil else { return }
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    let path = env["DOISLAND_BRIDGE_LOG"] ?? "/tmp/doisland-bridge.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

func nonEmptyString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func detectTTY() -> String {
    let fd = open("/dev/tty", O_RDONLY | O_NOCTTY)
    if fd >= 0 {
        if let name = ttyname(fd) {
            close(fd)
            return String(cString: name)
        }
        close(fd)
    }
    return ""
}

func findBinary(_ name: String) -> String? {
    let searchPaths = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)",
    ]
    return searchPaths.first { access($0, X_OK) == 0 }
}

func runCommand(_ path: String, args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    } catch {
        return nil
    }
}

// MARK: - Process ancestry

func executablePath(for pid: pid_t) -> String? {
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    guard len > 0 else { return nil }
    return String(cString: pathBuffer)
}

func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard ret > 0, info.pbi_ppid > 0 else { return nil }
    return pid_t(info.pbi_ppid)
}

func buildAncestry(startingAt pid: pid_t, maxDepth: Int = 6) -> [(pid: pid_t, executablePath: String?)] {
    guard pid > 0 else { return [] }
    var result: [(pid: pid_t, executablePath: String?)] = []
    var current: pid_t? = pid
    var visited = Set<pid_t>()

    while let currentPid = current, currentPid > 0, result.count < maxDepth, !visited.contains(currentPid) {
        visited.insert(currentPid)
        result.append((pid: currentPid, executablePath: executablePath(for: currentPid)))
        current = parentPID(of: currentPid)
    }

    return result
}

/// Parser for the `KERN_PROCARGS2` sysctl buffer: `argc` (Int32), the exec
/// path, NUL padding, `argc` NUL-terminated argv strings, then the environment
/// as NUL-terminated `KEY=VALUE` strings up to an empty string.
/// (CodeIslandCore/HostHarness.swift ProcArgsParser, arguments-only)
enum ProcArgsParser {
    static func parse(_ buffer: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }

        var offset = intSize
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }  // exec path
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }  // padding

        func nextString() -> String? {
            guard offset < buffer.count else { return nil }
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
            let value = String(decoding: buffer[start..<offset], as: UTF8.self)
            offset += 1
            return value
        }

        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }
        return (arguments, [:])
    }
}

// MARK: - CLI source resolution (trimmed CLIProcessResolver)
//
// Mirrors the doisland source list in TodoIsland/Agents/Core/AgentSessionSnapshot.swift;
// the bridge is a standalone binary, so it carries its own reduced copy.

enum CLIProcessResolver {
    static let supportedSources: Set<String> = [
        "claude", "codex", "gemini", "cursor", "cursor-cli", "trae", "traecn",
        "traecli", "copilot", "qoder", "qoder-cli", "qoderwork", "droid",
        "codebuddy", "codybuddycn", "stepfun", "opencode", "mimo",
        "antigravity", "google-antigravity", "workbuddy", "hermes", "grok",
        "openclaw", "qwen", "kimi", "pi", "kiro", "cline", "dsh", "zcode",
        "aiwork", "aiwork-cli", "minimax",
    ]

    /// Desktop-IDE *host* sources are excluded from ancestry inference: their
    /// GUI host processes appear in the ancestry of any CLI run from the IDE's
    /// integrated terminal and would be greedily matched by the loose
    /// `/<source>` substring rule (CodeIsland #220).
    static let ideHostSources: Set<String> = [
        "cursor", "qoder", "qoderwork", "trae", "traecn", "codebuddy",
        "codybuddycn", "aiwork",
    ]

    static func normalizedSupportedSource(_ source: String?) -> String? {
        guard let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        if supportedSources.contains(trimmed) { return trimmed }
        // Common spellings the doisland list folds together.
        switch trimmed {
        case "claude-code", "claudecode": return "claude"
        case "codex-cli", "codexcli": return "codex"
        case "antigravity": return "google-antigravity"
        default: return nil
        }
    }

    static func sourceMatchesExecutablePath(_ path: String, source: String?) -> Bool {
        guard let normalizedSource = normalizedSupportedSource(source) else { return false }
        let lowercasedPath = path.lowercased()

        switch normalizedSource {
        case "codex":
            return lowercasedPath.hasSuffix("/codex") || lowercasedPath.contains("/codex ")
        case "claude":
            // The native installer (Claude Code's default) runs the binary
            // named by its version: ~/.local/share/claude/versions/2.1.294.
            return lowercasedPath.hasSuffix("/claude") || lowercasedPath.contains("/claude ")
                || lowercasedPath.contains("/.local/share/claude/versions/")
        case "qwen":
            return lowercasedPath.hasSuffix("/qwen")
                || lowercasedPath.hasSuffix("/qwen-code")
                || lowercasedPath.contains("/qwen ")
                || lowercasedPath.contains("/qwen-code ")
        case "gemini":
            return lowercasedPath.hasSuffix("/gemini") || lowercasedPath.contains("/gemini ")
        case "cursor-cli":
            // Cursor's CLI agent installs to ~/.local/share/cursor-agent/versions/<v>/cursor-agent
            return lowercasedPath.contains("/cursor-agent")
        case "qoder-cli":
            let basename = (lowercasedPath as NSString).lastPathComponent
            return lowercasedPath.hasSuffix("/qodercli")
                || lowercasedPath.contains("/qodercli ")
                || lowercasedPath.contains("/@qoder-ai/qodercli")
                || basename == "qoderclicn"
                || basename.hasPrefix("qoderclicn-")
        case "google-antigravity":
            return lowercasedPath.hasSuffix("/agy")
                || lowercasedPath.contains("/agy ")
                || lowercasedPath.contains("/google-antigravity")
        case "grok":
            // Managed Grok installs execute the versioned binary directly from
            // $GROK_HOME/downloads; package-manager installs expose a bare `grok`.
            let basename = (lowercasedPath as NSString).lastPathComponent
            return basename == "grok"
                || (basename.hasPrefix("grok-")
                    && (lowercasedPath.contains("/.grok/downloads/")
                        || lowercasedPath.contains("/grok/downloads/")))
        case "dsh":
            return lowercasedPath.hasSuffix("/dsh") || lowercasedPath.contains("/dsh ")
        case "traecli":
            return lowercasedPath.hasSuffix("/coco")
                || lowercasedPath.hasSuffix("/traecli")
                || lowercasedPath.contains("/coco ")
                || lowercasedPath.contains("/traecli ")
        default:
            return lowercasedPath.contains("/\(normalizedSource)")
        }
    }

    /// Walk the process ancestry and return the first known CLI source whose
    /// binary appears along the chain. Used when a hook event reaches the
    /// bridge without a `--source` tag, so the event is attributed to the CLI
    /// that fired it rather than to whichever hook path installed the command.
    static func inferSource(ancestry: [(pid: Int32, executablePath: String?)]) -> String? {
        // Try `-cli` variants first so `cursor-agent` isn't mis-attributed to
        // the desktop `cursor` source (CodeIsland #134).
        let all = supportedSources.subtracting(ideHostSources)
        let cliFirst = all.filter { $0.hasSuffix("-cli") }.sorted()
            + all.filter { !$0.hasSuffix("-cli") }.sorted()
        for entry in ancestry {
            guard let path = entry.executablePath, !path.isEmpty else { continue }
            for source in cliFirst {
                if sourceMatchesExecutablePath(path, source: source) {
                    return source
                }
            }
        }
        return nil
    }

    /// The PID the island should treat as the agent process. Some CLIs execute
    /// hooks through `sh -c`, so the immediate parent can be a transient shell;
    /// the first source-matching ancestor is the long-lived CLI process.
    static func resolvedTrackedPID(
        immediateParentPID: Int32,
        source: String?,
        ancestry: [(pid: Int32, executablePath: String?)]
    ) -> Int32 {
        guard immediateParentPID > 0 else { return immediateParentPID }
        if let directMatch = ancestry.first(where: {
            sourceMatchesExecutablePath($0.executablePath ?? "", source: source)
        }) {
            return directMatch.pid
        }
        return immediateParentPID
    }

    /// Stable per-session PID for fallback session_id generation. Walks the
    /// ancestry from root downward and picks the *highest* binary matching the
    /// source, so sub-agent processes spawned by the same parent CLI collapse
    /// onto a single session card instead of fanning into one per sub-agent
    /// ppid (CodeIsland #148).
    static func resolvedSessionPID(
        immediateParentPID: Int32,
        source: String?,
        ancestry: [(pid: Int32, executablePath: String?)]
    ) -> Int32 {
        guard immediateParentPID > 0 else { return immediateParentPID }
        if let rootMatch = ancestry.last(where: {
            sourceMatchesExecutablePath($0.executablePath ?? "", source: source)
        }) {
            return rootMatch.pid
        }
        return immediateParentPID
    }
}

// MARK: - Event name normalization
//
// (CodeIslandCore/EventNormalizer.swift, verbatim table — the island's reducer
// keys on these PascalCase names.)

enum EventNormalizer {
    static func normalize(_ name: String) -> String {
        switch name {
        // Cursor (camelCase)
        case "beforeSubmitPrompt":    return "UserPromptSubmit"
        case "beforeShellExecution":  return "PreToolUse"
        case "afterShellExecution":   return "PostToolUse"
        case "beforeReadFile":        return "PreToolUse"
        case "afterFileEdit":         return "PostToolUse"
        case "beforeMCPExecution":    return "PreToolUse"
        case "afterMCPExecution":     return "PostToolUse"
        case "afterAgentThought":     return "Notification"
        case "afterAgentResponse":    return "AfterAgentResponse"
        case "stop":                  return "Stop"
        // Gemini
        case "BeforeTool":            return "PermissionRequest"
        case "AfterTool":             return "PostToolUse"
        case "BeforeAgent":           return "SubagentStart"
        case "AfterAgent":            return "SubagentStop"
        // GitHub Copilot CLI
        case "sessionStart":          return "SessionStart"
        case "sessionEnd":            return "SessionEnd"
        case "userPromptSubmitted":   return "UserPromptSubmit"
        case "preToolUse":            return "PreToolUse"
        case "postToolUse":           return "PostToolUse"
        case "errorOccurred":         return "Notification"
        // Kiro CLI (camelCase, agent-scoped)
        case "agentSpawn":            return "SessionStart"
        case "userPromptSubmit":      return "UserPromptSubmit"
        // Traecli (snake_case)
        case "session_start":         return "SessionStart"
        case "session_end":           return "SessionEnd"
        case "user_prompt_submit":    return "UserPromptSubmit"
        case "pre_tool_use":          return "PreToolUse"
        case "post_tool_use":         return "PostToolUse"
        case "post_tool_use_failure": return "PostToolUseFailure"
        case "permission_request":    return "PermissionRequest"
        case "permission_denied":     return "PermissionDenied"
        // Grok emits StopFailure when a turn ends on an API error. It is still
        // terminal for Island state, so fold both wire spellings onto Stop.
        case "stop_failure", "StopFailure": return "Stop"
        case "subagent_start":        return "SubagentStart"
        case "subagent_stop":         return "SubagentStop"
        case "pre_compact":           return "PreCompact"
        case "post_compact":          return "PostCompact"
        case "notification":          return "Notification"
        // Hermes (Nous Research) — snake_case but diverged from Claude/Gemini.
        case "pre_tool_call":         return "PreToolUse"
        case "post_tool_call":        return "PostToolUse"
        case "pre_llm_call":          return "UserPromptSubmit"
        case "post_llm_call":         return "AgentTurnSettled"
        case "on_session_start":      return "SessionStart"
        case "on_session_end":        return "Stop"
        case "on_session_finalize":   return "SessionEnd"
        case "on_session_reset":      return "SessionEnd"
        // Cline (VSCode extension)
        case "TaskStart":             return "SessionStart"
        case "TaskResume":            return "UserPromptSubmit"
        case "TaskComplete":          return "TaskRoundComplete"
        case "TaskCancel":            return "TaskRoundComplete"
        default:                      return name
        }
    }
}

// MARK: - Socket I/O

func connectSocket(_ path: String, timeoutMs: Int32 = 3000) -> Int32? {
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { return nil }

    // Suppress per-write SIGPIPE on this socket (belt-and-suspenders with global SIG_IGN)
    var on: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
        path.withCString { _ = strcpy(ptr, $0) }
    }

    // Non-blocking connect with timeout — prevents hanging if the listener is stuck
    let origFlags = fcntl(sock, F_GETFL)
    _ = fcntl(sock, F_SETFL, origFlags | O_NONBLOCK)

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result != 0 && errno != EINPROGRESS {
        close(sock)
        return nil
    }

    if result != 0 {
        // Wait for connect to complete (or timeout)
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, timeoutMs)
        if ready <= 0 {
            close(sock)
            return nil
        }
        // Check for socket error
        var sockErr: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &errLen)
        if sockErr != 0 {
            close(sock)
            return nil
        }
    }

    // Restore blocking mode for send/recv
    _ = fcntl(sock, F_SETFL, origFlags)
    return sock
}

func sendAll(_ sock: Int32, data: Data) {
    data.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        var sent = 0
        while sent < buf.count {
            let n = send(sock, base + sent, buf.count - sent, 0)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            sent += n
        }
    }
}

func recvAll(_ sock: Int32) -> Data {
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(sock, &buf, buf.count, 0)
        if n < 0 {
            if errno == EINTR { continue }
            break
        }
        if n == 0 { break }
        response.append(contentsOf: buf[..<n])
    }
    return response
}

// MARK: - Main

let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments

// Socket path — same resolution as TodoIsland/Agents/Core/AgentSocketPath.swift
let socketPath = env["DOISLAND_AGENTS_SOCKET_PATH"] ?? "/tmp/doisland-agents-\(getuid()).sock"

// Parse --source flag (e.g. --source codex)
var sourceTag: String? = nil
if let idx = args.firstIndex(of: "--source"), idx + 1 < args.count {
    sourceTag = args[idx + 1]
}

// Parse --event flag (e.g. --event sessionStart) for CLIs that lack hook_event_name in stdin
var eventTag: String? = nil
if let idx = args.firstIndex(of: "--event"), idx + 1 < args.count {
    eventTag = args[idx + 1]
}

// Quick exit: skip if DOISLAND_AGENTS_SKIP is set
guard env["DOISLAND_AGENTS_SKIP"] == nil else { exit(0) }

// Quick exit: socket doesn't exist or isn't a socket
var statBuf = stat()
guard stat(socketPath, &statBuf) == 0, (statBuf.st_mode & S_IFMT) == S_IFSOCK else { exit(0) }

// Safety: arm a short alarm before reading stdin — if the calling process
// forgot to close its pipe, we bail out instead of blocking forever.
alarm(5)
let input = FileHandle.standardInput.readDataToEndOfFile()
alarm(0)  // stdin done, cancel preliminary alarm
let parsedInput = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
if let inputStr = String(data: input, encoding: .utf8) {
    debugLog("raw input: \(inputStr)")
}

guard !input.isEmpty, var json = parsedInput else {
    exit(0)
}

// Generic compatibility: accept common camelCase aliases from third-party forks
if json["hook_event_name"] == nil {
    if let event = nonEmptyString(json["hookEventName"]) {
        json["hook_event_name"] = event
    } else if let event = nonEmptyString(json["eventName"]) {
        json["hook_event_name"] = event
    } else if let event = nonEmptyString(json["event"]) {
        json["hook_event_name"] = event
    } else if let event = eventTag {
        json["hook_event_name"] = event
    }
}
if json["session_id"] == nil {
    if let sessionId = nonEmptyString(json["sessionId"]) {
        json["session_id"] = sessionId
    } else if let payload = json["payload"] as? [String: Any],
              let sessionId = nonEmptyString(payload["session_id"]) ?? nonEmptyString(payload["sessionId"]) {
        json["session_id"] = sessionId
    } else if let data = json["data"] as? [String: Any],
              let sessionId = nonEmptyString(data["session_id"]) ?? nonEmptyString(data["sessionId"]) {
        json["session_id"] = sessionId
    } else if let conversationId = nonEmptyString(json["conversationId"]) {
        json["session_id"] = conversationId
    }
}

// Bridge the camelCase `transcriptPath` spelling onto snake_case
// `transcript_path` (what the island's reader expects).
if json["transcript_path"] == nil, let tp = nonEmptyString(json["transcriptPath"]) {
    json["transcript_path"] = tp
}

// Copilot CLI adaptation: its stdin JSON lacks session_id and hook_event_name.
// Normalize Copilot's camelCase payload and pass through sessionId when present.
if sourceTag == "copilot" {
    if json["hook_event_name"] == nil, let event = eventTag {
        json["hook_event_name"] = event
    }
    if json["session_id"] == nil, let sessionId = nonEmptyString(json["sessionId"]) {
        json["session_id"] = sessionId
    }
    // Map Copilot-specific field names to internal conventions
    if let toolName = json["toolName"] as? String {
        json["tool_name"] = toolName
    }
    if let toolArgsStr = json["toolArgs"] as? String,
       let argsData = toolArgsStr.data(using: .utf8),
       let argsObj = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
        json["tool_input"] = argsObj
    }
}

// Cline adaptation: sends hookName and taskId instead of hook_event_name and session_id.
if sourceTag == "cline" {
    if json["hook_event_name"] == nil, let name = nonEmptyString(json["hookName"]) {
        json["hook_event_name"] = name
    }
    if json["session_id"] == nil, let taskId = nonEmptyString(json["taskId"]) {
        json["session_id"] = taskId
    }
    // Cline structures tool info as flat fields inside preToolUse/postToolUse objects:
    // PreToolUse:  { preToolUse:  { toolName: "execute_command", parameters: { ... } } }
    // PostToolUse: { postToolUse: { toolName: "execute_command", parameters: { ... }, result: ..., success: bool } }
    if json["tool_name"] == nil {
        if let preToolUse = json["preToolUse"] as? [String: Any],
           let toolName = nonEmptyString(preToolUse["toolName"] as? String) {
            json["tool_name"] = toolName
            if json["tool_input"] == nil, let parameters = preToolUse["parameters"] as? [String: Any] {
                json["tool_input"] = parameters
            }
        } else if let postToolUse = json["postToolUse"] as? [String: Any],
                  let toolName = nonEmptyString(postToolUse["toolName"] as? String) {
            json["tool_name"] = toolName
        }
    }
}

// Resolve process ancestry once — used for source inference when no --source
// was passed (e.g. Claude Code's own hook command) and for `_ppid` resolution
// downstream. Some CLIs execute hooks through `sh -c`, so `getppid()` can be a
// transient shell rather than the long-lived CLI process.
let immediateParentPID = getppid()
let ancestry = buildAncestry(startingAt: immediateParentPID)

// Source tag: declared `--source` wins; otherwise infer the real source from
// the process ancestry so the event is not misattributed to whichever hook
// path fired it (CodeIsland #95).
let effectiveSource = sourceTag ?? CLIProcessResolver.inferSource(ancestry: ancestry)
if let source = effectiveSource {
    json["_source"] = source
}

let resolvedTrackedPID = CLIProcessResolver.resolvedTrackedPID(
    immediateParentPID: immediateParentPID,
    source: effectiveSource,
    ancestry: ancestry
)
json["_ppid"] = resolvedTrackedPID
if resolvedTrackedPID != immediateParentPID {
    json["_hook_ppid"] = immediateParentPID
}
// Cline hooks are shell scripts spawned by a VSCode extension — the immediate
// parent is a transient shell, not a persistent agent process. Tracking this
// short-lived PID would make the island drop the session as soon as each hook
// returns. Clear it so no PID is tracked.
if effectiveSource == "cline" {
    json["_ppid"] = 0
}

// Validate: must have non-empty session_id
if json["session_id"] == nil,
   let source = sourceTag,
   !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    // Fallback for providers that don't include a stable session ID: use the
    // root same-source binary in the ancestry so sub-agent processes collapse
    // onto a single session card (CodeIsland #148).
    let sessionPID = CLIProcessResolver.resolvedSessionPID(
        immediateParentPID: immediateParentPID,
        source: effectiveSource ?? source,
        ancestry: ancestry
    )
    json["session_id"] = "\(source)-ppid-\(sessionPID)"
    debugLog("session_id missing, generated fallback id: \(json["session_id"] ?? "")")
}
guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
    debugLog("no session_id, dropping")
    exit(0)
}

// Event type detection
let eventName = json["hook_event_name"] as? String ?? ""
let normalizedEventName = EventNormalizer.normalize(eventName)
let isPermission = normalizedEventName == "PermissionRequest"
let isQuestion = (normalizedEventName == "Notification" || eventName == "afterAgentThought")
    && json["question"] as? String != nil
let isBlocking = isPermission || isQuestion

debugLog("event=\(eventName) normalized=\(normalizedEventName) session=\(sessionId) permission=\(isPermission) question=\(isQuestion)")

// Arm deadline for env collection + connect + send (protects all events).
// For blocking events, this is disarmed right before the long recvAll wait.
alarm(8)

// --- Terminal environment collection ---
// Terminal app identification (only include when present)
if let termApp = env["TERM_PROGRAM"], !termApp.isEmpty {
    json["_term_app"] = termApp
}
if let termBundle = env["__CFBundleIdentifier"], !termBundle.isEmpty {
    json["_term_bundle"] = termBundle
}

// iTerm2 session — extract GUID after "w0t0p0:" prefix for AppleScript matching
if let iterm = env["ITERM_SESSION_ID"], !iterm.isEmpty {
    if let colonIdx = iterm.firstIndex(of: ":") {
        json["_iterm_session"] = String(iterm[iterm.index(after: colonIdx)...])
    } else {
        json["_iterm_session"] = iterm
    }
}

// Kitty window
if let kitty = env["KITTY_WINDOW_ID"], !kitty.isEmpty {
    json["_kitty_window"] = kitty
}

// tmux detection — deep info collection
if let tmux = env["TMUX"], !tmux.isEmpty {
    json["_tmux"] = tmux
    if let pane = env["TMUX_PANE"], !pane.isEmpty {
        json["_tmux_pane"] = pane
        // Get client TTY — use explicit path (hook PATH may lack homebrew)
        if let tmuxBin = findBinary("tmux"),
           let clientTTY = runCommand(tmuxBin, args: ["display-message", "-p", "-t", pane, "-F", "#{client_tty}"]) {
            json["_tmux_client_tty"] = clientTTY
        }
    }
}

// Zellij multiplexer detection
if let zellij = env["ZELLIJ"], !zellij.isEmpty {
    json["_zellij"] = zellij
}

// WezTerm / Kaku pane id — both forks set WEZTERM_PANE
if let weztermPane = env["WEZTERM_PANE"], !weztermPane.isEmpty {
    json["_wezterm_pane"] = weztermPane
}

// The island app is a GUI process and does not inherit the terminal's env, so
// the raw terminal variables ride along in `_env` for focus resolution.
let terminalEnvKeys = [
    "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "__CFBundleIdentifier",
    "ITERM_SESSION_ID", "KITTY_WINDOW_ID", "TMUX", "TMUX_PANE",
    "ZELLIJ", "ZELLIJ_PANE_ID", "WEZTERM_PANE", "WEZTERM_UNIX_SOCKET",
]
var terminalEnv: [String: String] = [:]
for key in terminalEnvKeys {
    if let value = env[key], !value.isEmpty {
        terminalEnv[key] = value
    }
}
if !terminalEnv.isEmpty {
    json["_env"] = terminalEnv
}

// TTY path
let tty = detectTTY()
if !tty.isEmpty {
    json["_tty"] = tty
}

// Inject cwd if not already present, so the island can resolve the project
// name even for CLIs whose payload omits it.
if json["cwd"] == nil {
    json["cwd"] = FileManager.default.currentDirectoryPath
}

// --- Serialize enriched JSON ---
guard let enriched = try? JSONSerialization.data(withJSONObject: json) else { exit(0) }

// --- Connect to Unix socket ---
guard let sock = connectSocket(socketPath, timeoutMs: 3000) else {
    debugLog("socket connect failed")
    exit(0)
}

// Set socket timeouts: blocking events wait up to a day for the user's
// decision; everything else must answer fast and gets discarded anyway.
var sendTv = timeval(tv_sec: isBlocking ? 86400 : 3, tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &sendTv, socklen_t(MemoryLayout<timeval>.size))
var recvTv = timeval(tv_sec: isBlocking ? 86400 : 3, tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &recvTv, socklen_t(MemoryLayout<timeval>.size))

// Send enriched event data
sendAll(sock, data: enriched)

// Signal end of write (half-close → server sees EOF)
shutdown(sock, SHUT_WR)

// Blocking events wait for user interaction (minutes/hours) — disarm the deadline.
// Non-blocking events keep the alarm; SO_RCVTIMEO (3s) + alarm(8) double-protect.
if isBlocking {
    alarm(0)
}

// Wait for server response — critical: without this, close() races ahead
// of the listener's main-thread handler and the event is lost
let response = recvAll(sock)

// Blocking events: forward the server's response to stdout (the CLI's
// permission prompt / question answer).
if isBlocking && !response.isEmpty {
    FileHandle.standardOutput.write(response)
}

close(sock)
exit(0)
