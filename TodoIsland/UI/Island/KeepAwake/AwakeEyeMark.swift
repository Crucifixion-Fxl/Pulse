// Adapted from krishhgg/Insomnia, Copyright (c) 2026 Krish Garg.
// MIT license: Resources/INSOMNIA-LICENSE.txt.
import SwiftUI

/// The almond lens on its own, for stroking.
struct AwakeEyeLens: Shape {
    func path(in rect: CGRect) -> Path {
        Path(AwakeEyeMarkGeometry.lens(in: rect))
    }
}

/// The lid that shades the lens, for filling: nothing at 1, the whole lens at 0.
struct AwakeEyeLid: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(AwakeEyeMarkGeometry.lid(in: rect, progress: progress))
    }
}

/// The five lashes on one side of the lens, for stroking. They never move.
struct AwakeEyeLashes: Shape {
    let side: AwakeEyeMarkGeometry.Side

    func path(in rect: CGRect) -> Path {
        Path(AwakeEyeMarkGeometry.lashes(in: rect, side: side))
    }
}

/// Fades one set of lashes with the blink: the lower set is gone by half
/// way, the upper set only starts to show from there, so no lash is ever
/// seen while the lid edge passes its side of the lens. Animatable so the
/// timing follows the lid's own progress rather than a plain crossfade.
nonisolated struct AwakeEyeLashFade: ViewModifier, Animatable {
    var progress: CGFloat
    let side: AwakeEyeMarkGeometry.Side

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private var opacity: CGFloat {
        let x = side == .above ? (progress - 0.5) * 2 : 1 - progress * 2
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    func body(content: Content) -> some View {
        content.opacity(opacity)
    }
}

/// The pupil with its highlight bitten out, for filling.
struct AwakeEyePupil: Shape {
    func path(in rect: CGRect) -> Path {
        Path(AwakeEyeMarkGeometry.pupil(in: rect))
    }
}

/// The pupil as the blink draws it: scaled about its own centre and faded,
/// then clipped to the lens outline, so neither the opening spring's
/// overshoot nor a blink interrupted at its peak can show it outside the
/// lens. The highlight bite is part of the same path, so it is clipped too.
struct AwakeEyePupilLayer: View {
    var scale: CGFloat
    var opacity: CGFloat

    /// The pupil's centre as a fraction of the (square) mark.
    static let anchor = UnitPoint(
        x: AwakeEyeMarkGeometry.pupilCenter.x / AwakeEyeMarkGeometry.designSize,
        y: AwakeEyeMarkGeometry.pupilCenter.y / AwakeEyeMarkGeometry.designSize
    )

    var body: some View {
        AwakeEyePupil()
            .fill(.black)
            .scaleEffect(scale, anchor: Self.anchor)
            .opacity(opacity)
            .clipShape(AwakeEyeLens())
    }
}

/// The mark as it appears in the status item: a closed eye while idle (the
/// lens shaded, lashes below), which opens while sleep is held (the lens
/// clear with a pupil, lashes above). The change is a blink: the lid lifts
/// while the lashes swap sides, and the pupil arrives behind it a beat
/// later (the 0.2-second pupil delay) and shrinks away as the lid drops; or a
/// crossfade under Reduce Motion, where the pupil only fades.
/// Everything is drawn in `.primary`, so the mark follows the light or dark
/// menu bar and never takes a tint.
struct AwakeEyeMarkView: View {
    /// 0 closed, 1 open.
    let progress: CGFloat
    let reduceMotion: Bool
    var size: CGFloat = 17

    /// What the blink's animations are keyed on. Keying on both means a
    /// Reduce Motion change mid-blink is itself a value change, so it
    /// crossfades from the current presentation instead of jumping, and
    /// any delayed pupil animation still pending is retargeted.
    struct BlinkState: Equatable {
        var progress: CGFloat
        var reduceMotion: Bool
    }

    init(isRunning: Bool, reduceMotion: Bool, size: CGFloat = 17) {
        self.init(progress: isRunning ? 1 : 0, reduceMotion: reduceMotion, size: size)
    }

    /// One frozen frame of the blink, for previews.
    init(progress: CGFloat, reduceMotion: Bool = true, size: CGFloat = 17) {
        self.progress = progress
        self.reduceMotion = reduceMotion
        self.size = size
    }

    static func stroke(size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: AwakeEyeLensGeometry.lineWidth(for: size), lineCap: .round, lineJoin: .round)
    }

    private var state: BlinkState { BlinkState(progress: progress, reduceMotion: reduceMotion) }
    private var opening: Bool { progress > 0.5 }

    private var verticalCenteringOffset: CGFloat {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        // The lens is centered, but the one-sided lashes shift the visible
        // silhouette. Center that silhouette, mirrored as the eye opens.
        let closedBounds = AwakeEyeMarkGeometry.lens(in: rect).boundingBoxOfPath
            .union(AwakeEyeMarkGeometry.lashes(in: rect, side: .below).boundingBoxOfPath)
        return (rect.midY - closedBounds.midY) * (1 - 2 * min(max(progress, 0), 1))
    }

    /// The pupil's scale for this state: full in the open eye, shrunk in
    /// the closed one, and never anything else under Reduce Motion. A frozen
    /// frame between the two is drawn part way, for previews.
    var pupilScale: CGFloat {
        reduceMotion ? 1 : AwakeMotion.pupilClosedScale + (1 - AwakeMotion.pupilClosedScale) * min(max(progress, 0), 1)
    }

    /// The pupil's opacity for this state: present in the open eye, gone in
    /// the closed one.
    var pupilOpacity: CGFloat {
        min(max(progress, 0), 1)
    }

    var body: some View {
        // The layers are drawn opaque and used as a mask over a single
        // `.primary` fill: the label colour is translucent, and this keeps the
        // lid, outline and lashes from doubling up where they overlap.
        Rectangle()
            .fill(.primary)
            .mask { layers }
            .frame(width: size, height: size)
            .offset(y: verticalCenteringOffset)
            .animation(AwakeMotion.blink(opening: opening, reduceMotion: reduceMotion), value: state)
    }

    private var layers: some View {
        let stroke = Self.stroke(size: size)
        return ZStack {
            AwakeEyeLens()
                .stroke(.black, style: stroke)
            // The pupil runs on its own curve, keyed on the eye state so a
            // close during its opening delay retargets it from wherever it is.
            AwakeEyePupilLayer(scale: pupilScale, opacity: pupilOpacity)
                .animation(AwakeMotion.pupil(opening: opening, reduceMotion: reduceMotion), value: state)
            // The lid and the lashes share the lid's curve, so the lash
            // hand-over follows the lid edge. Under Reduce Motion the closed
            // lid crossfades instead of lifting; the lashes hand over the
            // same way in both modes.
            Group {
                AwakeEyeLid(progress: reduceMotion ? 0 : progress)
                    .fill(.black)
                    .opacity(reduceMotion ? 1 - progress : 1)
                AwakeEyeLashes(side: .below)
                    .stroke(.black, style: stroke)
                    .modifier(AwakeEyeLashFade(progress: progress, side: .below))
                AwakeEyeLashes(side: .above)
                    .stroke(.black, style: stroke)
                    .modifier(AwakeEyeLashFade(progress: progress, side: .above))
            }
            .animation(AwakeMotion.blink(opening: opening, reduceMotion: reduceMotion), value: state)
        }
    }
}
