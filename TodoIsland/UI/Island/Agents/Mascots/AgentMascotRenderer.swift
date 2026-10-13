// Ported from wxtsky/CodeIsland (MIT License) — see ThirdParty/CODEISLAND-LICENSE.txt
// (Sources/CodeIsland/PixelCharacterView.swift, MascotTimeline.swift,
//  MascotMotion.swift, MascotAnimationGate.swift)
//
// Shared machinery every pixel mascot renders through: the SVG rect-grid
// mapper (upstream's `V` on a 15×10 base grid), rotated-arm polygons,
// keyframe curves, the frame driver (TimelineView cadence + Reduce Motion /
// Low Power gating), and the three status scenes' shell — idle → sleeping,
// processing/running → typing, waitingApproval/waitingQuestion → alert.
//
// Trimmings for this port (vs upstream): the `mascotSpeed` environment is
// gone (upstream default was already 1.0), and the AppKit panel-visibility /
// sleep-wake observers are dropped — the constraint here is pure SwiftUI +
// Foundation, so the gate watches only Reduce Motion and
// `ProcessInfo.isLowPowerModeEnabled`.

import Foundation
import SwiftUI

// MARK: - Motion vocabulary (MascotMotion, verbatim)

/// Shared motion curves for the pixel mascots.
///
/// Everything here is a PURE function of the timeline time `t` (plus constant
/// seeds), because mascot frames are re-rendered from scratch by
/// ``AgentMascotTimeline`` — there is no retained animation state, so
/// "randomness" must be deterministic.
enum AgentMascotMotion {

    /// Stable hash of an integer slot → [0, 1). Used to vary blink gaps,
    /// quirk picks, etc. without any stored state.
    static func hash01(_ n: Int, seed: UInt64 = 0) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &+ 0x9E3779B97F4A7C15 &+ seed &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        x = x ^ (x >> 31)
        return Double(x % 1_000_000) / 1_000_000
    }

    /// Asymmetric breath: quicker inhale, slower exhale, and a soft pause at
    /// the bottom — reads as "alive" instead of a metronome. Returns 0…1
    /// (0 = rest, 1 = full inhale).
    static func breathe(_ t: Double, period: Double = 4.5) -> CGFloat {
        let phase = (t / period).truncatingRemainder(dividingBy: 1)
        // 35% inhale, 45% exhale, 20% rest.
        if phase < 0.35 {
            let p = phase / 0.35
            return CGFloat(0.5 - 0.5 * cos(p * .pi))            // ease-in-out up
        } else if phase < 0.80 {
            let p = (phase - 0.35) / 0.45
            return CGFloat(0.5 + 0.5 * cos(p * .pi))            // ease-in-out down
        } else {
            return 0
        }
    }

    /// Natural blink signal: 1 = eyes open, 0 = eyes shut, with eased lids.
    /// Blinks land at irregular gaps (2.4–5.6 s) and ~1 in 6 is a double
    /// blink — the biggest single "it's alive" tell on a tiny sprite.
    static func blink(_ t: Double, seed: UInt64 = 0) -> CGFloat {
        let slotLength = 4.0
        let slot = Int(floor(t / slotLength))
        let r = hash01(slot, seed: seed)
        // Blink start jitters inside the slot; keep clear of the slot edges.
        let start = slotLength * (0.15 + 0.6 * r)
        let local = t - Double(slot) * slotLength

        let blinkDuration = 0.14
        func lid(_ dt: Double) -> CGFloat {
            guard dt >= 0, dt < blinkDuration else { return 1 }
            // Close fast, open slightly slower.
            let p = dt / blinkDuration
            return CGFloat(p < 0.4 ? 1 - (p / 0.4) : (p - 0.4) / 0.6)
        }

        var openness = lid(local - start)
        // Occasional double blink right after the first.
        if hash01(slot, seed: seed ^ 0xB11) < 0.18 {
            openness = min(openness, lid(local - start - 0.22))
        }
        return openness
    }

    /// Low-frequency "quirk" window for idle micro-actions (ear twitch, tail
    /// flick, head tilt, stretch…). Returns the 0→1→0 envelope of the quirk
    /// when inside its window, else 0. At most one quirk per `cycle` seconds,
    /// and ~30% of cycles skip theirs so the rhythm never feels scheduled.
    static func quirk(_ t: Double, cycle: Double = 7.0, duration: Double = 0.9, seed: UInt64 = 0) -> CGFloat {
        let slot = Int(floor(t / cycle))
        guard hash01(slot, seed: seed ^ 0x9D2C) > 0.30 else { return 0 }
        let start = cycle * (0.2 + 0.55 * hash01(slot, seed: seed))
        let local = t - Double(slot) * cycle - start
        guard local >= 0, local < duration else { return 0 }
        let p = local / duration
        // Smooth in-out envelope.
        return CGFloat(sin(p * .pi))
    }

    /// Picks a variant index (0..<count) for the quirk in the current cycle,
    /// so a mascot can rotate between e.g. ear-twitch / tail-flick / look-around.
    static func quirkVariant(_ t: Double, cycle: Double = 7.0, count: Int, seed: UInt64 = 0) -> Int {
        guard count > 0 else { return 0 }
        let slot = Int(floor(t / cycle))
        return Int(hash01(slot, seed: seed ^ 0x51DE) * Double(count)) % count
    }

    /// Humanized typing beat: a base cadence with deterministic micro-jitter
    /// per keystroke slot, so hands don't hammer like a metronome.
    static func typingStroke(_ t: Double, cadence: Double = 0.16, seed: UInt64 = 0) -> (active: Bool, slot: Int) {
        let slot = Int(floor(t / cadence))
        // ~18% of strokes are skipped — bursts and pauses, like real typing.
        let active = hash01(slot, seed: seed) > 0.18
        return (active, slot)
    }
}

