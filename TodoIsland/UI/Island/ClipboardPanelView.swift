import SwiftUI

private enum Layout {
  static let cardWidth: CGFloat = 220
  static let cardHeight: CGFloat = 252
  static let cardSpacing: CGFloat = 12
  static let viewport: CGFloat = 3 * cardWidth + 2 * cardSpacing
}

/// The clipboard-history sidebar panel. A horizontal rail of capture
/// cards — three visible at a time, the mouse wheel (and horizontal
/// trackpad swipe) pages through the trailing seven. Clicking a card
/// puts it back on the system pasteboard.
struct ClipboardPanelView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  enum Metrics {
    /// Matches the other feature panes so the island height stays uniform.
    static let contentHeight: CGFloat = 324
  }

  @State private var scrollOffset: CGFloat = 0
  @State private var pendingScroll: CGFloat = 0
  @State private var pendingDecay: Task<Void, Never>?
  @State private var wheelMonitor: Any?
  @State private var copiedFlashID: UUID?

  private var cardPitch: CGFloat { Layout.cardWidth + Layout.cardSpacing }
  private var maxOffset: CGFloat {
    max(0, CGFloat(model.clipboardItems.count) * cardPitch - Layout.viewport)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if model.clipboardItems.isEmpty {
        emptyState
      } else {
        rail
        pageDots
      }
    }
    .padding(.top, 2)
    .onAppear { installWheelMonitor() }
    .onDisappear { removeWheelMonitor() }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("clipboard.title")
        .font(.system(size: 13, weight: .semibold))
      Spacer(minLength: 0)
      Text(String(format: L10n.text("clipboard.count"), model.clipboardItems.count))
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
    }
  }

  // MARK: - Rail

  private var rail: some View {
    HStack(spacing: Layout.cardSpacing) {
      ForEach(model.clipboardItems) { item in
        ClipboardCard(item: item, flashCopied: copiedFlashID == item.id) {
          model.recopyClipboardItem(item)
          flashCopied(item)
        }
        .frame(width: Layout.cardWidth, height: Layout.cardHeight)
      }
    }
    .offset(x: -scrollOffset)
    .animation(
      reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86),
      value: scrollOffset
    )
    .frame(width: Layout.viewport, height: Layout.cardHeight, alignment: .leading)
    .clipped()
  }

  /// Wheel paging with a threshold: tiny movements accumulate silently
  /// and only a crossing (≈ one firm notch) commits a one-card step, so
  /// high-resolution wheels and trackpad jitter don't crawl the rail.
  private static let scrollThreshold: CGFloat = 42

  private func installWheelMonitor() {
    guard wheelMonitor == nil else { return }
    wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      let deltaY = event.scrollingDeltaY
      let deltaX = event.scrollingDeltaX
      guard deltaY != 0 || deltaX != 0 else { return event }
      let primary = deltaY != 0 ? deltaY : -deltaX
      onWheel(primary)
      return event
    }
  }

  private func onWheel(_ delta: CGFloat) {
    pendingScroll += delta
    pendingDecay?.cancel()
    pendingDecay = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(180))
      guard !Task.isCancelled else { return }
      pendingScroll = 0
    }
    while abs(pendingScroll) >= Self.scrollThreshold {
      let direction: CGFloat = pendingScroll > 0 ? 1 : -1
      pendingScroll -= direction * Self.scrollThreshold
      let target = min(max(scrollOffset + direction * cardPitch, 0), maxOffset)
      guard target != scrollOffset else {
        pendingScroll = 0
        break
      }
      withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86)) {
        scrollOffset = target
      }
    }
  }

  private func removeWheelMonitor() {
    if let wheelMonitor {
      NSEvent.removeMonitor(wheelMonitor)
    }
    wheelMonitor = nil
  }

  private var pageDots: some View {
    let pageCount = max(1, Int((maxOffset / cardPitch).rounded(.up)) + 1)
    let current = max(0, min(Int(scrollOffset / cardPitch), pageCount - 1))
    return HStack(spacing: 5) {
      ForEach(0..<pageCount, id: \.self) { page in
        Circle()
          .fill(page == current ? Color.white.opacity(0.85) : Color.white.opacity(0.25))
          .frame(width: 4, height: 4)
      }
    }
    .frame(maxWidth: .infinity)
    .animation(.easeOut(duration: 0.2), value: current)
  }

  private func flashCopied(_ item: ClipboardItem) {
    copiedFlashID = item.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
      if copiedFlashID == item.id { copiedFlashID = nil }
    }
  }

  // MARK: - Empty state

  private var emptyState: some View {
    HStack(spacing: Layout.cardSpacing) {
      ForEach(0..<3, id: \.self) { _ in
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(ReUITheme.subtleBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
          .frame(width: Layout.cardWidth, height: Layout.cardHeight)
          .overlay(
            VStack(spacing: 6) {
              Image(systemName: "doc.on.clipboard")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(ReUITheme.muted)
              Text("clipboard.empty")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ReUITheme.muted)
            }
          )
      }
    }
    .frame(width: Layout.viewport, height: Layout.cardHeight, alignment: .leading)
  }
}

