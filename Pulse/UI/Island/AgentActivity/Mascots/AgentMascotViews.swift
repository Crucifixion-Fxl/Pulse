// Ported from wxtsky/CodeIsland (MIT License) — see ThirdParty/CODEISLAND-LICENSE.txt
// (Sources/CodeIsland/MascotView.swift, PixelCharacterView.swift, DexView.swift,
//  GeminiView.swift, CursorView.swift, GrokView.swift)
//
// Routing is trimmed to the mascots this port carries — claude (Clawd),
// codex (Dex), grok, gemini, cursor; every other source falls back to the
// existing ``AgentMonogramView`` tile. The mascotSpeed / animation-gate
// environment plumbing is gone: the renderer runs at the fixed 1.0 default
// and reads Reduce Motion + Low Power Mode itself. All rect coordinate
// tables are copied verbatim from upstream.

import SwiftUI

/// Routes a CLI source identifier to its pixel mascot view; unknown sources
/// fall back to the monogram tile.
struct AgentMascotView: View {
    let source: String
    let status: AgentStatus
    let size: CGFloat

    var body: some View {
        let resolved = AgentSessionSnapshot.normalizedSupportedSource(source) ?? source
        switch resolved {
        case "claude":
            AgentClawdView(status: status, size: size)
        case "codex":
            AgentDexView(status: status, size: size)
        case "grok":
            AgentGrokView(status: status, size: size)
        case "gemini", "google-antigravity":
            // Google Antigravity is Gemini-based — reuse the Gemini mascot.
            AgentGeminiView(status: status, size: size)
        case "cursor", "cursor-cli":
            AgentCursorView(status: status, size: size)
        default:
            AgentMonogramView(source: source, size: size)
        }
    }
}

// MARK: - Clawd (Claude) — PixelCharacterView.swift, verbatim coordinates

/// Clawd — Claude mascot, adapted from clawd-on-desk SVG pixel art.
/// Renders SVG rects proportionally via Canvas + timeline animations.
struct AgentClawdView: View {
    let status: AgentStatus
    var size: CGFloat = 27

