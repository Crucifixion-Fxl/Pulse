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

  /// Decoded-once thumbnails: decoding at render time hitches the first
  /// scroll frame, so every item's image is preloaded into an NSCache the
  /// moment the history changes — paging then only moves textures.
  @MainActor
  final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSUUID, NSImage>()

    func image(for item: ClipboardItem) -> NSImage? {
      if let cached = cache.object(forKey: item.id as NSUUID) { return cached }
      // Restored items carry no in-RAM image data (only previews load at
      // launch); items whose preview generation also failed fall back to a
      // one-time decode of the on-disk full blob.
      guard
        let data = item.previewImageData ?? item.imageData
          ?? ClipboardHistoryService.shared.fullImageData(for: item.id),
        let image = NSImage(data: data)
      else { return nil }
      image.cacheMode = .always
      cache.setObject(image, forKey: item.id as NSUUID)
      return image
    }

    func preload(_ items: [ClipboardItem]) {
      for item in items where item.kind == .image {
        _ = image(for: item)
      }
    }
  }

  enum Metrics {
    /// Matches the other feature panes so the island height stays uniform.
    static let contentHeight: CGFloat = 324
  }

  @State private var leadingItemID: UUID?
  @State private var copiedFlashID: UUID?

  private var pageCount: Int { max(1, model.clipboardItems.count - 2) }
  private var clampedIndex: Int {
    min(model.clipboardItems.firstIndex { $0.id == leadingItemID } ?? 0, pageCount - 1)
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
    .onAppear {
      ThumbnailCache.shared.preload(model.clipboardItems)
    }
    .onChange(of: model.clipboardItems) { _, items in
      ThumbnailCache.shared.preload(items)
    }
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
    ClipboardCardRail(itemIDs: model.clipboardItems.map(\.id), leadingItemID: $leadingItemID) {
      HStack(spacing: Layout.cardSpacing) {
        ForEach(model.clipboardItems) { item in
          ClipboardCard(item: item, flashCopied: copiedFlashID == item.id) {
            model.recopyClipboardItem(item)
            flashCopied(item)
          }
          .frame(width: Layout.cardWidth, height: Layout.cardHeight)
        }
      }
      .scrollTargetLayout()
    }
    .frame(width: Layout.viewport, height: Layout.cardHeight)
  }

  private var pageDots: some View {
    HStack(spacing: 5) {
      ForEach(0..<pageCount, id: \.self) { page in
        Circle()
          .fill(page == clampedIndex ? Color.white.opacity(0.85) : Color.white.opacity(0.25))
          .frame(width: 4, height: 4)
      }
    }
    .frame(maxWidth: .infinity)
    .animation(.easeOut(duration: 0.2), value: clampedIndex)
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
    Button(action: onCopy) {
      cardBody
    }
    .buttonStyle(.plain)
  }

  private var cardBody: some View {
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
        .allowsHitTesting(false)
      }
    }
    .scaleEffect(isHovering && !reduceMotion ? 1.02 : 1)
    .contentShape(Rectangle())
    .onHover { inside in
      withAnimation(.easeOut(duration: 0.15)) { isHovering = inside }
    }
    .animation(.easeOut(duration: 0.15), value: isHovering)
    .accessibilityLabel(Text("\(kindLabel), \(item.displayName)"))
    .accessibilityHint(Text("clipboard.copy.accessibility"))
  }

  @ViewBuilder
  private var preview: some View {
    switch item.kind {
    case .text:
      // Full-bleed text well with a fade at the bottom so truncation
      // reads as "more below" rather than a hard cut.
      ClipboardTextPreview(text: item.text ?? "")
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
      if let image = ClipboardPanelView.ThumbnailCache.shared.image(for: item) {
        Image(nsImage: image)
          .resizable()
          .interpolation(.medium)
          .scaledToFit()
          .padding(6)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(ReUITheme.itemHover)
          )
          .drawingGroup()
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

// MARK: - Text typography

/// Short notes read at a glance; paragraphs keep a consistent reading edge.
/// This changes only the preview — copying always uses the original text.
struct ClipboardTextPreview: View {
  let text: String

  private var trimmedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isShortNote: Bool {
    trimmedText.count <= 36 && paragraphs.count <= 2
  }

  private var paragraphs: [String] {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
  }

  var body: some View {
    GeometryReader { geometry in
      if isShortNote {
        Text(trimmedText)
          .font(.system(size: 16, weight: .medium))
          .multilineTextAlignment(.center)
          .lineSpacing(4)
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: max(0, geometry.size.width - 24),
            height: geometry.size.height * 0.82, alignment: .center)
          .padding(.horizontal, 12)
      } else {
        ScrollView(.vertical, showsIndicators: false) {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
              Text(paragraph.isEmpty ? " " : paragraph)
                .font(.system(size: 13))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(12)
        }
      }
    }
    .foregroundStyle(.white.opacity(0.88))
  }
}
