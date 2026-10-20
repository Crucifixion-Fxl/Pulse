import XCTest

@testable import TodoIsland

/// Codex rollout parsing: filename dating, tail token_count extraction,
/// lane-classified windows, and the snapshot aggregation — pure functions.
final class CodexUsageTests: XCTestCase {
  func testOfflineRetainsLiveQuotaAcrossRestartAndRecovers() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let sessions = home.appendingPathComponent(".codex/sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
    let rollout = sessions.appendingPathComponent("rollout-\(stamp.string(from: Date()))-test.jsonl")
    try Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50}},"rate_limits":{"primary":{"used_percent":20,"window_minutes":10080,"resets_at":2000000000}}}}"#.utf8).write(to: rollout)
    let source = QuotaSequence()
    let provider = CodexAIUsageProvider(homeDirectory: home, loadWindows: { _ in try await source.next() })
    let live = try await provider.fetchUsage()
    XCTAssertEqual(live.subscriptions.first?.quota.used, 22)
    XCTAssertFalse(live.subscriptions[0].isStale)
    let offline = try await provider.fetchUsage()
    XCTAssertEqual(offline.subscriptions.first?.quota.used, 22, "must not revert to rollout's 20")
    XCTAssertTrue(offline.subscriptions[0].isStale)
    XCTAssertEqual(offline.today?.inputTokens, 50, "local tokens still refresh offline")
    let restarted = CodexAIUsageProvider(homeDirectory: home, loadWindows: { _ in throw URLError(.notConnectedToInternet) })
    let persisted = try await restarted.fetchUsage()
    XCTAssertEqual(persisted.subscriptions.first?.quota.used, 22)
    XCTAssertTrue(persisted.subscriptions[0].isStale)
    let recovered = try await provider.fetchUsage()
    XCTAssertEqual(recovered.subscriptions.first?.quota.used, 28)
    XCTAssertFalse(recovered.subscriptions[0].isStale)
  }

  private actor QuotaSequence {
    var calls = 0
    func next() throws -> CodexAIUsageProvider.Windows {
      calls += 1
      if calls == 2 { throw URLError(.notConnectedToInternet) }
      return (nil, CodexRateWindow(usedPercent: calls == 1 ? 22 : 28, windowMinutes: 10080, resetsAt: Date()))
    }
  }

  private let calendar = Calendar.current

  private func fixedNow() -> Date {
    var comps = DateComponents()
    comps.year = 2026
    comps.month = 10
    comps.day = 13
    comps.hour = 12
    return calendar.date(from: comps)!
  }

  private func day(_ month: Int, _ day: Int) -> Date {
    var comps = DateComponents()
    comps.year = 2026
    comps.month = month
    comps.day = day
    comps.hour = 10
    return calendar.date(from: comps)!
  }

  func testSessionDateParsesRolloutFilenames() {
    XCTAssertEqual(
      CodexUsageParser.sessionDate(
        filename: "rollout-2026-09-24T13-49-23-01a0d1f6-2055-7cd2-bb04-d647576005fe.jsonl",
        calendar: calendar).map { calendar.startOfDay(for: $0) },
      calendar.startOfDay(for: day(9, 24)))
    XCTAssertNil(CodexUsageParser.sessionDate(filename: "history.jsonl"))
    XCTAssertNil(CodexUsageParser.sessionDate(filename: "rollout-short.jsonl"))
  }

  func testLastTokenCountReadsFinalEventWithRateLimits() {
    let jsonl = """
      {"timestamp":"2026-10-13T02:00:00.000Z","type":"event_msg","payload":{"type":"turn_started"}}
      {"timestamp":"2026-10-13T02:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":110}}}}
      {"timestamp":"2026-10-13T02:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7357928,"cached_input_tokens":6962304,"cache_write_input_tokens":12,"output_tokens":21918}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":34.0,"window_minutes":10080,"resets_at":1790573343}}}}
      """
    let parsed = CodexUsageParser.lastTokenCount(in: Data(jsonl.utf8))
    XCTAssertEqual(parsed?.usage.input, 7_357_928)
    XCTAssertEqual(parsed?.usage.cached, 6_962_304)
    XCTAssertEqual(parsed?.usage.cacheWrite, 12)
    XCTAssertEqual(parsed?.usage.output, 21_918)
    XCTAssertEqual(parsed?.rateWindow?.usedPercent, 34.0)
    XCTAssertEqual(parsed?.rateWindow?.resetsAt, Date(timeIntervalSince1970: 1_790_573_343))
    XCTAssertEqual(parsed?.rateWindow?.observedAt, ISO8601DateFormatter().date(from: "2026-10-13T02:02:00Z"))
    // No token_count at all.
    XCTAssertNil(CodexUsageParser.lastTokenCount(in: Data("{}".utf8)))
  }

  func testBuildSnapshotAggregatesDaysAndKeepsNewestRate() {
    let sessions: [(date: Date, usage: CodexTokenUsage, rateWindow: CodexRateWindow?)] = [
      (
        day(10, 13),
        CodexTokenUsage(input: 1000, cached: 400, cacheWrite: 0, output: 100),
        CodexRateWindow(usedPercent: 34, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1_790_573_343))
      ),
      (
        day(10, 13),
        CodexTokenUsage(input: 500, cached: 0, cacheWrite: 50, output: 50),
        nil
      ),
      (
        day(10, 11),
        CodexTokenUsage(input: 200, cached: 0, cacheWrite: 0, output: 20),
        CodexRateWindow(usedPercent: 12, windowMinutes: 10_080, resetsAt: Date(timeIntervalSince1970: 1_790_000_000))
      ),
      (
        day(8, 1),
        CodexTokenUsage(input: 999, cached: 0, cacheWrite: 0, output: 9),
        nil
      ),
    ]

    let snapshot = CodexUsageParser.buildSnapshot(
      sessions: sessions, now: fixedNow(), calendar: calendar)

    XCTAssertEqual(snapshot.days.count, 15, "half-month window ending today")
    XCTAssertEqual(snapshot.isSample, false)
    // Cache is subtracted from input (the panel splits them) and cache
    // writes fold into the cache column.
    let today = snapshot.days.last!
    XCTAssertEqual(today.inputTokens, 1_100)  // (1000-400) + (500-0)
    XCTAssertEqual(today.outputTokens, 150)
    XCTAssertEqual(today.cacheTokens, 450)  // 400 + 0 + 0 + 50
    // Days outside the window are dropped entirely.
    XCTAssertFalse(snapshot.days.contains { $0.day == calendar.startOfDay(for: day(8, 1)) })
    // Zero-filled day in the middle.
    XCTAssertEqual(snapshot.days[snapshot.days.count - 3].totalTokens, 220)

    XCTAssertEqual(snapshot.subscriptions.count, 1)
    let codex = snapshot.subscriptions[0]
    XCTAssertEqual(codex.id, "codex-weekly")
    XCTAssertEqual(codex.vendor, .openAI)
    XCTAssertEqual(codex.planName, "Weekly limit")
    XCTAssertEqual(codex.quota.used, 34)
    XCTAssertEqual(codex.quota.limit, 100)
    XCTAssertEqual(codex.quota.unit, .percent)
    XCTAssertEqual(codex.resetsAt, Date(timeIntervalSince1970: 1_790_573_343))
  }

  func testWindowLaneClassificationCanonicalizesJitter() {
    XCTAssertEqual(
      CodexRateWindow(usedPercent: 10, windowMinutes: 298, resetsAt: Date()).lane, .session)
    XCTAssertEqual(
      CodexRateWindow(usedPercent: 10, windowMinutes: 305, resetsAt: Date()).lane, .session)
    XCTAssertEqual(
      CodexRateWindow(usedPercent: 10, windowMinutes: 10_083, resetsAt: Date()).lane, .weekly)
    XCTAssertEqual(
      CodexRateWindow(usedPercent: 10, windowMinutes: 720, resetsAt: Date()).lane, .unknown)
  }

  func testNewestRolloutWinsWhenWeeklyResetTimeIsUnchanged() {
    let reset = fixedNow().addingTimeInterval(5 * 24 * 3600)
    let older = CodexRateWindow(usedPercent: 8, windowMinutes: 10_080, resetsAt: reset)
    let newer = CodexRateWindow(usedPercent: 22, windowMinutes: 10_080, resetsAt: reset)
    let snapshot = CodexUsageParser.buildSnapshot(
      sessions: [
        (date: fixedNow().addingTimeInterval(-3600), usage: CodexTokenUsage(input: 1, cached: 0, cacheWrite: 0, output: 1), rateWindow: older),
        (date: fixedNow(), usage: CodexTokenUsage(input: 1, cached: 0, cacheWrite: 0, output: 1), rateWindow: newer),
      ],
      now: fixedNow(), calendar: calendar)
    XCTAssertEqual(snapshot.subscriptions.first?.quota.used, 22)
  }

  func testNewestRateObservationWinsEvenFromOlderSession() {
    let reset = fixedNow().addingTimeInterval(5 * 24 * 3600)
    let active = CodexRateWindow(usedPercent: 22, windowMinutes: 10_080,
                                 resetsAt: reset, observedAt: fixedNow())
    let idle = CodexRateWindow(usedPercent: 9, windowMinutes: 10_080,
                               resetsAt: reset, observedAt: fixedNow().addingTimeInterval(-1800))
    let usage = CodexTokenUsage(input: 1, cached: 0, cacheWrite: 0, output: 1)
    let snapshot = CodexUsageParser.buildSnapshot(sessions: [
      (date: fixedNow().addingTimeInterval(-86400), usage: usage, rateWindow: active),
      (date: fixedNow().addingTimeInterval(-3600), usage: usage, rateWindow: idle),
    ], now: fixedNow(), calendar: calendar)
    XCTAssertEqual(snapshot.subscriptions.first?.quota.used, 22)
  }

  func testLiveWindowsProduceBothCardsAndWeeklyCapsSession() {
    let weekly = CodexRateWindow(
      usedPercent: 100, windowMinutes: 10_080,
      resetsAt: fixedNow().addingTimeInterval(3 * 24 * 3600))
    let session = CodexRateWindow(
      usedPercent: 42, windowMinutes: 300,
      resetsAt: fixedNow().addingTimeInterval(3600))

    let snapshot = CodexUsageParser.buildSnapshot(
      sessions: [], liveWindows: (session, weekly), now: fixedNow(), calendar: calendar)

    XCTAssertEqual(snapshot.subscriptions.map(\.id), ["codex-weekly", "codex-session"])
    XCTAssertEqual(snapshot.subscriptions[0].quota.used, 100)
    // The spent week drags the session bar up so it cannot imply headroom.
    XCTAssertEqual(snapshot.subscriptions[1].quota.used, 100)
    XCTAssertEqual(snapshot.subscriptions[1].planName, "5-hour window")
  }

  func testSlotOrderDoesNotMatterForLiveWindows() {
    // A provider that hands the weekly window in the "session" tuple slot
    // by mistake still lands on the right card via lane classification —
    // exercised through buildSnapshot's lane-based fallback path.
    let only = CodexRateWindow(
      usedPercent: 7, windowMinutes: 10_080, resetsAt: fixedNow().addingTimeInterval(3600))
    let snapshot = CodexUsageParser.buildSnapshot(
      sessions: [(date: fixedNow(), usage: CodexTokenUsage(input: 10, cached: 0, cacheWrite: 0, output: 2), rateWindow: only)],
      now: fixedNow(), calendar: calendar)
    XCTAssertEqual(snapshot.subscriptions.first?.id, "codex-weekly")
  }

  /// The default chain keeps the other vendors' virtual cards beside the
  /// real Codex ones, each flagged as sample.
  func testChainMergesRealCodexWithVirtualVendors() async throws {
    let codexOnly = AIUsageSnapshot(
      days: [],
      subscriptions: [
        AISubscription(
          id: "codex-weekly", vendor: .openAI, planName: "Weekly limit",
          quota: AIQuota(used: 10, limit: 100, unit: .percent), resetsAt: fixedNow())
      ],
      isSample: false)

    let chain = DefaultAIUsageProvider(
      codex: StubProvider(snapshot: codexOnly),
      fallback: SampleAIUsageProvider(now: fixedNow()))

    let merged = try await chain.fetchUsage()
    XCTAssertEqual(merged.isSample, false)
    XCTAssertEqual(merged.subscriptions.map(\.id).prefix(1), ["codex-weekly"])
    XCTAssertEqual(
      Set(merged.subscriptions.map(\.vendor)),
      Set(AIUsageVendor.allCases))
    XCTAssertTrue(merged.subscriptions.filter { $0.vendor != .openAI }.allSatisfy(\.isSample))
    XCTAssertFalse(merged.subscriptions.first!.isSample)
  }

  private struct StubProvider: AIUsageProvider {
    let snapshot: AIUsageSnapshot
    func fetchUsage() async throws -> AIUsageSnapshot { snapshot }
  }

  func testProviderFallsBackToSampleWithoutCodexDirectory() async throws {
    let provider = CodexAIUsageProvider(
      homeDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-missing-\(UUID().uuidString)"))
    do {
      _ = try await provider.fetchUsage()
      XCTFail("expected a throw for a missing sessions directory")
    } catch {
      // expected
    }

    // Inject the doomed codex provider so the chain verdict does not
    // depend on whether THIS machine happens to be logged in.
    let chain = DefaultAIUsageProvider(codex: provider, fallback: SampleAIUsageProvider())
    let snapshot = try await chain.fetchUsage()
    XCTAssertEqual(snapshot.isSample, true, "chain falls back to the sample")
  }
}
