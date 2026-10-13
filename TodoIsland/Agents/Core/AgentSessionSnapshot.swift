// Ported from wxtsky/CodeIsland (MIT License) — see ThirdParty/CODEISLAND-LICENSE.txt
// (Sources/CodeIslandCore/SessionSnapshot.swift, trimmed)
//
// Trimmed relative to upstream:
// - Agent-task checklist (AgentTaskList / AgentTaskHookParser) and SessionRecap —
//   the reducer's calls into them are dropped; everything else in an event's
//   path is kept.
// - Hermes payload/store parsing (HermesHookPayload, HermesSessionStore): the
//   two hermesHooksReport* flags are kept, but the one-shot-removal /
//   endsInterruptedTurn / isQuiet / hermesChatElsewhere branches are compiled
//   out (their predicates are constant false here).
// - Custom CLI sources loaded from UserDefaults (Settings dependency).
// - Terminal multiplexer / window-activation identity (cmux, zellij, WezTerm,
//   herdr, Superset, Orca, hostHarness) and the display helpers that consume
//   them. Common terminal identity (termApp, bundle id, iTerm, tty, kitty,
//   tmux) is kept because the reducer writes it.
// - Cursor display-name path decoding (NSCache memoization): displayName uses
//   the simple last-component fallback.
// The reducer `reduceEvent`, `AgentSideEffect`, the isWaiting guard, subagent
// tombstones, the interrupted/lastTurnFailed handling and the completion
// enqueue effects are ported faithfully.

import Foundation

struct AgentSessionSnapshot: Sendable {
    static let supportedSources: Set<String> = [
        "claude",
        "codex",
        "gemini",
        "cursor",
        "cursor-cli",
        "trae",
        "traecn",
        "traecli",
        "copilot",
        "qoder",
        "qoder-cli",
        "qoderwork",
        "droid",
        "codebuddy",
        "codybuddycn",
        "stepfun",
        "opencode",
        // MiMo Code (Xiaomi's OpenCode 1.x fork) and the Xiaomi MiMo desktop
        // app, which runs MiMo Code as its engine — one plugin feeds both.
        "mimo",
        "antigravity",
        "google-antigravity",
        "workbuddy",
        "hermes",
        "grok",
        "openclaw",
        "qwen",
        "kimi",
        "pi",
        "kiro",
        "cline",
        "dsh",
        "zcode",
        "aiwork",
        "aiwork-cli",
        "minimax",
    ]

    static let ideCompletionSources: Set<String> = [
        "cursor",
        "cursor-cli",
        "qoder",
        "qoder-cli",
        "trae",
        "traecn",
        "codebuddy",
        "codybuddycn",
    ]

    var status: AgentStatus = .idle
    var currentTool: String?
    var toolDescription: String?
    var lastActivity: Date = Date()
    var cwd: String?
    var model: String?
    var permissionMode: String?
    var toolHistory: [ToolHistoryEntry] = []
    var totalToolCallCount: Int = 0
    var subagents: [String: SubagentState] = [:]
    /// Agent ids closed by SubagentStop/Stop/SessionEnd, in insertion order
    /// (newest last). Blocks merge/fold from putting a finished subagent back
    /// on the parent. Live growth is capped at ``maxClosedSubagentIds``;
    /// restored lists may be larger (see ``restoreClosedSubagentIds``).
    /// Mutate only via ``recordClosedSubagentId``, ``clearClosedSubagentId``,
    /// or ``restoreClosedSubagentIds`` so the live cap cannot be bypassed.
    private(set) var closedSubagentIds: [String] = []
    /// O(1) membership mirror of ``closedSubagentIds`` for hot-path tombstone checks.
    private var closedSubagentIdSet: Set<String> = []
    /// Bound for *live* ``closedSubagentIds`` growth in long-lived Cursor sessions.
    /// Persist restore does not apply this cap (see ``restoreClosedSubagentIds``).
    static let maxClosedSubagentIds = 256
    var startTime: Date = Date()
    var lastUserPrompt: String?
    var lastAssistantMessage: String?
    /// Public assistant text emitted during the active Codex turn. This is
    /// transient UI state: a new turn clears it while chat history remains.
    var liveCodexOutput: String?
    /// Absolute path to the JSONL transcript currently backing this session.
    var transcriptPath: String?
    /// Recent chat messages (max 3) for preview
    var recentMessages: [ChatMessage] = []
    // Terminal info for window activation
    var termApp: String?        // "iTerm.app", "Apple_Terminal", etc.
    var itermSessionId: String?  // iTerm2 session ID for direct activation
    var ttyPath: String?         // /dev/ttys00X
    var kittyWindowId: String?   // Kitty window ID for precise focus
    var tmuxPane: String?        // tmux pane identifier (%0, %1, etc.)
    var tmuxClientTty: String?   // tmux client TTY for real terminal detection
    var tmuxEnv: String?         // raw TMUX env var (socket info for non-default tmux server)
    var termBundleId: String?    // __CFBundleIdentifier for precise terminal ID
    /// Claude Desktop's own id for a Code-tab session (`local_…`, from
    /// CLAUDE_CODE_HOST_SESSION_ID).
    var claudeDesktopSessionId: String?
    var cliPid: pid_t?            // CLI process PID (from bridge _ppid)
    var cliStartTime: Date?       // Start time of the tracked CLI PID (guards PID reuse)
    var source: String = "claude" // "claude" or "codex"
    var interrupted: Bool = false
    /// The last turn ended on an error (Claude Code / Grok `StopFailure`, a
    /// failed AiWork stream or Cowork turn); the card's status reads ERROR
    /// until the next prompt. Set by the completion executor. Transient.
    var lastTurnFailed: Bool = false
    /// Cline-specific: true after TaskComplete/TaskCancel until the next TaskStart/TaskResume.
    /// Cline runs hooks asynchronously (background bridge), so events from prior tools can
    /// arrive after a TaskCancel and revive the session. This flag drops those stale events.
    var taskRoundEnded: Bool = false
    var sessionTitle: String?
    var providerSessionId: String?
    var remoteHostId: String?
    var remoteHostName: String?
    /// When a hook last reported `model`. An attach-time transcript backfill
    /// must not replace it with a model from an older line
    /// (`claude --resume --model X` over a transcript that ran on Y).
    var modelReportedAt: Date?
    /// Hermes hooks reported this card's prompts (`pre_llm_call`) / replies
    /// (`post_llm_call`) themselves. Transient, never persisted.
    var hermesHooksReportPrompts = false
    var hermesHooksReportReplies = false

    init(startTime: Date = Date()) {
        self.startTime = startTime
    }

    /// Record a closed subagent/Task id (no-op if already present). Evicts the
    /// oldest entries when over ``maxClosedSubagentIds``.
    mutating func recordClosedSubagentId(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !closedSubagentIdSet.contains(trimmed) else { return }
        closedSubagentIds.append(trimmed)
        closedSubagentIdSet.insert(trimmed)
        let overflow = closedSubagentIds.count - Self.maxClosedSubagentIds
        if overflow > 0 {
            for evicted in closedSubagentIds.prefix(overflow) {
                closedSubagentIdSet.remove(evicted)
            }
            closedSubagentIds.removeFirst(overflow)
        }
    }

    /// Drop a tombstone so the agent/Task may be folded or shown again.
    /// Trims like ``recordClosedSubagentId`` so whitespace-padded ids clear.
    mutating func clearClosedSubagentId(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard closedSubagentIdSet.remove(trimmed) != nil else { return }
        closedSubagentIds.removeAll { $0 == trimmed }
    }

    /// O(1) tombstone check used on the subagent hook hot path.
    /// Trims like ``recordClosedSubagentId`` / ``clearClosedSubagentId``.
    func hasClosedSubagentId(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return closedSubagentIdSet.contains(trimmed)
    }

