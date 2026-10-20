import XCTest

@testable import Pulse

/// Tests for the CodeIsland-derived pure reducer (`reduceEvent`) — ported test
/// spirit from Tests/CodeIslandTests, fixtures written for this port.
final class AgentReducerTests: XCTestCase {
    private var sessions: [String: AgentSessionSnapshot] = [:]

    override func setUp() {
        super.setUp()
        sessions = [:]
    }

    @discardableResult
    private func reduce(_ payload: [String: Any], maxHistory: Int = 20) throws -> [AgentSideEffect] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data), "event should decode: \(payload)")
        return reduceEvent(sessions: &sessions, event: event, maxHistory: maxHistory)
    }

    private func snapshot(_ sessionId: String) throws -> AgentSessionSnapshot {
        try XCTUnwrap(sessions[sessionId], "session should exist: \(sessionId)")
    }

    func testTaskTitleKeepsFirstPromptAndPrefersExplicitTitle() throws {
        try reduce(["hook_event_name": "UserPromptSubmit", "session_id": "s1",
                    "prompt": "  优化灵动岛\n展开动画  ", "cwd": "/work/TodoIsland"])
        try reduce(["hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "同意"])
        var snap = try snapshot("s1")
        XCTAssertEqual(snap.displayTitle(sessionId: "s1"), "优化灵动岛 展开动画")
        XCTAssertEqual(snap.lastUserPrompt, "同意")
        XCTAssertEqual(snap.projectName, "TodoIsland")
        snap.sessionTitle = "动画性能优化"
        XCTAssertEqual(snap.displayTitle(sessionId: "s1"), "动画性能优化")
        snap.sessionTitle = "s1"
        XCTAssertEqual(snap.displayTitle(sessionId: "s1"), "优化灵动岛 展开动画")
    }

    func testMissingTaskMetadataNeverDisplaysSessionIDOrHomeDirectory() {
        var snap = AgentSessionSnapshot()
        snap.source = "codex"
        snap.providerSessionId = "provider-id"
        snap.cwd = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertNil(snap.projectName)
        XCTAssertFalse(snap.displayTitle(sessionId: "internal-id").contains("internal-id"))
        XCTAssertFalse(snap.displayTitle(sessionId: "internal-id").contains("provider-id"))
        XCTAssertEqual(snap.displaySessionId(sessionId: "internal-id"), "provider-id")
        snap.lastUserPrompt = "  \n"
        snap.lastUserPrompt = String(repeating: "🧑🏽‍💻", count: 80)
        XCTAssertEqual(snap.displayTitle(sessionId: "internal-id").count, 65)
        XCTAssertTrue(snap.displayTitle(sessionId: "internal-id").hasSuffix("…"))
    }

    func testRecentActivityAgeUsesActivityTimeAndClampsFutureDates() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(agentActivityAge(now, from: now), L10n.text("agents.activity.now"))
        XCTAssertEqual(agentActivityAge(now.addingTimeInterval(30), from: now), L10n.text("agents.activity.now"))
        XCTAssertEqual(agentActivityAge(now.addingTimeInterval(-25), from: now),
                       String(format: L10n.text("agents.activity.seconds"), 25))
        XCTAssertEqual(agentActivityAge(now.addingTimeInterval(-120), from: now),
                       String(format: L10n.text("agents.activity.minutes"), 2))
    }

    func testCodexTitleIndexSkipsMalformedRowsAndUsesNewestMatchingTitle() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("titles-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = [
            "{\"id\":\"target\",\"thread_name\":\"旧标题\"}",
            "{\"id\":\"other\",\"thread_name\":\"其他会话\"}",
            "{\"id\":\"target\",\"thread_name\":\" 新标题 \"}",
            "{\"id\":\"target\",\"thread_name\":\" \"}",
            "{unfinished"
        ]
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSessionStore.localCodexTitle(sessionId: "target", indexURL: url), "新标题")
        XCTAssertNil(AgentSessionStore.localCodexTitle(sessionId: "missing", indexURL: url))
    }

    // MARK: - Prompt / tool lifecycle

    func testUserPromptSubmitRecordsPromptAndClearsInterruptedAndFailure() throws {
        sessions["s1"] = AgentSessionSnapshot()
        sessions["s1"]?.interrupted = true
        sessions["s1"]?.lastTurnFailed = true

        let effects = try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "cwd": "/Users/dev/project",
            "prompt": "Fix the login bug",
        ])

        let snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .processing)
        XCTAssertEqual(snap.lastUserPrompt, "Fix the login bug")
        XCTAssertFalse(snap.interrupted)
        XCTAssertFalse(snap.lastTurnFailed)
        XCTAssertNil(snap.currentTool)
        XCTAssertEqual(snap.recentMessages.last?.isUser, true)
        XCTAssertEqual(snap.recentMessages.last?.text, "Fix the login bug")
        XCTAssertTrue(effects.contains(.playSound("UserPromptSubmit")))
        XCTAssertTrue(effects.contains(.setActiveSession(sessionId: "s1")))
        // cwd known → the reducer asks the caller to monitor the CLI process
        XCTAssertTrue(effects.contains(.tryMonitorSession(sessionId: "s1")))
    }

    func testPreToolUseRunsThenPostToolUseRecordsHistoryAndReturnsToProcessing() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "Ship it",
        ])
        try reduce([
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_input": ["command": "swift build", "description": "Build the app"],
        ])

        var snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .running)
        XCTAssertEqual(snap.currentTool, "Bash")
        // Upstream keeps both halves when description and command differ.
        XCTAssertEqual(snap.toolDescription, "Build the app\nCommand:\nswift build")

        try reduce([
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "tool_name": "Bash",
        ])

        snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .processing)
        XCTAssertNil(snap.currentTool)
        XCTAssertNil(snap.toolDescription)
        XCTAssertEqual(snap.toolHistory.count, 1)
        XCTAssertEqual(snap.toolHistory.last?.tool, "Bash")
        XCTAssertEqual(snap.toolHistory.last?.description, "Build the app\nCommand:\nswift build")
        XCTAssertEqual(snap.toolHistory.last?.success, true)
        XCTAssertNil(snap.toolHistory.last?.agentType)
        XCTAssertEqual(snap.totalToolCallCount, 1)
    }

    func testPostToolUseFailureRecordsUnsuccessfulHistoryEntry() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "Ship it",
        ])
        try reduce([
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "tool_name": "Edit",
            "tool_input": ["file_path": "/Users/dev/project/Main.swift"],
        ])
        let effects = try reduce([
            "hook_event_name": "PostToolUseFailure",
            "session_id": "s1",
            "tool_name": "Edit",
        ])

        let snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .processing)
        XCTAssertEqual(snap.toolHistory.count, 1)
        XCTAssertEqual(snap.toolHistory.last?.tool, "Edit")
        XCTAssertEqual(snap.toolHistory.last?.success, false)
        XCTAssertEqual(snap.toolHistory.last?.description, "Main.swift")
        // A single failed tool is routine and must stay silent.
        XCTAssertFalse(effects.contains { $0 == .playSound("PostToolUseFailure") })
    }

    // MARK: - Stop

    func testStopIdlesEnqueuesCompletionAndCapturesAssistantMessage() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "Fix the login bug",
        ])
        let effects = try reduce([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "last_assistant_message": "Done, fixed in AuthService.",
        ])

        let snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .idle)
        XCTAssertFalse(snap.interrupted)
        XCTAssertNil(snap.currentTool)
        XCTAssertEqual(snap.lastAssistantMessage, "Done, fixed in AuthService.")
        XCTAssertEqual(snap.recentMessages.last?.isUser, false)
        XCTAssertEqual(snap.recentMessages.last?.text, "Done, fixed in AuthService.")
        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
        XCTAssertTrue(effects.contains(.playSound("Stop")))
        // Stop deliberately does not steal the active-session pointer.
        XCTAssertFalse(effects.contains(.setActiveSession(sessionId: "s1")))
    }

    func testStopWithUserStopReasonMarksInterrupted() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "go",
        ])
        try reduce([
            "hook_event_name": "Stop",
            "session_id": "s1",
            "stop_reason": "user",
        ])

        let snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .idle)
        XCTAssertTrue(snap.interrupted)
    }

    func testStopFailureFoldsOntoStopWithTurnFailedSound() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "go",
        ])
        let effects = try reduce([
            "hook_event_name": "StopFailure",
            "session_id": "s1",
            "last_assistant_message": "rate limited",
        ])

        let snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .idle)
        XCTAssertEqual(snap.lastAssistantMessage, "rate limited")
        // The turn died on an error: a completion is still enqueued, and the
        // only error signal the reducer emits is the StopFailure sound event.
        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "s1")))
        XCTAssertTrue(effects.contains(.playSound("StopFailure")))
    }

    // MARK: - isWaiting guard

    func testWaitingApprovalIsNotOverwrittenByToolEvents() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "go",
        ])
        try reduce([
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_input": ["command": "swift build", "description": "Build the app"],
        ])
        try reduce([
            "hook_event_name": "Notification",
            "session_id": "s1",
            "message": "Claude needs your permission to use Bash",
            "notification_type": "permission_prompt",
        ])
        XCTAssertEqual(try snapshot("s1").status, .waitingApproval)

        try reduce([
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "tool_name": "Read",
            "tool_input": ["file_path": "/Users/dev/project/A.swift"],
        ])
        var snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .waitingApproval, "PreToolUse must not clear a pending approval")
        // The guard skips currentTool entirely while waiting.
        XCTAssertEqual(snap.currentTool, "Bash")

        try reduce([
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "tool_name": "Read",
        ])
        snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .waitingApproval, "PostToolUse must not clear a pending approval")
    }

    // MARK: - Notification

    func testNotificationWithQuestionSetsWaitingQuestion() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "go",
        ])
        try reduce([
            "hook_event_name": "Notification",
            "session_id": "s1",
            "message": "Which approach do you prefer?",
            "question": "Which approach do you prefer?",
            "options": ["Fix forward", "Revert"],
        ])

        let snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .waitingQuestion)
        XCTAssertEqual(snap.toolDescription, "Which approach do you prefer?")
    }

    func testNotificationWithPermissionPromptSetsWaitingApproval() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "go",
        ])
        try reduce([
            "hook_event_name": "Notification",
            "session_id": "s1",
            "message": "Claude needs your permission to use Bash",
            "notification_type": "permission_prompt",
        ])

        XCTAssertEqual(try snapshot("s1").status, .waitingApproval)
    }

    // MARK: - Session lifecycle

    func testSessionStartRebuildsFreshSnapshotWithCwdAndModel() throws {
        sessions["s1"] = AgentSessionSnapshot()
        sessions["s1"]?.status = .running
        sessions["s1"]?.currentTool = "Bash"
        sessions["s1"]?.lastUserPrompt = "stale prompt"

        let effects = try reduce([
            "hook_event_name": "SessionStart",
            "session_id": "s1",
            "cwd": "/Users/dev/project",
            "model": "claude-opus-4-6",
            "_source": "claude",
            "_ppid": 4242,
        ])

        let snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .idle)
        XCTAssertNil(snap.currentTool)
        XCTAssertNil(snap.lastUserPrompt)
        XCTAssertTrue(snap.toolHistory.isEmpty)
        XCTAssertEqual(snap.cwd, "/Users/dev/project")
        XCTAssertEqual(snap.model, "claude-opus-4-6")
        XCTAssertEqual(snap.source, "claude")
        XCTAssertEqual(snap.cliPid, 4242)
        XCTAssertTrue(effects.contains(.stopMonitor(sessionId: "s1")))
        XCTAssertTrue(effects.contains(.tryMonitorSession(sessionId: "s1")))
    }

    func testSessionEndEmitsRemoveSessionOnly() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "go",
        ])
        let effects = try reduce([
            "hook_event_name": "SessionEnd",
            "session_id": "s1",
        ])

        XCTAssertEqual(effects, [.removeSession(sessionId: "s1")])
    }

    // MARK: - Subagents

    func testSubagentStartRunsAgentToolAndSubagentStopRevertsAndTombstones() throws {
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": "go",
        ])
        let startEffects = try reduce([
            "hook_event_name": "SubagentStart",
            "session_id": "s1",
            "agent_id": "agent-1",
            "agent_type": "Explore",
        ])

        var snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .running)
        XCTAssertEqual(snap.currentTool, "Agent")
        XCTAssertEqual(snap.toolDescription, "Explore")
        XCTAssertEqual(snap.subagents["agent-1"]?.agentType, "Explore")
        XCTAssertEqual(snap.subagents["agent-1"]?.status, .running)
        // Subagent-routed events return early: no sound, just the pointer.
        XCTAssertEqual(startEffects, [.setActiveSession(sessionId: "s1")])

        let stopEffects = try reduce([
            "hook_event_name": "SubagentStop",
            "session_id": "s1",
            "agent_id": "agent-1",
        ])

        snap = try snapshot("s1")
        XCTAssertEqual(snap.status, .processing)
        XCTAssertNil(snap.currentTool)
        XCTAssertTrue(snap.subagents.isEmpty)
        XCTAssertTrue(snap.hasClosedSubagentId("agent-1"), "SubagentStop must tombstone the agent id")
        XCTAssertTrue(stopEffects.isEmpty)

        // A tombstoned id must not be revived by a late tool hook.
        try reduce([
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "agent_id": "agent-1",
            "tool_name": "Bash",
            "tool_input": ["command": "ls"],
        ])
        snap = try snapshot("s1")
        XCTAssertTrue(snap.subagents.isEmpty)
        XCTAssertEqual(snap.status, .processing)
    }

    // MARK: - Interrupted terminal-state latch (Codex)

    func testCodexInterruptedLatchDropsStaleToolEventsUntilNextPrompt() throws {
        try reduce([
            "hook_event_name": "SessionStart",
            "session_id": "cx",
            "_source": "codex",
        ])
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "cx",
            "prompt": "go",
        ])
        let interruptEffects = try reduce([
            "hook_event_name": "Interrupt",
            "session_id": "cx",
        ])
        XCTAssertTrue(interruptEffects.contains(.enqueueCompletion(sessionId: "cx")))
        XCTAssertEqual(try snapshot("cx").status, .idle)
        XCTAssertTrue(try snapshot("cx").interrupted)

        // A stale queued tool hook must not revive the card.
        let staleEffects = try reduce([
            "hook_event_name": "PreToolUse",
            "session_id": "cx",
            "tool_name": "Bash",
            "tool_input": ["command": "swift build", "description": "Build"],
        ])
        XCTAssertEqual(staleEffects, [])
        XCTAssertEqual(try snapshot("cx").status, .idle)
        XCTAssertNil(try snapshot("cx").currentTool)

        // The next prompt unlatches the terminal state.
        try reduce([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "cx",
            "prompt": "again",
        ])
        let snap = try snapshot("cx")
        XCTAssertEqual(snap.status, .processing)
        XCTAssertFalse(snap.interrupted)
    }
}
