import XCTest
import SwiftUI

@testable import TodoIsland

final class DisplayGeometryTests: XCTestCase {
  func testExpandedShouldersJoinFullTopEdgeAndTaperInwardSymmetrically() {
    let path = IslandSurfaceShape(
      shoulderInset: 8, topShoulderDepth: 8, bottomRadius: 36
    ).path(in: CGRect(x: 0, y: 0, width: 520, height: 320))
    XCTAssertTrue(path.contains(CGPoint(x: 2, y: 0.1)))
    XCTAssertTrue(path.contains(CGPoint(x: 518, y: 0.1)))
    XCTAssertTrue(path.contains(CGPoint(x: 4, y: 1)))
    XCTAssertFalse(path.contains(CGPoint(x: 4, y: 7)))
    XCTAssertFalse(path.contains(CGPoint(x: 516, y: 7)))
    // The shoulder must finish within 8 points, then remain vertical.
    for y in [9.0, 30, 140, 280] {
      XCTAssertFalse(path.contains(CGPoint(x: 7.5, y: y)))
      XCTAssertFalse(path.contains(CGPoint(x: 512.5, y: y)))
      XCTAssertTrue(path.contains(CGPoint(x: 8.5, y: y)))
      XCTAssertTrue(path.contains(CGPoint(x: 511.5, y: y)))
    }
    for y in stride(from: 1.0, through: 319.0, by: 7) {
      for x in stride(from: 1.5, through: 259.0, by: 7) {
        if path.contains(CGPoint(x: x, y: y)) != path.contains(CGPoint(x: 520 - x, y: y)) {
          XCTFail("Silhouette is not mirrored at x=\(x), y=\(y)")
          return
        }
      }
    }
  }
  func testAnimatedSurfaceTracksCurrentWindowSize() {
    let intermediateWindowSize = CGSize(width: 372, height: 126)
    let previewTargetSize = CGSize(width: 440, height: 220)

    XCTAssertEqual(
      IslandAnimatedSurfaceLayout.surfaceSize(
        windowSize: intermediateWindowSize,
        targetSize: previewTargetSize
      ),
      intermediateWindowSize
    )
  }

  func testPhysicalNotchUsesSafeAreaHeightAndCentersAtTop() {
    let display = DisplayMetrics(
      frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
      safeAreaTop: 32,
      auxiliaryLeftWidth: 654,
      auxiliaryRightWidth: 654
    )

    let geometry = DisplayGeometryCalculator.geometry(for: display)
    XCTAssertEqual(geometry.collapsedSize.height, 32)
    XCTAssertEqual(geometry.collapsedSize.width, 348)
    let sideWidth = (geometry.collapsedSize.width - display.physicalNotchWidth) / 2
    XCTAssertEqual(sideWidth, 72)
    let collapsedOrigin = geometry.origin(for: .collapsed, in: display)
    XCTAssertEqual(collapsedOrigin.x + sideWidth, display.auxiliaryLeftWidth)
    XCTAssertEqual(collapsedOrigin.x + sideWidth + display.physicalNotchWidth, 858)
    XCTAssertEqual(geometry.expandedSize, CGSize(width: 760, height: 420))
    XCTAssertEqual(geometry.origin(for: .pinned, in: display), CGPoint(x: 376, y: 562))
  }

  func testHoverPreviewIsShorterThanPinnedIsland() {
    let display = DisplayMetrics(
      frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
      safeAreaTop: 32,
      auxiliaryLeftWidth: 654,
      auxiliaryRightWidth: 654
    )

    let geometry = DisplayGeometryCalculator.geometry(for: display)

    XCTAssertLessThan(
      geometry.size(for: .preview).height,
      geometry.size(for: .pinned).height
    )
  }

  func testHoverPreviewReservesHeightForCompactCalendarAndDaySchedule() {
    let display = DisplayMetrics(
      frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
      visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
      safeAreaTop: 32,
      auxiliaryLeftWidth: 654,
      auxiliaryRightWidth: 654
    )

    let geometry = DisplayGeometryCalculator.geometry(for: display)

    XCTAssertEqual(geometry.previewSize, CGSize(width: 680, height: 280))
  }

  func testNoNotchUsesMenuBarHeightAndCapsuleWidth() {
    let display = DisplayMetrics(
      frame: CGRect(x: 100, y: 50, width: 1440, height: 900),
      visibleFrame: CGRect(x: 100, y: 50, width: 1440, height: 875),
      safeAreaTop: 0,
      auxiliaryLeftWidth: nil,
      auxiliaryRightWidth: nil
    )

    let geometry = DisplayGeometryCalculator.geometry(for: display)
    XCTAssertEqual(geometry.collapsedSize, CGSize(width: 340, height: 25 + 5))
    XCTAssertEqual(geometry.origin(for: .collapsed, in: display), CGPoint(x: 650, y: 920))
  }
}