    /// Restore persisted ids in file order **without** applying the live cap.
    ///
    /// Pre-cap builds wrote this array via `Set.sorted()` (lexicographic) — that
    /// order is not recency, so keep-last-N on restore would drop arbitrary
    /// tombstones and allow finished Tasks to re-fold. Disk size already bounds
    /// memory; ``recordClosedSubagentId`` still caps *new* live growth.
    mutating func restoreClosedSubagentIds(_ ids: [String]) {
        closedSubagentIds = []
        closedSubagentIdSet = []
        closedSubagentIds.reserveCapacity(ids.count)
        closedSubagentIdSet.reserveCapacity(ids.count)
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !closedSubagentIdSet.contains(trimmed) else { continue }
            closedSubagentIds.append(trimmed)
            closedSubagentIdSet.insert(trimmed)
        }
    }

    static func normalizedSupportedSource(_ source: String?) -> String? {
        guard let source else { return nil }
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        let aliases: [String: String] = [
            "factory": "droid",
            "ag": "antigravity",
            "anti-gravity": "antigravity",
            "anti gravity": "antigravity",
            // Google Antigravity (Gemini-based IDE/CLI). A SEPARATE product from
            // the "antigravity" Claude-Code fork above — it reads
            // ~/.gemini/config/hooks.json, not .antigravity/settings.json. Keep
            // the "ag"/"anti-gravity" aliases pointed at the fork; only these
            // explicit google-prefixed / -ide variants resolve here (#215).
            "googleantigravity": "google-antigravity",
            "google antigravity": "google-antigravity",
            "google-anti-gravity": "google-antigravity",
            "antigravity-ide": "google-antigravity",
            "antigravity-cli": "google-antigravity",
            "agy": "google-antigravity",
            "work-buddy": "workbuddy",
            "work body": "workbuddy",
            "work-body": "workbuddy",
            "workbody": "workbuddy",
            "hermes-agent": "hermes",
            "hermes-agents": "hermes",
            "hermes agent": "hermes",
            "hermes agents": "hermes",
            "grok-cli": "grok",
            "grokcli": "grok",
            "grok-build": "grok",
            "grok build": "grok",
            // OpenClaw (openclaw.ai) — personal-assistant Gateway daemon,
            // formerly branded Clawdbot. Keep the old name as an alias so
            // events from a not-yet-renamed install land on the same source.
            "open-claw": "openclaw",
            "open claw": "openclaw",
            "clawdbot": "openclaw",
            "qwen-code": "qwen",
            "qwencode": "qwen",
            "cursor-agent": "cursor-cli",
            "cursoragent": "cursor-cli",
            "cursorcli": "cursor-cli",
            "qodercli": "qoder-cli",
            // Qoder 国行 (China build): a separate `qoderclicn` binary rooted at
            // ~/.qoder-cn, but the same Claude-format hook contract as the
            // international CLI — so it shares the qoder-cli source (#289).
            "qoderclicn": "qoder-cli",
            "qodercli-cn": "qoder-cli",
            "qoder-cn": "qoder-cli",
            // AiWork (formerly DTCoder) — the pre-rename spelling and the
            // no-separator CLI variants normalise onto the `aiwork*` keys.
            "dtcoder": "aiwork",
            "dtcoder-cli": "aiwork-cli",
            "dtcodercli": "aiwork-cli",
            "aiworkcli": "aiwork-cli",
            "qodercn": "qoder-cli",
            // QoderWork — Qoder's standalone desktop assistant app (not the
            // IDE); own hooks file at ~/.qoderwork/settings.json (#249).
            "qoder-work": "qoderwork",
            "qoder work": "qoderwork",
            "kimi-cli": "kimi",
            "kimicli": "kimi",
            "kimi-code": "kimi",
            "kimicode": "kimi",
            "kimi_code": "kimi",
            "kimi-code-cli": "kimi",
            "kimicodecli": "kimi",
            "kimi_code_cli": "kimi",
            "kiro-cli": "kiro",
            "kirocli": "kiro",
            "codebuddycn": "codybuddycn",
            "codybuddy-cn": "codybuddycn",
            "step-fun": "stepfun",
            "step fun": "stepfun",
            "trae-cn": "traecn",
            "trae_cn": "traecn",
            "trae cn": "traecn",
            "traecli": "traecli",
            "omp": "pi",
            "oh-my-pi": "pi",
            "oh my pi": "pi",
            "z-code": "zcode",
            "z code": "zcode",
            // MiniMax Code CLI — the executable is `mcode` (npm @minimax-ai/code)
            // and the Node runtime renames the process title to `minimax-code`,
            // so both spellings (and the product name) normalize onto `minimax`.
            "mcode": "minimax",
            "minimax-code": "minimax",
            "minimaxcode": "minimax",
            "minimax-cli": "minimax",
            "minimaxcli": "minimax",
            "minimax-code-cli": "minimax",
            // MiMo Code (`mimo` CLI, npm @mimo-ai/cli) and the Xiaomi MiMo
            // desktop app share one source: the app's engine is MiMo Code.
            // No prefix rule — "mimo…" is too short a stem to claim.
            "mimocode": "mimo",
            "mimo-code": "mimo",
            "mimo_code": "mimo",
            "mimo code": "mimo",
            "mimo-cli": "mimo",
            "mimocli": "mimo",
            "mimo-desktop": "mimo",
            "mimodesktop": "mimo",
            "xiaomi-mimo": "mimo",
            "xiaomimimo": "mimo",
            "xiaomi mimo": "mimo",
            "xiaomi-mimo-ai": "mimo",
        ]
        let canonical = aliases[normalized] ?? normalized

        if supportedSources.contains(canonical) { return canonical }
        // Match Google Antigravity variants BEFORE the bare "antigravity" prefix
        // clause below, so a "google-antigravity-*" sub-brand never falls through
        // to the Claude-fork source.
        if canonical.hasPrefix("google-antigravity") || canonical.hasPrefix("googleantigravity") { return "google-antigravity" }
        if canonical.hasPrefix("antigravity") { return "antigravity" }
        if canonical.hasPrefix("workbuddy") { return "workbuddy" }
        if canonical.hasPrefix("hermes") { return "hermes" }
        if canonical.hasPrefix("grok") { return "grok" }
        if canonical.hasPrefix("openclaw") { return "openclaw" }
        if canonical.hasPrefix("qwen") { return "qwen" }
        if canonical.hasPrefix("kiro") { return "kiro" }
        if canonical.hasPrefix("kimi") { return "kimi" }
        if canonical.hasPrefix("minimax") { return "minimax" }
        if canonical.hasPrefix("codybuddycn") || canonical.hasPrefix("codebuddycn") { return "codybuddycn" }
        if canonical.hasPrefix("stepfun") { return "stepfun" }
        if canonical.hasPrefix("traecn") { return "traecn" }
        if canonical.hasPrefix("traecli") { return "traecli" }
        if canonical.hasPrefix("trae") { return "trae" }
        return nil
    }

    var activeSubagentCount: Int {
        subagents.values.filter { $0.status != .idle }.count
    }

    mutating func addRecentMessage(_ msg: ChatMessage, maxCount: Int = 3) {
        recentMessages.append(msg)
        if recentMessages.count > maxCount {
            recentMessages.removeFirst(recentMessages.count - maxCount)
        }
    }

    mutating func insertRecentMessage(_ msg: ChatMessage, at index: Int, maxCount: Int = 3) {
        recentMessages.insert(msg, at: index)
        if recentMessages.count > maxCount {
            recentMessages.removeFirst(recentMessages.count - maxCount)
        }
    }

    mutating func recordTool(_ tool: String, description: String?, success: Bool, agentType: String?, maxHistory: Int) {
        totalToolCallCount += 1
        let entry = ToolHistoryEntry(tool: tool, description: description, timestamp: Date(), success: success, agentType: agentType)
        toolHistory.append(entry)
        if toolHistory.count > maxHistory {
            toolHistory.removeFirst()
        }
    }

    /// Display name: project folder, or short session ID
    var displayName: String {
        guard let cwd = cwd else { return "Session" }
        let last = (cwd as NSString).lastPathComponent
        // If last component is a timestamp/numeric ID (e.g. CodeBuddy "20260406010126"),
        // show the parent directory name instead
        if last.count >= 8 && last.allSatisfy(\.isNumber) {
            let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty && parent != "/" { return parent }
        }
        return last
    }

    /// Directory names that are agent metadata, not user projects. Only these
    /// exact dot-dirs are treated as unhelpful — legitimate dot-named
    /// repos (.dotfiles, .config, .emacs.d) must keep their own name.
    static let agentMetadataDirNames: Set<String> = [
        ".claude", ".cursor", ".codex", ".gemini", ".qoder", ".qoder-cn", ".qoderwork",
        ".trae", ".trae-cn", ".kiro", ".copilot", ".factory", ".codebuddy",
        ".codybuddycn", ".stepfun", ".workbuddy", ".hermes", ".kimi", ".kimi-code",
        ".grok", ".pi", ".omp", ".qwen", ".zcode", ".openclaw",
    ]

    /// Hook/bridge cwd values that carry no project identity — getcwd() inside
    /// `~/.claude` or at `$HOME` must not block workspace_roots / transcript_path.
    static func isUnhelpfulHookCwd(_ cwd: String) -> Bool {
        if isHomeDirectoryPath(cwd) { return true }
        let last = (cwd as NSString).lastPathComponent
        guard agentMetadataDirNames.contains(last) else { return false }
        return isHomeDirectoryPath((cwd as NSString).deletingLastPathComponent)
    }

    static func isHomeDirectoryPath(_ path: String) -> Bool {
        let home = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).standardizingPath
        return (path as NSString).standardizingPath == home
    }

    static func isHomeDirectoryBasename(_ name: String, for cwd: String) -> Bool {
        name == (FileManager.default.homeDirectoryForCurrentUser.path as NSString).lastPathComponent
            && (isHomeDirectoryPath(cwd) || isUnhelpfulHookCwd(cwd))
    }

    func displayTitle(sessionId: String) -> String {
        sessionLabel ?? sessionId
    }

    func displaySessionId(sessionId: String) -> String {
        if let providerSessionId {
            let trimmed = providerSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return sessionId
    }

    var isRemote: Bool {
        guard let remoteHostId else { return false }
        return !remoteHostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var remoteDisplayName: String? {
        guard let remoteHostName else { return nil }
        let trimmed = remoteHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var sessionLabel: String? {
        guard let sessionTitle else { return nil }
        let trimmed = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shortened model name: "claude-opus-4-6" → "opus"
    var shortModelName: String? {
        guard let model = model else { return nil }
        let lower = model.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        if lower.contains("gemini") { return "gemini" }
        if let last = model.split(separator: "-").last, last.count <= 8 {
            return String(last)
        }
        return String(model.prefix(8))
    }

    /// Source label for display
    var sourceLabel: String {
        switch source {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "cursor": return "Cursor"
        case "cursor-cli": return "Cursor CLI"
        case "trae": return "Trae"
        case "traecn": return "Trae CN"
        case "traecli": return "Traecli"
        case "qoder": return termBundleId == "com.qoder.ide" ? "Qoder IDE" : "Qoder"
        case "qoder-cli": return "Qoder CLI"
        case "qoderwork": return "QoderWork"
        case "droid": return "Factory"
        case "codebuddy": return "CodeBuddy"
        case "codybuddycn": return "CodyBuddyCN"
        case "stepfun": return "StepFun"
        case "opencode": return "OpenCode"
        case "mimo": return "MiMo"
        case "antigravity": return "AntiGravity"
        case "google-antigravity": return "Google Antigravity"
        case "workbuddy": return "WorkBuddy"
        case "hermes": return "Hermes"
        case "grok": return "Grok CLI"
        case "openclaw": return "OpenClaw"
        case "qwen": return "Qwen Code"
        case "kimi": return "Kimi Code CLI"
        case "pi": return "Pi"
        case "kiro": return "Kiro"
        case "cline": return "Cline"
        case "zcode": return "ZCode"
        case "aiwork": return "AiWork"
        case "aiwork-cli": return "AiWork CLI"
        case "minimax": return "MiniMax Code CLI"
        default:
            return source.capitalized
        }
    }

    var isCodex: Bool { source == "codex" }
    var isClaude: Bool { source == "claude" }

    /// Subtitle: cwd path or model info
    var subtitle: String? {
        if let cwd = cwd {
            // Show parent/folder instead of just folder
            let parts = cwd.split(separator: "/")
            let pathText: String
            if parts.count >= 2 {
                pathText = "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
            } else {
                pathText = cwd
            }
            if let remote = remoteDisplayName {
                return "\(pathText) · \(remote)"
            }
            return pathText
        }
        if let remote = remoteDisplayName {
            return remote
        }
        return model
    }
}

struct SessionSummary: Sendable {
    let status: AgentStatus
    let primarySource: String
    let activeSessionCount: Int
    let totalSessionCount: Int

    init(status: AgentStatus, primarySource: String, activeSessionCount: Int, totalSessionCount: Int) {
        self.status = status
        self.primarySource = primarySource
        self.activeSessionCount = activeSessionCount
        self.totalSessionCount = totalSessionCount
    }
}

func deriveSessionSummary(from sessions: [String: AgentSessionSnapshot]) -> SessionSummary {
    var highestStatus: AgentStatus = .idle
    var source = "claude"
    var active = 0
    var mostRecentIdleSource: (source: String, time: Date)?

    for session in sessions.values {
        if session.status != .idle {
            active += 1
        } else if mostRecentIdleSource == nil || session.lastActivity > mostRecentIdleSource!.time {
            mostRecentIdleSource = (session.source, session.lastActivity)
        }

        switch session.status {
        case .waitingApproval:
            highestStatus = .waitingApproval
            source = session.source
        case .waitingQuestion:
            if highestStatus != .waitingApproval {
                highestStatus = .waitingQuestion
                source = session.source
            }
        case .running:
            if highestStatus == .idle || highestStatus == .processing {
                highestStatus = .running
                source = session.source
            }
        case .processing:
            if highestStatus == .idle {
                highestStatus = .processing
                source = session.source
            }
        case .idle:
            break
        }
    }

    if highestStatus == .idle, let idleSource = mostRecentIdleSource?.source {
        source = idleSource
    }

    return SessionSummary(
        status: highestStatus,
        primarySource: source,
        activeSessionCount: active,
        totalSessionCount: sessions.count
    )
}

// MARK: - Side Effects

enum AgentSideEffect: Equatable {
    case playSound(String)
    case tryMonitorSession(sessionId: String)
    case stopMonitor(sessionId: String)
    case removeSession(sessionId: String)
    case enqueueCompletion(sessionId: String)
    case setActiveSession(sessionId: String?)
}

// MARK: - Pure Reducer

/// Pure reducer: mutates sessions, returns side effects for the caller to execute.
func reduceEvent(
    sessions: inout [String: AgentSessionSnapshot],
    event: HookEvent,
    maxHistory: Int,
    replyCompletePlaceholder: String = "Reply complete"
) -> [AgentSideEffect] {
    let sessionId = event.sessionId ?? "default"
    let eventName = EventNormalizer.normalize(event.eventName)
    var effects: [AgentSideEffect] = []

    // Ensure session exists
    if sessions[sessionId] == nil {
        sessions[sessionId] = AgentSessionSnapshot()
    }

    // Always update metadata from parent events. Subagent events are routed
    // through the parent session ID, so applying their full metadata here would
    // overwrite the parent's model/transcript/title with child-session values.
    // Still fill *missing* identity fields so a merge-first Task hook does not
    // leave the parent stuck as the default `source == "claude"`.
    if event.agentId == nil {
        extractMetadata(into: &sessions, sessionId: sessionId, event: event)
    } else {
        fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
    }
    let isRemote = sessions[sessionId]?.isRemote == true

    // Cline ships hooks via shell scripts that spawn the bridge in the background,
    // so events for the same session can arrive out of order. Once a task round
    // ends (TaskComplete/TaskCancel), drop any in-flight tool events that race in
    // afterwards — they would otherwise revive the session into .processing/.running.
    // The next TaskStart (SessionStart) or TaskResume (UserPromptSubmit) clears the flag.
    if sessions[sessionId]?.source == "cline",
       sessions[sessionId]?.taskRoundEnded == true,
       eventName != "SessionStart",
       eventName != "UserPromptSubmit" {
        return effects
    }

    // Codex may flush already queued tool hooks after an Interrupt. Keep the
    // terminal state latched until a new prompt/session starts so stale work
    // cannot revive the card as processing.
    //
    // SubagentStop still passes: interrupting the root turn does not stop
    // spawned agents, and dropping their stop would leave them in `subagents`
    // so the next root Stop sees "active subagents" and pins the card to
    // running/Agent. Removing a subagent never revives an idle parent.
    if sessions[sessionId]?.source == "codex",
       sessions[sessionId]?.interrupted == true,
       eventName != "SessionStart",
       eventName != "UserPromptSubmit",
       eventName != "SessionEnd",
       eventName != "SubagentStop",
       eventName != "Interrupt" {
        return effects
    }

    // Route subagent-specific events
    if let agentId = event.agentId {
        let handled = handleSubagentEvent(
            sessions: &sessions,
            sessionId: sessionId,
            agentId: agentId,
            eventName: eventName,
            event: event,
            maxHistory: maxHistory,
            effects: &effects
        )
        recordSubagentModel(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event)
        if handled { return effects }
    }

    // Remote Codex hooks can enrich ordinary lifecycle events with the latest
    // public assistant text because their transcript path is not readable on
    // this Mac. Apply it only after stale/interrupted and subagent events have
    // been filtered, and keep it separate from persisted chat history.
    if sessions[sessionId]?.source == "codex",
       eventName != "UserPromptSubmit",
       eventName != "SessionStart",
       let output = event.rawJSON["last_assistant_message"] as? String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sessions[sessionId]?.liveCodexOutput = trimmed
        }
    }

    // Preserve actionable states: don't let activity updates overwrite waiting states
    let isWaiting = sessions[sessionId]?.status == .waitingApproval
        || sessions[sessionId]?.status == .waitingQuestion

    // Update this session's state
    switch eventName {
    case "UserPromptSubmit":
        sessions[sessionId]?.interrupted = false
        sessions[sessionId]?.lastTurnFailed = false
        sessions[sessionId]?.taskRoundEnded = false
        if sessions[sessionId]?.source == "codex" {
            sessions[sessionId]?.liveCodexOutput = nil
        }
        sessions[sessionId]?.status = .processing
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        // Separate-mode Cursor Task Stop self-tombstones; a new prompt means relaunch.
        if let source = sessions[sessionId]?.source,
           source == "cursor" || source == "cursor-cli" {
            sessions[sessionId]?.clearClosedSubagentId(sessionId)
        }
        // Probe a wider set of field names + nested containers. Qwen Code (#103)
        // and most Claude forks put the prompt at "prompt" top-level, but some
        // forks nest it inside `input` / `data` / `payload` / `params`, Hermes's
        // pre_llm_call sends `extra.user_message`, and Cursor's
        // `beforeSubmitPrompt` uses a different shape. Empty strings are skipped
        // so we don't insert blank chat rows when a hook fires with a placeholder.
        let prompt = firstStringFromEvent(
            event,
            keys: ["prompt", "user_prompt", "userPrompt", "user_message", "message", "input", "content", "text"],
            includeNested: true
        )
        if let prompt {
            if sessions[sessionId]?.source == "hermes" {
                sessions[sessionId]?.hermesHooksReportPrompts = true
            }
            sessions[sessionId]?.lastUserPrompt = prompt
            if sessions[sessionId]?.recentMessages.last?.isUser == true {
                sessions[sessionId]?.recentMessages.removeLast()
            }
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        }
    case "PreToolUse":
        if !isWaiting {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = event.activityLabel
            sessions[sessionId]?.toolDescription = event.toolDescription
        }
    case "PostToolUse":
        if let tool = sessions[sessionId]?.currentTool {
            let desc = sessions[sessionId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: true, agentType: nil, maxHistory: maxHistory)
        }
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "PostToolUseFailure":
        if let tool = sessions[sessionId]?.currentTool {
            let desc = sessions[sessionId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: false, agentType: nil, maxHistory: maxHistory)
        }
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "PermissionDenied":
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "SubagentStart":
        if !isWaiting {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = "Agent"
            sessions[sessionId]?.toolDescription = event.rawJSON["agent_type"] as? String
        }
    case "SubagentStop":
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "AfterAgentResponse":
        // Cursor-specific: AI reply arrives here (in "text" field), not in Stop
        let responseText = firstStringFromEvent(
            event,
            keys: ["text", "message"],
            includeNested: true
        )
        if let text = responseText, !text.isEmpty {
            sessions[sessionId]?.lastAssistantMessage = text
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: text))
        }
        let hasActiveSubagents = sessions[sessionId]?.subagents.values.contains {
            $0.status != .idle
        } == true
        if let source = sessions[sessionId]?.source,
           AgentSessionSnapshot.ideCompletionSources.contains(source) {
            // Parent chat finished a turn while folded Tasks are still working —
            // keep the card active and do not pop a premature completion.
            if hasActiveSubagents {
                if !isWaiting {
                    sessions[sessionId]?.status = .running
                    if sessions[sessionId]?.currentTool == nil {
                        sessions[sessionId]?.currentTool = "Agent"
                    }
                }
            } else {
                sessions[sessionId]?.status = .idle
                sessions[sessionId]?.currentTool = nil
                sessions[sessionId]?.toolDescription = nil
                effects.append(.enqueueCompletion(sessionId: sessionId))
            }
        } else {
            sessions[sessionId]?.status = .processing
        }
    case "AgentTurnSettled":
        // Hermes's post_llm_call: the turn's final reply, sent just before
        // on_session_end (Stop) ends the turn. Drop the tool chrome and record
        // the reply; the completion belongs to the Stop that follows.
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        // It repeats the turn's prompt. Without an approved pre_llm_call hook
        // this is the first the card hears of it, so it goes in ahead of the reply.
        if let prompt = firstStringFromEvent(event, keys: ["user_message"], includeNested: true),
           prompt != sessions[sessionId]?.lastUserPrompt {
            sessions[sessionId]?.lastUserPrompt = prompt
            if sessions[sessionId]?.recentMessages.last?.isUser == true {
                sessions[sessionId]?.recentMessages.removeLast()
            }
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        }
        if let msg = firstStringFromEvent(
            event,
            keys: ["assistant_response", "last_assistant_message", "text", "message"],
            includeNested: true
        ), !msg.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.hermesHooksReportReplies = true
            sessions[sessionId]?.lastAssistantMessage = msg
            // A store read can land the same reply a moment before this hook.
            let alreadyShown = sessions[sessionId]?.recentMessages.last.map { !$0.isUser && $0.text == msg } ?? false
            if !alreadyShown {
                sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: msg))
            }
        }
        if !isWaiting {
            sessions[sessionId]?.status = .processing
        }
    case "TaskRoundComplete":
        sessions[sessionId]?.interrupted = (event.eventName == "TaskCancel")
        sessions[sessionId]?.status = .processing
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        let assistantMsg = firstStringFromEvent(
            event,
            keys: ["last_assistant_message", "text", "message", "summary"],
            includeNested: true
        )
        if let msg = assistantMsg {
            sessions[sessionId]?.lastAssistantMessage = msg
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: msg))
        } else if sessions[sessionId]?.lastAssistantMessage == nil,
                  sessions[sessionId]?.recentMessages.last?.isUser == true {
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: replyCompletePlaceholder))
        }
        // Cline tasks are single-round — treat completion/cancellation as session end,
        // and latch a flag so out-of-order in-flight tool events don't revive it.
        if sessions[sessionId]?.source == "cline" {
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.taskRoundEnded = true
        }
        effects.append(.enqueueCompletion(sessionId: sessionId))
    case "Stop":
        // Detect ESC/Ctrl+C interruption
        let stopReason = event.rawJSON["stop_reason"] as? String ?? ""
        let wasInterrupted = (stopReason == "user" || stopReason == "interrupted")
        let hasActiveSubagents = sessions[sessionId]?.subagents.values.contains {
            $0.status != .idle
        } == true
        // Separate-mode Cursor Tasks have no agent_id, so merge later must see
        // this id as closed — otherwise a still-live IDE `_ppid` resuscitates them.
        // Only self-tombstone foldable Task cards (transcript parent ≠ session id),
        // never the parent chat — that would suppress late Permission UI and wipe
        // the IDE `_ppid` monitor after a normal turn Stop.
        if !hasActiveSubagents,
           let source = sessions[sessionId]?.source,
           source == "cursor" || source == "cursor-cli",
           CursorSessionFolding.foldTarget(
               childSessionId: sessionId,
               transcriptPath: sessions[sessionId]?.transcriptPath
           ) != nil {
            sessions[sessionId]?.recordClosedSubagentId(sessionId)
            // Drop process identity so a still-open IDE `_ppid` does not look like
            // a live Task after Stop when the card is later considered for merge.
            sessions[sessionId]?.cliPid = nil
            sessions[sessionId]?.cliStartTime = nil
        }

        let assistantMsg = firstStringFromEvent(
            event,
            keys: ["last_assistant_message", "text", "message", "summary"],
            includeNested: true
        )
        if let msg = assistantMsg {
            sessions[sessionId]?.lastAssistantMessage = msg
            // Stop's last_assistant_message (Claude Code, Codex, mcode, …) is
            // often the reply the transcript tailer already appended, and with
            // maxCount 3 a duplicate crowds a real row off the card. Skip it
            // only when that reply is the newest row: after a new prompt, the
            // same text is a new answer and still lands.
            let normalizedIncoming = normalizedCursorChatText(from: msg) ?? msg
            let alreadyShown = sessions[sessionId]?.recentMessages.last.map {
                !$0.isUser && (normalizedCursorChatText(from: $0.text) ?? $0.text) == normalizedIncoming
            } ?? false
            if !alreadyShown {
                sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: msg))
            }
        } else if sessions[sessionId]?.lastAssistantMessage == nil,
                  sessions[sessionId]?.recentMessages.last?.isUser == true {
            // No reply content from hook (e.g. CodeBuddy) -- add placeholder
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: replyCompletePlaceholder))
        }
        // Try to capture user prompt from Stop event if not already set
        if sessions[sessionId]?.lastUserPrompt == nil {
            if let prompt = event.rawJSON["last_user_message"] as? String {
                sessions[sessionId]?.lastUserPrompt = prompt
                let insertAt = max(0, (sessions[sessionId]?.recentMessages.count ?? 1) - 1)
                sessions[sessionId]?.insertRecentMessage(ChatMessage(isUser: true, text: prompt), at: insertAt)
            }
        }

        // Parent chat Stop while folded Tasks are still working — keep the card
        // active and do not pop a premature completion (same as AfterAgentResponse).
        if hasActiveSubagents {
            if !isWaiting {
                sessions[sessionId]?.status = .running
                if sessions[sessionId]?.currentTool == nil {
                    sessions[sessionId]?.currentTool = "Agent"
                }
            }
            // Do not latch `interrupted` onto a still-active parent+Task card.
        } else {
            sessions[sessionId]?.interrupted = wasInterrupted
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
            effects.append(.enqueueCompletion(sessionId: sessionId))
        }
    case "SessionStart":
        effects.append(.stopMonitor(sessionId: sessionId))
        sessions[sessionId] = AgentSessionSnapshot(startTime: Date())
        // Re-apply metadata from this event (common extraction above wrote to the old session)
        if let cwd = event.rawJSON["cwd"] as? String, !cwd.isEmpty { sessions[sessionId]?.cwd = cwd }
        if let model = hookReportedModel(event) {
            sessions[sessionId]?.model = model
            sessions[sessionId]?.modelReportedAt = Date()
        }
        if let ppid = event.rawJSON["_ppid"] as? Int, ppid > 0 {
            let newPid = pid_t(ppid)
            if sessions[sessionId]?.cliPid != newPid {
                sessions[sessionId]?.cliPid = newPid
                sessions[sessionId]?.cliStartTime = nil
            }
        }
        if let source = AgentSessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) {
            sessions[sessionId]?.source = source
        }
        if let app = event.rawJSON["_term_app"] as? String, !app.isEmpty { sessions[sessionId]?.termApp = app }
        if let bundle = event.rawJSON["_term_bundle"] as? String, !bundle.isEmpty { sessions[sessionId]?.termBundleId = bundle }
        if let ses = event.rawJSON["_iterm_session"] as? String, !ses.isEmpty { sessions[sessionId]?.itermSessionId = ses }
        if let tty = event.rawJSON["_tty"] as? String, !tty.isEmpty { sessions[sessionId]?.ttyPath = tty }
        if let kitty = event.rawJSON["_kitty_window"] as? String, !kitty.isEmpty { sessions[sessionId]?.kittyWindowId = kitty }
        if let pane = event.rawJSON["_tmux_pane"] as? String, !pane.isEmpty { sessions[sessionId]?.tmuxPane = pane }
        if let tmuxTty = event.rawJSON["_tmux_client_tty"] as? String, !tmuxTty.isEmpty { sessions[sessionId]?.tmuxClientTty = tmuxTty }
        if let tmux = event.rawJSON["_tmux"] as? String, !tmux.isEmpty { sessions[sessionId]?.tmuxEnv = tmux }
        if let mode = event.rawJSON["permission_mode"] as? String { sessions[sessionId]?.permissionMode = mode }
        if let roots = event.rawJSON["workspace_roots"] as? [String], let first = roots.first, !first.isEmpty {
            sessions[sessionId]?.cwd = first
        }
        if let hostId = claudeDesktopSessionId(in: event) {
            sessions[sessionId]?.claudeDesktopSessionId = hostId
        }
        if let env = event.rawJSON["_env"] as? [String: String] {
            applyEnvMetadata(into: &sessions, sessionId: sessionId, env: env)
        }
        if let remoteHostId = event.rawJSON["_remote_host_id"] as? String, !remoteHostId.isEmpty {
            sessions[sessionId]?.remoteHostId = remoteHostId
        }
        if let remoteHostName = event.rawJSON["_remote_host_name"] as? String, !remoteHostName.isEmpty {
            sessions[sessionId]?.remoteHostName = remoteHostName
        }
        if let providerSessionId = event.rawJSON["session_id"] as? String,
           !providerSessionId.isEmpty,
           sessions[sessionId]?.isRemote == true
                || (sessions[sessionId]?.source == "codex"
                    && sessions[sessionId]?.termBundleId == "com.openai.codex") {
            let isCodexDesktop = sessions[sessionId]?.source == "codex"
                && sessions[sessionId]?.termBundleId == "com.openai.codex"
            sessions[sessionId]?.providerSessionId = isCodexDesktop
                ? normalizedCodexDesktopProviderSessionId(providerSessionId)
                : providerSessionId
        }
        if let sessionTitle = event.rawJSON["session_title"] as? String,
           !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.sessionTitle = sessionTitle
        }
        if !isRemote {
            effects.append(.tryMonitorSession(sessionId: sessionId))
        }
    case "SessionEnd":
        // Side effect: app state handles pending permission deny before removal
        effects.append(.removeSession(sessionId: sessionId))
        return effects
    case "Notification":
        let notificationText = firstStringFromEvent(
            event,
            keys: ["message", "text", "summary", "status", "detail"],
            includeNested: true
        )
        if let msg = notificationText, !msg.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.toolDescription = msg
        }
        if QuestionPayload.from(event: event) != nil {
            sessions[sessionId]?.status = .waitingQuestion
        } else {
            // Notifications that describe what the agent is waiting for. A
            // Notification cannot block (it is observe-only), so this is a
            // display-only wait: the decision is made in the terminal, and the
            // next PostToolUse/Stop clears it via the existing wasWaiting drain.
            // Without this the card sat on "thinking" while the CLI was in fact
            // blocked on the user (#290).
            switch notificationKind(from: event) {
            case "permission_prompt":
                sessions[sessionId]?.status = .waitingApproval
            case "idle_prompt":
                // "Waiting for your input after 60s idle" — the turn is over.
                sessions[sessionId]?.status = .idle
            default:
                break
            }
        }
    case "PreCompact":
        sessions[sessionId]?.status = .processing
        if sessions[sessionId]?.source == "codex" {
            sessions[sessionId]?.currentTool = "Compacting"
        }
        sessions[sessionId]?.toolDescription = "Compacting context\u{2026}"
    case "PostCompact":
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "Interrupt":
        sessions[sessionId]?.interrupted = true
        sessions[sessionId]?.status = .idle
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        effects.append(.enqueueCompletion(sessionId: sessionId))
    default:
        break
    }

    sessions[sessionId]?.lastActivity = Date()

    // Ensure process monitor is set up (covers sessions created implicitly)
    if sessions[sessionId]?.cwd != nil, !isRemote {
        effects.append(.tryMonitorSession(sessionId: sessionId))
    }

    // Trigger sound for this event. A single failed tool stays silent; only a
    // turn that died (StopFailure) rings the error sound. See EventSoundRouting.
    if let sound = EventSoundRouting.soundEvent(rawEventName: event.eventName, normalizedEventName: eventName) {
        effects.append(.playSound(sound))
    }

    // Switch display to the session that just had activity
    if eventName == "Stop" {
        // Stop event: keep activeSessionId on completed session (set by enqueueCompletion)
    } else if sessions[sessionId]?.status != .idle {
        effects.append(.setActiveSession(sessionId: sessionId))
    }
    // Note: the "else if activeSessionId == sessionId → mostActive" case
    // is handled by the app state since it needs to check current activeSessionId

    return effects
}

