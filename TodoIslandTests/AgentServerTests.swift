import XCTest
import Network
import Darwin

@testable import TodoIsland

/// Integration + routing tests for the agent-status socket server and its
/// session store. Socket tests run a real NWListener on a unique temp path and
/// drive it with a POSIX client that mimics the hook bridge: write one JSON
/// document, `shutdown(SHUT_WR)`, read the response to EOF.
@MainActor
final class AgentServerTests: XCTestCase {

    private var store: AgentSessionStore!
    private var server: AgentHookServer!
    private var socketPath: String!

    override func setUp() async throws {
        try await super.setUp()
        store = AgentSessionStore()
        socketPath = Self.makeSocketPath()
        server = AgentHookServer(store: store, socketPath: socketPath)
        server.start()
        let ready = await server.waitUntilReady(timeout: 5)
        let path = socketPath ?? "<nil>"
        XCTAssertTrue(ready, "listener should become ready on \(path)")
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        store = nil
        if let socketPath {
            unlink(socketPath)
        }
        socketPath = nil
        try await super.tearDown()
    }

    private static func makeSocketPath() -> String {
        var dir = NSTemporaryDirectory()
        if !dir.hasSuffix("/") { dir += "/" }
        let path = dir + "doisland-agenttests-\(UUID().uuidString.prefix(8)).sock"
        precondition(path.utf8.count < 104, "unix socket path too long: \(path)")
        return path
    }

    // MARK: - POSIX bridge client

    /// Blocking connect/write/half-close/read, run off the main actor so the
    /// server (main queue) is free to answer.
    private func roundTrip(_ payload: Data) async throws -> Data {
        let path = try XCTUnwrap(socketPath)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.sendAndReceive(payload, to: path))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Pure POSIX client code — nonisolated so it can run on the worker queue.
    private nonisolated static func sendAndReceive(_ payload: Data, to path: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }

