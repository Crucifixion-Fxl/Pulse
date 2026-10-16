import XCTest
@testable import TodoIsland

final class CollapsedBotStateTests: XCTestCase {
  func testIdleSleepsAndActivityWakesExactlyOnce() {
    var animation = CollapsedBotAnimation(at: 0)
    XCTAssertEqual(animation.state(at: 44.9), .idle)
    XCTAssertEqual(animation.state(at: 45), .sleeping)
    XCTAssertLessThan(animation.expression(at: 47).eyeOpen, 0.1)
    let asleep = animation.expression(at: 47)
    animation.update(.init(activity: .thinking), at: 47)
    XCTAssertEqual(animation.state(at: 47), .waking)
    XCTAssertEqual(animation.expression(at: 47), asleep, "Wake starts at the presented pose")
    animation.update(.init(activity: .working), at: 47.8)
    XCTAssertEqual(animation.state(at: 48), .waking)
    XCTAssertEqual(animation.state(at: 48.7), .working, "Tool events must not restart waking")
  }

  func testHoverMusicAndAlertPreventSleep() {
    for context in [CollapsedBotAnimation.Context(isHovered: true),
      .init(isPlaying: true), .init(isAlert: true), .init(activity: .thinking),
      .init(activity: .searching), .init(activity: .working)] {
      let animation = CollapsedBotAnimation(context: context, at: 0)
      XCTAssertNotEqual(animation.state(at: 120), .sleeping)
    }
    var animation = CollapsedBotAnimation(at: 0)
    animation.update(.init(isHovered: true), at: 50)
    XCTAssertEqual(animation.state(at: 50.3), .waking)
    XCTAssertEqual(animation.state(at: 52), .listening)
    animation.update(.init(isHovered: true, isAlert: true), at: 53)
    XCTAssertEqual(animation.state(at: 53), .idle, "Red alert bypasses listening and wake delay")
    animation.update(.init(), at: 55)
    XCTAssertEqual(animation.state(at: 99), .idle)
    XCTAssertEqual(animation.state(at: 101), .sleeping)
  }

  func testRapidInterruptedTransitionsStayContinuous() {
    var animation = CollapsedBotAnimation(at: 0)
    for (index, state) in CollapsedBotState.allCases.enumerated() {
      let time = Double(index) * 0.1
      let before = animation.expression(at: time)
      animation.update(.init(activity: state), at: time)
      XCTAssertEqual(animation.expression(at: time), before)
    }
    let idle = CollapsedBotAnimation(at: 0)
    // Compare at the same blink phase; a blink can move appreciably even
    // across a tiny time delta, independently of entering sleep.
    let beforeSleep = CollapsedBotFace.expression(at: 45 + 0.0001,
      inputs: .init(isPlaying: false, isHovered: false))
    let enteringSleep = idle.expression(at: 45 + 0.0001)
    XCTAssertEqual(beforeSleep.eyeOpen, enteringSleep.eyeOpen, accuracy: 0.001)
    XCTAssertEqual(beforeSleep.faceRotation, enteringSleep.faceRotation, accuracy: 0.001)
  }

  func testSevenPosesAreDistinctAndSafeAtSmallSizes() {
    XCTAssertEqual(CollapsedBotState.allCases.count, 7)
    var poses: [CollapsedBotFace.Expression] = []
    for state in CollapsedBotState.allCases {
      let pose = CollapsedBotFace.expression(at: 2, inputs: .init(
        isPlaying: false, isHovered: false, state: state, stateElapsed: 0.8))
      XCTAssertFalse(poses.contains(pose), "Duplicate pose for \(state)")
      poses.append(pose)
      for time in stride(from: 0.0, through: 20, by: 0.07) {
        let e = CollapsedBotFace.expression(at: time, inputs: .init(
          isPlaying: false, isHovered: false, state: state, stateElapsed: time))
        XCTAssertTrue((0.02...1.3).contains(e.eyeOpen))
        XCTAssertTrue((0.98...1.04).contains(e.faceScale))
        XCTAssertLessThanOrEqual(abs(e.faceOffsetYFraction), 0.03)
        XCTAssertLessThanOrEqual(abs(e.faceRotation), 0.15)
        XCTAssertLessThanOrEqual(abs(e.glanceX), 1)
      }
      let reduced = CollapsedBotFace.staticExpression(state: state, alert: false)
      XCTAssertEqual(reduced.faceScale, 1)
      XCTAssertEqual(reduced.faceOffsetYFraction, 0)
    }
  }

  @MainActor
  func testActualAgentHooksDriveThinkingSearchingAndWorking() throws {
    let store = AgentSessionStore()
    func send(_ name: String, tool: String? = nil) throws {
      var payload: [String: Any] = ["hook_event_name": name, "session_id": "bot-state-test",
        "_source": "codex"]
      if let tool { payload["tool_name"] = tool }
      store.apply(try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload))))
    }
    XCTAssertEqual(CollapsedBotState.activity(in: store.sessions), .idle)
    try send("UserPromptSubmit")
    XCTAssertEqual(CollapsedBotState.activity(in: store.sessions), .thinking)
    try send("PreToolUse", tool: "grep")
    XCTAssertEqual(CollapsedBotState.activity(in: store.sessions), .searching)
    try send("PostToolUse", tool: "grep")
    XCTAssertEqual(CollapsedBotState.activity(in: store.sessions), .thinking)
    try send("PreToolUse", tool: "apply_patch")
    XCTAssertEqual(CollapsedBotState.activity(in: store.sessions), .working)
    try send("Stop")
    XCTAssertEqual(CollapsedBotState.activity(in: store.sessions), .idle)
  }

  func testMostRecentActiveSessionWinsOverStaleIdleOrWaitingCards() {
    var working = AgentSessionSnapshot()
    working.status = .running
    working.currentTool = "Bash"
    working.lastActivity = Date(timeIntervalSinceReferenceDate: 2)
    var search = working
    search.currentTool = "WebSearch"
    search.lastActivity = Date(timeIntervalSinceReferenceDate: 1)
    var stale = working
    stale.status = .waitingApproval
    stale.lastActivity = Date(timeIntervalSinceReferenceDate: 10)
    XCTAssertEqual(CollapsedBotState.activity(in: ["work": working, "search": search, "stale": stale]),
      .working)
    search.lastActivity = Date(timeIntervalSinceReferenceDate: 3)
    XCTAssertEqual(CollapsedBotState.activity(in: ["work": working, "search": search]), .searching)
  }
}
