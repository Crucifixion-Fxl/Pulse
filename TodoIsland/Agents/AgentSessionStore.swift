// Ported from wxtsky/CodeIsland (MIT License) — see ThirdParty/CODEISLAND-LICENSE.txt
// (Sources/CodeIsland/AppState.swift + Sources/CodeIsland/Models.swift, trimmed)
//
// The app-side half of the agent hook pipeline: the reducer-driven session
// map plus the blocking permission/question routing that HookServer ports
// from upstream. Deliberately NOT ported from AppState.swift: sounds, panel
// surfaces / animations, process monitors, transcript tailers, push/webhook
// forwarding, remote hosts, Codex app-server questions, Cursor/Codex
// sub-session folding, quota tracking, persistence. What remains is exactly
// what a headless "which sessions exist + answer their blocking prompts"
// consumer needs.

import Foundation
import Network

/// Owns all agent-session state fed by hook events, and every blocking
/// decision (permissions, questions) a CLI is waiting on.
///
/// All entry points are main-actor; `AgentHookServer` is the only intended
/// producer, the island UI the consumer.
@MainActor
final class AgentSessionStore: ObservableObject {

    // MARK: - Requests (Models.swift port, trimmed)

    /// One queued permission decision. The CLI blocks until the continuation
    /// is resumed with the serialized hook response.
    struct PermissionRequest: Identifiable {
        let id: UUID
        let event: HookEvent
        fileprivate var continuation: CheckedContinuation<Data, Never>

        init(id: UUID = UUID(), event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
            self.id = id
            self.event = event
            self.continuation = continuation
        }

        var toolUseId: String? { event.toolUseId }
        var sessionId: String { event.sessionId ?? "default" }
    }

    /// One queued question — either a Notification carrying `question`, or an
    /// AskUserQuestion PermissionRequest converted to a question.
    struct QuestionRequest: Identifiable {
        let id: UUID
        let event: HookEvent
        fileprivate var continuation: CheckedContinuation<Data, Never>
        /// true when this came from an AskUserQuestion tool call: its answer
        /// must be returned as a PermissionRequest allow with `updatedInput`,
        /// and draining it denies the tool call.
        let isFromPermission: Bool

        init(
            id: UUID = UUID(),
            event: HookEvent,
            continuation: CheckedContinuation<Data, Never>,
            isFromPermission: Bool = false
        ) {
            self.id = id
            self.event = event
            self.continuation = continuation
            self.isFromPermission = isFromPermission
        }

        var sessionId: String { event.sessionId ?? "default" }

        /// The question payloads this request wants answered, in order.
        /// Notification questions have one; AskUserQuestion may have several.
        var questions: [AskQuestionItem] {
            if isFromPermission {
                return AgentSessionStore.askUserQuestionItems(for: event)
            }
            if let payload = QuestionPayload.from(event: event) {
                return [AskQuestionItem(payload: payload, multiSelect: false)]
            }
            return []
        }

        var question: QuestionPayload? { questions.first?.payload }
    }

    /// A single question inside a request, with its multi-select flag kept
    /// alongside (AskUserQuestion puts `multiSelect` on each question).
    struct AskQuestionItem {
        let payload: QuestionPayload
        let multiSelect: Bool
        /// Key the answer is booked under in `updatedInput.answers` — Claude
        /// Code looks answers up by question text (upstream #XXX: header keys
        /// arrive as empty strings). Duplicate texts get `_2` suffixes.
        let answerKey: String

        init(payload: QuestionPayload, multiSelect: Bool, answerKey: String? = nil) {
            self.payload = payload
            self.multiSelect = multiSelect
            self.answerKey = answerKey ?? payload.question
        }
    }

    /// A user's answer to one question of a wizard. `selectedOptions` carries
    /// the raw label array for a multiSelect question.
    struct QuestionAnswer {
        let question: String
        let answer: String
        let selectedOptions: [String]

        init(question: String, answer: String, selectedOptions: [String] = []) {
            self.question = question
            self.answer = answer
            self.selectedOptions = selectedOptions
        }
    }

    // MARK: - State

    @Published private(set) var sessions: [String: AgentSessionSnapshot] = [:]
    @Published private(set) var permissionQueue: [PermissionRequest] = []
    @Published private(set) var questionQueue: [QuestionRequest] = []

