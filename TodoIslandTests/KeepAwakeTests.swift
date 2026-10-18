import AppKit
import XCTest
@testable import TodoIsland

@MainActor
final class KeepAwakeTests: XCTestCase {
  func testCountdownUsesDeadlineAndNeverGoesNegative() {
    let start = Date(timeIntervalSince1970: 1000)
    let session = KeepAwakeSession(deadline: start.addingTimeInterval(3661))
    XCTAssertEqual(session.countdown(at: start), "1:01:01")
    XCTAssertEqual(session.countdown(at: start.addingTimeInterval(3601)), "01:00")
    XCTAssertEqual(session.countdown(at: start.addingTimeInterval(9999)), "00:00")
  }

  func testStartsOnlyAfterSystemConfirmationAndStopsAtDeadline() async {
    let service = FakeKeepAwakeController()
    var now = Date(timeIntervalSince1970: 1000)
    service.deadline = now.addingTimeInterval(60)
    let store = KeepAwakeStore(controller: service, clock: { now })
    await store.start(minutes: 1)
    XCTAssertEqual(store.phase, .starting)
    service.value = "active"
    store.poll(thermalCritical: false)
    XCTAssertEqual(store.phase, .active)
    await store.start(minutes: 60)
    XCTAssertEqual(service.starts, 1, "Do not start overlapping authorized jobs")
    now = now.addingTimeInterval(61)
    store.poll(thermalCritical: false)
    XCTAssertEqual(store.phase, .stopping)
    XCTAssertEqual(service.stops, 1)
    XCTAssertNotNil(store.session, "Keep the session visible until restoration is confirmed")
    service.value = "expired"
    store.poll(thermalCritical: false)
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.session)
  }

  func testRestorationFailureAndMissingStatusCannotReportSuccess() async {
    let service = FakeKeepAwakeController()
    let store = KeepAwakeStore(controller: service)
    await store.start(minutes: 60)
    service.value = "active"; store.poll(thermalCritical: false)
    store.stop()
    service.value = "restore-failed"; store.poll(thermalCritical: false)
    XCTAssertEqual(store.phase, .recoveryRequired)
    await store.start(minutes: 60)
    XCTAssertEqual(service.starts, 1)
    service.value = nil; store.poll(thermalCritical: false)
    XCTAssertEqual(store.phase, .recoveryRequired)
    service.value = "stopped"; store.poll(thermalCritical: false)
    XCTAssertEqual(store.phase, .idle)
  }

  func testThermalEndAndQuitRequestIndependentRecovery() async {
    let service = FakeKeepAwakeController()
    let store = KeepAwakeStore(controller: service)
    await store.start(minutes: 60)
    service.value = "active"; store.poll(thermalCritical: true)
    XCTAssertEqual(store.phase, .stopping)
    service.value = "stopped"; store.poll(thermalCritical: false)
    XCTAssertEqual(store.messageKey, "awake.ended.heat")
    store.shutdown()
    XCTAssertEqual(service.stops, 2)
  }

  func testInvalidDurationAndCancelledAuthorizationDoNotBecomeActive() async {
    let service = FakeKeepAwakeController()
    let store = KeepAwakeStore(controller: service)
    await store.start(minutes: 0)
    await store.start(minutes: 1441)
    XCTAssertEqual(service.starts, 0)
    service.failure = KeepAwakeError.authorization("User canceled -128")
    await store.start(minutes: 60)
    XCTAssertEqual(store.phase, .idle)
    XCTAssertNil(store.session)
    XCTAssertEqual(store.messageKey, "awake.error.cancelled")
  }

  func testShellAndAppleScriptQuotingPreserveLiteralPayload() throws {
    let value = "spaces ' quote \" double $HOME `whoami` \\ line\nnext"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "return " + KeepAwakeService.appleScriptQuote(value)]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    XCTAssertEqual(String(data: output, encoding: .utf8), value + "\n")
    let shell = Process(); shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "printf '%s' " + KeepAwakeService.shellQuote(value)]
    let shellPipe = Pipe(); shell.standardOutput = shellPipe
    try shell.run(); shell.waitUntilExit()
    XCTAssertEqual(String(data: shellPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), value)
  }

  func testAwakeHeaderPrecedesWeatherAndDisappearsWhenCollapsed() {
    let awake = NSView(); let weather = NSView()
    let header = IslandStatusHeader(quota: NSView(), bot: NSView(),
      additionalQuotas: NSView(), weather: weather, keepAwake: awake, barHeight: 32)
    header.settle(size: CGSize(width: 760, height: 400), state: .pinned)
    XCTAssertEqual(awake.frame.maxX + 8, weather.frame.minX)
    XCTAssertGreaterThanOrEqual(awake.frame.minX, 479, "Clear the physical camera housing")
    XCTAssertEqual(awake.layer?.opacity, 1)
    header.setKeepAwakeEditing(true)
    XCTAssertEqual(awake.frame.maxX + 8, weather.frame.minX)
    XCTAssertEqual(awake.frame.width, 188)
    XCTAssertEqual(weather.frame.width, 28)
    header.settle(size: CGSize(width: 340, height: 32), state: .collapsed)
    XCTAssertEqual(awake.layer?.opacity, 0)
    XCTAssertNil(header.hitTest(awake.frame.origin))
  }
}

@MainActor
private final class FakeKeepAwakeController: KeepAwakeControlling {
  var value: String? = "armed"
  var starts = 0
  var stops = 0
  var failure: Error?
  var deadline = Date().addingTimeInterval(3600)
  func begin(seconds: Int) async throws -> Date {
    starts += 1
    if let failure { throw failure }
    return deadline
  }
  func requestStop() { stops += 1 }
  func status() -> String? { value }
}