    // Colors from clawd-on-desk
    private static let bodyC  = Color(red: 0.871, green: 0.533, blue: 0.427) // #DE886D
    private static let eyeC   = Color.black
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)     // #FF3D00
    private static let kbBase = Color(red: 0.38, green: 0.44, blue: 0.50)  // lighter base
    private static let kbKey  = Color(red: 0.60, green: 0.66, blue: 0.72)  // visible keys
    private static let kbHi   = Color.white                                 // bright flash

    var body: some View {
        AgentMascotSceneShell(
            status: status,
            size: size,
            alertGlow: Self.alertC,
            gatesGlowOnMotionSettings: true
        ) {
            sleepScene
        } work: {
            workScene
        } alert: {
            alertScene
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SLEEP — sploot pose, breathing, floating z's
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var sleepScene: some View {
        ZStack {
            // Character body (behind) — 8fps: breathing/blinking needs no more.
            AgentMascotTimeline(interval: 0.12) { t in
                sleepCanvas(t: t)
            }

            // Z's — continuous float-up loop, staggered timing
            AgentMascotTimeline(interval: 0.12) { t in
                AgentMascotFloatingZs(t: t, size: size)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        // Asymmetric breath (quick inhale, slow exhale, rest) reads far more
        // alive than the old symmetric sin pulse.
        let breathe = AgentMascotMotion.breathe(t, period: 4.5)

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 17, svgH: 7, svgY0: 9)
            drawSleeping(c, v: v, breathe: breathe, t: t)
        }
    }

    // Draw sleeping character (sploot pose from clawd-sleeping.svg)
    private func drawSleeping(_ ctx: GraphicsContext, v: AgentMascotGrid, breathe: CGFloat, t: Double) {
        // Shadow (wider for sploot, pulses with breath)
        let shadowScale: CGFloat = 1.0 + breathe * 0.03
        ctx.fill(Path(v.r(-1, 15, 17 * shadowScale, 1)),
                 with: .color(.black.opacity(0.35 + breathe * 0.08)))

        // Legs pointing up from behind. One leg occasionally twitches in its
        // sleep — the classic dreaming-pet kick. Deterministic quirk:
        // at most one twitch per ~6s cycle, sometimes skipped entirely.
        let twitch = AgentMascotMotion.quirk(t, cycle: 6.0, duration: 0.55, seed: 0xC1A)
        let twitchLeg = AgentMascotMotion.quirkVariant(t, cycle: 6.0, count: 4, seed: 0xC1A)
        for (i, x) in ([3, 5, 9, 11] as [CGFloat]).enumerated() {
            let kick: CGFloat = i == twitchLeg ? twitch * 0.9 : 0
            ctx.fill(Path(v.r(x, 8.5 - kick, 1, 1.5 + kick)), with: .color(Self.bodyC))
        }

        // Flattened torso — big puff on inhale (25% from SVG)
        let puff = max(0, breathe) * 0.25
        let torsoH: CGFloat = 5 * (1.0 + puff)
        let torsoY: CGFloat = 15 - torsoH
        let torsoW: CGFloat = 13 * (1.0 + breathe * 0.015) // slight width pulse
        let torsoX: CGFloat = 1 - (torsoW - 13) / 2
        ctx.fill(Path(v.r(torsoX, torsoY, torsoW, torsoH)), with: .color(Self.bodyC))

        // Arms spread flat on the ground
        ctx.fill(Path(v.r(-1, 13, 2, 2)), with: .color(Self.bodyC))
        ctx.fill(Path(v.r(14, 13, 2, 2)), with: .color(Self.bodyC))

        // Shut eyes (thicker for visibility, move with puff). A rare REM
        // flutter narrows them for a beat — dreaming, not just parked.
        let rem = AgentMascotMotion.quirk(t, cycle: 9.0, duration: 0.7, seed: 0x5EE)
        let eyeH: CGFloat = 1.0 - rem * 0.5
        let eyeY: CGFloat = 12.2 - puff * 2.5 + (1.0 - eyeH) / 2
        ctx.fill(Path(v.r(3, eyeY, 2.5, eyeH)), with: .color(Self.eyeC))
        ctx.fill(Path(v.r(9.5, eyeY, 2.5, eyeH)), with: .color(Self.eyeC))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // WORK — typing: bounce + arm rotation + keyboard + squinted eyes
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var workScene: some View {
        AgentMascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Thinking pause: every ~11s Clawd stops typing for a beat, hands
        // hovering, eyes drifting up — bursts feel intentional, not looped.
        let pause = AgentMascotMotion.quirk(t, cycle: 11.0, duration: 1.4, seed: 0x7A9)
        let typingIntensity = 1.0 - Double(pause)

        // Body bounce softens to a breath-sway while pausing.
        let bounce = sin(t * 2 * .pi / 0.35) * 1.2 * typingIntensity
            + sin(t * 2 * .pi / 2.8) * 0.35 * (1 - typingIntensity)
        let breathe = sin(t * 2 * .pi / 3.2)

        // Arm typing with humanized cadence: strokes occasionally skip
        // (bursts and micro-pauses), and both arms lift while thinking.
        let strokeL = AgentMascotMotion.typingStroke(t, cadence: 0.15, seed: 0x1EF7)
        let strokeR = AgentMascotMotion.typingStroke(t, cadence: 0.12, seed: 0x819)
        let armLRaw = (strokeL.active ? sin(t * 2 * .pi / 0.15) : -0.6) * typingIntensity
        let armRRaw = (strokeR.active ? sin(t * 2 * .pi / 0.12) : -0.6) * typingIntensity
        let armL = armLRaw * 22.5 - 32.5        // -55 to -10
        let armR = armRRaw * 22.5 + 32.5        // 10 to 55

        // Key flash only on real strokes.
        let leftHit = strokeL.active && armLRaw > 0.3
        let rightHit = strokeR.active && armRRaw > 0.3
        // Vary which key lights per stroke slot (deterministic).
        let leftKeyCol = Int(AgentMascotMotion.hash01(strokeL.slot, seed: 0xFACE0) * 3)
        let rightKeyCol = 3 + Int(AgentMascotMotion.hash01(strokeR.slot, seed: 0xFACE1) * 3)

        // Eyes: squinted while typing; look up during the thinking pause or
        // the occasional screen-scan; natural blink cadence on top.
        let scanPhase = t.truncatingRemainder(dividingBy: 10.0)
        let scanning = scanPhase > 5.7 && scanPhase < 6.9
        let eyeScale: CGFloat = (scanning || pause > 0.3) ? 1.0 : 0.5
        let eyeDY: CGFloat = eyeScale < 0.8 ? 1.0 : -0.5
        let finalEyeScale = eyeScale * max(0.1, AgentMascotMotion.blink(t, seed: 0xB1))

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 16, svgH: 11, svgY0: 5.5)
            let dy = bounce

            // 1. Shadow
            let shadowW: CGFloat = 9 - abs(dy) * 0.3
            c.fill(Path(v.r(3 + (9 - shadowW) / 2, 15, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.4 - abs(dy) * 0.03))))

            // 2. Short legs (h=2, behind keyboard)
            for x: CGFloat in [3, 5, 9, 11] {
                c.fill(Path(v.r(x, 13, 1, 2)), with: .color(Self.bodyC))
            }

            // 3. Torso
            let bScale = 1.0 + breathe * 0.015
            let torsoW = 11 * bScale
            c.fill(Path(v.r(2 - (torsoW - 11) / 2, 6, torsoW, 7, dy: dy)),
                   with: .color(Self.bodyC))

            // 4. Eyes
            let eyeH: CGFloat = 2 * finalEyeScale
            let eyeY: CGFloat = 8 + (2 - eyeH) / 2 + eyeDY
            c.fill(Path(v.r(4, eyeY, 1, eyeH, dy: dy)), with: .color(Self.eyeC))
            c.fill(Path(v.r(10, eyeY, 1, eyeH, dy: dy)), with: .color(Self.eyeC))

            // 5. Keyboard (on top of legs)
            c.fill(Path(v.r(-0.5, 11.8, 16, 3.5)), with: .color(Self.kbBase))
            // Key grid: 6 columns × 3 rows
            for row in 0..<3 {
                let ky = 12.2 + CGFloat(row) * 1.0
                for col in 0..<6 {
                    let kx = 0.3 + CGFloat(col) * 2.5
                    let w: CGFloat = (col == 2 && row == 1) ? 4.5 : 2.0
                    c.fill(Path(v.r(kx, ky, w, 0.7)), with: .color(Self.kbKey))
                }
            }
            // Key flashes synced with arm hits
            if leftHit {
                let row = leftKeyCol % 3
                let kx = 0.3 + CGFloat(leftKeyCol) * 2.5
                let ky = 12.2 + CGFloat(row) * 1.0
                c.fill(Path(v.r(kx, ky, 2.0, 0.7)), with: .color(Self.kbHi.opacity(0.9)))
            }
            if rightHit {
                let row = (rightKeyCol - 3) % 3
                let kx = 0.3 + CGFloat(rightKeyCol) * 2.5
                let ky = 12.2 + CGFloat(row) * 1.0
                c.fill(Path(v.r(kx, ky, 2.0, 0.7)), with: .color(Self.kbHi.opacity(0.9)))
            }

            // 6. Arms on top — pivot at body connection (inner edge of arm)
            c.fill(AgentMascotRenderer.armPath(v, x: 0, y: 9, w: 2, h: 2, pivotX: 2, pivotY: 10,
                                               angle: armL, dy: dy), with: .color(Self.bodyC))
            c.fill(AgentMascotRenderer.armPath(v, x: 13, y: 9, w: 2, h: 2, pivotX: 13, pivotY: 10,
                                               angle: armR, dy: dy), with: .color(Self.bodyC))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ALERT — 3.5s cycle: startle → decaying jumps → rest
    // Matches clawd-notification.svg keyframes
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var alertScene: some View {
        AgentMascotTimeline(interval: 0.03) { t in
            alertCanvas(t: t)
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        // Body jump — smooth interpolation from SVG keyframes
        let jumpY = AgentMascotRenderer.lerp(AgentMascotAlert.clawdJump, at: pct)

        // Squash/stretch on landing (exaggerated for visibility)
        let scaleX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.05 : 1.0  // squash wider
        let scaleY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.04 : 1.0  // squash shorter

        // Arm waving — smooth interpolation
        let armL = AgentMascotRenderer.lerp(AgentMascotAlert.waveArm, at: pct)
        let armR = -AgentMascotRenderer.lerp(AgentMascotAlert.waveArm, at: pct)

        // Eye startle: widen + shift gaze on initial startle
        let eyeScale: CGFloat = (pct > 0.03 && pct < 0.15) ? 1.3 : 1.0
        let eyeDY: CGFloat = (pct > 0.03 && pct < 0.15) ? -0.5 : 0

        // ! mark
        let bangOpacity = AgentMascotRenderer.lerp(AgentMascotAlert.bangOpacity, at: pct)
        let bangScale = AgentMascotRenderer.lerp(AgentMascotAlert.bangScale, at: pct)

        return Canvas { c, sz in
            // Taller viewport to fit ! mark above head
            let v = AgentMascotGrid(sz, svgW: 15, svgH: 12, svgY0: 4)

            // Shadow — reacts to jump height
            let shadowW: CGFloat = 9 * (1.0 - abs(min(0, jumpY)) * 0.04)
            let shadowOp = max(0.08, 0.5 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(3 + (9 - shadowW) / 2, 15, shadowW, 1)),
                   with: .color(.black.opacity(shadowOp)))

            // Legs
            for x: CGFloat in [3, 5, 9, 11] {
                c.fill(Path(v.r(x, 11, 1, 4)), with: .color(Self.bodyC))
            }

            // Torso with squash/stretch
            let torsoW = 11 * scaleX
            let torsoH = 7 * scaleY
            let torsoX = 2 - (torsoW - 11) / 2
            let torsoY = 6 + (7 - torsoH)  // stretch from bottom
            c.fill(Path(v.r(torsoX, torsoY, torsoW, torsoH, dy: jumpY)),
                   with: .color(Self.bodyC))

            // Eyes (startled = wider)
            let eyeH = 2 * eyeScale
            let eyeYPos = 8 + (2 - eyeH) / 2 + eyeDY
            c.fill(Path(v.r(4, eyeYPos, 1, eyeH, dy: jumpY)), with: .color(Self.eyeC))
            c.fill(Path(v.r(10, eyeYPos, 1, eyeH, dy: jumpY)), with: .color(Self.eyeC))

            // Arms — correct pivot at body connection
            c.fill(AgentMascotRenderer.armPath(v, x: 0, y: 9, w: 2, h: 2, pivotX: 2, pivotY: 10,
                                               angle: armL, dy: jumpY), with: .color(Self.bodyC))
            c.fill(AgentMascotRenderer.armPath(v, x: 13, y: 9, w: 2, h: 2, pivotX: 13, pivotY: 10,
                                               angle: armR, dy: jumpY), with: .color(Self.bodyC))

            // ! mark — positioned above head, dampened movement (doesn't fly off screen)
            if bangOpacity > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 4.5 + jumpY * 0.15 // dampened: only 15% of jump
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOpacity)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOpacity)))
            }
        }
    }
}