// MARK: - Private Helpers

private func applyEnvMetadata(into sessions: inout [String: AgentSessionSnapshot], sessionId: String, env: [String: String]) {
    if sessions[sessionId]?.termApp == nil,
       let app = env["TERM_PROGRAM"], !app.isEmpty {
        sessions[sessionId]?.termApp = app
    }
    if sessions[sessionId]?.termBundleId == nil,
       let bundle = env["__CFBundleIdentifier"], !bundle.isEmpty {
        sessions[sessionId]?.termBundleId = bundle
    }
    if sessions[sessionId]?.itermSessionId == nil,
       let ses = env["ITERM_SESSION_ID"], !ses.isEmpty {
        if let colonIdx = ses.firstIndex(of: ":") {
            sessions[sessionId]?.itermSessionId = String(ses[ses.index(after: colonIdx)...])
        } else {
            sessions[sessionId]?.itermSessionId = ses
        }
    }
    if sessions[sessionId]?.kittyWindowId == nil,
       let kitty = env["KITTY_WINDOW_ID"], !kitty.isEmpty {
        sessions[sessionId]?.kittyWindowId = kitty
    }
    if sessions[sessionId]?.tmuxEnv == nil,
       let tmux = env["TMUX"], !tmux.isEmpty {
        sessions[sessionId]?.tmuxEnv = tmux
    }
    if sessions[sessionId]?.tmuxPane == nil,
       let pane = env["TMUX_PANE"], !pane.isEmpty {
        sessions[sessionId]?.tmuxPane = pane
    }
    if sessions[sessionId]?.claudeDesktopSessionId == nil,
       let host = env[ClaudeDesktopCodeSession.hostSessionEnvKey],
       ClaudeDesktopCodeSession.isValidHostSessionId(host) {
        sessions[sessionId]?.claudeDesktopSessionId = host
    }
}