// MARK: - Grid mapper (upstream's struct V, verbatim)

/// Coordinate helper: maps SVG pixel-art units to view points on a 15×10
/// base grid (each mascot passes its own viewport bounds + y-origin).
struct AgentMascotGrid {
    let ox: CGFloat, oy: CGFloat, s: CGFloat
    let y0: CGFloat

    init(_ sz: CGSize, svgW: CGFloat = 15, svgH: CGFloat = 10, svgY0: CGFloat = 6) {
        s = min(sz.width / svgW, sz.height / svgH)
        ox = (sz.width - svgW * s) / 2
        oy = (sz.height - svgH * s) / 2
        y0 = svgY0
    }

    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
        CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
    }

    func pt(_ x: CGFloat, _ y: CGFloat, dy: CGFloat = 0) -> CGPoint {
        CGPoint(x: ox + x * s, y: oy + (y - y0 + dy) * s)
    }
}

// MARK: - Drawing helpers

enum AgentMascotRenderer {

    /// Rotated arm: returns polygon path for a rect rotated around pivot.
    static func armPath(_ v: AgentMascotGrid, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                        pivotX: CGFloat, pivotY: CGFloat, angle: CGFloat, dy: CGFloat) -> Path {
        let a = angle * .pi / 180
        let ca = cos(a), sa = sin(a)
        let corners: [(CGFloat, CGFloat)] = [
            (x - pivotX, y - pivotY),
            (x + w - pivotX, y - pivotY),
            (x + w - pivotX, y + h - pivotY),
            (x - pivotX, y + h - pivotY),
        ]
        var path = Path()
        for (i, (cx, cy)) in corners.enumerated() {
            let rx = cx * ca - cy * sa + pivotX
            let ry = cx * sa + cy * ca + pivotY
            let pt = CGPoint(x: v.ox + rx * v.s, y: v.oy + (ry - v.y0 + dy) * v.s)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }

    /// Interpolate between keyframes: [(pct, value)].
    static func lerp(_ keyframes: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        if pct <= first.0 { return first.1 }
        for i in 1..<keyframes.count {
            if pct <= keyframes[i].0 {
                let t = (pct - keyframes[i-1].0) / (keyframes[i].0 - keyframes[i-1].0)
                return keyframes[i-1].1 + (keyframes[i].1 - keyframes[i-1].1) * t
            }
        }
        return keyframes.last?.1 ?? 0
    }
}

/// Alert-scene curves — the 3.5 s startle cycle shared by the mascots
/// (keyframe tables verbatim from upstream).
enum AgentMascotAlert {
    /// Clawd's body jump, matching clawd-notification.svg keyframes.
    static let clawdJump: [(CGFloat, CGFloat)] = [
        (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
        (0.175, -10), (0.20, -10), (0.25, 1.5),
        (0.275, -8), (0.30, -8), (0.35, 1.2),
        (0.375, -5), (0.40, -5), (0.45, 1.0),
        (0.475, -3), (0.50, -3), (0.55, 0.5),
        (0.62, 0), (1.0, 0),
    ]

    /// The decaying jump used by the cloud / gem mascots.
    static let decayingJump: [(CGFloat, CGFloat)] = [
        (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
        (0.175, -8), (0.20, -8), (0.25, 1.5),
        (0.275, -6), (0.30, -6), (0.35, 1.0),
        (0.375, -4), (0.40, -4), (0.45, 0.8),
        (0.475, -2), (0.50, -2), (0.55, 0.3),
        (0.62, 0), (1.0, 0),
    ]

    /// Clawd's arm-wave table (the right arm mirrors it negated).
    static let waveArm: [(CGFloat, CGFloat)] = [
        (0, 0), (0.03, 0), (0.10, 25),
        (0.15, 30), (0.20, 155), (0.25, 115),
        (0.30, 140), (0.35, 100), (0.40, 115),
        (0.45, 80), (0.50, 80), (0.55, 40),
        (0.62, 0), (1.0, 0),
    ]

    /// `!` mark opacity over the cycle.
    static let bangOpacity: [(CGFloat, CGFloat)] = [
        (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
    ]

    /// `!` mark scale over the cycle.
    static let bangScale: [(CGFloat, CGFloat)] = [
        (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
    ]
}

// MARK: - Motion gate (MascotAnimationGate, trimmed to Foundation)

/// Decides whether the pixel mascots should keep driving their per-frame
/// `TimelineView` redraws: they stop under Reduce Motion and Low Power Mode,
/// and re-anchor their schedules (via `epoch`) when power state lifts.
@MainActor
final class AgentMascotAnimationGate: ObservableObject {
    static let shared = AgentMascotAnimationGate()

    /// True while Low Power Mode is on.
    @Published private(set) var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Bumped whenever animations resume so periodic schedules — keyed on the
    /// epoch via `.id()` — re-anchor to "now" instead of replaying the missed
    /// ticks in a catch-up burst.
    @Published private(set) var epoch = 0

    private var observer: NSObjectProtocol?

    private init() {}

    /// Pure decision shared by the frame driver and the alert glow. Animations
    /// only run without Reduce Motion and without Low Power Mode — there is no
    /// point burning frames the user asked the system to avoid.
    static func shouldAnimate(reduceMotion: Bool, lowPower: Bool) -> Bool {
        !reduceMotion && !lowPower
    }

    /// Begin observing power-state changes. Idempotent.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPowerState() }
        }
        applyPowerState()
    }

    private func applyPowerState() {
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard isLowPowerModeEnabled != low else { return }
        isLowPowerModeEnabled = low
        if !low { epoch &+= 1 }
    }

    // No deinit observer removal: this is a process-lifetime singleton (and
    // Swift 6 forbids touching the non-Sendable observer from a nonisolated
    // deinit), so the center outlives it anyway.
}

// MARK: - Frame driver (MascotTimeline, speed fixed at the 1.0 default)

/// Shared frame driver for every pixel mascot.
///
/// Wraps `TimelineView(.periodic)` with the motion-gate plumbing, so mascots
/// hold a single static frame instead of looping while Reduce Motion or Low
/// Power Mode is on, and re-anchor their schedules on resume:
///
///     AgentMascotTimeline(interval: 0.05) { t in workCanvas(t: t) }
///
/// `content` receives the mascot-local time `t` (seconds since the reference
/// date; upstream scaled it by the user's animation-speed setting, fixed at
/// the 1.0 default here). The effective interval is clamped to
/// `minInterval` (20 fps): a 32 pt pixel sprite gains nothing perceivable
/// above that, and the wasted wakeups were a real heat contributor upstream.
struct AgentMascotTimeline<Content: View>: View {
    /// Floor for all mascot frame intervals — 20 fps.
    static var minInterval: TimeInterval { 0.05 }

    let interval: TimeInterval
    /// Time handed to `content` for the single static frame rendered while
    /// animations are gated off.
    var staticTime: Double = 0
    @ViewBuilder let content: (Double) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var gate = AgentMascotAnimationGate.shared

    private var animationsActive: Bool {
        AgentMascotAnimationGate.shouldAnimate(
            reduceMotion: reduceMotion, lowPower: gate.isLowPowerModeEnabled)
    }

    var body: some View {
        Group {
            if animationsActive {
                TimelineView(.periodic(from: .now, by: max(interval, Self.minInterval))) { ctx in
                    content(ctx.date.timeIntervalSinceReferenceDate)
                }
                .id(gate.epoch)
            } else {
                content(staticTime)
            }
        }
        .onAppear { gate.start() }
    }
}

// MARK: - Status → scene mapping

enum AgentMascotScene: Equatable {
    case sleep
    case work
    case alert

    init(_ status: AgentStatus) {
        switch status {
        case .idle: self = .sleep
        case .processing, .running: self = .work
        case .waitingApproval, .waitingQuestion: self = .alert
        }
    }
}

// MARK: - The three status scenes (shell)

/// The status shell every mascot renders inside (upstream's per-view `body`
/// switch, extracted): idle → sleeping scene, processing/running → typing
/// scene, waitingApproval/waitingQuestion → alert glow + startle pose. Also
/// owns the `alive` reset that re-triggers the alert glow when the status
/// changes.
struct AgentMascotSceneShell<Sleep: View, Work: View, AlertContent: View>: View {
    let status: AgentStatus
    let size: CGFloat
    /// Pulsing glow behind the alert pose — #FF3D00 upstream default; the
    /// Codex mascot passes its amber warning color instead.
    var alertGlow: Color = Color(red: 1.0, green: 0.24, blue: 0.0)  // #FF3D00
    /// Clawd's variant gates the `repeatForever` glow on the motion settings
    /// (upstream #225 — the CAAnimation misbehaves across display wake);
    /// every other mascot keys it on `alive` only, exactly as upstream.
    var gatesGlowOnMotionSettings = false

    @ViewBuilder let sleep: () -> Sleep
    @ViewBuilder let work: () -> Work
    @ViewBuilder let alert: () -> AlertContent

    @State private var alive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var gate = AgentMascotAnimationGate.shared

    var body: some View {
        ZStack {
            switch AgentMascotScene(status) {
            case .sleep:
                sleep()
            case .work:
                work()
            case .alert:
                ZStack {
                    alertGlowCircle
                    alert()
                }
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear { alive = true }
        .onChange(of: status) {
            alive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { alive = true }
        }
    }

    private var animationsActive: Bool {
        AgentMascotAnimationGate.shouldAnimate(
            reduceMotion: reduceMotion, lowPower: gate.isLowPowerModeEnabled)
    }

    private var alertGlowCircle: some View {
        let glowActive = gatesGlowOnMotionSettings ? (alive && animationsActive) : alive
        let pulse = Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)
        return Circle()
            .fill(alertGlow.opacity(glowActive ? 0.12 : 0))
            .frame(width: size * 0.8)
            .blur(radius: size * 0.05)
            .animation(
                gatesGlowOnMotionSettings && !animationsActive ? .default : pulse,
                value: glowActive)
            .id(gate.epoch)
    }
}

// MARK: - Floating Z's (sleep scene, shared)

/// The staggered `z z z` float-above-the-sleeper loop. Upstream mascots differ
/// only in the horizontal drift (Clawd/Dex hug the sprite, Gemini/Cursor
/// fan out further) and whether the sideways wave is present.
struct AgentMascotFloatingZs: View {
    let t: Double
    let size: CGFloat
    var xBase: Double = 0.08
    var xStep: Double = 0.06
    var wave = true

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ci = Double(i)
                let cycle = 2.8 + ci * 0.3
                let delay = ci * 0.9
                let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                let p = max(0, phase)
                let fontSize = max(6, size * CGFloat(0.18 + p * 0.10))
                let baseOpacity = 0.7 - ci * 0.1
                let opacity = p < 0.8 ? baseOpacity : (1.0 - p) * 3.5 * baseOpacity
                let waveTerm = wave ? sin(p * .pi * 2) * 0.03 : 0
                let xOff = size * CGFloat(xBase + ci * xStep + waveTerm)
                let yOff = -size * CGFloat(0.15 + p * 0.38)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }
}