// MARK: - Dex (Codex) — DexView.swift, verbatim coordinates

/// Dex — Codex mascot, pixel-art cloud with terminal prompt face.
/// Inspired by Codex's cloud icon with `>_` symbol. OpenAI black & white style.
struct AgentDexView: View {
    let status: AgentStatus
    var size: CGFloat = 27

    // OpenAI black & white palette — white body, black prompt
    private static let cloudC    = Color(red: 0.92, green: 0.92, blue: 0.93) // off-white
    private static let cloudDark = Color(red: 0.70, green: 0.70, blue: 0.72) // legs
    private static let promptC   = Color.black
    private static let alertC    = Color(red: 1.0, green: 0.55, blue: 0.0)   // amber warning
    private static let kbBase    = Color(red: 0.18, green: 0.18, blue: 0.20)
    private static let kbKey     = Color(red: 0.40, green: 0.40, blue: 0.42)
    private static let kbHi      = Color.white

    var body: some View {
        AgentMascotSceneShell(status: status, size: size, alertGlow: Self.alertC) {
            sleepScene
        } work: {
            workScene
        } alert: {
            alertScene
        }
    }

    // ── Cloud body: a pixel-art blob shape ──
    // Rounded cloud made of overlapping rects (8-bit style)
    private func drawCloud(_ c: GraphicsContext, v: AgentMascotGrid, dy: CGFloat,
                           squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let cc = Self.cloudC

        // Center offset for squash
        let cx: CGFloat = 7.5
        func sx(_ x: CGFloat, w: CGFloat) -> (CGFloat, CGFloat) {
            let nx = cx + (x - cx) * squashX
            return (nx, w * squashX)
        }

        // Cloud body — flat black, pixel blob shape
        let rows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
            (14, 4, 7),       // bottom
            (13, 3, 9),
            (12, 2, 11),
            (11, 1, 13),      // widest
            (10, 1, 13),
            (9,  1, 13),
            (8,  2, 11),
            (7,  2, 11),
            // Top bumps (cloud silhouette)
            (6,  3, 3),       // left bump
            (6,  6, 3),       // center bump
            (6,  9, 3),       // right bump
            (5,  4, 2),       // left bump top
            (5,  6.5, 2),     // center bump top
            (5,  9, 2),       // right bump top
        ]

