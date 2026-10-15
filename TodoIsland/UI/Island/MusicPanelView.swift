import SwiftUI

private enum Layout {
  static let favoritesWidth: CGFloat = 168
  static let playerCardWidth: CGFloat = 236
  static let artworkSize: CGFloat = 128
  static let artworkRadius: CGFloat = 12
  static let cardSpacing: CGFloat = 10
  static let cardHeight: CGFloat = 324
}

/// The music sidebar panel: player card on the left (artwork, metadata,
/// progress, controls) and synced lyrics on the right, following the
/// system Now Playing state. Shows empty states when nothing plays and
/// a shimmer while lyrics are being found.
struct MusicPanelView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Last decoded artwork. Both the cover and the blurred ambience used to
  /// run NSImage(data:) on every body eval — twice per 2Hz publish — for
  /// the same bytes; one decode per artwork serves both.
  @State private var artworkImage: (data: Data, image: NSImage)?

  enum Metrics {
    /// Matches the AI usage pane so the island height stays uniform.
    static let contentHeight: CGFloat = 324
  }

  private func cachedArtwork(_ data: Data) -> NSImage? {
    if let held = artworkImage, held.data == data { return held.image }
    guard let image = NSImage(data: data) else { return nil }
    image.cacheMode = .always
    artworkImage = (data, image)
    return image
  }

  var body: some View {
    HStack(alignment: .top, spacing: Layout.cardSpacing) {
      favoritesCard
      if let track = model.nowPlaying {
        playerCard(track)
        lyricsCard(track)
      } else {
        notPlayingCard
        lyricsWaitingCard
      }
    }
  }

  // MARK: Favorites

  private var favoritesCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 5) {
        Image(systemName: "heart.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color(hue: 0.98, saturation: 0.62, brightness: 0.9))
        Text("music.favorites.title")
          .font(.system(size: 11.5, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 0)
        Text(String(format: L10n.text("music.favorites.count"), model.favoriteTracks.count))
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
      }
      .padding(.bottom, 7)

      switch model.favoritesState {
      case .idle, .loading:
        VStack(spacing: 8) {
          ForEach(0..<6, id: \.self) { _ in
            Capsule(style: .continuous)
              .fill(.white.opacity(0.05))
              .frame(width: 110, height: 9)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      case .unconfigured, .failed:
        VStack(spacing: 6) {
          Image(systemName: "heart")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(ReUITheme.muted)
          Text(
            model.favoritesState == .unconfigured
              ? "music.favorites.unconfigured"
              : model.neteaseMusicU == nil
                ? "music.favorites.needs-login"
                : "music.favorites.failed")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(ReUITheme.muted)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        ScrollView(showsIndicators: false) {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(model.favoriteTracks) { track in
              FavoriteRow(
                track: track,
                isCurrent: isCurrentlyPlaying(track)
              ) {
                model.playFavorite(track)
              }
            }
          }
          .padding(.vertical, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      }
    }
    .padding(10)
    .frame(width: Layout.favoritesWidth, height: Layout.cardHeight, alignment: .top)
    .panelCard()
  }

  private func isCurrentlyPlaying(_ track: FavoriteTrack) -> Bool {
    guard let now = model.nowPlaying else { return false }
    return LyricsIdentity.normalize(now.title) == LyricsIdentity.normalize(track.name)
      && (track.artist.isEmpty
        || LyricsIdentity.normalize(now.artist).contains(LyricsIdentity.normalize(track.artist)))
  }

  // MARK: Player

  private func playerCard(_ track: NowPlayingTrack) -> some View {
    VStack(alignment: .center, spacing: 0) {
      artwork
        .frame(maxWidth: .infinity)

      Text(track.title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.8)
        .multilineTextAlignment(.center)
        .padding(.top, 10)

      Text(track.artist)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
        .lineLimit(1)
        .padding(.top, 2)

      Spacer(minLength: 8)

      progressSection(track)
        .padding(.bottom, 10)

      controlsRow

      if !model.mediaKeysReady.contains(16) {
        Text("music.controls.seed-hint")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
          .padding(.top, 6)
      }
    }
    .padding(12)
    .frame(width: Layout.playerCardWidth, height: Layout.cardHeight, alignment: .top)
    .background(artworkAmbience)
    .panelCard()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("\(track.title), \(track.artist)"))
  }

  @ViewBuilder
  private var artwork: some View {
    let shape = RoundedRectangle(cornerRadius: Layout.artworkRadius, style: .continuous)
    if let data = model.nowPlaying?.artworkData,
      let image = cachedArtwork(data)
    {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: Layout.artworkSize, height: Layout.artworkSize)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    } else if let title = model.nowPlaying?.title, !title.isEmpty {
      // No artwork: the song title's first glyph on a cold-to-warm
      // gradient — each track gets its own visual identity.
      let glyph = String(title.prefix(1))
      shape
        .fill(
          LinearGradient(
            colors: [
              Color(hue: 0.58, saturation: 0.45, brightness: 0.28),
              Color(hue: 0.08, saturation: 0.40, brightness: 0.22),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
          )
        )
        .frame(width: Layout.artworkSize, height: Layout.artworkSize)
        .overlay(
          Text(glyph)
            .font(.system(size: Layout.artworkSize * 0.42, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .minimumScaleFactor(0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    } else {
      shape
        .fill(ReUITheme.itemHover)
        .frame(width: Layout.artworkSize, height: Layout.artworkSize)
        .overlay(
          Image(systemName: "music.note")
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(ReUITheme.muted)
        )
    }
  }

  /// Blurred cover wash behind the player card, clipped to the card.
  @ViewBuilder
  private var artworkAmbience: some View {
    if let data = model.nowPlaying?.artworkData,
      let image = cachedArtwork(data)
    {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: Layout.playerCardWidth, height: Layout.cardHeight)
        .blur(radius: 40)
        .opacity(0.22)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
  }

  private func progressSection(_ track: NowPlayingTrack) -> some View {
    VStack(spacing: 4) {
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule(style: .continuous)
            .fill(.white.opacity(0.10))
          Capsule(style: .continuous)
            .fill(.white.opacity(0.92))
            .frame(width: max(4, proxy.size.width * track.progress))
        }
        .contentShape(Rectangle())
        .onTapGesture { (location: CGPoint) in
          guard model.nowPlayingSupportsSeeking, track.duration > 0, proxy.size.width > 0
          else { return }
          let fraction = min(max(location.x / proxy.size.width, 0), 1)
          model.musicSeek(to: fraction * track.duration)
        }
      }
      .frame(height: 4)

      HStack {
        Text(MusicFormat.mmss(track.elapsed))
        Spacer(minLength: 0)
        Text("-" + MusicFormat.mmss(max(track.duration - track.elapsed, 0)))
      }
      .font(.system(size: 10, weight: .medium))
      .monospacedDigit()
      .foregroundStyle(ReUITheme.muted)
    }
  }

  private var controlsRow: some View {
    HStack(spacing: 26) {
      ControlButton(
        symbol: "backward.fill", size: 15, label: "music.controls.previous"
      ) {
        model.musicSkipBackward()
      }
      ControlButton(
        symbol: model.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
        size: 17,
        label: "music.controls.toggle"
      ) {
        model.musicTogglePlayPause()
      }
      ControlButton(
        symbol: "forward.fill", size: 15, label: "music.controls.next"
      ) {
        model.musicSkipForward()
      }
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: Lyrics

  private func lyricsCard(_ track: NowPlayingTrack) -> some View {
    ZStack {
      switch model.lyricsState {
      case .idle, .loading:
        lyricsShimmer
      case .loaded(let lyrics):
        lyricList(lyrics: lyrics, track: track)
      case .notFound:
        lyricsNotFound(track)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(height: Layout.cardHeight, alignment: .top)
    // Borderless by design: the lyric column floats on the island surface.
  }

  /// The lyric list, fume-style: the active line prints character by
  /// character with a breathing glow at the frontier, neighbours recede
  /// into scale/blur depth, and line changes ride a near-critical spring
  /// scroll (folia-major's "浮名" semantics reinterpreted for the panel).
  /// Paused playback renders one static frame instead of keeping a
  /// timeline alive.
  private func lyricList(
    lyrics: Lyrics, track: NowPlayingTrack
  ) -> some View {
    Group {
      if track.isPlaying {
        // 0.1s drives only line progression and the scroll trigger; the
        // 30Hz print sweep lives inside the single current-line row.
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
          lyricColumn(
            lyrics: lyrics, track: track,
            elapsed: Self.liveElapsed(track: track, at: timeline.date))
        }
      } else {
        lyricColumn(
          lyrics: lyrics, track: track, elapsed: Self.liveElapsed(track: track, at: Date()))
      }
    }
    .overlay(lyricsEdgeFades)
  }

  private static func liveElapsed(track: NowPlayingTrack, at date: Date) -> TimeInterval {
    track.elapsed
      + (track.isPlaying
        ? max(date.timeIntervalSince(track.receivedAt), 0) * track.playbackRate
        : 0)
  }

  private func lyricColumn(
    lyrics: Lyrics, track: NowPlayingTrack, elapsed: TimeInterval
  ) -> some View {
    let currentIndex = LyricsParse.currentLineIndex(
      at: elapsed - model.lyricOffset, lines: lyrics.lines
    )

    return ScrollViewReader { proxy in
      ScrollView(showsIndicators: false) {
        VStack(spacing: 12) {
          ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
            lyricLine(
              line, index: index, currentIndex: currentIndex,
              lyrics: lyrics, track: track)
          }
        }
        .padding(.vertical, 110)
        .frame(maxWidth: .infinity)
        .id(track.lyricsIdentity)
      }
      .onChange(of: currentIndex) { _, newValue in
        guard let newValue else { return }
        if reduceMotion {
          proxy.scrollTo(newValue, anchor: .center)
        } else {
          withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) {
            proxy.scrollTo(newValue, anchor: .center)
          }
        }
      }
      .onAppear {
        guard let currentIndex else { return }
        proxy.scrollTo(currentIndex, anchor: .center)
      }
    }
  }

  private func lyricLine(
    _ line: LyricLine,
    index: Int,
    currentIndex: Int?,
    lyrics: Lyrics,
    track: NowPlayingTrack
  ) -> some View {
    let isCurrent = index == currentIndex
    let distance = currentIndex.map { abs($0 - index) } ?? Int.max
    let depth = LyricDepth(distance: distance)

    let window = lyrics.printWindow(
      for: index,
      fallbackSpan: max(4, min(8, track.duration - line.time)))
    let timing = LyricPrintTiming(
      charCount: line.text.count, start: window.start, end: window.end)

    // Fixed-size identities crossfading: fonts never interpolate (fractional
    // point sizes re-wrap and jitter every frame), and the uniform row
    // height keeps layout completely static — the handover is pure
    // opacity/scale transforms, so it is smooth by construction.
    return VStack(spacing: 4) {
      ZStack {
        // Small identity: every non-current line at a constant 16pt.
        Text(line.text)
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(.white.opacity(depth.alpha))
          .multilineTextAlignment(.center)
          .scaleEffect(reduceMotion ? 1 : depth.scale)
          .blur(radius: isCurrent || reduceMotion ? 0 : depth.blur)
          .opacity(isCurrent ? 0 : 1)

        // Big identity: the printing current line at a constant 28pt.
        printingLine(line, isCurrent: isCurrent, timing: timing, track: track)
      }
      .frame(minHeight: 42, alignment: .center)

      // Translation slots are reserved permanently: inserting/removing the
      // subline on handover changed the row height for one frame, which
      // shifted the whole column mid-spring. Pure opacity now.
      if let translation = line.translation {
        Text(translation)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
          .multilineTextAlignment(.center)
          .opacity(isCurrent ? 1 : 0)
          .accessibilityHidden(!isCurrent)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      guard model.nowPlayingSupportsSeeking else { return }
      model.musicSeek(to: line.time)
    }
    // Both triggers matter: the current-line handover animates the font
    // size and mask, and each neighbour's depth-slot shift (1 -> 2 -> 3)
    // animates its scale/opacity/blur — previously those popped.
    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: isCurrent)
    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: distance)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }

  /// The current line's printing pair. Its 30Hz timeline is scoped here so
  /// the print sweep re-evaluates one row, not the whole column — the
  /// whole-column re-render during scroll springs read as a flash.
  @ViewBuilder
  private func printingLine(
    _ line: LyricLine, isCurrent: Bool, timing: LyricPrintTiming, track: NowPlayingTrack
  ) -> some View {
    if track.isPlaying {
      TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
        let t = Self.liveElapsed(track: track, at: timeline.date) - model.lyricOffset
        printingLineContent(
          line, isCurrent: isCurrent,
          fill: timing.fillFraction(at: t), envelope: timing.glowEnvelope(at: t))
      }
    } else {
      let t = Self.liveElapsed(track: track, at: Date()) - model.lyricOffset
      printingLineContent(
        line, isCurrent: isCurrent,
        fill: timing.fillFraction(at: t), envelope: timing.glowEnvelope(at: t))
    }
  }

  private func printingLineContent(
    _ line: LyricLine, isCurrent: Bool, fill: Double, envelope: Double
  ) -> some View {
    let printing = isCurrent && !reduceMotion
    // Whole-point radii only: fractional blur re-rasterizes every frame.
    let glowRadius = CGFloat((3 + 5 * envelope).rounded())
    return ZStack {
      Text(line.text)
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(.white.opacity(printing ? 0.28 : 0))
        .multilineTextAlignment(.center)
      Text(line.text)
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .shadow(
          color: printing ? .white.opacity(0.35 + 0.3 * envelope) : .clear,
          radius: printing ? glowRadius : 0)
        .mask(printFillMask(fraction: printing ? fill : 1))
    }
    .opacity(isCurrent ? 1 : 0)
    .scaleEffect(isCurrent ? 1 : 0.86)
  }

  /// Hard-edged left-to-right reveal for the printed overlay, with a soft
  /// 3% frontier so the glow glides instead of stepping.
  private func printFillMask(fraction: Double) -> some View {
    LinearGradient(
      stops: [
        .init(color: .white, location: 0),
        .init(color: .white, location: max(0, fraction - 0.015)),
        .init(color: .clear, location: min(1, fraction + 0.015)),
        .init(color: .clear, location: 1),
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  /// Soft fade into the island surface top and bottom — the Day
  /// Schedule's clipped-viewport idiom, retuned for the borderless
  /// column.
  private var lyricsEdgeFades: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [.black, .black.opacity(0)],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: 16)
      Spacer(minLength: 0)
      LinearGradient(
        colors: [.black.opacity(0), .black],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: 16)
    }
    .allowsHitTesting(false)
  }

  private var lyricsShimmer: some View {
    VStack(spacing: 12) {
      ForEach(0..<3, id: \.self) { _ in
        Capsule(style: .continuous)
          .fill(.white.opacity(0.05))
          .frame(width: 120, height: 12)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func lyricsNotFound(_ track: NowPlayingTrack) -> some View {
    VinylRecordView(isPlaying: track.isPlaying)
      // Duration may arrive after playback starts; only a song change
      // should replay the entrance.
      .id([track.lyricsIdentity.title, track.lyricsIdentity.artist])
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityLabel(Text("music.lyrics.not-found"))
  }

  // MARK: Empty states

  private var notPlayingCard: some View {
    VStack(spacing: 8) {
      Image(systemName: "music.note")
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
      Text("music.not-playing")
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white)
      Text("music.not-playing.detail")
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(width: Layout.playerCardWidth, height: Layout.cardHeight, alignment: .center)
    .panelCard()
  }

  private var lyricsWaitingCard: some View {
    Text("music.lyrics.waiting")
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(ReUITheme.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .frame(height: Layout.cardHeight, alignment: .center)
  }
}

// MARK: - Favorite row

private struct FavoriteRow: View {
  let track: FavoriteTrack
  let isCurrent: Bool
  let onPlay: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: onPlay) {
      HStack(spacing: 6) {
        Image(systemName: isCurrent ? "waveform" : "play.fill")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(
            isCurrent ? Color(hue: 0.98, saturation: 0.62, brightness: 0.9) : ReUITheme.muted
          )
          .opacity(isCurrent || isHovering ? 1 : 0.45)

        VStack(alignment: .leading, spacing: 1) {
          Text(track.name)
            .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? .white : .white.opacity(0.82))
            .lineLimit(1)
          Text(track.artist)
            .font(.system(size: 8.5))
            .foregroundStyle(ReUITheme.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3.5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(
            isCurrent
              ? Color.white.opacity(0.09)
              : isHovering ? ReUITheme.itemHover : .clear
          )
      )
    }
    .buttonStyle(.plain)
    .onHover { inside in
      withAnimation(.easeOut(duration: 0.12)) { isHovering = inside }
    }
    .accessibilityLabel(Text("\(track.name), \(track.artist)"))
    .accessibilityHint(Text("music.favorites.play.accessibility"))
  }
}

// MARK: - Lyric depth

/// Distance-based receding slots around the active line — folia-major's
/// neighbour falloff retuned for the panel: near lines stay legible, far
/// lines shrink, dim, and soften out of focus.
private struct LyricDepth {
  let scale: CGFloat
  let alpha: Double
  let blur: CGFloat

  init(distance: Int) {
    switch distance {
    case 0: (scale, alpha, blur) = (1, 1, 0)
    case 1: (scale, alpha, blur) = (0.85, 0.70, 0)
    case 2: (scale, alpha, blur) = (0.74, 0.45, 1)
    default: (scale, alpha, blur) = (0.66, 0.25, 1.5)
    }
  }
}

// MARK: - Control button

/// Playback control glyph with the sidebar-icon hover treatment: white
/// glow plus a slight scale-up, disabled under Reduce Motion.
private struct ControlButton: View {
  let symbol: String
  let size: CGFloat
  let label: LocalizedStringKey
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: isHovering ? .white.opacity(0.6) : .clear, radius: 4)
        .scaleEffect(isHovering && !reduceMotion ? 1.08 : 1)
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
    }
    .accessibilityLabel(Text(label))
  }
}
