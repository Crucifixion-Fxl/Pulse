import XCTest
@testable import TodoIsland

final class ClipboardTests: XCTestCase {
  private func makeItem(
    _ text: String, kind: ClipboardItem.Kind = .text, hash: Int? = nil
  ) -> ClipboardItem {
    ClipboardItem(
      id: UUID(), kind: kind, text: text, imageData: nil, fileURL: nil,
      capturedAt: Date(), contentHash: hash ?? text.hashValue
    )
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