        for row in rows {
            let (adjX, adjW) = sx(row.x, w: row.w)
            let adjH: CGFloat = 1 * squashY
            c.fill(Path(v.r(adjX, row.y * squashY + (1 - squashY) * 10, adjW, adjH, dy: dy)),
                   with: .color(cc))
        }
    }

    // ── Draw `>_` terminal prompt as face ──
    private func drawPrompt(_ c: GraphicsContext, v: AgentMascotGrid, dy: CGFloat,
                            color: Color = Self.promptC, cursorOn: Bool = true) {
        // `>` chevron — pixel art
        c.fill(Path(v.r(3, 10, 1, 1, dy: dy)), with: .color(color))
        c.fill(Path(v.r(4, 11, 1, 1, dy: dy)), with: .color(color))
        c.fill(Path(v.r(3, 12, 1, 1, dy: dy)), with: .color(color))

        // `_` cursor
        if cursorOn {
            c.fill(Path(v.r(6, 12, 3, 1, dy: dy)), with: .color(color))
        }
    }

    // ── Shadow ──
    private func drawShadow(_ c: GraphicsContext, v: AgentMascotGrid, width: CGFloat = 9, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 15, width, 1)),
               with: .color(.black.opacity(opacity)))
    }

    // ── Small legs (pixel stubs under cloud) ──
    private func drawLegs(_ c: GraphicsContext, v: AgentMascotGrid) {
        c.fill(Path(v.r(5, 14.5, 1, 1.5)), with: .color(Self.cloudDark))
        c.fill(Path(v.r(9, 14.5, 1, 1.5)), with: .color(Self.cloudDark))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SLEEP — floating gently, cursor blinking slow
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var sleepScene: some View {
        ZStack {
            AgentMascotTimeline(interval: 0.12) { t in
                sleepCanvas(t: t)
            }
            AgentMascotTimeline(interval: 0.12) { t in
                AgentMascotFloatingZs(t: t, size: size)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        // Cloud drift: two incommensurate sines — the float never quite repeats,
        // which is exactly how a cloud should behave.
        let float = sin(t * 2 * .pi / 4.0) * 0.7 + sin(t * 2 * .pi / 6.3) * 0.35
        // Standby heartbeat: mostly a slow blink, but every ~8s the cursor gives
        // a quick double-pulse — a terminal dreaming in its sleep.
        let pulse = AgentMascotMotion.quirk(t, cycle: 8.0, duration: 0.5, seed: 0xDE1)
        let cursorPhase = t.truncatingRemainder(dividingBy: 1.2)
        let cursorOn = pulse > 0 ? (pulse * 4).truncatingRemainder(dividingBy: 1) < 0.5 : cursorPhase < 0.6

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 15, svgH: 12, svgY0: 4)

            drawShadow(c, v: v, width: 7 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v)
            drawCloud(c, v: v, dy: float)
            // Sleep: only show dim cursor (no `>` chevron = mouth closed)
            if cursorOn {
                c.fill(Path(v.r(6, 12, 3, 1, dy: float)),
                       with: .color(Self.promptC.opacity(pulse > 0 ? 0.5 : 0.3)))
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // WORK — bouncing, cursor active, typing on keyboard
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var workScene: some View {
        AgentMascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Compile-wait pause: every ~12s the terminal stops hammering keys for
        // a moment (cursor steady, bounce settles) — output is "scrolling".
        let pause = AgentMascotMotion.quirk(t, cycle: 12.0, duration: 1.2, seed: 0xDE2)
        let intensity = 1.0 - Double(pause)
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0 * intensity

        // Cursor rapid blink while typing; solid during the pause (busy, not idle).
        let cursorPhase = t.truncatingRemainder(dividingBy: 0.3)
        let cursorOn = pause > 0.3 ? true : cursorPhase < 0.15

        // Key flash with humanized stroke cadence — skipped strokes read as bursts.
        let stroke = AgentMascotMotion.typingStroke(t, cadence: 0.1, seed: 0xDE3)
        let keyPhase = Int(AgentMascotMotion.hash01(stroke.slot, seed: 0xDE4) * 6)

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 16, svgH: 14, svgY0: 3)
            let dy = bounce

            // Shadow
            let shadowW: CGFloat = 8 - abs(dy) * 0.3
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(dy) * 0.03))))

            drawLegs(c, v: v)

            // Keyboard
            c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    let kx = 0.5 + CGFloat(col) * 2.4
                    c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            // Key flash — only on real strokes, and never during the pause
            if stroke.active && pause < 0.3 {
                let flashRow = keyPhase / 3
                let flashCol = keyPhase % 6
                let fkx = 0.5 + CGFloat(flashCol) * 2.4
                let fky = 13.5 + CGFloat(flashRow) * 1.2
                c.fill(Path(v.r(fkx, fky, 1.8, 0.7)), with: .color(Self.kbHi.opacity(0.9)))
            }

            drawCloud(c, v: v, dy: dy)
            drawPrompt(c, v: v, dy: dy, cursorOn: cursorOn)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ALERT — shaking, prompt flashing amber
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var alertScene: some View {
        AgentMascotTimeline(interval: 0.03) { t in
            alertCanvas(t: t)
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = AgentMascotRenderer.lerp(AgentMascotAlert.decayingJump, at: pct)

        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0

        // Shake
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // Prompt flashing between white and amber
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0.0
        let promptColor = flash > 0.5 ? Self.alertC : Self.promptC

        // ! mark
        let bangOp = AgentMascotRenderer.lerp(AgentMascotAlert.bangOpacity, at: pct)
        let bangScale = AgentMascotRenderer.lerp(AgentMascotAlert.bangScale, at: pct)

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 16, svgH: 14, svgY0: 3)

            // Shadow
            let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
            let shadowOp = max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(shadowOp)))

            drawLegs(c, v: v)

            // Cloud body with shake offset — draw manually with offset
            // Since drawCloud doesn't take shakeX, we apply transform
            c.translateBy(x: shakeX * v.s, y: 0)
            drawCloud(c, v: v, dy: jumpY, squashX: squashX, squashY: squashY)
            drawPrompt(c, v: v, dy: jumpY, color: promptColor, cursorOn: true)
            c.translateBy(x: -shakeX * v.s, y: 0)

            // ! mark
            if bangOp > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 4 + jumpY * 0.15
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }
}

