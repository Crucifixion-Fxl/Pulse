import AppKit
import CoreGraphics
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
  /// Full-fidelity image bytes (re-copy source); on disk in the blob file.
  var imageData: Data?
  /// Downscaled JPEG for display — full-res bitmaps stall the rail's
  /// animation. Falls back to imageData when absent.
  var previewImageData: Data?
  var fileURL: URL?
  var capturedAt: Date
  /// Content fingerprint for consecutive-duplicate suppression.
  var contentHash: Int

  var displayName: String {
    switch kind {
    case .text:
      (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    case .image:
      fileURL?.lastPathComponent ?? "image"
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

  static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "gif", "webp",
    "bmp", "avif", "svg", "ico", "icns",
  ]

  static func isConcealed(typeNames: Set<String>) -> Bool {
    !typeNames.isDisjoint(with: concealedTypes)
  }

  /// Priority: video file > image (file bytes first, then pasteboard
  /// image data) > text. Nil when nothing usable.
  static func classify(
    typeNames: Set<String>,
    fileURLs: [URL],
    imageBytes: Data?,
    text: String?
  ) -> ClipboardItem.Kind? {
    if fileURLs.contains(where: { videoExtensions.contains($0.pathExtension.lowercased()) }) {
      return .video
    }
    if fileURLs.contains(where: { imageExtensions.contains($0.pathExtension.lowercased()) }) {
      return .image
    }
    if let imageBytes, !imageBytes.isEmpty { return .image }
    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return .text
    }
    return nil
  }
}

enum ClipboardImageNormalization {
  /// Decodes ANY format CoreGraphics understands and re-encodes as TIFF,
  /// so previews never depend on the source format (HEIC et al.).
  static func tiffRepresentation(of data: Data) -> Data? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .tiff, properties: [:])
  }

  /// Small JPEG for on-card display: full-resolution TIFFs re-composite
  /// every animation frame and stall the rail. Fit within `maxPixel`,
  /// preserving alpha as PNG when present.
  static func previewRepresentation(of data: Data, maxPixel: CGFloat = 720) -> Data? {
    guard let image = NSImage(data: data) else { return nil }
    let size = image.size
    let scale = min(1, maxPixel / max(size.width, size.height, 1))
    let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    guard target.width >= 1, target.height >= 1 else { return nil }

    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = target
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: target))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(
      using: .jpeg, properties: [.compressionFactor: 0.85]
    )
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
