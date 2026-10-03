import AppKit
import Foundation

/// One captured clipboard entry. Video arrives as copied file URLs; the
/// history keeps a reference (not the bytes — clips run to hundreds of
/// megabytes) and flags dead files at render time.
struct ClipboardItem: Identifiable, Hashable, Sendable {
  enum Kind: String, Hashable, Sendable {
    case text
    case image
    case video
  }

  let id: UUID
  let kind: Kind
  var text: String?
  /// Runtime image bytes; on disk this lives in the blob file.
  var imageData: Data?
  var fileURL: URL?
  var capturedAt: Date
  /// Content fingerprint for consecutive-duplicate suppression.
  var contentHash: Int

  var displayName: String {
    switch kind {
    case .text:
      (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    case .image:
      "image"
    case .video:
      fileURL?.lastPathComponent ?? "video"
    }
  }
}

/// Pure classification over pasteboard contents — unit-tested without a
/// live pasteboard.
enum ClipboardClassification {
  /// Marked-hidden payloads (password managers) must never enter history.
  static let concealedTypes: Set<String> = [
    "org.nspasteboard.ConcealedType",
  ]

  static let videoExtensions: Set<String> = [
    "mp4", "mov", "m4v", "avi", "mkv", "webm",
  ]

  static func isConcealed(typeNames: Set<String>) -> Bool {
    !typeNames.isDisjoint(with: concealedTypes)
  }

  /// Priority: video file > image > text. Nil when nothing usable.
  static func classify(
    typeNames: Set<String>,
    fileURLs: [URL],
    imageBytes: Data?,
    text: String?
  ) -> ClipboardItem.Kind? {
    let video = fileURLs.first {
      videoExtensions.contains($0.pathExtension.lowercased())
    }
    if let video { _ = video; return .video }
    if let imageBytes, !imageBytes.isEmpty { return .image }
    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .text
    }
    return nil
  }
}

/// Pure history arithmetic — the insert/dedupe/cap rules, testable.
enum ClipboardHistoryMath {
  static let capacity = 7

  /// Newest first. A repeat of the current head is a no-op (the same
  /// content copying over itself shouldn't reshuffle the deck); older
  /// repeats resurface to the front. Overflow drops the tail.
  static func insert(_ item: ClipboardItem, into items: [ClipboardItem]) -> [ClipboardItem] {
    if items.first?.contentHash == item.contentHash { return items }
    var next = items.filter { $0.id != item.id && $0.contentHash != item.contentHash }
    next.insert(item, at: 0)
    if next.count > capacity {
      next.removeLast(next.count - capacity)
    }
    return next
  }
}