// MARK: - Gemini — GeminiView.swift, verbatim coordinates

/// Gemini — Google Gemini CLI mascot, four-pointed sparkle star.
/// Blue→Purple→Rose gradient (#4796E4 → #847ACE → #C3677F).
struct AgentGeminiView: View {
    let status: AgentStatus
    var size: CGFloat = 27

    // Gemini brand gradient
    private static let blueC  = Color(red: 0.278, green: 0.588, blue: 0.894) // #4796E4
    private static let purpC  = Color(red: 0.518, green: 0.478, blue: 0.808) // #847ACE
    private static let roseC  = Color(red: 0.765, green: 0.404, blue: 0.498) // #C3677F
    private static let faceC  = Color.white
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.22, green: 0.25, blue: 0.38)
    private static let kbKey  = Color(red: 0.40, green: 0.44, blue: 0.58)
    private static let kbHi   = Color.white

    var body: some View {
        AgentMascotSceneShell(status: status, size: size, alertGlow: Self.alertC) {
            sleepScene
        } work: {
            workScene
        } alert: {
            alertScene
        }
    }

    // ── Draw sparkle star body — 4-pointed star with gradient fill ──
    private func drawStar(_ c: GraphicsContext, v: AgentMascotGrid, dy: CGFloat,
                          scale: CGFloat = 1.0, rotate: CGFloat = 0) {
        let cx: CGFloat = 7.5, cy: CGFloat = 10.0
        let outerR: CGFloat = 4.5 * scale
        let innerR: CGFloat = 1.8 * scale
        let rot = rotate * .pi / 180

        var path = Path()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 - .pi / 2 + rot
            let r = i % 2 == 0 ? outerR : innerR
            let px = cx + cos(angle) * r
            let py = cy + sin(angle) * r
            let pt = CGPoint(x: v.ox + px * v.s, y: v.oy + (py - v.y0 + dy) * v.s)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()

        // Gradient fill (top-left blue → bottom-right rose)
        let topPt = CGPoint(x: v.ox + (cx - outerR) * v.s, y: v.oy + (cy - outerR - v.y0 + dy) * v.s)
        let botPt = CGPoint(x: v.ox + (cx + outerR) * v.s, y: v.oy + (cy + outerR - v.y0 + dy) * v.s)
        c.fill(path, with: .linearGradient(
            Gradient(colors: [Self.blueC, Self.purpC, Self.roseC]),
            startPoint: topPt, endPoint: botPt))
    }

    // ── Draw face: two dot eyes ──
    private func drawFace(_ c: GraphicsContext, v: AgentMascotGrid, dy: CGFloat,
                          eyeScale: CGFloat = 1.0, blinkPhase: CGFloat = 1.0) {
        let eyeH: CGFloat = 1.5 * eyeScale * blinkPhase
        let eyeY: CGFloat = 9.5 + (1.5 - eyeH) / 2
        c.fill(Path(v.r(5.5, eyeY, 1.2, max(0.3, eyeH), dy: dy)), with: .color(Self.faceC))
        c.fill(Path(v.r(8.3, eyeY, 1.2, max(0.3, eyeH), dy: dy)), with: .color(Self.faceC))
    }

    // ── Shadow ──
    private func drawShadow(_ c: GraphicsContext, v: AgentMascotGrid, width: CGFloat = 7, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 15, width, 1)),
               with: .color(.black.opacity(opacity)))
    }

    // ── Small legs (partially follow body) ──
    private func drawLegs(_ c: GraphicsContext, v: AgentMascotGrid, dy: CGFloat = 0) {
        let legDy = dy * 0.3  // legs follow body at 30% amplitude
        c.fill(Path(v.r(5.5, 14, 1, 2, dy: legDy)), with: .color(Self.purpC.opacity(0.7)))
        c.fill(Path(v.r(8.5, 14, 1, 2, dy: legDy)), with: .color(Self.purpC.opacity(0.7)))
    }

    // ━━━━━━ SLEEP ━━━━━━
    private var sleepScene: some View {
        ZStack {
            AgentMascotTimeline(interval: 0.12) { t in
                sleepCanvas(t: t)
            }
            AgentMascotTimeline(interval: 0.12) { t in
                AgentMascotFloatingZs(t: t, size: size, xBase: 0.15, xStep: 0.08)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        // Two incommensurate drift periods — the float never quite repeats,
        // and every mascot has its own rhythm so multi-session rows don't sync.
        let float = sin(t * 2 * .pi / 4.67) * 0.68 + sin(t * 2 * .pi / 7.01) * 0.36
        let phase = (t / 4.67).truncatingRemainder(dividingBy: 1)
        let slowSpin = sin(phase * .pi * 2) * 5  // gentle rotation
        let blinkCycle = t.truncatingRemainder(dividingBy: 4.0)
        let blink: CGFloat = (blinkCycle > 3.5 && blinkCycle < 3.7) ? 0.15 : 0.5  // sleepy but visible

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 15, svgH: 12, svgY0: 4)
            drawShadow(c, v: v, width: 6 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v, dy: float)
            drawStar(c, v: v, dy: float, scale: 0.9, rotate: slowSpin)
            drawFace(c, v: v, dy: float, blinkPhase: blink)
        }
    }

    // ━━━━━━ WORK ━━━━━━
    private var workScene: some View {
        AgentMascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Work pause: every ~13s the bounce settles for a beat —
        // reading output, not hammering keys nonstop.
        let workPause = AgentMascotMotion.quirk(t, cycle: 12.9, duration: 1.2, seed: 0x40d)
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let spin = sin(t * 2 * .pi / 1.2) * 15  // gentle wobble, not full rotation
        let blink = max(0.1, AgentMascotMotion.blink(t, seed: 0x40e))
        let keyPhase = Int(t / 0.1) % 6

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 16, svgH: 14, svgY0: 3)
            let dy = bounce

            // Shadow
            let shadowW: CGFloat = 7 - abs(dy) * 0.3
            c.fill(Path(v.r(4 + (7 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(dy) * 0.03))))

            drawLegs(c, v: v, dy: dy)

            // Keyboard
            c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    let kx = 0.5 + CGFloat(col) * 2.4
                    c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            let flashRow = keyPhase / 3
            let flashCol = keyPhase % 6
            c.fill(Path(v.r(0.5 + CGFloat(flashCol) * 2.4, 13.5 + CGFloat(flashRow) * 1.2, 1.8, 0.7)),
                   with: .color(Self.kbHi.opacity(0.9)))

            drawStar(c, v: v, dy: dy, scale: 1.0, rotate: spin)
            drawFace(c, v: v, dy: dy, blinkPhase: blink)
        }
    }

    // ━━━━━━ ALERT ━━━━━━
    private var alertScene: some View {
        AgentMascotTimeline(interval: 0.03) { t in
            alertCanvas(t: t)
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = AgentMascotRenderer.lerp(AgentMascotAlert.decayingJump, at: pct)

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0
        let pulseScale: CGFloat = (pct > 0.03 && pct < 0.55)
            ? 1.0 + sin(pct * 20) * 0.15 : 1.0

        let bangOp = AgentMascotRenderer.lerp(AgentMascotAlert.bangOpacity, at: pct)
        let bangScale = AgentMascotRenderer.lerp(AgentMascotAlert.bangScale, at: pct)

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 16, svgH: 14, svgY0: 3)

            // Shadow
            let shadowW: CGFloat = 7 * (1.0 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (7 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04))))

            drawLegs(c, v: v, dy: jumpY)

            c.translateBy(x: shakeX * v.s, y: 0)
            drawStar(c, v: v, dy: jumpY, scale: pulseScale, rotate: 0)
            drawFace(c, v: v, dy: jumpY, eyeScale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
            c.translateBy(x: -shakeX * v.s, y: 0)

            // ! mark
            if bangOp > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 4 + jumpY * 0.15
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }
}