/// Fill identity fields on a parent card from a merged Task/subagent hook.
/// Unlike `extractMetadata`, never overwrites values already set on the parent
/// (child payloads can carry Task-specific cwd/model/title).
func fillMissingParentMetadataFromSubagentEvent(
    into sessions: inout [String: AgentSessionSnapshot],
    sessionId: String,
    event: HookEvent
) {
    // Default AgentSessionSnapshot.source is "claude". Upgrade when the hook carries a
    // real source so merge-first Cursor Tasks are not branded as Claude forever.
    if sessions[sessionId]?.source == "claude",
       let source = AgentSessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
            ?? AgentSessionSnapshot.normalizedSupportedSource(event.rawJSON["source"] as? String),
       source != "claude" {
        sessions[sessionId]?.source = source
    }
    // Cursor Task hooks often omit `--source` and keep the default "claude".
    // Rebrand when transcript_path is clearly under Cursor agent-transcripts.
    if sessions[sessionId]?.source == "claude",
       let path = event.rawJSON["transcript_path"] as? String,
       CursorSessionFolding.isCursorAgentTranscriptPath(path) {
        sessions[sessionId]?.source = "cursor"
    }

    let cwdMissing = sessions[sessionId]?.cwd == nil
        || AgentSessionSnapshot.isUnhelpfulHookCwd(sessions[sessionId]?.cwd ?? "")
    if cwdMissing {
        if let cwd = event.rawJSON["cwd"] as? String, !cwd.isEmpty,
           !AgentSessionSnapshot.isUnhelpfulHookCwd(cwd) {
            sessions[sessionId]?.cwd = cwd
        } else if let roots = event.rawJSON["workspace_roots"] as? [String],
                  let first = roots.first, !first.isEmpty {
            sessions[sessionId]?.cwd = first
        } else if let tp = event.rawJSON["transcript_path"] as? String,
                  tp.contains("/.cursor/projects/") {
            let parts = tp.split(separator: "/")
            if let idx = parts.firstIndex(of: "projects"), idx + 1 < parts.count {
                let projectName = String(parts[idx + 1])
                sessions[sessionId]?.cwd = "/\(parts[...idx].joined(separator: "/"))/\(projectName)"
            }
        }
    }

    // Claude and Cursor child hooks carry the parent's transcript; a Codex
    // child's is its own rollout. Tailing that as the parent's would label
    // the parent with the child's model and effort.
    if sessions[sessionId]?.transcriptPath == nil,
       !isCodexSubagentEvent(event, session: sessions[sessionId]),
       let transcriptPath = event.rawJSON["transcript_path"] as? String, !transcriptPath.isEmpty {
        sessions[sessionId]?.transcriptPath = transcriptPath
    }

    if sessions[sessionId]?.cliPid == nil,
       let ppid = event.rawJSON["_ppid"] as? Int, ppid > 0 {
        sessions[sessionId]?.cliPid = pid_t(ppid)
    }

    // A subagent runs inside the parent's CLI, so it carries the same id.
    if sessions[sessionId]?.claudeDesktopSessionId == nil,
       let hostId = claudeDesktopSessionId(in: event) {
        sessions[sessionId]?.claudeDesktopSessionId = hostId
    }
}

