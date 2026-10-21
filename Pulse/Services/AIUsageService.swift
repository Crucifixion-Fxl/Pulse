import Foundation
import os

/// Read-only AI usage source for the usage panel. The sample provider is the
/// only conformer today; local ~/.claude log parsing and vendor APIs arrive
/// as additional conformers without touching AppModel or the panel view.
protocol AIUsageProvider: Sendable {
  func fetchUsage() async throws -> AIUsageSnapshot
  /// Small local snapshot for the first frame; never performs network or log scans.
  func cachedUsage() -> AIUsageSnapshot?
}

extension AIUsageProvider {
  func cachedUsage() -> AIUsageSnapshot? { nil }
}

/// Fabricates a deterministic snapshot so the panel has something beautiful
/// to render before real data sources exist.
struct SampleAIUsageProvider: AIUsageProvider {
  var now: Date = Date()

  func fetchUsage() async throws -> AIUsageSnapshot {
    AIUsageSample.makeSnapshot(now: now)
  }
}

/// The default chain: real Codex usage when `~/.codex` has sessions, the
/// sample snapshot otherwise — so machines without Codex still get a
/// populated panel and the sample badge clears itself the moment real
/// data appears.
struct DefaultAIUsageProvider: AIUsageProvider {
  var codex: AIUsageProvider = CodexAIUsageProvider()
  var fallback: AIUsageProvider = SampleAIUsageProvider()

  func cachedUsage() -> AIUsageSnapshot? {
    guard var cached = codex.cachedUsage() else { return nil }
    cached.subscriptions += AIUsageSample.makeSnapshot(now: Date()).subscriptions.filter { $0.vendor != .openAI }
    return cached
  }

  func fetchUsage() async throws -> AIUsageSnapshot {
    let real: AIUsageSnapshot?
    do {
      real = try await codex.fetchUsage()
    } catch {
      // Diagnostic: the chip silently falling back to sample/session data
      // is invisible otherwise.
      Self.log.error("codex provider failed, falling back: \(String(describing: error), privacy: .public)")
      real = nil
    }
    guard let real else {
      return try await fallback.fetchUsage()
    }
    // Keep the other vendors' (virtual) cards beside the real Codex ones
    // until real providers land; each carries its per-card sample marker.
    let sample = try await fallback.fetchUsage()
    var merged = real
    merged.subscriptions += sample.subscriptions.filter { $0.vendor != .openAI }
    return merged
  }

  private static let log = Logger(subsystem: "com.fxl.TodoIsland", category: "ai-usage")
}
