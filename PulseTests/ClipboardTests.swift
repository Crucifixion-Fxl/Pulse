import XCTest
@testable import Pulse

final class ClipboardTests: XCTestCase {
  private func makeItem(
    _ text: String, kind: ClipboardItem.Kind = .text, hash: Int? = nil
  ) -> ClipboardItem {
    ClipboardItem(
      id: UUID(), kind: kind, text: text, imageData: nil, fileURL: nil,
      capturedAt: Date(), contentHash: hash ?? text.hashValue
    )
  }

  // MARK: Lazy blob restoration

  /// Restored items keep full-fidelity bytes on disk: only previews load
  /// at init, and fullImageData(for:) pulls the blob back on demand.
  @MainActor
  func testRestoredItemsLoadPreviewsButNotFullBlobs() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("clipboard-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let id = UUID()
    let full = Data(repeating: 0xAB, count: 2048)
    let preview = Data(repeating: 0xCD, count: 128)
    let fullBlob = "blob-\(id.uuidString)"
    let previewBlob = "prev-\(id.uuidString)"
    try full.write(to: directory.appendingPathComponent(fullBlob))
    try preview.write(to: directory.appendingPathComponent(previewBlob))
    let index = """
      [{"id":"\(id.uuidString)","kind":"image","text":null,
        "blob":"\(fullBlob)","previewBlob":"\(previewBlob)",
        "fileURL":null,"capturedAt":800000000,"contentHash":42}]
      """
    try Data(index.utf8).write(to: directory.appendingPathComponent("history.json"))

    let service = ClipboardHistoryService(directory: directory)

    XCTAssertEqual(service.items.count, 1)
    let restored = try XCTUnwrap(service.items.first)
    XCTAssertNil(restored.imageData, "full-fidelity bytes must not load at init")
    XCTAssertEqual(restored.previewImageData, preview)
    XCTAssertEqual(service.fullImageData(for: id), full, "blob reads back on demand")
    XCTAssertNil(service.fullImageData(for: UUID()), "unknown id has no blob")
  }

  // MARK: Classification

  func testVideoFileURLWinsOverEverything() {
    let video = URL(fileURLWithPath: "/tmp/clip.mov")
    let kind = ClipboardClassification.classify(
      typeNames: ["public.file-url", "public.utf8-plain-text"],
      fileURLs: [video],
      imageBytes: Data([1, 2, 3]),
      text: "whatever"
    )
    XCTAssertEqual(kind, .video)
  }

  func testImageBeatsText() {
    let kind = ClipboardClassification.classify(
      typeNames: ["public.tiff", "public.utf8-plain-text"],
      fileURLs: [],
      imageBytes: Data([9, 9]),
      text: "caption"
    )
    XCTAssertEqual(kind, .image)
  }

  func testPlainTextClassifiesAndBlankDoesNot() {
    XCTAssertEqual(
      ClipboardClassification.classify(
        typeNames: ["public.utf8-plain-text"], fileURLs: [], imageBytes: nil, text: "hello"
      ),
      .text
    )
    XCTAssertNil(
      ClipboardClassification.classify(
        typeNames: ["public.utf8-plain-text"],
        fileURLs: [], imageBytes: nil, text: "   \n "
      )
    )
    XCTAssertNil(
      ClipboardClassification.classify(
        typeNames: ["public.rtf"], fileURLs: [], imageBytes: nil, text: nil
      )
    )
  }

  func testImageFileURLClassifiesAsImage() {
    let kind = ClipboardClassification.classify(
      typeNames: ["public.file-url", "public.tiff"],
      fileURLs: [URL(fileURLWithPath: "/tmp/photo.HEIC")],
      imageBytes: nil,
      text: "file:///tmp/photo.HEIC"
    )
    XCTAssertEqual(kind, .image)
  }

