import XCTest
@testable import TodoIsland

final class AIUsageTests: XCTestCase {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    return calendar
  }

  private func fixedNow() -> Date {
    // 2026-10-02 09:30 local, whatever the test machine's zone is.
    var components = DateComponents()
    components.year = 2026
    components.month = 10
    components.day = 2
    components.hour = 9
    components.minute = 30
    return calendar.date(from: components)!
  }

  // MARK: Sample snapshot shape

  func testSampleSnapshotHasFifteenAscendingDaysEndingToday() {
    let now = fixedNow()
    let snapshot = AIUsageSample.makeSnapshot(now: now, calendar: calendar)

    XCTAssertEqual(snapshot.days.count, 15)
    XCTAssertEqual(snapshot.days.last?.day, calendar.startOfDay(for: now))
    for pair in zip(snapshot.days, snapshot.days.dropFirst()) {
      let dayApart = calendar.date(
        byAdding: .day, value: 1, to: pair.0.day
      )
      XCTAssertEqual(pair.1.day, dayApart)
    }
    XCTAssertEqual(snapshot.today, snapshot.days.last)
  }

  func testDayTotalsSumComponents() {
    let snapshot = AIUsageSample.makeSnapshot(now: fixedNow(), calendar: calendar)
    for day in snapshot.days {
      XCTAssertEqual(day.totalTokens, day.inputTokens + day.outputTokens + day.cacheTokens)
    }
  }

  func testSampleTodayTotalIsPlausible() {
    let snapshot = AIUsageSample.makeSnapshot(now: fixedNow(), calendar: calendar)
    let today = try! XCTUnwrap(snapshot.today)
    XCTAssertGreaterThan(today.totalTokens, 500_000)
    XCTAssertLessThan(today.totalTokens, 5_000_000)
  }

  func testSampleSubscriptionsCoverThreeUniqueVendors() {
    let snapshot = AIUsageSample.makeSnapshot(now: fixedNow(), calendar: calendar)
    XCTAssertEqual(
      Set(snapshot.subscriptions.map(\.id)),
      Set(AIUsageVendor.allCases)
    )
  }

  func testSampleSubscriptionsUsedNeverExceedsLimit() {
    let snapshot = AIUsageSample.makeSnapshot(now: fixedNow(), calendar: calendar)
    for subscription in snapshot.subscriptions {
      XCTAssertLessThanOrEqual(subscription.quota.used, subscription.quota.limit)
      XCTAssertGreaterThan(subscription.quota.limit, 0)
    }
  }

  // MARK: Quota math

  func testQuotaFractionClamps() {
    XCTAssertEqual(AIQuota(used: -5, limit: 100, unit: .requests).fraction, 0)
    XCTAssertEqual(AIQuota(used: 250, limit: 100, unit: .requests).fraction, 1)
    XCTAssertEqual(AIQuota(used: 10, limit: 0, unit: .requests).fraction, 0)
    XCTAssertEqual(AIQuota(used: 25, limit: 100, unit: .requests).fraction, 0.25)
  }

  func testQuotaStatusThresholds() {
    XCTAssertEqual(AIQuota(used: 79, limit: 100, unit: .requests).status, .normal)
    XCTAssertEqual(AIQuota(used: 80, limit: 100, unit: .requests).status, .warning)
    XCTAssertEqual(AIQuota(used: 94, limit: 100, unit: .requests).status, .warning)
    XCTAssertEqual(AIQuota(used: 95, limit: 100, unit: .requests).status, .danger)
    XCTAssertEqual(AIQuota(used: 100, limit: 100, unit: .requests).status, .danger)
  }

  // MARK: Formatting

  func testCompactTokenFormatting() {
    XCTAssertEqual(
      AIUsageFormat.compactTokens(1_252_000, locale: Locale(identifier: "en_US")),
      "1.25M"
    )
    XCTAssertEqual(
      AIUsageFormat.compactTokens(386_214, locale: Locale(identifier: "en_US")),
      "386.2K"
    )
    XCTAssertEqual(
      AIUsageFormat.compactTokens(1252, locale: Locale(identifier: "en_US")),
      "1.3K"
    )
    XCTAssertEqual(
      AIUsageFormat.compactTokens(1_252_000, locale: Locale(identifier: "zh_CN")),
      "125.2万"
    )
    XCTAssertEqual(
      AIUsageFormat.compactTokens(500_000, locale: Locale(identifier: "zh_CN")),
      "50万"
    )
  }

  func testGroupedUsesGroupingSeparator() {
    let grouped = AIUsageFormat.grouped(1_252_000, locale: Locale(identifier: "en_US"))
    XCTAssertTrue(grouped.contains(","), "expected grouping in \(grouped)")
    XCTAssertFalse(grouped.contains("万"))
  }

  func testDaysUntilCountsWholeDays() {
    let now = fixedNow()
    let inThreeDays = calendar.date(byAdding: .day, value: 3, to: now)!
    XCTAssertEqual(AIUsageFormat.days(until: inThreeDays, from: now, calendar: calendar), 3)

    let laterToday = now.addingTimeInterval(3600)
    XCTAssertEqual(AIUsageFormat.days(until: laterToday, from: now, calendar: calendar), 0)

    let past = now.addingTimeInterval(-3600)
    XCTAssertNil(AIUsageFormat.days(until: past, from: now, calendar: calendar))
  }

  // MARK: Panel height

  func testAIUsageSidebarHeightIsSane() {
    XCTAssertGreaterThan(IslandSidebarItem.aiUsage.preferredContentHeight, 300)
  }

  // MARK: AppModel wiring

  @MainActor
  func testRefreshAIUsagePopulatesSnapshotAndThrottles() async throws {
    let defaults = UserDefaults(suiteName: #function)!
    defer { defaults.removePersistentDomain(forName: #function) }
    let now = fixedNow()

    let model = AppModel(
      store: LocalOnlyTestReminderStore(),
      defaults: defaults,
      aiUsageProvider: SampleAIUsageProvider(now: now)
    )

    XCTAssertNil(model.aiUsage)
    model.refreshAIUsage()
    try await Task.sleep(for: .milliseconds(50))
    let snapshot = try XCTUnwrap(model.aiUsage)
    XCTAssertTrue(snapshot.isSample)
    XCTAssertEqual(snapshot.days.count, 15)
    XCTAssertEqual(snapshot.days.last?.day, calendar.startOfDay(for: now))

    // Within the throttle window a second call must not refetch: the
    // provider's `now` differing would move the anchor date otherwise.
    let counting = CountingProvider()
    let model2 = AppModel(
      store: LocalOnlyTestReminderStore(),
      defaults: defaults,
      aiUsageProvider: counting
    )
    model2.refreshAIUsage()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(counting.fetchCount, 1)
    model2.refreshAIUsage()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(counting.fetchCount, 1, "second refresh within 5 min must be throttled")
  }

  /// Fetch counting happens entirely on the MainActor, where AppModel's
  /// refresh task and the test both run — no locking needed.
  @MainActor
  private final class CountingProvider: AIUsageProvider {
    private(set) var fetchCount = 0

    func fetchUsage() async throws -> AIUsageSnapshot {
      fetchCount += 1
      return AIUsageSample.makeSnapshot(now: Date(timeIntervalSince1970: 0))
    }
  }
}

  // MARK: Odometer count-up

  func testOdometerStartsTenThousandBelowAndLandsExactly() {
    let value = 1_252_362
    XCTAssertEqual(
      AIUsagePanelView.RollingNumber.displayValue(underlying: value, progress: 0),
      value - 10_000
    )
    XCTAssertEqual(
      AIUsagePanelView.RollingNumber.displayValue(underlying: value, progress: 1),
      value
    )
    XCTAssertEqual(
      AIUsagePanelView.RollingNumber.displayValue(underlying: value, progress: 2),
      value,
      "past the end it must hold the final value"
    )
  }

  func testOdometerPassesThroughIntermediateValuesMonotonically() {
    let value = 1_252_362
    // Sample 60 frames like a display link would.
    let frames = (0...60).map {
      AIUsagePanelView.RollingNumber.displayValue(
        underlying: value, progress: Double($0) / 60.0
      )
    }
    XCTAssertEqual(frames.first, value - 10_000)
    XCTAssertEqual(frames.last, value)
    // Monotonic non-decreasing: an odometer never counts backwards.
    XCTAssertEqual(frames, frames.sorted())
    // The wheel actually spins: sampled frames step by small amounts and
    // cover a contiguous spread of last digits rather than jumping.
    let lastDigits = Set(frames.map { $0 % 10 })
    XCTAssertGreaterThanOrEqual(lastDigits.count, 8, "last digit should cycle through most digits, got \(lastDigits)")
  }
