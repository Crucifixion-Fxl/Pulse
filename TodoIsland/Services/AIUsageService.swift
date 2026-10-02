import Foundation

/// Read-only AI usage source for the usage panel. The sample provider is the
/// only conformer today; local ~/.claude log parsing and vendor APIs arrive
/// as additional conformers without touching AppModel or the panel view.
protocol AIUsageProvider: Sendable {
  func fetchUsage() async throws -> AIUsageSnapshot
}

/// Fabricates a deterministic snapshot so the panel has something beautiful
/// to render before real data sources exist.
struct SampleAIUsageProvider: AIUsageProvider {
  var now: Date = Date()

  func fetchUsage() async throws -> AIUsageSnapshot {
    AIUsageSample.makeSnapshot(now: now)
  }
}
