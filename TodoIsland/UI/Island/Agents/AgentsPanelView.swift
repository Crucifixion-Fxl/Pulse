import AppKit
import SwiftUI

/// The agents sidebar pane, 1:1 with CodeIsland's expanded surfaces: the
/// queue-head approval/question card on top, the session list below —
/// status rails, chips, tool detail glyphs, and the exact button palette.
struct AgentsPanelView: View {
  @EnvironmentObject private var store: AgentSessionStore

  enum Metrics {
    /// Matches the other feature panes so the island height stays uniform.
    static let contentHeight: CGFloat = 324
  }

  private var type = AgentTypography()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let request = store.permissionQueue.first {
        ApprovalCard(request: request, type: type)
          .transition(.blurFadeCard)
      } else if let question = store.questionQueue.first {
        QuestionCard(request: question, type: type)
          .transition(.blurFadeCard)
      }

      if orderedSessions.isEmpty && store.permissionQueue.isEmpty && store.questionQueue.isEmpty {
        emptyState
      } else {
        sessionList
      }
    }
    .padding(.top, 2)
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.permissionQueue.map(\.id))
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.questionQueue.map(\.id))
  }

  // MARK: Session list

  private var orderedSessions: [(id: String, session: AgentSessionSnapshot)] {
    store.sessions
      .filter { AgentSessionSnapshot.normalizedSupportedSource($0.value.source) != nil }
      .map { (id: $0.key, session: $0.value) }
      .sorted(by: { lhs, rhs in
        let lt = cardStatus(lhs.session).tier
        let rt = cardStatus(rhs.session).tier
        if lt != rt { return lt < rt }
        if lt <= 1 {
          return lhs.session.startTime > rhs.session.startTime
        }
        return lhs.session.lastActivity > rhs.session.lastActivity
      })
  }

  private var sessionList: some View {
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(orderedSessions, id: \.id) { entry in
          SessionCard(sessionID: entry.id, session: entry.session, type: type)
        }
      }
      .padding(.vertical, 2)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "person.2")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.white.opacity(0.35))
      Text("agents.empty.title")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
      Text("agents.empty.detail")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(ReUITheme.muted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Card status (SessionCardStatus, 1:1)

struct AgentCardStatus: Equatable {
  let label: String
  let color: Color
  let tier: Int
}

func cardStatus(_ session: AgentSessionSnapshot) -> AgentCardStatus {
  switch session.status {
  case .waitingApproval, .waitingQuestion:
    return AgentCardStatus(label: L10n.text("agents.status.needs-you"), color: AgentsPanelPalette.needsYou, tier: 0)
  case .running:
    return AgentCardStatus(label: L10n.text("agents.status.working"), color: AgentsPanelPalette.working, tier: 1)
  case .processing:
    return AgentCardStatus(label: L10n.text("agents.status.thinking"), color: AgentsPanelPalette.working, tier: 1)
  case .idle:
    if session.lastTurnFailed {
      return AgentCardStatus(label: L10n.text("agents.status.error"), color: AgentsPanelPalette.error, tier: 2)
    }
    if session.interrupted {
      return AgentCardStatus(label: L10n.text("agents.status.stopped"), color: AgentsPanelPalette.stopped, tier: 2)
    }
    if !session.recentMessages.isEmpty || session.lastAssistantMessage != nil {
      return AgentCardStatus(label: L10n.text("agents.status.done"), color: AgentsPanelPalette.done, tier: 2)
    }
    return AgentCardStatus(label: L10n.text("agents.status.idle"), color: AgentsPanelPalette.idle, tier: 2)
  }
}

// MARK: - Session card

private struct SessionCard: View {
  let sessionID: String
  let session: AgentSessionSnapshot
  let type: AgentTypography

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(spacing: 2) {
        AgentMascotView(source: session.source, status: session.status, size: 32)
        if !session.subagents.isEmpty {
          Text("+\(session.subagents.count)")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(AgentsPanelPalette.subagentTag)
        }
      }
      .frame(width: 36)

      VStack(alignment: .leading, spacing: 5) {
        headerRow
        if session.status == .running || session.status == .processing {
          liveRow
        } else {
          chatRows
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .padding(.horizontal, 6)
    .background(cardBackground)
    .contextMenu { copySessionIDButton }
  }

  private var status: AgentCardStatus { cardStatus(session) }

  private var cardBackground: some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(0.05))
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(railColor)
        .frame(width: 3)
        .padding(.vertical, 6)
    }
  }

  private var railColor: Color {
    switch status.tier {
    case 0, 1: status.color
    case 2: session.lastTurnFailed || session.interrupted ? status.color : .white.opacity(0.28)
    default: status.color
    }
  }

  private var headerRow: some View {
    HStack(spacing: 6) {
      AgentStatusChip(label: status.label, color: status.color, type: type)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(3)

      if let project = session.projectName {
        AgentProjectCapsule(name: project, type: type)
      }
      Text(session.displayTitle(sessionId: sessionID))
        .font(.system(size: type.body + 2, weight: .semibold))
        .foregroundStyle(.white.opacity(0.95))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(session.displayTitle(sessionId: sessionID))

      if let model = session.model, !model.isEmpty {
        Text(model)
          .font(.system(size: type.caption, design: .monospaced))
          .foregroundStyle(.white.opacity(0.45))
          .lineLimit(1)
          .frame(maxWidth: 110, alignment: .trailing)
          .layoutPriority(2)
          .help(model)
      }
      AgentActivityTime(date: session.lastActivity)
        .font(.system(size: type.caption))
        .foregroundStyle(.white.opacity(0.55))
        .fixedSize()

      Menu { copySessionIDButton } label: {
        Image(systemName: "ellipsis")
          .foregroundStyle(.white.opacity(0.5))
          .frame(width: 18, height: 18)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel(Text("agents.session.actions"))
    }
  }

  private var copySessionIDButton: some View {
    Button {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(session.displaySessionId(sessionId: sessionID), forType: .string)
    } label: {
      Label("agents.session.copy-id", systemImage: "doc.on.doc")
    }
  }

  @ViewBuilder
  private var chatRows: some View {
    let messages = session.recentMessages.suffix(1)
    if !messages.isEmpty {
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
          HStack(alignment: .top, spacing: 4) {
            Text(message.isUser ? "›" : "●")
              .font(.system(size: type.body, weight: .bold, design: .monospaced))
              .foregroundStyle(
                message.isUser ? .white.opacity(0.5) : AgentsPanelPalette.editNew)
              .scaleEffect(message.isUser ? 1 : 0.72, anchor: .center)
            Text(message.text)
              .font(.system(size: type.secondary, design: .monospaced))
              .foregroundStyle(.white.opacity(message.isUser ? 0.62 : 0.72))
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var liveRow: some View {
    switch session.status {
    case .running:
      if let tool = session.currentTool {
        HStack(spacing: 5) {
          AgentToolChip(tool: tool, type: type)
          if let description = session.toolDescription, !description.isEmpty {
            MorphText(description)
              .font(.system(size: type.body, design: .monospaced))
              .foregroundStyle(.white.opacity(0.75))
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
      }
    case .processing:
      TypingIndicatorText(text: L10n.text("agents.thinking"))
    default:
      EmptyView()
    }
  }
}

// MARK: - Live tool chip

struct AgentToolChip: View {
  let tool: String
  let type: AgentTypography

  var body: some View {
    HStack(spacing: 3) {
      Text("▸")
        .font(.system(size: type.body, weight: .bold, design: .monospaced))
      Text(tool)
        .font(.system(size: max(9, type.body - 1), weight: .bold, design: .monospaced))
    }
    .foregroundStyle(AgentsPanelPalette.toolStatus(tool))
    .padding(.horizontal, 4)
    .padding(.vertical, 1)
    .background(
      AgentsPanelPalette.toolStatus(tool).opacity(0.12),
      in: RoundedRectangle(cornerRadius: 3, style: .continuous))
  }
}

// MARK: - Monogram (mascot placeholder until the pixel mascots land)

/// Deterministic letter tile for unknown/pending mascots — upstream's
/// hash-derived hue fallback: hue from name hash, sat 0.55, bri 0.72.
struct AgentMonogramView: View {
  let source: String
  let size: CGFloat

  var body: some View {
    let hue = Double(abs(source.hashValue % 360)) / 360.0
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        .fill(Color(hue: hue, saturation: 0.55, brightness: 0.72))
      Text(String(source.prefix(1)).uppercased())
        .font(.system(size: size * 0.45, weight: .bold))
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
    .accessibilityLabel(Text(source))
  }
}

// MARK: - Helpers

/// Redraw only the small timestamp, and pause while the retained pane is hidden.
private struct AgentActivityTime: View {
  let date: Date
  @Environment(\.agentPanelActive) private var panelActive

  var body: some View {
    TimelineView(.animation(minimumInterval: 1, paused: !panelActive)) { timeline in
      Text(agentActivityAge(date, from: timeline.date))
    }
    .help(Text("agents.activity.help"))
  }
}

func agentActivityAge(_ date: Date, from now: Date = Date()) -> String {
  let seconds = max(0, Int(now.timeIntervalSince(date)))
  if seconds < 10 { return L10n.text("agents.activity.now") }
  if seconds < 60 { return String(format: L10n.text("agents.activity.seconds"), seconds) }
  let minutes = seconds / 60
  if minutes < 60 { return String(format: L10n.text("agents.activity.minutes"), minutes) }
  let hours = minutes / 60
  if hours < 24 { return String(format: L10n.text("agents.activity.hours"), hours) }
  return String(format: L10n.text("agents.activity.days"), hours / 24)
}

extension AnyTransition {
  /// CodeIsland's blurFade: blur radius 5 + opacity (no compositingGroup —
  /// macOS 26 bug workaround upstream).
  static var blurFadeCard: AnyTransition {
    .modifier(
      active: BlurFadeModifier(blur: 5, opacity: 0),
      identity: BlurFadeModifier(blur: 0, opacity: 1))
  }
}

private struct BlurFadeModifier: ViewModifier {
  var blur: CGFloat
  var opacity: Double

  func body(content: Content) -> some View {
    content.blur(radius: blur).opacity(opacity)
  }
}