// MARK: - CursorBot (Cursor) — CursorView.swift, verbatim coordinates

/// CursorBot — Cursor AI mascot, pixel-art hexagonal gem with diagonal highlight.
/// Based on Cursor's actual logo: a faceted polyhedron with a bright diagonal slash.
/// Warm dark #14120B body, light face #EDECEC highlight.
struct AgentCursorView: View {
    let status: AgentStatus
    var size: CGFloat = 27

    // Cursor brand palette
    private static let darkC   = Color(red: 0.08, green: 0.07, blue: 0.04)  // #14120B
    private static let midC    = Color(red: 0.15, green: 0.14, blue: 0.12)  // #26251E facet
    private static let lightC  = Color(red: 0.93, green: 0.93, blue: 0.93)  // #EDECEC highlight
    private static let edgeC   = Color(red: 0.30, green: 0.28, blue: 0.24)  // facet edge
    private static let alertC  = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase  = Color(red: 0.12, green: 0.11, blue: 0.08)
    private static let kbKey   = Color(red: 0.30, green: 0.28, blue: 0.22)
    private static let kbHi    = Color(red: 0.93, green: 0.93, blue: 0.93)

    var body: some View {
        AgentMascotSceneShell(status: status, size: size, alertGlow: Self.alertC) {
            sleepScene
        } work: {
            workScene
        } alert: {
            alertScene
        }
    }

