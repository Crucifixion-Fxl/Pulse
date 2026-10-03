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

  enum Metrics {
    /// Matches the AI usage pane so the island height stays uniform.
    static let contentHeight: CGFloat = 324
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
      let image = NSImage(data: data)
    {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
        .frame(width: Layout.artworkSize, height: Layout.artworkSize)
        .clipShape(shape)
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
      let image = NSImage(data: data)
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
        lyricsNotFound
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(height: Layout.cardHeight, alignment: .top)
    // Borderless by design: the lyric column floats on the island surface.
  }

  /// The original lyric list: a plain scrolling column. Lines keep their
  /// natural heights and the active line scrolls to centre with a short
  /// ease — the behaviour the product started with.
  private func lyricList(
    lyrics: Lyrics, track: NowPlayingTrack
  ) -> some View {
    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
      let liveElapsed =
        track.elapsed
        + (track.isPlaying
          ? max(timeline.date.timeIntervalSince(track.receivedAt), 0) * track.playbackRate
          : 0)
      let currentIndex = LyricsParse.currentLineIndex(
        at: liveElapsed - model.lyricOffset, lines: lyrics.lines
      )

      ScrollViewReader { proxy in
        ScrollView(showsIndicators: false) {
          LazyVStack(spacing: 12) {
            ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
              lyricLine(line, index: index, currentIndex: currentIndex)
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
            withAnimation(.easeInOut(duration: 0.3)) {
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
    .overlay(lyricsEdgeFades)
    .overlay(alignment: .bottomTrailing) { lyricOffsetControls }
  }

  /// ±0.25 s lyric lead/lag; the value label resets to zero.
  private var lyricOffsetControls: some View {
    HStack(spacing: 6) {
      Button {
        model.lyricOffset -= 0.25
      } label: {
        Image(systemName: "minus")
          .font(.system(size: 8.5, weight: .semibold))
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)

      Button {
        model.lyricOffset = 0
      } label: {
        Text(
          model.lyricOffset == 0
            ? "0s"
            : String(format: "%+.2fs", model.lyricOffset)
        )
          .font(.system(size: 9, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(ReUITheme.muted)
          .frame(minWidth: 34)
      }
      .buttonStyle(.plain)

      Button {
        model.lyricOffset += 0.25
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 8.5, weight: .semibold))
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)
    }
    .foregroundStyle(ReUITheme.muted)
    .padding(6)
    .accessibilityLabel(Text("music.lyrics.offset.accessibility"))
    .accessibilityValue(Text(String(format: "%+.2fs", model.lyricOffset)))
  }

  private func lyricLine(_ line: LyricLine, index: Int, currentIndex: Int?) -> some View {
    let isCurrent = index == currentIndex
    let distance = currentIndex.map { abs($0 - index) } ?? Int.max

    return VStack(spacing: 4) {
      Text(line.text)
        .font(
          .system(size: isCurrent ? 28 : 16, weight: isCurrent ? .semibold : .regular)
        )
        .foregroundStyle(
          isCurrent ? .white : (distance <= 2 ? ReUITheme.muted : .white.opacity(0.30))
        )
        .multilineTextAlignment(.center)

      if isCurrent, let translation = line.translation {
        Text(translation)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(ReUITheme.muted)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .onTapGesture {
      guard model.nowPlayingSupportsSeeking else { return }
      model.musicSeek(to: line.time)
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: isCurrent)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
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

  private var lyricsNotFound: some View {
    VStack(spacing: 6) {
      Image(systemName: "music.note")
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
      Text("music.lyrics.not-found")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