/// The Claude Desktop Code-tab id the bridge forwarded from
/// CLAUDE_CODE_HOST_SESSION_ID. Only a well-formed id is kept: it ends up in
/// a URL on click.
private func claudeDesktopSessionId(in event: HookEvent) -> String? {
    guard let hostId = event.rawJSON["_claude_desktop_session"] as? String,
          ClaudeDesktopCodeSession.isValidHostSessionId(hostId) else { return nil }
    return hostId
}

private func shouldReopenCursorSubagentOnPrompt(event: HookEvent, session: AgentSessionSnapshot?) -> Bool {
    if (event.rawJSON["_cursor_subagent"] as? Bool) == true {
        return true
    }
    let source = AgentSessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        ?? AgentSessionSnapshot.normalizedSupportedSource(event.rawJSON["source"] as? String)
        ?? session?.source
    return source == "cursor" || source == "cursor-cli"
}

/// Whether a subagent-routed event comes from Codex (native child threads).
private func isCodexSubagentEvent(_ event: HookEvent, session: AgentSessionSnapshot?) -> Bool {
    let source = AgentSessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        ?? session?.source
    return source == "codex"
}

/// Whether folded-child prompt/response text should appear on the parent card.
private func shouldSurfaceCursorSubagentChat(event: HookEvent, session: AgentSessionSnapshot?) -> Bool {
    if (event.rawJSON["_cursor_subagent"] as? Bool) == true {
        return true
    }
    return CursorSubsessionRouter.isCursorFamilySource(
        (event.rawJSON["_source"] as? String)
            ?? (event.rawJSON["source"] as? String)
            ?? session?.source
    )
}