    // ── Draw gem body — hexagonal polyhedron with facets ──
    private func drawGem(_ c: GraphicsContext, v: AgentMascotGrid, dy: CGFloat,
                         shimmer: CGFloat = 0) {
        // Hexagon vertices (flat-top orientation, centered at 7.5, 10)
        let cx: CGFloat = 7.5, cy: CGFloat = 10.0
        let rx: CGFloat = 5.0, ry: CGFloat = 4.5  // slightly wider than tall

        let top    = v.pt(cx, cy - ry, dy: dy)           // top center
        let topR   = v.pt(cx + rx, cy - ry * 0.45, dy: dy) // top-right
        let botR   = v.pt(cx + rx, cy + ry * 0.45, dy: dy) // bottom-right
        let bot    = v.pt(cx, cy + ry, dy: dy)            // bottom center
        let botL   = v.pt(cx - rx, cy + ry * 0.45, dy: dy) // bottom-left
        let topL   = v.pt(cx - rx, cy - ry * 0.45, dy: dy) // top-left
        let center = v.pt(cx, cy, dy: dy)

        // Left-dark facet (top-left → top → center → bottom-left)
        var leftTop = Path()
        leftTop.move(to: topL)
        leftTop.addLine(to: top)
        leftTop.addLine(to: center)
        leftTop.addLine(to: botL)
        leftTop.closeSubpath()
        c.fill(leftTop, with: .color(Self.darkC))

        // Right-dark facet (top → top-right → bottom-right → center)
        var rightFacet = Path()
        rightFacet.move(to: top)
        rightFacet.addLine(to: topR)
        rightFacet.addLine(to: botR)
        rightFacet.addLine(to: center)
        rightFacet.closeSubpath()
        c.fill(rightFacet, with: .color(Self.midC))

        // Bottom facet (bottom-left → center → bottom-right → bottom)
        var bottomFacet = Path()
        bottomFacet.move(to: botL)
        bottomFacet.addLine(to: center)
        bottomFacet.addLine(to: botR)
        bottomFacet.addLine(to: bot)
        bottomFacet.closeSubpath()
        c.fill(bottomFacet, with: .color(Self.edgeC))

        // Diagonal highlight slash — the signature Cursor element
        // A bright triangle from top-right area cutting diagonally
        let hlAlpha = 0.7 + shimmer * 0.3
        var highlight = Path()
        highlight.move(to: v.pt(cx + 1, cy - ry + 0.5, dy: dy))
        highlight.addLine(to: v.pt(cx + rx - 0.5, cy - ry * 0.45 + 0.3, dy: dy))
        highlight.addLine(to: v.pt(cx + 0.5, cy + 0.5, dy: dy))
        highlight.closeSubpath()
        c.fill(highlight, with: .color(Self.lightC.opacity(hlAlpha)))

        // Edge outline — bright enough to be visible on dark notch background
        var outline = Path()
        outline.move(to: top)
        outline.addLine(to: topR)
        outline.addLine(to: botR)
        outline.addLine(to: bot)
        outline.addLine(to: botL)
        outline.addLine(to: topL)
        outline.closeSubpath()
        c.stroke(outline, with: .color(Self.lightC.opacity(0.35)), lineWidth: v.s * 0.5)
    }

    // ── Draw "eyes" — two dots on the dark facet, sized for visibility ──
    private func drawEyes(_ c: GraphicsContext, v: AgentMascotGrid, dy: CGFloat,
                          scale: CGFloat = 1.0, color: Color = Self.lightC) {
        let eyeH: CGFloat = 1.3 * scale
        let eyeY: CGFloat = 9.5 + (1.3 - eyeH) / 2
        c.fill(Path(v.r(4.2, eyeY, 1.3, max(0.3, eyeH), dy: dy)), with: .color(color))
        c.fill(Path(v.r(6.8, eyeY, 1.3, max(0.3, eyeH), dy: dy)), with: .color(color))
    }

    private func drawShadow(_ c: GraphicsContext, v: AgentMascotGrid, width: CGFloat = 8, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 15.5, width, 1)),
               with: .color(.black.opacity(opacity)))
    }

    private func drawLegs(_ c: GraphicsContext, v: AgentMascotGrid) {
        c.fill(Path(v.r(5.5, 14.5, 1, 1.5)), with: .color(Self.edgeC))
        c.fill(Path(v.r(8.5, 14.5, 1, 1.5)), with: .color(Self.edgeC))
    }

    // ━━━━━━ SLEEP ━━━━━━
    private var sleepScene: some View {
        ZStack {
            AgentMascotTimeline(interval: 0.12) { t in
                sleepCanvas(t: t)
            }
            AgentMascotTimeline(interval: 0.12) { t in
                AgentMascotFloatingZs(t: t, size: size, xBase: 0.15, xStep: 0.08, wave: false)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        // Two incommensurate drift periods — the float never quite repeats,
        // and every mascot has its own rhythm so multi-session rows don't sync.
        let float = sin(t * 2 * .pi / 4.32) * 0.51 + sin(t * 2 * .pi / 6.29) * 0.27

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 15, svgH: 12, svgY0: 4)
            drawShadow(c, v: v, width: 7 + abs(float) * 0.2, opacity: 0.2)
            drawLegs(c, v: v)
            drawGem(c, v: v, dy: float)
            drawEyes(c, v: v, dy: float, scale: 0.3, color: Self.lightC.opacity(0.4))
        }
    }

    // ━━━━━━ WORK ━━━━━━
    private var workScene: some View {
        AgentMascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Work pause: every ~11s the bounce settles for a beat —
        // reading output, not hammering keys nonstop.
        let workPause = AgentMascotMotion.quirk(t, cycle: 11.0, duration: 1.2, seed: 0xe2e)
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let shimmer = sin(t * 2 * .pi / 1.5) * 0.5 + 0.5  // pulsing highlight
        let blink = max(0.1, AgentMascotMotion.blink(t, seed: 0xe2f))
        let keyPhase = Int(t / 0.1) % 6

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 16, svgH: 14, svgY0: 3)

            let shadowW: CGFloat = 8 - abs(bounce) * 0.3
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

            drawLegs(c, v: v)

            // Keyboard
            c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    let kx = 0.5 + CGFloat(col) * 2.4
                    c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            let fCol = keyPhase % 6
            let fRow = keyPhase / 3
            c.fill(Path(v.r(0.5 + CGFloat(fCol) * 2.4, 13.5 + CGFloat(fRow) * 1.2, 1.8, 0.7)),
                   with: .color(Self.kbHi.opacity(0.9)))

            drawGem(c, v: v, dy: bounce, shimmer: shimmer)
            drawEyes(c, v: v, dy: bounce, scale: blink)
        }
    }

    // ━━━━━━ ALERT ━━━━━━
    private var alertScene: some View {
        AgentMascotTimeline(interval: 0.03) { t in
            alertCanvas(t: t)
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = AgentMascotRenderer.lerp(AgentMascotAlert.decayingJump, at: pct)

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // Highlight flashes intensely during alert
        let shimmer: CGFloat = (pct > 0.03 && pct < 0.55) ? sin(pct * 30) * 0.5 + 0.5 : 0

        let bangOp = AgentMascotRenderer.lerp(AgentMascotAlert.bangOpacity, at: pct)
        let bangScale = AgentMascotRenderer.lerp(AgentMascotAlert.bangScale, at: pct)

        return Canvas { c, sz in
            let v = AgentMascotGrid(sz, svgW: 16, svgH: 14, svgY0: 3)

            let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04))))

            drawLegs(c, v: v)

            c.translateBy(x: shakeX * v.s, y: 0)
            drawGem(c, v: v, dy: jumpY, shimmer: shimmer)
            let eyeColor: Color = (pct > 0.03 && pct < 0.55 && sin(pct * 25) > 0)
                ? Self.alertC : Self.lightC
            drawEyes(c, v: v, dy: jumpY, scale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0,
                     color: eyeColor)
            c.translateBy(x: -shakeX * v.s, y: 0)

            if bangOp > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 4 + jumpY * 0.15
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }
}