// MARK: - Animated check

/// The copy confirmation: the disc pops in with a spring and the tick
/// draws itself stroke-by-stroke, then the overlay lingers briefly.
private struct AnimatedCheckmark: View {
  let reduceMotion: Bool

  @State private var discScale: CGFloat = 0.4
  @State private var trim: CGFloat = 0

  var body: some View {
    ZStack {
      Circle()
        .fill(Color.green)
        .frame(width: 44, height: 44)
        .shadow(color: .green.opacity(0.45), radius: 9, y: 1)
        .scaleEffect(discScale)
      CheckShape()
        .trim(from: 0, to: trim)
        .stroke(
          Color.white,
          style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
        )
        .frame(width: 19, height: 14)
    }
    .onAppear {
      if reduceMotion {
        discScale = 1
        trim = 1
        return
      }
      withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) {
        discScale = 1
      }
      withAnimation(.easeOut(duration: 0.26).delay(0.1)) {
        trim = 1
      }
    }
  }

  private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
      var path = Path()
      path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.08))
      path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      return path
    }
  }
}

// MARK: - Card

private struct ClipboardCard: View {
  let item: ClipboardItem
  let flashCopied: Bool
  let onCopy: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      preview

      VStack(alignment: .leading, spacing: 2) {
        Text(kindLabel)
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(kindTint)
        Text(item.displayName)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .padding(.top, 8)
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .panelCard(
      fill: isHovering ? ReUITheme.itemHover : ReUITheme.item,
      stroke: isHovering ? .white.opacity(0.16) : ReUITheme.subtleBorder
    )
    .overlay {
      if flashCopied {
        VStack(spacing: 5) {
          AnimatedCheckmark(reduceMotion: reduceMotion)
          Text("clipboard.copied")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity)
      }
    }
    .scaleEffect(isHovering && !reduceMotion ? 1.02 : 1)
    .contentShape(Rectangle())
    .onHover { inside in
      withAnimation(.easeOut(duration: 0.15)) { isHovering = inside }
    }
    .animation(.easeOut(duration: 0.15), value: isHovering)
    .onTapGesture(perform: onCopy)
    .accessibilityLabel(Text("\(kindLabel), \(item.displayName)"))
    .accessibilityHint(Text("clipboard.copy.accessibility"))
  }

  @ViewBuilder
  private var preview: some View {
    switch item.kind {
    case .text:
      // Full-bleed text well with a fade at the bottom so truncation
      // reads as "more below" rather than a hard cut.
      ScrollView(.vertical, showsIndicators: false) {
        Text(item.text ?? "")
          .font(.system(size: 10.5))
          .foregroundStyle(.white.opacity(0.88))
          .lineSpacing(2.5)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(9)
      }
      .frame(maxHeight: .infinity)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(.white.opacity(0.05))
      )
      .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
      .overlay(alignment: .bottom) {
        LinearGradient(
          colors: [.clear, .black.opacity(0.55)],
          startPoint: .top, endPoint: .bottom
        )
        .frame(height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .allowsHitTesting(false)
      }
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: "text.quote")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
          .padding(6)
      }
    case .image:
      if let data = item.imageData, let image = NSImage(data: data) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .padding(6)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(ReUITheme.itemHover)
          )
          .overlay(alignment: .bottomTrailing) {
            Text("\(Int(image.size.width))×\(Int(image.size.height))")
              .font(.system(size: 8.5, weight: .semibold))
              .monospacedDigit()
              .foregroundStyle(.white.opacity(0.85))
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(
                Capsule(style: .continuous).fill(.black.opacity(0.5))
              )
              .padding(5)
          }
      } else {
        missingPreview(icon: "photo")
      }
    case .video:
      ZStack {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(
            LinearGradient(
              colors: [kindTint.opacity(0.28), ReUITheme.itemHover],
              startPoint: .topLeading, endPoint: .bottomTrailing
            )
          )
        VStack(spacing: 5) {
          Image(systemName: "film.fill")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(kindTint.opacity(0.95))
            Text(item.fileURL?.pathExtension.uppercased() ?? "VIDEO")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
          if let size = fileSize {
            Text(size)
              .font(.system(size: 8.5, weight: .medium))
              .monospacedDigit()
              .foregroundStyle(ReUITheme.muted)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxHeight: .infinity)
    }
  }

  private var fileSize: String? {
    guard let url = item.fileURL,
      let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
        as? Int
    else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func missingPreview(icon: String) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(ReUITheme.itemHover)
      Image(systemName: icon)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
    }
    .frame(maxHeight: .infinity)
  }

  private var kindTint: Color {
    switch item.kind {
    case .text: Color(hue: 0.58, saturation: 0.55, brightness: 0.95)
    case .image: Color(hue: 0.45, saturation: 0.55, brightness: 0.85)
    case .video: Color(hue: 0.08, saturation: 0.62, brightness: 0.95)
    }
  }

  private var kindLabel: LocalizedStringKey {
    switch item.kind {
    case .text: "clipboard.kind.text"
    case .image: "clipboard.kind.image"
    case .video: "clipboard.kind.video"
    }
  }
}