func extractMetadata(into sessions: inout [String: AgentSessionSnapshot], sessionId: String, event: HookEvent) {
    let eventCwd = event.rawJSON["cwd"] as? String
    if let cwd = eventCwd, !cwd.isEmpty,
       !AgentSessionSnapshot.isUnhelpfulHookCwd(cwd) {
        sessions[sessionId]?.cwd = cwd
    }
    if sessions[sessionId]?.cwd == nil
        || AgentSessionSnapshot.isUnhelpfulHookCwd(sessions[sessionId]?.cwd ?? ""),
       let roots = event.rawJSON["workspace_roots"] as? [String],
       let first = roots.first, !first.isEmpty {
        sessions[sessionId]?.cwd = first
    } else if sessions[sessionId]?.cwd == nil
        || AgentSessionSnapshot.isUnhelpfulHookCwd(sessions[sessionId]?.cwd ?? ""),
              let tp = event.rawJSON["transcript_path"] as? String,
              tp.contains("/.cursor/projects/") {
        // Cursor: extract project dir from transcript_path
        // e.g. ~/.cursor/projects/<project>/agent-transcripts/... → ~/.cursor/projects/<project>
        // Must stay Cursor-scoped: Claude transcripts also contain a "projects"
        // component (~/.claude/projects/<encoded>/…) that is not a workspace.
        let parts = tp.split(separator: "/")
        if let idx = parts.firstIndex(of: "projects"), idx + 1 < parts.count {
            let projectName = String(parts[idx + 1])
            sessions[sessionId]?.cwd = "/\(parts[...idx].joined(separator: "/"))/\(projectName)"
        }
    } else if sessions[sessionId]?.cwd == nil, let cwd = eventCwd, !cwd.isEmpty {
        // Last resort: an unhelpful cwd ($HOME, ~/.claude) still beats nil —
        // transcript-based model lookup keys off it, and the display layer
        // already renders these paths as "Session".
        sessions[sessionId]?.cwd = cwd
    }
    // Git branch resolution is NOT done here: this reducer must stay pure and
    // .git probing can block on network mounts. Refresh it asynchronously
    // after reduce instead.
    if let model = hookReportedModel(event) {
        sessions[sessionId]?.model = model
        sessions[sessionId]?.modelReportedAt = Date()
    }
    if let mode = event.rawJSON["permission_mode"] as? String {
        sessions[sessionId]?.permissionMode = mode
    }
    // Hooks frequently include the absolute transcript path — capture it so a
    // tailer can attach to live appends without needing a filesystem scan.
    if let transcriptPath = event.rawJSON["transcript_path"] as? String, !transcriptPath.isEmpty {
        sessions[sessionId]?.transcriptPath = transcriptPath
    }
    // Terminal info (injected by hook script)
    if let app = event.rawJSON["_term_app"] as? String, !app.isEmpty, app != "unknown" {
        sessions[sessionId]?.termApp = app
    }
    if let ses = event.rawJSON["_iterm_session"] as? String, !ses.isEmpty {
        sessions[sessionId]?.itermSessionId = ses
    }
    if let tty = event.rawJSON["_tty"] as? String, !tty.isEmpty {
        sessions[sessionId]?.ttyPath = tty
    }
    // Extended terminal info (from native bridge binary)
    if let kitty = event.rawJSON["_kitty_window"] as? String, !kitty.isEmpty {
        sessions[sessionId]?.kittyWindowId = kitty
    }
    if let pane = event.rawJSON["_tmux_pane"] as? String, !pane.isEmpty {
        sessions[sessionId]?.tmuxPane = pane
    }
    if let tmuxTty = event.rawJSON["_tmux_client_tty"] as? String, !tmuxTty.isEmpty {
        sessions[sessionId]?.tmuxClientTty = tmuxTty
    }
    if let tmux = event.rawJSON["_tmux"] as? String, !tmux.isEmpty {
        sessions[sessionId]?.tmuxEnv = tmux
    }
    if let bundle = event.rawJSON["_term_bundle"] as? String, !bundle.isEmpty {
        sessions[sessionId]?.termBundleId = bundle
    }
    // Fallback: extract terminal/multiplexer info from _env sub-object (direct plugin format)
    if let env = event.rawJSON["_env"] as? [String: String] {
        applyEnvMetadata(into: &sessions, sessionId: sessionId, env: env)
    }
    if let ppid = event.rawJSON["_ppid"] as? Int, ppid > 0 {
        let newPid = pid_t(ppid)
        if sessions[sessionId]?.cliPid != newPid {
            sessions[sessionId]?.cliPid = newPid
            sessions[sessionId]?.cliStartTime = nil
        }
    }
    if let source = AgentSessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) {
        sessions[sessionId]?.source = source
    } else if sessions[sessionId]?.source == "claude",
              let path = (event.rawJSON["transcript_path"] as? String)
                ?? (event.rawJSON["transcriptPath"] as? String),
              CursorSessionFolding.isCursorAgentTranscriptPath(path) {
        // Untagged Cursor Agent Task hooks inherit AgentSessionSnapshot's default
        // "claude" — rebrand so merge/hide and the badge follow Cursor.
        sessions[sessionId]?.source = "cursor"
    }
    if let remoteHostId = event.rawJSON["_remote_host_id"] as? String, !remoteHostId.isEmpty {
        sessions[sessionId]?.remoteHostId = remoteHostId
    }
    if let remoteHostName = event.rawJSON["_remote_host_name"] as? String, !remoteHostName.isEmpty {
        sessions[sessionId]?.remoteHostName = remoteHostName
    }
    if let providerSessionId = event.rawJSON["session_id"] as? String,
       !providerSessionId.isEmpty,
       sessions[sessionId]?.isRemote == true
            || (sessions[sessionId]?.source == "codex"
                && sessions[sessionId]?.termBundleId == "com.openai.codex") {
        let isCodexDesktop = sessions[sessionId]?.source == "codex"
            && sessions[sessionId]?.termBundleId == "com.openai.codex"
        sessions[sessionId]?.providerSessionId = isCodexDesktop
            ? normalizedCodexDesktopProviderSessionId(providerSessionId)
            : providerSessionId
    }
    if let sessionTitle = event.rawJSON["session_title"] as? String,
       !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sessions[sessionId]?.sessionTitle = sessionTitle
    }
}