    /// Finished turn the completion UI should show next.
    @Published private(set) var lastCompletion: (session: AgentSessionSnapshot, failed: Bool)?

    /// Whether any permission or question needs the user. Derived, so it
    /// refreshes with the queues it reads from.
    var hasPending: Bool { !permissionQueue.isEmpty || !questionQueue.isEmpty }

    /// While paused, events are ignored and cleanup stops — reserved for a
    /// future "do not disturb" surface; nothing sets it yet.
    var isPaused: Bool = false

    /// Which connection (bridge process) parked each queued request, so a
    /// peer drop can release exactly the CLIs that died.
    private var requestOrigins: [UUID: ObjectIdentifier] = [:]

    private var cleanupTimer: Timer?

    /// Tool calls that never need the user (upstream SettingsDefaults list).
    nonisolated static let autoApproveTools: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop",
        "TodoRead", "TodoWrite", "EnterPlanMode", "ExitPlanMode",
    ]

    /// Permission modes where the user told the CLI to decide for itself
    /// (`permission_mode` on PermissionRequest payloads, both Claude Code
    /// and Codex). A blocking queue here would re-ask what auto mode
    /// already answers — and out-rank its safety classifier — so requests
    /// in these modes get no decision and the CLI's own flow runs. AskUser
    /// Question is exempt: questions are for the user in every mode.
    nonisolated static let selfApprovingModes: Set<String> = [
        "auto", "dontAsk", "bypassPermissions",
    ]

    /// Upstream `SettingsDefaults.maxToolHistory` (no settings UI in this port).
    private let maxHistory = 20

    /// 10MB safety limit shared with the socket transport.
    nonisolated static let maxPayloadSize = 10_485_760

    init() {
        // Cleanup heartbeat. Timer holds self weakly; invalidated in deinit.
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performCleanup()
            }
        }
    }

    deinit {
        // Continuations must be resumed exactly once or the CLI's hook bridge
        // hangs forever. The queues are main-actor state, so the drain can only
        // run when the last reference is released on the main thread — which is
        // where this store's whole ownership graph (server + UI) lives.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                drainAllForTeardown()
                cleanupTimer?.invalidate()
            }
        }
    }

    // MARK: - Event application (reducer-driven core)

    /// Apply one hook event to the session map. Returns the reducer's side
    /// effects — callers ignore sound/monitor effects; this store consumes
    /// `.removeSession` / `.enqueueCompletion` itself.
    @discardableResult
    func apply(_ event: HookEvent) -> [AgentSideEffect] {
        guard !isPaused else { return [] }

        let sessionId = event.sessionId ?? "default"
        let normalizedName = EventNormalizer.normalize(event.eventName)

        let prevStatus = sessions[sessionId]?.status
        let wasWaiting = prevStatus == .waitingApproval || prevStatus == .waitingQuestion

        var next = sessions
        let effects = reduceEvent(sessions: &next, event: event, maxHistory: maxHistory)
        sessions = next

        for effect in effects {
            switch effect {
            case .removeSession(let sid):
                // Deny anything the dying session still blocks on first —
                // upstream removeSession drains before removing.
                denyAllForSession(sessionId: sid)
                sessions.removeValue(forKey: sid)
            case .enqueueCompletion(let sid):
                let failed = EventSoundRouting.soundEvent(
                    rawEventName: event.eventName,
                    normalizedEventName: normalizedName
                ) == EventSoundRouting.turnFailed
                sessions[sid]?.lastTurnFailed = failed
                if let snapshot = sessions[sid] {
                    lastCompletion = (session: snapshot, failed: failed)
                }
            case .playSound, .tryMonitorSession, .stopMonitor, .setActiveSession:
                break  // no sound / process monitoring in this port
            }
        }

        // Port of upstream handleEvent's wasWaiting branch: a session that was
        // blocked and then shows activity was answered elsewhere (observe-only
        // providers keep emitting events) — release its questions so that CLI
        // is not left hanging, but never touch other in-flight permissions.
        if wasWaiting {
            let keepWaiting: Set<String> = ["Notification", "SessionStart", "SessionEnd", "PreCompact"]
            if !keepWaiting.contains(normalizedName) {
                drainQuestions(sessionId: sessionId, agentId: event.agentId)
                let stillHasPermission = permissionQueue.contains { $0.sessionId == sessionId }
                let stillHasQuestion = questionQueue.contains { $0.sessionId == sessionId }
                if !stillHasPermission && !stillHasQuestion,
                   sessions[sessionId]?.status == .waitingApproval
                       || sessions[sessionId]?.status == .waitingQuestion {
                    sessions[sessionId]?.status = (normalizedName == "Stop") ? .idle : .processing
                    sessions[sessionId]?.currentTool = nil
                    sessions[sessionId]?.toolDescription = nil
                }
            }
        }

        return effects
    }

    // MARK: - Connection routing (HookServer.processRequest + AppState handlers)

    enum RouteKind: Equatable {
        case permission
        case question
        case event
    }

    /// Where a hook event goes (upstream HookServer.routeKind, minus the
    /// Antigravity deferral which needs CodexPermissionRules).
    nonisolated static func routeKind(for event: HookEvent) -> RouteKind {
        let normalizedName = EventNormalizer.normalize(event.eventName)
        if normalizedName == "PermissionRequest" {
            return .permission
        }
        if normalizedName == "Notification", QuestionPayload.from(event: event) != nil {
            return .question
        }
        return .event
    }

    /// Route one decoded hook payload. Returns the exact JSON document the
    /// CLI's hook bridge should print. `origin` identifies the connection so
    /// a later peer drop can release only this CLI's prompts.
    func handleConnection(payload: Data, origin: ObjectIdentifier? = nil) async -> Data {
        guard payload.count <= Self.maxPayloadSize else {
            return Self.permissionDecisionData(behavior: "deny")
        }
        guard let event = HookEvent(from: payload) else {
            return Data(#"{"error":"parse_failed"}"#.utf8)
        }

        // Unknown `_source` values are dropped with an empty response so a
        // rogue bridge cannot mint sessions (upstream behavior).
        if let rawSource = event.rawJSON["_source"] as? String,
           AgentSessionSnapshot.normalizedSupportedSource(rawSource) == nil {
            return Data("{}".utf8)
        }

        switch Self.routeKind(for: event) {
        case .permission:
            // Codex fires PermissionRequest BEFORE its approval routing, and
            // the payload itself cannot tell "approve for me" (automatic
            // review) from a real ask — permission_mode stays "default"
            // either way. The session transcript CAN: its path rides in the
            // payload, and every turn context records `approvals_reviewer`.
            // Automatic review defers to Codex (a blocking queue would
            // re-ask what the reviewer already handles); a human ask queues
            // on the island like Claude's do.
            if (event.rawJSON["_source"] as? String)?.lowercased() == "codex",
               Self.codexUsesAutoReview(transcriptPath: event.rawJSON["transcript_path"] as? String) {
                Self.logPermissionRoute(event, outcome: "deferred-to-codex (auto review)")
                return Data("{}".utf8)
            }

            // Safe internal tools never need the user.
            if let toolName = event.toolName, Self.autoApproveTools.contains(toolName) {
                Self.logPermissionRoute(event, outcome: "auto-approved-tool")
                return Self.permissionDecisionData(behavior: "allow")
            }

            // AskUserQuestion is a question, not a permission.
            if event.toolName == "AskUserQuestion" {
                if Self.askUserQuestionItems(for: event).isEmpty {
                    // Nothing answerable in the payload — let the call through
                    // with an empty answer set (upstream guard path), with the
                    // session back to plain processing.
                    let sessionId = event.sessionId ?? "default"
                    if sessions[sessionId] == nil {
                        sessions[sessionId] = AgentSessionSnapshot()
                    }
                    apply(event)
                    sessions[sessionId]?.status = .processing
                    sessions[sessionId]?.currentTool = nil
                    sessions[sessionId]?.toolDescription = nil
                    let updatedInput = Self.askUserQuestionUpdatedInput(
                        event: event,
                        answers: [:],
                        scalarAnswer: nil,
                        questionAnswers: []
                    )
                    let obj: [String: Any] = [
                        "hookSpecificOutput": [
                            "hookEventName": "PermissionRequest",
                            "decision": [
                                "behavior": "allow",
                                "updatedInput": updatedInput,
                            ] as [String: Any],
                        ] as [String: Any],
                    ]
                    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
                }
                return await withCheckedContinuation { continuation in
                    enqueueAskUserQuestion(event, continuation: continuation, origin: origin)
                }
            }

            // Self-approving modes (auto / dontAsk / bypassPermissions):
            // answer nothing and step aside — the CLI decides, including
            // its denials. Queuing would put the island between the user
            // and a mode they explicitly switched on.
            if let mode = event.rawJSON["permission_mode"] as? String,
               Self.selfApprovingModes.contains(mode) {
                Self.logPermissionRoute(event, outcome: "stepped-aside mode=\(mode)")
                return Data("{}".utf8)
            }

            Self.logPermissionRoute(event, outcome: "queued")

            return await withCheckedContinuation { continuation in
                enqueuePermissionRequest(event, continuation: continuation, origin: origin)
            }

        case .question:
            return await withCheckedContinuation { continuation in
                enqueueNotificationQuestion(event, continuation: continuation, origin: origin)
            }

        case .event:
            apply(event)
            return Data("{}".utf8)
        }
    }

    // MARK: Enqueue paths

    private func enqueuePermissionRequest(
        _ event: HookEvent,
        continuation: CheckedContinuation<Data, Never>,
        origin: ObjectIdentifier?
    ) {
        let sessionId = event.sessionId ?? "default"

        // A permission replaces any question this same agent was asking
        // (mutually exclusive within one agent; upstream drains by agent_id).
        drainQuestions(sessionId: sessionId, agentId: event.agentId)

        enqueueWaiting(event: event, kind: .approval)

        let request = PermissionRequest(event: event, continuation: continuation)
        permissionQueue.append(request)
        if let origin {
            requestOrigins[request.id] = origin
        }
    }

    private func enqueueAskUserQuestion(
        _ event: HookEvent,
        continuation: CheckedContinuation<Data, Never>,
        origin: ObjectIdentifier?
    ) {
        let sessionId = event.sessionId ?? "default"
        drainQuestions(sessionId: sessionId, agentId: event.agentId)

        let firstQuestion = Self.askUserQuestionItems(for: event).first?.payload.question ?? "Question"
        enqueueWaiting(event: event, kind: .question(firstQuestion))

        let request = QuestionRequest(
            event: event,
            continuation: continuation,
            isFromPermission: true
        )
        questionQueue.append(request)
        if let origin {
            requestOrigins[request.id] = origin
        }
    }

    private func enqueueNotificationQuestion(
        _ event: HookEvent,
        continuation: CheckedContinuation<Data, Never>,
        origin: ObjectIdentifier?
    ) {
        guard QuestionPayload.from(event: event) != nil else {
            continuation.resume(returning: Data("{}".utf8))
            return
        }
        let sessionId = event.sessionId ?? "default"
        drainPermissions(sessionId: sessionId, agentId: event.agentId)

        // The reducer's Notification branch puts a question-bearing event into
        // waitingQuestion by itself.
        apply(event)

        let request = QuestionRequest(event: event, continuation: continuation)
        questionQueue.append(request)
        if let origin {
            requestOrigins[request.id] = origin
        }
    }

    /// Put a session into a waiting state "via a synthesized reducer event".
    ///
    /// The reducer has no PermissionRequest branch (upstream sets those fields
    /// by hand in AppState); synthesizing a Notification keeps session
    /// creation, metadata extraction and monitor effects flowing through the
    /// one true state machine. `permission_prompt` is the reducer's own
    /// spelling of waitingApproval; a `question` key routes to waitingQuestion.
    private func enqueueWaiting(event: HookEvent, kind: WaitingKind) {
        var raw = event.rawJSON
        raw["hook_event_name"] = "Notification"
        switch kind {
        case .approval:
            raw["notification_type"] = "permission_prompt"
            // Don't let a stale `question` key re-route to waitingQuestion.
            raw.removeValue(forKey: "question")
        case .question(let text):
            raw["question"] = text
            if raw["message"] == nil {
                raw["message"] = text
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let synthesized = HookEvent(from: data) else {
            return
        }
        apply(synthesized)

        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId]?.status == .waitingApproval {
            // Upstream also pins the tool onto the waiting card.
            sessions[sessionId]?.currentTool = event.activityLabel
            if let description = event.toolDescription {
                sessions[sessionId]?.toolDescription = description
            }
        }
    }

    private enum WaitingKind {
        case approval
        case question(String)
    }

    // MARK: - User decisions

    /// Approve the queued permission. `always` asks the CLI to add a
    /// session-scoped allow rule for the tool (ruleContent omitted for
    /// `mcp__*` tools — `mcp__server__tool(*)` never matches a real call).
    func approvePermission(_ id: UUID, always: Bool = false) {
        guard let index = permissionQueue.firstIndex(where: { $0.id == id }) else { return }
        let pending = permissionQueue.remove(at: index)
        requestOrigins.removeValue(forKey: pending.id)

        let responseData: Data
        if always {
            responseData = Self.alwaysAllowResponseData(event: pending.event)
        } else {
            responseData = Self.permissionDecisionData(behavior: "allow")
        }
        pending.continuation.resume(returning: responseData)
        reconcileWaitingStatus(sessionId: pending.sessionId, fallback: .processing)
    }

    func denyPermission(_ id: UUID) {
        guard let index = permissionQueue.firstIndex(where: { $0.id == id }) else { return }
        let pending = permissionQueue.remove(at: index)
        requestOrigins.removeValue(forKey: pending.id)
        pending.continuation.resume(returning: Self.permissionDecisionData(behavior: "deny"))
        reconcileWaitingStatus(sessionId: pending.sessionId, fallback: .processing)
    }

    /// Hide the request but keep it queued and the CLI blocked — the user can
    /// still answer it in the terminal, or reopen it later.
    func dismissPermission(_ id: UUID) {
        // Deliberately does not resume the continuation.
    }

    /// Answer the queued question. Single-question requests only; wizards
    /// with several questions need ``answerQuestionMulti(_:answers:)``.
    func answerQuestion(_ id: UUID, answer: String) {
        guard let index = questionQueue.firstIndex(where: { $0.id == id }) else { return }
        if questionQueue[index].isFromPermission, questionQueue[index].questions.count > 1 {
            return  // one answer cannot fill a wizard; use answerQuestionMulti
        }
        let answers = questionQueue[index].questions.map {
            QuestionAnswer(question: $0.payload.question, answer: answer, selectedOptions: [])
        }
        resolveQuestion(at: index, answers: answers)
    }

    /// Answer every question of an AskUserQuestion wizard, one entry per
    /// question, in order. A multiSelect question's `selectedOptions` carries
    /// its chosen labels.
    func answerQuestionMulti(_ id: UUID, answers: [QuestionAnswer]) {
        guard let index = questionQueue.firstIndex(where: { $0.id == id }) else { return }
        let items = questionQueue[index].questions
        guard answers.count == items.count,
              zip(answers, items).allSatisfy({ $0.question == $1.payload.question }) else {
            return  // answers collected for a different request (#333 parity)
        }
        resolveQuestion(at: index, answers: answers)
    }

    /// Skip: for AskUserQuestion this denies the tool call; for a Notification
    /// question it returns an empty Notification response.
    func skipQuestion(_ id: UUID) {
        guard let index = questionQueue.firstIndex(where: { $0.id == id }) else { return }
        let pending = questionQueue.remove(at: index)
        requestOrigins.removeValue(forKey: pending.id)

        let responseData: Data
        if pending.isFromPermission {
            responseData = Self.permissionDecisionData(behavior: "deny")
        } else {
            responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"Notification"}}"#.utf8)
        }
        pending.continuation.resume(returning: responseData)
        reconcileWaitingStatus(sessionId: pending.sessionId, fallback: .processing)
    }

    private func resolveQuestion(at index: Int, answers: [QuestionAnswer]) {
        let pending = questionQueue.remove(at: index)
        requestOrigins.removeValue(forKey: pending.id)

        let responseData: Data
        if pending.isFromPermission {
            var answersDict: [String: String] = [:]
            for item in pending.questions {
                let match = answers.first { $0.question == item.payload.question }
                answersDict[item.answerKey] = match?.answer ?? ""
            }
            let updatedInput = Self.askUserQuestionUpdatedInput(
                event: pending.event,
                answers: answersDict,
                scalarAnswer: answers.first?.answer,
                questionAnswers: answers
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput,
                    ] as [String: Any],
                ] as [String: Any],
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answers.first?.answer ?? "",
                ] as [String: Any],
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.continuation.resume(returning: responseData)
        reconcileWaitingStatus(sessionId: pending.sessionId, fallback: .processing)
    }

    // MARK: - Bulk release (peer drop, session end, teardown)

    /// Release everything a session still blocks on: permissions and
    /// AskUserQuestion calls are denied, Notification questions answered with
    /// an empty document.
    func denyAllForSession(sessionId: String) {
        drainPermissions(sessionId: sessionId, agentId: nil)
        drainQuestions(sessionId: sessionId, agentId: nil)
        reconcileWaitingStatus(sessionId: sessionId, fallback: .idle)
    }

    /// Release everything parked on a connection whose peer (the bridge
    /// process) died — the CLI cannot receive an answer anymore.
    func denyAll(from connection: NWConnection) {
        denyAll(origin: ObjectIdentifier(connection))
    }

    /// Same release keyed by a connection identity captured at accept time.
    func denyAll(origin: ObjectIdentifier) {
        let denyPermissionData = Self.permissionDecisionData(behavior: "deny")
        var affectedSessions = Set<String>()
        permissionQueue.removeAll { request in
            guard requestOrigins.removeValue(forKey: request.id) == origin else { return false }
            affectedSessions.insert(request.sessionId)
            request.continuation.resume(returning: denyPermissionData)
            return true
        }
        questionQueue.removeAll { request in
            guard requestOrigins.removeValue(forKey: request.id) == origin else { return false }
            affectedSessions.insert(request.sessionId)
            let data = request.isFromPermission
                ? denyPermissionData
                : Data("{}".utf8)
            request.continuation.resume(returning: data)
            return true
        }
        for sessionId in affectedSessions {
            reconcileWaitingStatus(sessionId: sessionId, fallback: .idle)
        }
    }

    /// A waiting badge is actionable only while this store still has a request
    /// for the session. Observe-only notifications have no queue and age out
    /// through performCleanup instead.
    private func reconcileWaitingStatus(sessionId: String, fallback: AgentStatus) {
        guard sessions[sessionId]?.status == .waitingApproval
                || sessions[sessionId]?.status == .waitingQuestion else { return }
        if permissionQueue.contains(where: { $0.sessionId == sessionId }) {
            sessions[sessionId]?.status = .waitingApproval
        } else if questionQueue.contains(where: { $0.sessionId == sessionId }) {
            sessions[sessionId]?.status = .waitingQuestion
        } else {
            sessions[sessionId]?.status = fallback
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    }

    private func drainPermissions(sessionId: String, agentId: String?) {
        let denyData = Self.permissionDecisionData(behavior: "deny")
        permissionQueue.removeAll { request in
            guard request.sessionId == sessionId,
                  agentId == nil || request.event.agentId == agentId else { return false }
            requestOrigins.removeValue(forKey: request.id)
            request.continuation.resume(returning: denyData)
            return true
        }
    }

    private func drainQuestions(sessionId: String, agentId: String?) {
        let denyData = Self.permissionDecisionData(behavior: "deny")
        questionQueue.removeAll { request in
            guard request.sessionId == sessionId,
                  agentId == nil || request.event.agentId == agentId else { return false }
            requestOrigins.removeValue(forKey: request.id)
            request.continuation.resume(returning: request.isFromPermission ? denyData : Data("{}".utf8))
            return true
        }
    }

    /// Store teardown: nothing can answer these anymore, so every blocked CLI
    /// gets the response that frees it.
    private func drainAllForTeardown() {
        let denyData = Self.permissionDecisionData(behavior: "deny")
        for pending in permissionQueue {
            pending.continuation.resume(returning: denyData)
        }
        permissionQueue = []
        for pending in questionQueue {
            let data = pending.isFromPermission ? denyData : Data("{}".utf8)
            pending.continuation.resume(returning: data)
        }
        questionQueue = []
        requestOrigins = [:]
    }

    // MARK: - Cleanup (upstream cleanupIdleSessions, the no-monitor halves)

    /// 3s heartbeat: unstick sessions whose CLI stopped talking, release
    /// waits that were never answered, drop long-idle sessions.
    func performCleanup(now: Date = Date()) {
        guard !isPaused else { return }

        // Stuck mid-turn: no tool for 300s, a tool for 180s.
        for (key, session) in sessions
        where session.status == .processing || session.status == .running {
            let threshold: TimeInterval = session.currentTool != nil ? 180 : 300
            if now.timeIntervalSince(session.lastActivity) > threshold {
                sessions[key]?.status = .idle
                sessions[key]?.currentTool = nil
                sessions[key]?.toolDescription = nil
            }
        }

        // A wait nobody answered for 300s — the connection is most likely
        // gone; release the CLI with a deny.
        for (key, session) in sessions
        where session.status == .waitingApproval || session.status == .waitingQuestion {
            if now.timeIntervalSince(session.lastActivity) > 300 {
                denyAllForSession(sessionId: key)
            }
        }

        // Idle for 30 minutes — the card is dead weight.
        for (key, session) in sessions where session.status == .idle {
            if now.timeIntervalSince(session.lastActivity) > 1800 {
                sessions.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Response builders

    /// Whether the Codex session that sent this request answers approvals
    /// with automatic review ("approve for me"). The LAST
    /// `approvals_reviewer` value in the transcript wins — the reviewer
    /// can be toggled mid-session. Unreadable/missing transcript assumes
    /// automatic review: defer (stay quiet) rather than re-ask what the
    /// reviewer may already be handling.
    nonisolated private static func codexUsesAutoReview(transcriptPath: String?) -> Bool {
        guard let path = transcriptPath, !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return true }
        // Plain escaped needle, not a raw literal: `#""…":"#` eats its
        // trailing quote as the closing delimiter and silently searches for
        // the wrong string.
        guard let range = text.range(of: "\"approvals_reviewer\":\"", options: .backwards) else {
            return false  // no reviewer configured → a genuine human ask
        }
        return text[range.upperBound...].hasPrefix("auto_review")
    }

    /// One line per incoming PermissionRequest — tool, mode, routing
    /// outcome — so "why did the island ask" is answerable from
    /// /tmp/doisland-agents-activity.log. Deliberately no tool_input: the
    /// log must stay safe to paste (commands can carry secrets). The full
    /// payload (minus tool_input) rides along so undocumented fields —
    /// the only place an approval policy could hide — are visible.
    nonisolated private static func logPermissionRoute(_ event: HookEvent, outcome: String) {
        var payload = event.rawJSON
        payload.removeValue(forKey: "tool_input")
        payload.removeValue(forKey: "tool_response")
        let detail = (try? Self.serializeSafely(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] PermissionRequest → \(outcome)\n  payload: \(detail)\n"
        let path = "/tmp/doisland-agents-activity.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    /// JSONSerialization minus the crash-prone edge cases: values that
    /// snuck in non-property-list types drop out instead of killing the
    /// logger.
    nonisolated private static func serializeSafely(_ object: [String: Any]) throws -> Data {
        let filtered = object.filter { JSONSerialization.isValidJSONObject([$0.value]) }
        return try JSONSerialization.data(
            withJSONObject: filtered, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"…"}}}`
    nonisolated private static func permissionDecisionData(behavior: String) -> Data {
        Data(
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"\#(behavior)"}}}"#
                .utf8
        )
    }

    /// "Always allow" — allow plus a permission update so the CLI stops
    /// asking for this tool. Claude Code only: codex requests never queue
    /// (they defer at the routing gate above).
    ///
    /// Echo the `permission_suggestions` entry Claude itself attached —
    /// exactly the rule its native dialog would write, destination
    /// included. Without a suggestion, add a whole-tool allow rule with
    /// `ruleContent` OMITTED (the docs' spelling for matching the whole
    /// tool — `"*"` is invalid rule content and Claude rejects the entire
    /// update as "unsupported updatedPermissions"), written where the
    /// native "don't ask again" lands: project-local settings.
    nonisolated private static func alwaysAllowResponseData(event: HookEvent) -> Data {
        var update: [String: Any]
        if let suggestions = event.rawJSON["permission_suggestions"] as? [[String: Any]],
           let echoed = suggestions.first,
           JSONSerialization.isValidJSONObject([echoed]) {
            update = echoed
        } else if let toolName = event.toolName, !toolName.isEmpty {
            update = [
                "type": "addRules",
                "rules": [["toolName": toolName] as [String: Any]],
                "behavior": "allow",
                "destination": "localSettings",
            ]
        } else {
            return permissionDecisionData(behavior: "allow")
        }

        let obj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "updatedPermissions": [update],
                ] as [String: Any],
            ] as [String: Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? permissionDecisionData(behavior: "allow")
    }

    // MARK: - AskUserQuestion payload parsing / answer injection

    /// Parse `tool_input.questions` (and the single-question spelling) into
    /// answerable items, deduplicating answer keys the way Claude Code's
    /// `mapToolResultToToolResultBlockParam` expects (upstream handleAskUserQuestion).
    nonisolated static func askUserQuestionItems(for event: HookEvent) -> [AskQuestionItem] {
        var items: [AskQuestionItem] = []

        if let questions = event.toolInput?["questions"] as? [[String: Any]] {
            for item in questions {
                let questionText = item["question"] as? String ?? "Question"
                let header = item["header"] as? String
                let multiSelect = item["multiSelect"] as? Bool ?? false
                var optionLabels: [String]?
                var optionDescriptions: [String]?
                if let options = item["options"] as? [[String: Any]] {
                    optionLabels = options.compactMap { $0["label"] as? String }
                    optionDescriptions = options.compactMap { $0["description"] as? String }
                }
                if optionLabels?.isEmpty == true { optionLabels = nil }
                if optionDescriptions?.isEmpty == true { optionDescriptions = nil }
                items.append(
                    AskQuestionItem(
                        payload: QuestionPayload(
                            question: questionText,
                            options: optionLabels,
                            descriptions: optionDescriptions,
                            header: header
                        ),
                        multiSelect: multiSelect
                    )
                )
            }
        }

        if items.isEmpty {
            let questionText = event.toolInput?["question"] as? String ?? "Question"
            var options: [String]?
            if let stringOptions = event.toolInput?["options"] as? [String] {
                options = stringOptions
            } else if let dictOptions = event.toolInput?["options"] as? [[String: Any]] {
                options = dictOptions.compactMap { $0["label"] as? String }
            }
            if !questionText.isEmpty {
                items.append(
                    AskQuestionItem(
                        payload: QuestionPayload(question: questionText, options: options),
                        multiSelect: false
                    )
                )
            }
        }

        // Deduplicate answer keys (identical question texts) with _N suffixes.
        var usedKeys = Set<String>()
        return items.map { item in
            let base = item.payload.question
            var key = base
            if usedKeys.contains(key) {
                var suffix = 2
                while usedKeys.contains("\(base)_\(suffix)") {
                    suffix += 1
                }
                key = "\(base)_\(suffix)"
            }
            usedKeys.insert(key)
            return AskQuestionItem(payload: item.payload, multiSelect: item.multiSelect, answerKey: key)
        }
    }

    /// Build `updatedInput` for an answered AskUserQuestion (upstream
    /// askUserQuestionUpdatedInput, plus this port's per-question injection).
    ///
    /// - `answers`: question-text-keyed answer map (Claude Code's lookup).
    /// - `answer`: scalar convenience copy of the first answer.
    /// - each question dict gets its `answer` (string) / `answers` (label
    ///   array for multiSelect) injected so label-array consumers can read
    ///   structured picks without splitting a joined string.
    nonisolated private static func askUserQuestionUpdatedInput(
        event: HookEvent,
        answers: [String: String],
        scalarAnswer: String?,
        questionAnswers: [QuestionAnswer]
    ) -> [String: Any] {
        var updatedInput = event.toolInput ?? [:]

        // `questions` must always be present (Claude Code maps over it
        // directly; absent key = "undefined is not an object").
        let originalQuestions = (event.toolInput?["questions"] as? [[String: Any]])
            ?? ((event.toolInput?["questions"] as? [Any]) ?? [])
        updatedInput["questions"] = originalQuestions

        updatedInput["answers"] = answers
        if let scalarAnswer, !scalarAnswer.isEmpty {
            updatedInput["answer"] = scalarAnswer
        }

        // Per-question injection: answers are matched by question text.
        if var questions = updatedInput["questions"] as? [[String: Any]] {
            for index in questions.indices {
                let text = questions[index]["question"] as? String
                guard let text, let match = questionAnswers.first(where: { $0.question == text }) else {
                    continue
                }
                if !match.selectedOptions.isEmpty {
                    questions[index]["answers"] = match.selectedOptions
                    questions[index]["answer"] = match.selectedOptions.joined(separator: ", ")
                } else {
                    questions[index]["answer"] = match.answer
                }
            }
            updatedInput["questions"] = questions
        }

        return updatedInput
    }
}
