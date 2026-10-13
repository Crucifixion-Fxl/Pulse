import SwiftUI

// MARK: - Palette
// 1:1 with wxtsky/CodeIsland's NotchCardPalette / SessionCardStatus colors
// (MIT — see ThirdParty/CODEISLAND-LICENSE.txt).

/// Status colors and card chrome for the agents panel.
enum AgentsPanelPalette {
  // Session status
  static let needsYou = Color(red: 1.0, green: 0.6, blue: 0.2)  // #FF9933
  static let working = Color(red: 0.3, green: 0.85, blue: 0.4)  // #4DD966
  static let done = Color.white.opacity(0.62)
  static let idle = Color.white.opacity(0.55)
  static let stopped = Color(red: 1.0, green: 0.55, blue: 0.4)  // #FF8C66
  static let error = Color(red: 1.0, green: 0.38, blue: 0.42)  // #FF616B

  // Card buttons
  static let allowFill = Color(red: 0.16, green: 0.50, blue: 0.24)  // #29803D
  static let allowFillHover = Color(red: 0.17, green: 0.53, blue: 0.26)  // #2B8742
  static let deny = Color(red: 0.92, green: 0.38, blue: 0.38)  // #EB6161
  static let link = Color(red: 0.45, green: 0.72, blue: 1.0)  // #73B8FF
  static let permission = Color(red: 1.0, green: 0.6, blue: 0.2)  // #FF9933
  static let questionAccent = Color(red: 0.4, green: 0.7, blue: 1.0)  // #66B3FF

  // Tool detail glyphs
  static let bashPrompt = Color(red: 0.3, green: 0.85, blue: 0.4)  // #4DD966
  static let editOld = Color(red: 1.0, green: 0.4, blue: 0.4)  // #FF6666
  static let editNew = Color(red: 0.3, green: 0.85, blue: 0.4)  // #4DD966
  static let grepPattern = Color(red: 0.9, green: 0.6, blue: 0.9)  // #E699E6
  static let globPattern = Color(red: 0.6, green: 0.8, blue: 1.0)  // #99CCFF
  static let detailKey = Color(red: 0.6, green: 0.7, blue: 0.9)  // #99B3E6

  // Tags
  static let remoteTag = Color(red: 0.45, green: 0.72, blue: 1.0)  // #73B8FF
  static let subagentTag = Color(red: 0.65, green: 0.55, blue: 0.95)  // #A68CF2
  static let yoloTag = Color(red: 1.0, green: 0.35, blue: 0.35)  // #FF5959

  // Collapsed-bar bell
  static let bell = Color(red: 1.0, green: 0.7, blue: 0.28)  // #FFB347

  // Tool-status colors (compact bar / live tool chip).
  static func toolStatus(_ tool: String) -> Color {
    let t = tool.lowercased()
    if t == "bash" || t.contains("running command") {
      return Color(red: 0.4, green: 1.0, blue: 0.5)  // #66FF80
    } else if t == "edit" || t == "write" || t.contains("editing") {
      return Color(red: 0.5, green: 0.7, blue: 1.0)  // #80B3FF
    } else if t == "read" || t.contains("reading") {
      return Color(red: 0.9, green: 0.8, blue: 0.4)  // #E6CC66
    } else if t == "grep" || t == "glob" || t.contains("searching") || t.contains("mcp") {
      return Color(red: 0.8, green: 0.6, blue: 1.0)  // #CC99FF
    } else if t == "agent" || t.contains("delegating") {
      return Color(red: 1.0, green: 0.6, blue: 0.4)  // #FF9966
    } else if t.contains("compacting") {
      return Color(red: 0.4, green: 0.85, blue: 0.9)  // #66D9E6
    } else {
      return .white.opacity(0.7)
    }
  }
}

// MARK: - Typography
// CodeIsland's NotchCardTypography scale, anchored at contentFontSize 11.

struct AgentTypography {
  let base: CGFloat

  init(contentFontSize: CGFloat = 11) { base = contentFontSize }

  var title: CGFloat { base + 1 }
  var body: CGFloat { base }
  var secondary: CGFloat { base - 1 }
  var caption: CGFloat { max(9, base - 2) }
  var badge: CGFloat { max(8.5, base - 2) }
  var button: CGFloat { min(base + 1, 15) }
  var link: CGFloat { base - 0.5 }
  var icon: CGFloat { base + 2 }
}

// MARK: - Typing indicator
// Monospaced text with a sweeping gradient band masked to the glyphs
// (base opacity 0.35, band peak 0.5, easeInOut 2.5s repeat).

struct TypingIndicatorText: View {
  let text: String
  var bright = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      plain
    } else {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
        let phase =
          (timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.5))
          / 2.5
        sweep(phase: bright ? -80 + 180 * phase : -60 + 140 * phase)
      }
    }
  }

  private var plain: some View {
    Text(text)
      .font(.system(size: 11, weight: .medium, design: .monospaced))
      .foregroundStyle(.white.opacity(bright ? 0.6 : 0.35))
  }

  private func sweep(phase: Double) -> some View {
    let bandWidth: CGFloat = bright ? 80 : 60
    let baseOpacity = bright ? 0.6 : 0.35
    let peak = bright ? 0.8 : 0.5
    return plain
      .foregroundStyle(.white)
      .mask {
        GeometryReader { proxy in
          LinearGradient(
            stops: [
              .init(color: .white.opacity(baseOpacity), location: 0),
              .init(color: .white.opacity(baseOpacity), location: 0.999),
            ],
            startPoint: .leading, endPoint: .trailing
          )
          .overlay(
            LinearGradient(
              stops: [
                .init(color: .white.opacity(peak), location: 0.35),
                .init(color: .white.opacity(baseOpacity), location: 1),
              ],
              startPoint: .leading, endPoint: .trailing
            )
            .frame(width: bandWidth)
            .offset(x: phase - bandWidth / 2)
            .blendMode(.plusLighter)
          )
          .frame(width: proxy.size.width + bandWidth, height: proxy.size.height)
          .offset(x: -bandWidth / 2)
        }
      }
  }
}

// MARK: - Morphing text
// On change: blur in (easeOut 0.1) with a 15% opacity dip, swap after 60ms,
// un-blur (easeOut 0.15) — CodeIsland's MorphText.

struct MorphText: View {
  let text: String
  var font: Font = .system(size: 11, design: .monospaced)
  var color: Color = .white.opacity(0.75)

  @State private var displayed: String
  @State private var blurRadius: CGFloat = 0
  @State private var dimmed = false

  init(_ text: String, font: Font = .system(size: 11, design: .monospaced), color: Color = .white.opacity(0.75)) {
    self.text = text
    self.font = font
    self.color = color
    _displayed = State(initialValue: text)
  }

  var body: some View {
    Text(displayed)
      .font(font)
      .foregroundStyle(color)
      .opacity(dimmed ? 0.85 : 1)
      .blur(radius: blurRadius)
      .onChange(of: text) { _, newValue in
        guard newValue != displayed else { return }
        withAnimation(.easeOut(duration: 0.1)) {
          blurRadius = 1
          dimmed = true
        }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(60))
          displayed = newValue
          withAnimation(.easeOut(duration: 0.15)) {
            blurRadius = 0
            dimmed = false
          }
        }
      }
  }
}

// MARK: - Status chip
// Mono bold ~10pt on color.15, radius 4, h5 v2.

struct AgentStatusChip: View {
  let label: String
  let color: Color
  let type: AgentTypography

  var body: some View {
    Text(label)
      .font(.system(size: min(10, max(9, type.base - 2)), weight: .bold, design: .monospaced))
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
  }
}