        // A server-side close mid-write must not kill the test process.
        var noSigPipe: Int32 = 1
        _ = withUnsafeMutableBytes(of: &noSigPipe) { raw in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, raw.baseAddress, socklen_t(raw.count))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let sunPathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        precondition(pathBytes.count < sunPathCapacity, "unix socket path too long: \(path)")
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        // Write everything; tolerate failure once the server has denied an
        // oversized payload and torn the connection down.
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            if written <= 0 { break }
            offset += written
        }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while response.count <= AgentSessionStore.maxPayloadSize {
            let readCount = buffer.withUnsafeMutableBufferPointer { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            if readCount <= 0 { break }
            response.append(contentsOf: buffer[0..<readCount])
        }
        return response
    }

    // MARK: - Helpers

    private func jsonDictionary(_ data: Data) throws -> [String: Any] {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object, "response should be a JSON object: \(text)")
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private static let allowJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
    private static let denyJSON = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#

    private func assertEqualJSON(_ data: Data, _ expected: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actualObject = try? JSONSerialization.jsonObject(with: data)
        let expectedObject = try? JSONSerialization.jsonObject(with: Data(expected.utf8))
        XCTAssertEqual(
            actualObject as? NSDictionary, expectedObject as? NSDictionary,
            "\(String(data: data, encoding: .utf8) ?? "?") should equal \(expected)",
            file: file, line: line
        )
    }

    @discardableResult
    private func applyPayload(_ json: String) throws -> HookEvent {
        let event = try XCTUnwrap(HookEvent(from: Data(json.utf8)), "fixture should decode")
        store.apply(event)
        return event
    }

    private func waitForFirstPermission(timeout: TimeInterval = 5) async -> AgentSessionStore.PermissionRequest? {
        _ = await waitUntil(timeout: timeout) { !self.store.permissionQueue.isEmpty }
        return store.permissionQueue.first
    }

    private func waitForSecondPermission(timeout: TimeInterval = 5) async -> AgentSessionStore.PermissionRequest? {
        _ = await waitUntil(timeout: timeout) { self.store.permissionQueue.count >= 2 }
        return store.permissionQueue.count >= 2 ? store.permissionQueue[1] : nil
    }

    private func waitForFirstQuestion(timeout: TimeInterval = 5) async -> AgentSessionStore.QuestionRequest? {
        _ = await waitUntil(timeout: timeout) { !self.store.questionQueue.isEmpty }
        return store.questionQueue.first
    }

    // MARK: - Socket integration

    func testUserPromptSubmitRoundTripReturnsEmptyAndCreatesProcessingSession() async throws {
        let payload = #"{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"/tmp","prompt":"hi"}"#

        let response = try await roundTrip(Data(payload.utf8))

        XCTAssertEqual(response, Data("{}".utf8))
        let session = try XCTUnwrap(store.sessions["t1"], "session t1 should exist")
        XCTAssertEqual(session.status, .processing)
        XCTAssertEqual(session.lastUserPrompt, "hi")
        XCTAssertEqual(session.cwd, "/tmp")
        XCTAssertFalse(store.hasPending)
    }

    func testPermissionRequestRoundTripReturnsExactAllowJSONAfterApproval() async throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"t2","tool_name":"Bash","tool_input":{"command":"ls -la","description":"list files"},"tool_use_id":"tu-1","cwd":"/tmp"}
        """

        let responseTask = Task { [self] in
            try await roundTrip(Data(payload.utf8))
        }

        let request = await waitForFirstPermission()
        let permission = try XCTUnwrap(request, "permission should be queued")
        XCTAssertEqual(permission.event.toolName, "Bash")
        XCTAssertEqual(permission.sessionId, "t2")
        XCTAssertEqual(store.sessions["t2"]?.status, .waitingApproval)

        store.approvePermission(permission.id)

        let response = try await responseTask.value
        try assertEqualJSON(response, Self.allowJSON)
        XCTAssertTrue(store.permissionQueue.isEmpty, "queue drains after approving")
    }

    func testOversizedPayloadIsDeniedWithoutQueueing() async throws {
        var payload = Data(#"{"hook_event_name":"PermissionRequest","session_id":"t3","tool_name":"Bash","pad":"a"#.utf8)
        payload.append(Data(repeating: 0x61, count: AgentSessionStore.maxPayloadSize + 1024))

        let response = try await roundTrip(payload)

        try assertEqualJSON(response, Self.denyJSON)
        XCTAssertTrue(store.permissionQueue.isEmpty, "oversized payload must not queue anything")
        XCTAssertNil(store.sessions["t3"], "oversized payload must not create a session")
    }

    // MARK: - Store routing (no socket)

    func testParseFailureReturnsErrorJSON() async throws {
        let response = await store.handleConnection(payload: Data("not json at all".utf8))
        let object = try jsonDictionary(response)
        XCTAssertEqual(object["error"] as? String, "parse_failed")
    }

    func testInternalToolPermissionsAreAutoApprovedInstantly() async throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"t4","tool_name":"TodoWrite","tool_input":{"todos":[]},"cwd":"/tmp"}
        """
        let response = await store.handleConnection(payload: Data(payload.utf8))
        try assertEqualJSON(response, Self.allowJSON)
        XCTAssertTrue(store.permissionQueue.isEmpty, "internal tool must not queue")
        XCTAssertNil(store.sessions["t4"], "auto-approve never surfaces UI state (upstream behavior)")
        XCTAssertFalse(store.hasPending)
    }

    func testSelfApprovingModesReturnNoDecisionWithoutQueueing() async throws {
        for mode in ["auto", "dontAsk", "bypassPermissions"] {
            let payload = """
            {"hook_event_name":"PermissionRequest","session_id":"tm","permission_mode":"\(mode)","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}
            """
            let response = await store.handleConnection(payload: Data(payload.utf8))
            // No decision: the CLI's own flow (classifier / bypass / auto-deny)
            // decides — not an island "allow", which would out-rank it.
            XCTAssertEqual(response, Data("{}".utf8), "mode \(mode)")
            XCTAssertTrue(store.permissionQueue.isEmpty, "mode \(mode) must not queue")
            XCTAssertFalse(store.hasPending, "mode \(mode)")
        }
    }

    func testPromptingModesStillQueue() async throws {
        for mode in ["default", "acceptEdits", "plan"] {
            let payload = """
            {"hook_event_name":"PermissionRequest","session_id":"tp","permission_mode":"\(mode)","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}
            """
            let responseTask = Task { [self] in
                await store.handleConnection(payload: Data(payload.utf8))
            }
            let request = await waitForFirstPermission()
            let permission = try XCTUnwrap(request, "mode \(mode) should queue")
            store.denyPermission(permission.id)
            _ = try await responseTask.value
        }
        XCTAssertTrue(store.permissionQueue.isEmpty)
    }

    func testAskUserQuestionStillQueuesInSelfApprovingMode() async throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"tq","permission_mode":"auto","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one","key":"q1","options":[{"label":"A"},{"label":"B"}]}]},"cwd":"/tmp"}
        """
        let responseTask = Task { [self] in
            await store.handleConnection(payload: Data(payload.utf8))
        }
        let request = await waitForFirstQuestion()
        let question = try XCTUnwrap(request, "questions are for the user in every mode")
        store.skipQuestion(question.id)
        _ = try await responseTask.value
        XCTAssertTrue(store.questionQueue.isEmpty)
    }

    func testAlwaysAllowEchoesSuggestionOrOmitsRuleContent() async throws {
        // With a permission_suggestions entry: echo it verbatim — the exact
        // rule Claude's own dialog would write.
        let suggested = """
        {"hook_event_name":"PermissionRequest","session_id":"t5","tool_name":"Bash","tool_input":{"command":"cargo build"},"cwd":"/tmp","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"cargo build"}],"behavior":"allow","destination":"localSettings"}]}
        """
        let suggestedTask = Task { [self] in
            await store.handleConnection(payload: Data(suggested.utf8))
        }
        let suggestedRequest = await waitForFirstPermission()
        store.approvePermission(try XCTUnwrap(suggestedRequest, "should queue").id, always: true)
        let suggestedResponse = try jsonDictionary(try await suggestedTask.value)
        let echoedDecision = try XCTUnwrap(
            (suggestedResponse["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(echoedDecision["behavior"] as? String, "allow")
        let echoed = try XCTUnwrap(echoedDecision["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(echoed[0]["destination"] as? String, "localSettings")
        let echoedRules = try XCTUnwrap(echoed[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(echoedRules[0]["ruleContent"] as? String, "cargo build")

        // Without a suggestion: whole-tool rule, ruleContent OMITTED
        // ("*" is invalid rule content — Claude rejects the whole update),
        // persisted where the native "don't ask again" lands.
        let bash = """
        {"hook_event_name":"PermissionRequest","session_id":"t5b","tool_name":"Bash","tool_input":{"command":"cargo build"},"cwd":"/tmp"}
        """
        let bashTask = Task { [self] in
            await store.handleConnection(payload: Data(bash.utf8))
        }
        let bashRequest = await waitForFirstPermission()
        store.approvePermission(try XCTUnwrap(bashRequest, "Bash permission should queue").id, always: true)
        let bashResponse = try jsonDictionary(try await bashTask.value)

        let bashDecision = try XCTUnwrap(
            (bashResponse["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        XCTAssertEqual(bashDecision["behavior"] as? String, "allow")
        let bashPermissions = try XCTUnwrap(bashDecision["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(bashPermissions.count, 1)
        XCTAssertEqual(bashPermissions[0]["type"] as? String, "addRules")
        XCTAssertEqual(bashPermissions[0]["behavior"] as? String, "allow")
        XCTAssertEqual(bashPermissions[0]["destination"] as? String, "localSettings")
        let bashRules = try XCTUnwrap(bashPermissions[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(bashRules[0]["toolName"] as? String, "Bash")
        XCTAssertNil(bashRules[0]["ruleContent"], "whole-tool rules must omit ruleContent")

        // mcp__ tools: same whole-tool spelling (bare name).
        let mcp = """
        {"hook_event_name":"PermissionRequest","session_id":"t5c","tool_name":"mcp__github__create_issue","tool_input":{},"cwd":"/tmp"}
        """
        let mcpTask = Task { [self] in
            await store.handleConnection(payload: Data(mcp.utf8))
        }
        let mcpRequest = await waitForFirstPermission()
        store.approvePermission(try XCTUnwrap(mcpRequest, "mcp permission should queue").id, always: true)
        let mcpResponse = try jsonDictionary(try await mcpTask.value)

        let mcpDecision = try XCTUnwrap(
            (mcpResponse["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        let mcpPermissions = try XCTUnwrap(mcpDecision["updatedPermissions"] as? [[String: Any]])
        let mcpRules = try XCTUnwrap(mcpPermissions[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(mcpRules[0]["toolName"] as? String, "mcp__github__create_issue")
        XCTAssertNil(mcpRules[0]["ruleContent"], "mcp rules must not carry a ruleContent")
    }

    func testCodexAutoReviewDefersAndHumanAskQueues() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-transcripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // approve-for-me: the transcript's turn contexts record
        // approvals_reviewer "auto_review" (discovered in real rollouts —
        // the hook payload itself carries no such field).
        let autoReview = dir.appendingPathComponent("auto.jsonl")
        try #"{"turn":1,"approvals_reviewer":"auto_review"}"#
            .write(to: autoReview, atomically: true, encoding: .utf8)
        let autoPayload = """
        {"hook_event_name":"PermissionRequest","_source":"codex","session_id":"tcr1","permission_mode":"default","tool_name":"Bash","transcript_path":"\(autoReview.path)","tool_input":{"command":"ls"},"cwd":"/tmp"}
        """
        let autoResponse = await store.handleConnection(payload: Data(autoPayload.utf8))
        XCTAssertEqual(autoResponse, Data("{}".utf8))
        XCTAssertTrue(store.permissionQueue.isEmpty, "auto review must defer")
        XCTAssertFalse(store.hasPending)

        // Human ask: no reviewer configured → queue on the island.
        let human = dir.appendingPathComponent("human.jsonl")
        try #"{"turn":1}"#.write(to: human, atomically: true, encoding: .utf8)
        let humanPayload = """
        {"hook_event_name":"PermissionRequest","_source":"codex","session_id":"tcr2","permission_mode":"default","tool_name":"Bash","transcript_path":"\(human.path)","tool_input":{"command":"ls"},"cwd":"/tmp"}
        """
        let humanTask = Task { [self] in
            await store.handleConnection(payload: Data(humanPayload.utf8))
        }
        let request = await waitForFirstPermission()
        let permission = try XCTUnwrap(request, "human ask should queue")
        store.approvePermission(permission.id)
        let humanResponse = try jsonDictionary(try await humanTask.value)
        let decision = try XCTUnwrap(
            (humanResponse["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
    }

  func testCodexUnreadableTranscriptDefersConservatively() async throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","_source":"codex","session_id":"tcr3","tool_name":"Bash","transcript_path":"/nonexistent/doisland-test.jsonl","tool_input":{"command":"ls"},"cwd":"/tmp"}
        """
        let response = await store.handleConnection(payload: Data(payload.utf8))
        XCTAssertEqual(response, Data("{}".utf8))
        XCTAssertTrue(store.permissionQueue.isEmpty, "unreadable → assume auto review → defer")
    }

    func testDenyPermissionReturnsExactDenyJSON() async throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"t6","tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"x"},"cwd":"/tmp"}
        """
        let responseTask = Task { [self] in
            await store.handleConnection(payload: Data(payload.utf8))
        }
        let queued = await waitForFirstPermission()
        store.denyPermission(try XCTUnwrap(queued, "Write permission should queue").id)
        try assertEqualJSON(try await responseTask.value, Self.denyJSON)
    }

    func testDismissKeepsRequestQueuedAndCLIBlockedThenApproveStillAnswers() async throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"t7","tool_name":"WebFetch","tool_input":{"url":"https://example.com"},"cwd":"/tmp"}
        """
        let responseTask = Task { [self] in
            await store.handleConnection(payload: Data(payload.utf8))
        }
        let queued = await waitForFirstPermission()
        let request = try XCTUnwrap(queued, "WebFetch permission should queue")

        store.dismissPermission(request.id)

        XCTAssertEqual(store.permissionQueue.count, 1, "dismiss keeps the request queued")
        XCTAssertTrue(store.hasPending)
        // Still blocked after a beat: give the CLI a moment to prove it.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.permissionQueue.count, 1)
        store.approvePermission(request.id)
        try assertEqualJSON(try await responseTask.value, Self.allowJSON)
    }

    func testAskUserQuestionAnswerInjectsAnswersIntoUpdatedInput() async throws {
        let payload = """
        {"hook_event_name":"PermissionRequest","session_id":"t8","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Ship it?","header":"ship","options":[{"label":"Yes"},{"label":"No"}]},{"question":"Which parts?","header":"parts","multiSelect":true,"options":[{"label":"Core"},{"label":"Docs"}]}]},"cwd":"/tmp"}
        """
        let responseTask = Task { [self] in
            await store.handleConnection(payload: Data(payload.utf8))
        }

        let queuedQuestion = await waitForFirstQuestion()
        let request = try XCTUnwrap(queuedQuestion, "AskUserQuestion should become a queued question")
        XCTAssertTrue(request.isFromPermission)
        XCTAssertEqual(request.questions.count, 2)
        XCTAssertEqual(request.questions[0].payload.options, ["Yes", "No"])
        XCTAssertTrue(request.questions[1].multiSelect)
        XCTAssertEqual(store.sessions["t8"]?.status, .waitingQuestion)

        store.answerQuestionMulti(request.id, answers: [
            AgentSessionStore.QuestionAnswer(question: "Ship it?", answer: "Yes"),
            AgentSessionStore.QuestionAnswer(
                question: "Which parts?",
                answer: "Core, Docs",
                selectedOptions: ["Core", "Docs"]
            ),
        ])

        let response = try jsonDictionary(try await responseTask.value)
        let decision = try XCTUnwrap(
            (response["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        )
        XCTAssertEqual(decision["behavior"] as? String, "allow")

        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: String])
        XCTAssertEqual(answers["Ship it?"], "Yes")
        XCTAssertEqual(answers["Which parts?"], "Core, Docs")
        XCTAssertEqual(updatedInput["answer"] as? String, "Yes")

        let questions = try XCTUnwrap(updatedInput["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions[0]["answer"] as? String, "Yes")
        XCTAssertEqual(questions[1]["answer"] as? String, "Core, Docs")
        XCTAssertEqual(questions[1]["answers"] as? [String], ["Core", "Docs"])
    }

    func testNotificationQuestionAnswerAndSkipShapes() async throws {
        let payload = """
        {"hook_event_name":"Notification","session_id":"t9","question":"Proceed with the deploy?","options":["yes","no"],"cwd":"/tmp"}
        """
        let answerTask = Task { [self] in
            await store.handleConnection(payload: Data(payload.utf8))
        }
        let request = await waitForFirstQuestion()
        let notificationRequest = try XCTUnwrap(request, "Notification question should queue")
        XCTAssertFalse(notificationRequest.isFromPermission)
        XCTAssertEqual(notificationRequest.question?.question, "Proceed with the deploy?")
        XCTAssertEqual(store.sessions["t9"]?.status, .waitingQuestion)

        store.answerQuestion(notificationRequest.id, answer: "yes")

        let answered = try jsonDictionary(try await answerTask.value)
        XCTAssertEqual(
            answered as NSDictionary,
            ["hookSpecificOutput": ["hookEventName": "Notification", "answer": "yes"]] as NSDictionary
        )

        // Skip: bare Notification document, no answer key.
        let skipPayload = """
        {"hook_event_name":"Notification","session_id":"t9b","question":"Another one?","cwd":"/tmp"}
        """
        let skipTask = Task { [self] in
            await store.handleConnection(payload: Data(skipPayload.utf8))
        }
        let skipQueued = await waitForFirstQuestion()
        let skipRequest = try XCTUnwrap(skipQueued, "second question should queue")
        store.skipQuestion(skipRequest.id)
        let skipResponse = try jsonDictionary(try await skipTask.value)
        XCTAssertEqual(
            skipResponse as NSDictionary,
            ["hookSpecificOutput": ["hookEventName": "Notification"]] as NSDictionary
        )
    }

    func testSessionEndRemovesSessionAndDeniesItsPendingPermission() async throws {
        try applyPayload(#"{"hook_event_name":"UserPromptSubmit","session_id":"t10","cwd":"/tmp","prompt":"go"}"#)
        let permissionTask = Task { [self] in
            await store.handleConnection(payload: Data(
                #"{"hook_event_name":"PermissionRequest","session_id":"t10","tool_name":"Bash","tool_input":{"command":"make"},"cwd":"/tmp"}"#.utf8
            ))
        }
        let queued = await waitForFirstPermission()
        XCTAssertNotNil(queued, "permission should queue")

        try applyPayload(#"{"hook_event_name":"SessionEnd","session_id":"t10"}"#)

        XCTAssertNil(store.sessions["t10"], "SessionEnd removes the session")
        XCTAssertTrue(store.permissionQueue.isEmpty, "SessionEnd drains the session's pending")
        try assertEqualJSON(try await permissionTask.value, Self.denyJSON)
    }

    func testPeerDropReleasesOnlyThatConnection() async throws {
        let connectionA = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let connectionB = NWConnection(host: "127.0.0.1", port: 2, using: .tcp)
        defer { connectionA.cancel(); connectionB.cancel() }

        let taskA = Task { [self] in
            await store.handleConnection(
                payload: Data(#"{"hook_event_name":"PermissionRequest","session_id":"pa","tool_name":"Bash","tool_input":{"command":"a"},"cwd":"/tmp"}"#.utf8),
                origin: ObjectIdentifier(connectionA)
            )
        }
        let taskB = Task { [self] in
            await store.handleConnection(
                payload: Data(#"{"hook_event_name":"PermissionRequest","session_id":"pb","tool_name":"Bash","tool_input":{"command":"b"},"cwd":"/tmp"}"#.utf8),
                origin: ObjectIdentifier(connectionB)
            )
        }
        let firstQueued = await waitForFirstPermission()
        XCTAssertNotNil(firstQueued, "first permission should queue")
        let secondQueued = await waitForSecondPermission()
        XCTAssertNotNil(secondQueued, "second permission should queue")

        store.denyAll(from: connectionA)

        try assertEqualJSON(try await taskA.value, Self.denyJSON)
        XCTAssertEqual(store.permissionQueue.count, 1, "the other connection's request stays queued")
        XCTAssertEqual(store.permissionQueue.first?.sessionId, "pb")

        let survivor = try XCTUnwrap(store.permissionQueue.first)
        store.approvePermission(survivor.id)
        try assertEqualJSON(try await taskB.value, Self.allowJSON)
    }

    func testStopTurnEnqueuesCompletionAndDropIdleSweepsOldSessions() async throws {
        try applyPayload(#"{"hook_event_name":"UserPromptSubmit","session_id":"t11","cwd":"/tmp","prompt":"go"}"#)
        XCTAssertEqual(store.sessions["t11"]?.status, .processing)
        XCTAssertNil(store.lastCompletion)

        try applyPayload(#"{"hook_event_name":"Stop","session_id":"t11","last_assistant_message":"done"}"#)
        XCTAssertEqual(store.sessions["t11"]?.status, .idle)
        let completion = try XCTUnwrap(store.lastCompletion)
        XCTAssertEqual(completion.session.lastAssistantMessage, "done")
        XCTAssertFalse(completion.failed)

        // Cleanup with a clock 31 minutes ahead drops the idle session.
        store.performCleanup(now: Date().addingTimeInterval(31 * 60))
        XCTAssertNil(store.sessions["t11"])

        // A failed Stop (Grok stop_failure folds onto Stop) marks the
        // completion failed.
        try applyPayload(#"{"hook_event_name":"UserPromptSubmit","session_id":"t11b","cwd":"/tmp","prompt":"again"}"#)
        try applyPayload(#"{"hook_event_name":"stop_failure","session_id":"t11b"}"#)
        XCTAssertEqual(store.lastCompletion?.failed, true)
    }

    func testCleanupResetsStuckProcessingAndReleasesStaleWaits() async throws {
        try applyPayload(#"{"hook_event_name":"UserPromptSubmit","session_id":"t12","cwd":"/tmp","prompt":"go"}"#)
        try applyPayload(#"{"hook_event_name":"PreToolUse","session_id":"t12","tool_name":"Bash","tool_input":{"command":"sleep 9999"},"cwd":"/tmp"}"#)
        XCTAssertEqual(store.sessions["t12"]?.status, .running)

        // 181s with a tool → idle.
        store.performCleanup(now: Date().addingTimeInterval(181))
        XCTAssertEqual(store.sessions["t12"]?.status, .idle)

        // A wait nobody answers for 301s → deny + processing released.
        let permissionTask = Task { [self] in
            await store.handleConnection(payload: Data(
                #"{"hook_event_name":"PermissionRequest","session_id":"t12","tool_name":"Bash","tool_input":{"command":"rm"},"cwd":"/tmp"}"#.utf8
            ))
        }
        let queued = await waitForFirstPermission()
        XCTAssertNotNil(queued, "permission should queue")
        XCTAssertEqual(store.sessions["t12"]?.status, .waitingApproval)

        store.performCleanup(now: Date().addingTimeInterval(400))
        XCTAssertTrue(store.permissionQueue.isEmpty, "stale wait is released with a deny")
        try assertEqualJSON(try await permissionTask.value, Self.denyJSON)
    }
}