private func normalizedCodexDesktopProviderSessionId(_ sessionId: String) -> String {
    let prefix = "codexapp:"
    guard sessionId.hasPrefix(prefix) else { return sessionId }
    return String(sessionId.dropFirst(prefix.count))
}

/// Pull a non-empty string from a hook JSON value.
/// Supports plain strings and content-part arrays such as Kimi Code CLI's
/// `prompt: [{ "type": "text", "text": "..." }]`.
private func stringFromHookJSONValue(_ value: Any?) -> String? {
    if let value = value as? String {
        // Trim only to detect empty / whitespace-only payloads; return the
        // original value so callers preserve any leading/trailing
        // whitespace inside code-snippet prompts and multi-line content.
        return value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
            ? nil : value
    }

    let parts: [[String: Any]]
    if let typed = value as? [[String: Any]] {
        parts = typed
    } else if let anyParts = value as? [Any] {
        parts = anyParts.compactMap { $0 as? [String: Any] }
        if parts.isEmpty { return nil }
    } else {
        return nil
    }

    let texts = parts.compactMap { part -> String? in
        if let type = part["type"] as? String, type != "text" { return nil }
        guard let text = part["text"] as? String,
              !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }
    let joined = texts.joined()
    return joined.isEmpty ? nil : joined
}

/// The model a hook names: top-level `model`.
private func hookReportedModel(_ event: HookEvent) -> String? {
    if let model = event.rawJSON["model"] as? String, !model.isEmpty { return model }
    return nil
}

private func firstStringFromDict(_ dict: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = stringFromHookJSONValue(dict[key]) {
            return value
        }
    }
    return nil
}

/// Lowercased `notification_type` for a Notification event, if it carries one.
/// CodeBuddy documents `permission_prompt` / `idle_prompt` / `auth_success`;
/// other CLIs either omit the field or use the same spellings. (#290)
func notificationKind(from event: HookEvent) -> String? {
    guard let raw = firstStringFromEvent(
        event,
        keys: ["notification_type", "notificationType"],
        includeNested: true
    ) else { return nil }
    let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
    return trimmed.isEmpty ? nil : trimmed
}

private func firstStringFromEvent(_ event: HookEvent, keys: [String], includeNested: Bool) -> String? {
    if let value = firstStringFromDict(event.rawJSON, keys: keys) {
        return value
    }
    if includeNested {
        // "extra" is Hermes's envelope for everything beyond the four common
        // hook fields — assistant_response and friends live there (#303).
        for containerKey in ["payload", "data", "extra"] {
            if let nested = event.rawJSON[containerKey] as? [String: Any],
               let value = firstStringFromDict(nested, keys: keys) {
                return value
            }
        }
    }
    return nil
}

private func subagentType(from event: HookEvent) -> String {
    firstStringFromEvent(event, keys: ["agent_type", "agentType"], includeNested: false) ?? "Agent"
}

private func ensureSubagent(
    sessions: inout [String: AgentSessionSnapshot],
    sessionId: String,
    agentId: String,
    event: HookEvent
) -> Bool {
    // Only SubagentStart/SessionStart may reopen a closed agent id for most
    // providers. Cursor Tasks relaunch via UserPromptSubmit (see handleSubagentEvent).
    // Later tool/response hooks with the same agent_id must not revive it.
    if sessions[sessionId]?.hasClosedSubagentId(agentId) == true {
        return false
    }
    if sessions[sessionId]?.subagents[agentId] == nil {
        sessions[sessionId]?.subagents[agentId] = SubagentState(
            agentId: agentId,
            agentType: subagentType(from: event)
        )
    }
    return true
}

/// Keep a child's own `model` (Codex child threads report it on their hooks)
/// on its SubagentState. The parent's model is never used as a stand-in —
/// `extractMetadata` is skipped for subagent events for the same reason.
private func recordSubagentModel(
    sessions: inout [String: AgentSessionSnapshot],
    sessionId: String,
    agentId: String,
    event: HookEvent
) {
    guard sessions[sessionId]?.subagents[agentId] != nil,
          let model = (event.rawJSON["model"] as? String)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
          !model.isEmpty else { return }
    sessions[sessionId]?.subagents[agentId]?.model = model
}