  func testVideoFileStillWinsOverImageFile() {
    let kind = ClipboardClassification.classify(
      typeNames: ["public.file-url"],
      fileURLs: [
        URL(fileURLWithPath: "/tmp/pic.png"),
        URL(fileURLWithPath: "/tmp/clip.mov"),
      ],
      imageBytes: nil,
      text: nil
    )
    XCTAssertEqual(kind, .video)
  }

  func testNonVideoFileAloneDoesNotClassify() {
    XCTAssertNil(
      ClipboardClassification.classify(
        typeNames: ["public.file-url"],
        fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")],
        imageBytes: nil,
        text: nil
      )
    )
    // But its file URL still lands as text when nothing richer exists.
    XCTAssertEqual(
      ClipboardClassification.classify(
        typeNames: ["public.file-url", "public.utf8-plain-text"],
        fileURLs: [URL(fileURLWithPath: "/tmp/report.pdf")],
        imageBytes: nil,
        text: "file:///tmp/report.pdf"
      ),
      .text
    )
  }

  func testConcealedTypesAreRejected() {
    XCTAssertTrue(
      ClipboardClassification.isConcealed(
        typeNames: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"]
      )
    )
    XCTAssertFalse(
      ClipboardClassification.isConcealed(typeNames: ["public.utf8-plain-text"])
    )
  }

  // MARK: History math

  func testNewestFirstAndCapacitySeven() {
    var items: [ClipboardItem] = []
    for index in 0..<9 {
      items = ClipboardHistoryMath.insert(makeItem("item\(index)"), into: items)
    }
    XCTAssertEqual(items.count, ClipboardHistoryMath.capacity)
    XCTAssertEqual(items.first?.text, "item8")
    XCTAssertEqual(items.last?.text, "item2")
  }

  func testConsecutiveDuplicateIsDropped() {
    var items = ClipboardHistoryMath.insert(makeItem("abc"), into: [])
    let before = items
    items = ClipboardHistoryMath.insert(makeItem("abc"), into: items)
    XCTAssertEqual(items, before, "same content must not duplicate")
  }

  func testOlderRepeatResurfacesToFront() {
    let a = makeItem("a")
    var items: [ClipboardItem] = []
    items = ClipboardHistoryMath.insert(a, into: items)
    items = ClipboardHistoryMath.insert(makeItem("b"), into: items)
    items = ClipboardHistoryMath.insert(makeItem("c"), into: items)
    // Copy "a" again: it must move to the front, not duplicate.
    items = ClipboardHistoryMath.insert(
      ClipboardItem(
        id: UUID(), kind: .text, text: "a", imageData: nil, fileURL: nil,
        capturedAt: Date(), contentHash: a.contentHash
      ),
      into: items
    )
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items.map(\.text), ["a", "c", "b"])
  }
}

  // MARK: Image normalization

  func testNormalizationRoundTripsRealImageAndRejectsGarbage() {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.setColor(NSColor.red, atX: 0, y: 0)
    let tiff = rep.representation(using: .tiff, properties: [:])!

    let normalized = ClipboardImageNormalization.tiffRepresentation(of: tiff)
    XCTAssertNotNil(normalized, "a TIFF must normalize to TIFF")
    XCTAssertNotNil(NSImage(data: normalized!))

    XCTAssertNil(
      ClipboardImageNormalization.tiffRepresentation(of: Data("junk".utf8)),
      "garbage must fail cleanly"
    )
  }

  func testWideFormatSet() {
    for ext in ["heic", "heif", "avif", "webp", "svg"] {
      XCTAssertTrue(ClipboardClassification.imageExtensions.contains(ext), ext)
    }
  }

  func testPreviewRepresentationDownscalesAndStaysDecodable() {
    // 4000×3000 "photo" → preview must come back small and renderable.
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let tiff = rep.representation(using: .tiff, properties: [:])!
    let preview = ClipboardImageNormalization.previewRepresentation(of: tiff, maxPixel: 72)
    XCTAssertNotNil(preview)
    let image = try! XCTUnwrap(NSImage(data: preview!))
    XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 73)
    XCTAssertLessThan(preview!.count, tiff.count)
  }