// MARK: - Grok — GrokView.swift, verbatim geometry

/// Grok's February 2025 black-and-white geometric mark.
///
/// The two paths below preserve the published SVG geometry exactly. Keep the
/// mark static and unmodified; session state is communicated by the surrounding
/// UI rather than by transforming the trademark.
/// Source: https://upload.wikimedia.org/wikipedia/commons/f/f7/Grok-feb-2025-logo.svg
struct AgentGrokView: View {
    let status: AgentStatus
    var size: CGFloat = 27

    var body: some View {
        AgentGrokMark()
            .fill(Color.white)
            .frame(width: size * 0.68, height: size * 0.68)
            .frame(width: size, height: size)
            .accessibilityLabel("Grok")
    }
}

/// Exact geometry from the two `#mark` paths in Grok's February 2025 SVG.
/// Source view-box bounds for the mark are x: 0...33.6964, y: 0.5...32.5.
private struct AgentGrokMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sourceWidth: CGFloat = 33.6964
        let sourceHeight: CGFloat = 32.0
        let sourceMinY: CGFloat = 0.5
        let scale = min(rect.width / sourceWidth, rect.height / sourceHeight)
        let offsetX = rect.midX - sourceWidth * scale / 2
        let offsetY = rect.midY - sourceHeight * scale / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: offsetX + x * scale,
                y: offsetY + (y - sourceMinY) * scale
            )
        }

        var path = Path()

        path.move(to: point(13.2371, 21.0407))
        path.addLine(to: point(24.3186, 12.8506))
        path.addCurve(
            to: point(25.8973, 13.2294),
            control1: point(24.8619, 12.4491),
            control2: point(25.6384, 12.6057)
        )
        path.addCurve(
            to: point(23.9403, 23.1851),
            control1: point(27.2597, 16.5185),
            control2: point(26.651, 20.4712)
        )
        path.addCurve(
            to: point(14.0108, 25.1386),
            control1: point(21.2297, 25.8989),
            control2: point(17.4581, 26.4941)
        )
        path.addLine(to: point(10.2449, 26.8843))
        path.addCurve(
            to: point(26.304, 25.5601),
            control1: point(15.6463, 30.5806),
            control2: point(22.2053, 29.6665)
        )
        path.addCurve(
            to: point(29.6205, 13.8673),
            control1: point(29.5551, 22.3051),
            control2: point(30.562, 17.8683)
        )
        path.addLine(to: point(29.629, 13.8758))
        path.addCurve(
            to: point(33.449, 0.844576),
            control1: point(28.2637, 7.99809),
            control2: point(29.9647, 5.64871)
        )
        path.addCurve(
            to: point(33.6964, 0.5),
            control1: point(33.5314, 0.730667),
            control2: point(33.6139, 0.616757)
        )
        path.addLine(to: point(29.1113, 5.09055))
        path.addLine(to: point(29.1113, 5.07631))
        path.addLine(to: point(13.2343, 21.0436))
        path.closeSubpath()

        path.move(to: point(10.9503, 23.0313))
        path.addCurve(
            to: point(11.0498, 10.2763),
            control1: point(7.07343, 19.3235),
            control2: point(7.74185, 13.5853)
        )
        path.addCurve(
            to: point(21.0021, 8.2971),
            control1: point(13.4959, 7.82722),
            control2: point(17.5036, 6.82767)
        )
        path.addLine(to: point(24.7595, 6.55998))
        path.addCurve(
            to: point(22.2195, 5.17313),
            control1: point(24.0826, 6.07017),
            control2: point(23.215, 5.54334)
        )
        path.addCurve(
            to: point(8.67479, 7.90126),
            control1: point(17.7198, 3.31926),
            control2: point(12.3326, 4.24192)
        )
        path.addCurve(
            to: point(5.94992, 21.4622),
            control1: point(5.15635, 11.4239),
            control2: point(4.0499, 16.8403)
        )
        path.addCurve(
            to: point(2.69884, 29.826),
            control1: point(7.36924, 24.9165),
            control2: point(5.04257, 27.3598)
        )
        path.addCurve(
            to: point(0.36364, 32.5),
            control1: point(1.86829, 30.7002),
            control2: point(1.0349, 31.5745)
        )
        path.addLine(to: point(10.9474, 23.0341))
        path.closeSubpath()

        return path
    }
}