/// Handle subagent events. Returns true if the event was consumed.
private func handleSubagentEvent(
    sessions: inout [String: AgentSessionSnapshot],
    sessionId: String,
    agentId: String,
    eventName: String,
    event: HookEvent,
    maxHistory: Int,
    effects: inout [AgentSideEffect]
) -> Bool {
    switch eventName {
    case "SubagentStart", "SessionStart":
        let agentType = subagentType(from: event)
        sessions[sessionId]?.clearClosedSubagentId(agentId)
        sessions[sessionId]?.subagents[agentId] = SubagentState(
            agentId: agentId,
            agentType: agentType
        )
        // Subagent spawned — parent session is actively processing
        if sessions[sessionId]?.status == .idle || sessions[sessionId]?.status == .processing {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = "Agent"
            sessions[sessionId]?.toolDescription = agentType
        }
        sessions[sessionId]?.lastActivity = Date()
        effects.append(.setActiveSession(sessionId: sessionId))
        return true

    case "UserPromptSubmit":
        // Cursor has no SessionStart for Tasks; beforeSubmitPrompt is the relaunch signal.
        if shouldReopenCursorSubagentOnPrompt(event: event, session: sessions[sessionId]) {
            sessions[sessionId]?.clearClosedSubagentId(agentId)
        }
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        // Cursor merge-into-main only: keep parent chat text live for folded Tasks
        // (and for main-chat hooks incorrectly tagged with agent_id). Do not apply
        // to Codex/plugin children — their prompts must not overwrite the parent card.
        if shouldSurfaceCursorSubagentChat(event: event, session: sessions[sessionId]),
           let prompt = firstStringFromEvent(
               event,
               keys: ["prompt", "user_prompt", "userPrompt"],
               includeNested: true
           ) {
            sessions[sessionId]?.lastUserPrompt = prompt
            if sessions[sessionId]?.recentMessages.last?.isUser == true {
                sessions[sessionId]?.recentMessages.removeLast()
            }
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        }
        if sessions[sessionId]?.status != .waitingApproval && sessions[sessionId]?.status != .waitingQuestion {
            let agentType = sessions[sessionId]?.subagents[agentId]?.agentType
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = "Agent"
            sessions[sessionId]?.toolDescription = agentType
        }
        sessions[sessionId]?.lastActivity = Date()
        effects.append(.setActiveSession(sessionId: sessionId))
        return true

    case "SubagentStop", "Stop", "SessionEnd":
        sessions[sessionId]?.subagents.removeValue(forKey: agentId)
        // Codex fires SubagentStop at the end of every child *turn*, and its
        // agent_id is the child's thread id, reused for follow-up turns sent
        // via send_message / followup_task without a new SubagentStart. A
        // tombstone here would drop those turns' hooks (ensureSubagent) and
        // auto-deny their PermissionRequests.
        // Removing the entry is enough: Codex awaits each hook in order, so no
        // stale tool hook can trail the stop, and the next turn's hooks
        // recreate the entry.
        if !(eventName == "SubagentStop" && isCodexSubagentEvent(event, session: sessions[sessionId])) {
            sessions[sessionId]?.recordClosedSubagentId(agentId)
        }
        // If no more subagents, revert parent to processing (waiting for main thread to continue)
        if sessions[sessionId]?.subagents.isEmpty == true {
            if sessions[sessionId]?.status == .running && sessions[sessionId]?.currentTool == "Agent" {
                sessions[sessionId]?.status = .processing
                sessions[sessionId]?.currentTool = nil
                sessions[sessionId]?.toolDescription = nil
            }
        }
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PreToolUse":
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        sessions[sessionId]?.subagents[agentId]?.status = .running
        sessions[sessionId]?.subagents[agentId]?.currentTool = event.activityLabel
        sessions[sessionId]?.subagents[agentId]?.toolDescription = event.toolDescription
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        // Keep parent session showing as active while subagents work
        if sessions[sessionId]?.status != .waitingApproval && sessions[sessionId]?.status != .waitingQuestion {
            sessions[sessionId]?.status = .running
        }
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PostToolUse":
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        if let tool = sessions[sessionId]?.subagents[agentId]?.currentTool {
            let agentType = sessions[sessionId]?.subagents[agentId]?.agentType
            let desc = sessions[sessionId]?.subagents[agentId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: true, agentType: agentType, maxHistory: maxHistory)
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.currentTool = nil
        sessions[sessionId]?.subagents[agentId]?.toolDescription = nil
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PostToolUseFailure":
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        if let tool = sessions[sessionId]?.subagents[agentId]?.currentTool {
            let agentType = sessions[sessionId]?.subagents[agentId]?.agentType
            let desc = sessions[sessionId]?.subagents[agentId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: false, agentType: agentType, maxHistory: maxHistory)
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.currentTool = nil
        sessions[sessionId]?.subagents[agentId]?.toolDescription = nil
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "AfterAgentResponse":
        // Merged Cursor Task events arrive with parent session_id + child agent_id.
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        // Cursor-only: surface the folded reply on the parent card, but never
        // enqueue parent-turn completion from a Task response.
        if shouldSurfaceCursorSubagentChat(event: event, session: sessions[sessionId]),
           let text = firstStringFromEvent(
               event,
               keys: ["text", "message"],
               includeNested: true
           ),
           !text.isEmpty {
            sessions[sessionId]?.lastAssistantMessage = text
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: text))
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        sessions[sessionId]?.lastActivity = Date()
        if sessions[sessionId]?.status != .waitingApproval
            && sessions[sessionId]?.status != .waitingQuestion
            && sessions[sessionId]?.status != .running {
            sessions[sessionId]?.status = .processing
        }
        return true

    case "Notification":
        // Keep folded Tasks' ask/question notifications on the parent card.
        // Swallowing them here (as AfterAgentResponse did) dropped waitingQuestion.
        guard ensureSubagent(sessions: &sessions, sessionId: sessionId, agentId: agentId, event: event) else {
            return true
        }
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        sessions[sessionId]?.lastActivity = Date()
        let notificationText = firstStringFromEvent(
            event,
            keys: ["message", "text", "summary", "status", "detail"],
            includeNested: true
        )
        if let msg = notificationText, !msg.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.toolDescription = msg
            sessions[sessionId]?.subagents[agentId]?.toolDescription = msg
        }
        if QuestionPayload.from(event: event) != nil {
            sessions[sessionId]?.status = .waitingQuestion
            sessions[sessionId]?.subagents[agentId]?.status = .waitingQuestion
            effects.append(.setActiveSession(sessionId: sessionId))
        } else if sessions[sessionId]?.status != .waitingApproval
            && sessions[sessionId]?.status != .waitingQuestion
            && sessions[sessionId]?.status != .running {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.subagents[agentId]?.status = .processing
        }
        return true

    default:
        return false  // Fall through to normal session handling
    }
}

// MARK: - Ported micro-dependencies (Sources/CodeIslandCore)

/// Which sound, if any, a hook event rings.
///
/// Sounds mark turn boundaries, not steps inside a turn. A failed tool call —
/// a Bash command exiting non-zero, an Edit whose `old_string` did not match —
/// is routine: the agent reads the error and carries on. Ringing the "task
/// error" jingle for every one of them taught users to tune out the sound that
/// should mean "this turn died and needs you".
enum EventSoundRouting {
    /// Sound event for a turn that ended on an error rather than a reply:
    /// Claude Code / Grok `StopFailure` (rate limit, overload, auth, billing…).
    /// The name follows Claude Code's hook.
    static let turnFailed = "StopFailure"

    /// The sound event for a hook, or nil when it should stay silent.
    ///
    /// Takes the raw wire name as well as the normalized one because
    /// `EventNormalizer` folds `StopFailure` onto `Stop` — the island state
    /// really is "turn over" either way — and the failure is only visible
    /// before that fold.
    static func soundEvent(rawEventName: String, normalizedEventName: String) -> String? {
        if normalizedEventName == "PostToolUseFailure" { return nil }
        if rawEventName == "StopFailure" || rawEventName == "stop_failure" { return turnFailed }
        return normalizedEventName
    }
}

/// Claude Code sessions run from Claude Desktop's Code tab.
///
/// Claude Desktop starts each Code-tab session's CLI with its own id for that
/// session in `CLAUDE_CODE_HOST_SESSION_ID` (`local_<uuid>`).
enum ClaudeDesktopCodeSession {
    /// Environment variable Claude Desktop sets on a Code-tab session's CLI.
    static let hostSessionEnvKey = "CLAUDE_CODE_HOST_SESSION_ID"

    /// Whether `id` has the shape Claude Desktop's URL handler accepts for
    /// `?session=` — `^local_[A-Za-z0-9-]{1,64}$`. Anything else is refused
    /// there, so it is dropped here.
    static func isValidHostSessionId(_ id: String) -> Bool {
        let prefix = "local_"
        guard id.hasPrefix(prefix) else { return false }
        let body = id.dropFirst(prefix.count)
        guard (1...64).contains(body.count) else { return false }
        return body.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
        }
    }
}

/// Cursor session folding (Sources/CodeIslandCore/CursorSessionFolding.swift,
/// the pure path-parsing half).
enum CursorSessionFolding {
    private static let uuidDirPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    static func isCursorAgentTranscriptPath(_ path: String?) -> Bool {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return false
        }
        guard path.contains("/agent-transcripts/") else { return false }
        return path.contains("/.cursor/") || path.contains("/cursor/projects/")
    }

    /// Parent conversation id from a Cursor `transcript_path`, when present.
    ///
    /// Recognized layouts:
    /// - `…/agent-transcripts/<parentId>/<parentId>.jsonl`
    /// - `…/agent-transcripts/<parentId>/subagents/<childId>.jsonl`
    static func parentConversationId(fromTranscriptPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = (trimmed as NSString).pathComponents
        guard let transcriptsIdx = parts.lastIndex(of: "agent-transcripts"),
              transcriptsIdx + 1 < parts.count else {
            return nil
        }

        let parentCandidate = parts[transcriptsIdx + 1]
        guard parentCandidate.range(of: uuidDirPattern, options: .regularExpression) != nil else {
            return nil
        }
        return parentCandidate
    }

    /// Parent id when `childSessionId` is a Task of that conversation
    /// (`transcript_path` parent ≠ `childSessionId`).
    static func foldTarget(childSessionId: String, transcriptPath: String?) -> String? {
        let child = childSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !child.isEmpty,
              let path = transcriptPath,
              let parentId = parentConversationId(fromTranscriptPath: path),
              parentId != child else {
            return nil
        }
        return parentId
    }
}

enum CursorSubsessionRouter {
    /// `cursor` / `cursor-cli` after normalization.
    static func isCursorFamilySource(_ source: String?) -> Bool {
        let normalized = AgentSessionSnapshot.normalizedSupportedSource(source)
        return normalized == "cursor" || normalized == "cursor-cli"
    }
}

/// Strip Cursor's `<timestamp>`/`<user_query>` wrappers so a reply already on
/// the card compares equal to the same text re-sent by a Stop hook.
/// (Sources/CodeIslandCore/JSONLTailer.swift, the String-input path the
/// reducer's Stop dedup uses.)
private func normalizedCursorChatText(from text: String) -> String? {
    var text = text
    while let start = text.range(of: "<timestamp>"),
          let end = text.range(of: "</timestamp>", range: start.upperBound..<text.endIndex) {
        text.removeSubrange(start.lowerBound..<end.upperBound)
    }
    if let start = text.range(of: "<user_query>"),
       let end = text.range(of: "</user_query>", range: start.upperBound..<text.endIndex) {
        text = String(text[start.upperBound..<end.lowerBound])
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
