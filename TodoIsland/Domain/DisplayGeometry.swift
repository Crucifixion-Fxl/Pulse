import CoreGraphics

struct DisplayMetrics: Equatable, Sendable {
  let frame: CGRect
  let visibleFrame: CGRect
  let safeAreaTop: CGFloat
  let auxiliaryLeftWidth: CGFloat?
  let auxiliaryRightWidth: CGFloat?

  var hasPhysicalNotch: Bool { safeAreaTop > 0 }

  var physicalNotchWidth: CGFloat {
    guard
      hasPhysicalNotch,
      let auxiliaryLeftWidth,
      let auxiliaryRightWidth
    else { return 200 }

    return max(0, frame.width - auxiliaryLeftWidth - auxiliaryRightWidth)
  }
}

struct IslandGeometry: Equatable, Sendable {
  let collapsedSize: CGSize
  let previewSize: CGSize
  let expandedSize: CGSize

  func size(for state: IslandPresentationState) -> CGSize {
    switch state {
    case .collapsed:
      collapsedSize
    case .preview:
      previewSize
    case .pinned:
      expandedSize
    }
  }

  func origin(for state: IslandPresentationState, in display: DisplayMetrics) -> CGPoint {
    let size = size(for: state)
    return CGPoint(x: display.frame.midX - size.width / 2, y: display.frame.maxY - size.height)
  }
}

enum IslandAnimatedSurfaceLayout {
  static func surfaceSize(windowSize: CGSize, targetSize _: CGSize) -> CGSize {
    windowSize
  }
}

enum DisplayGeometryCalculator {
  static let collapsedNotchSideWidth: CGFloat = 72
  static let expandedBottomInset: CGFloat = 7
  static let expandedDisplayMargin: CGFloat = 16

  static func expandedContentTopInset(for display: DisplayMetrics) -> CGFloat {
    max(16, display.safeAreaTop + 6)
  }

  static func geometry(
    for display: DisplayMetrics,
    expandedContentHeight: CGFloat? = nil
  ) -> IslandGeometry {
    let availableWidth = max(320, display.frame.width - 32)
    let contentHeight = expandedContentHeight.flatMap {
      $0.isFinite && $0 > 0 ? $0 : nil
    }
    let requestedHeight = contentHeight.map {
      $0 + expandedContentTopInset(for: display) + expandedBottomInset
    } ?? 420
    // Keep the surface inside the display while allowing the selected
    // feature's calendar and completion heatmap to use the available height.
    // The old fixed 80-point deduction clipped the bottom of short displays.
    let maximumExpandedHeight = max(0, display.frame.height - expandedDisplayMargin)
    let expanded = CGSize(
      width: min(760, availableWidth),
      height: min(requestedHeight, maximumExpandedHeight))
    // Preview and pinned states share the selected feature's content height.
    let preview = expanded

    let collapsedHeight: CGFloat
    if display.hasPhysicalNotch {
      collapsedHeight = display.safeAreaTop
    } else {
      collapsedHeight = max(30, display.frame.maxY - display.visibleFrame.maxY)
    }

    let collapsedWidth =
      display.hasPhysicalNotch
      ? min(display.physicalNotchWidth + collapsedNotchSideWidth * 2, availableWidth)
      : min(340, availableWidth)
    return IslandGeometry(
      collapsedSize: CGSize(width: collapsedWidth, height: collapsedHeight),
      previewSize: preview,
      expandedSize: expanded
    )
  }
}
