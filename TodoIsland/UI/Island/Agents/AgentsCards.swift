import SwiftUI

// MARK: - Card buttons (NotchCardPalette/Button, 1:1)

enum AgentCardButtonStyle {
  case primary  // white text on #29803D fill
  case destructive  // #EB6161 text, transparent → .14 fill, deny stroke
  case secondary  // white 85% on white 3% → 10%, stroke 28% → 40%
  case quiet  // text-only white 60% → 85%
}

struct AgentCardButton: View {
  let title: String
  let style: AgentCardButtonStyle
  let action: () -> Void

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(foreground)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
        .frame(minHeight: 26)
        .background(background)
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(stroke, lineWidth: stroke == .clear ? 0 : 0.8))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { inside in
      guard !reduceMotion else { return }
      withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
    }
  }

  private var foreground: Color {
    switch style {
    case .primary: .white
    case .destructive: AgentsPanelPalette.deny
    case .secondary: .white.opacity(hovering ? 0.95 : 0.85)
    case .quiet: .white.opacity(hovering ? 0.85 : 0.6)
    }
  }

  private var horizontalPadding: CGFloat {
    switch style {
    case .primary: 14
    case .destructive, .secondary: 11
    case .quiet: 8
    }
  }

  private var background: some ShapeStyle {
    switch style {
    case .primary:
      AnyShapeStyle(hovering ? AgentsPanelPalette.allowFillHover : AgentsPanelPalette.allowFill)
    case .destructive:
      AnyShapeStyle(Color.white.opacity(hovering ? 0.14 : 0))
    case .secondary:
      AnyShapeStyle(Color.white.opacity(hovering ? 0.10 : 0.03))
    case .quiet:
      AnyShapeStyle(Color.clear)
    }
  }

  private var stroke: Color {
    switch style {
    case .primary: .clear
    case .destructive: AgentsPanelPalette.deny.opacity(hovering ? 0.9 : 0.7)
    case .secondary: .white.opacity(hovering ? 0.40 : 0.28)
    case .quiet: .clear
    }
  }
}

/// Underlined quiet link (#73B8FF), minHeight 26.
struct AgentCardTextLink: View {
  let title: String
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(AgentsPanelPalette.link.opacity(hovering ? 1.0 : 0.9))
        .underline()
        .frame(minHeight: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { inside in hovering = inside }
  }
}

// MARK: - Approval card (ApprovalBar, 1:1)

struct ApprovalCard: View {
  let request: AgentSessionStore.PermissionRequest
  let type: AgentTypography

  @EnvironmentObject private var store: AgentSessionStore

  private var session: AgentSessionSnapshot? { store.sessions[request.sessionId] }
  private var toolName: String { request.event.toolName ?? "" }
  private var queuePosition: String {
    let index = store.permissionQueue.firstIndex(where: { $0.id == request.id }) ?? 0
    return String(format: L10n.text("agents.approval.queue"), index + 1, store.permissionQueue.count)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      contextRow
      titleRow
      AgentApprovalToolDetail(toolName: toolName, input: request.event.toolInput, type: type)
        .frame(minHeight: type.body * 1.25 * 3 + 16, alignment: .top)
      actionRow
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(AgentsPanelPalette.permission.opacity(0.35), lineWidth: 1))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("agents.approval.tag"))
  }

  private var contextRow: some View {
    HStack(spacing: 6) {
      AgentMascotView(source: session?.source ?? "claude", status: .waitingApproval, size: type.icon)
      Text(session?.displayTitle(sessionId: request.sessionId) ?? L10n.text("agents.task.pending"))
        .font(.system(size: type.body, weight: .bold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
      Text(session?.projectName ?? "")
        .font(.system(size: type.secondary, design: .monospaced))
        .foregroundStyle(.white.opacity(0.5))
        .lineLimit(1)
      Spacer(minLength: 2)
      Text(queuePosition)
        .font(.system(size: type.badge, weight: .bold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.62))
    }
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text("agents.approval.tag")
        .font(.system(size: type.badge, weight: .bold, design: .monospaced))
        .foregroundStyle(AgentsPanelPalette.permission)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
          AgentsPanelPalette.permission.opacity(0.14),
          in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      Text(approvalTitle)
        .font(.system(size: type.title, weight: .semibold))
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(2)
    }
  }

  private var approvalTitle: String {
    let key: String
    switch toolName.lowercased() {
    case "bash": key = "agents.approval.title.bash"
    case "edit": key = "agents.approval.title.edit"
    case "write": key = "agents.approval.title.write"
    case "read": key = "agents.approval.title.read"
    case "grep": key = "agents.approval.title.grep"
    case "glob": key = "agents.approval.title.glob"
    case let name where name.hasPrefix("mcp__"): key = "agents.approval.title.mcp"
    default: key = "agents.approval.title.default"
    }
    if key == "agents.approval.title.mcp" {
      return String(format: L10n.text(key), toolName)
    }
    return L10n.text(key)
  }

  private var actionRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) { actions }
      VStack(alignment: .leading, spacing: 6) { actions }
    }
  }

  @ViewBuilder
  private var actions: some View {
    AgentCardTextLink(
      title: String(format: L10n.text("agents.approval.always"), alwaysToolLabel)
    ) {
      store.approvePermission(request.id, always: true)
    }
    Spacer(minLength: 8)
    AgentCardButton(title: L10n.text("agents.approval.hide"), style: .quiet) {
      store.dismissPermission(request.id)
    }
    AgentCardButton(title: L10n.text("agents.approval.deny"), style: .destructive) {
      store.denyPermission(request.id)
    }
    AgentCardButton(title: L10n.text("agents.approval.allow"), style: .primary) {
      store.approvePermission(request.id)
    }
  }

  private var alwaysToolLabel: String {
    toolName.hasPrefix("mcp__") ? "MCP" : toolName
  }
}

// MARK: - Tool detail (ApprovalToolDetailView, 1:1)

struct AgentApprovalToolDetail: View {
  let toolName: String
  let input: [String: Any]?
  let type: AgentTypography

  var body: some View {
    ScrollView(showsIndicators: false) {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
  }

  private var content: some View {
    Group {
      switch toolName.lowercased() {
      case "bash": bashDetail
      case "edit": editDetail
      case "write": writeDetail
      case "read": readDetail
      case "grep": grepDetail
      case "glob": globDetail
      default: defaultDetail
      }
    }
  }

  private var bashDetail: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top, spacing: 6) {
        Text("$")
          .font(.system(size: type.body, weight: .bold, design: .monospaced))
          .foregroundStyle(AgentsPanelPalette.bashPrompt)
        Text(string(["command", "cmd"]) ?? "")
          .font(.system(size: type.body, design: .monospaced))
          .foregroundStyle(.white.opacity(0.85))
          .textSelection(.enabled)
      }
      if let description = string(["description"]), !description.isEmpty {
        Text(description)
          .font(.system(size: type.secondary))
          .foregroundStyle(.white.opacity(0.55))
      }
    }
  }

  private var editDetail: some View {
    VStack(alignment: .leading, spacing: 3) {
      if let file = string(["file_path", "path", "filename"]) {
        Text(file)
          .font(.system(size: type.caption, design: .monospaced))
          .foregroundStyle(.white.opacity(0.5))
          .lineLimit(1)
          .truncationMode(.head)
      }
      diffLine(symbol: "−", text: string(["old_string"]) ?? "", color: AgentsPanelPalette.editOld, opacity: 0.85)
      diffLine(symbol: "+", text: string(["new_string"]) ?? "", color: AgentsPanelPalette.editNew, opacity: 0.7)
    }
  }

  private var writeDetail: some View {
    VStack(alignment: .leading, spacing: 3) {
      if let file = string(["file_path", "path", "filename"]) {
        Text(file)
          .font(.system(size: type.caption, design: .monospaced))
          .foregroundStyle(.white.opacity(0.5))
          .lineLimit(1)
          .truncationMode(.head)
      }
      Text(String((string(["content"]) ?? "").prefix(200)))
        .font(.system(size: type.secondary, design: .monospaced))
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(4)
    }
  }

  private var readDetail: some View {
    HStack(spacing: 6) {
      Text(string(["file_path", "path", "filename"]) ?? "")
        .font(.system(size: type.secondary, design: .monospaced))
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
        .truncationMode(.middle)
      if let offset = string(["offset"]), let limit = string(["limit"]) {
        Text("lines \(offset)–\((Int(offset) ?? 0) + (Int(limit) ?? 0))")
          .font(.system(size: type.caption, design: .monospaced))
          .foregroundStyle(.white.opacity(0.45))
      }
    }
  }

  private var grepDetail: some View {
    HStack(spacing: 6) {
      Text("/")
        .font(.system(size: type.body, weight: .bold, design: .monospaced))
        .foregroundStyle(AgentsPanelPalette.grepPattern)
      Text(string(["pattern"]) ?? "")
        .font(.system(size: type.body, design: .monospaced))
        .foregroundStyle(AgentsPanelPalette.grepPattern)
      if let path = string(["path"]) {
        Text(path)
          .font(.system(size: type.caption, design: .monospaced))
          .foregroundStyle(.white.opacity(0.45))
          .lineLimit(1)
      }
    }
  }

  private var globDetail: some View {
    HStack(spacing: 6) {
      Text(string(["pattern"]) ?? "")
        .font(.system(size: type.body, design: .monospaced))
        .foregroundStyle(AgentsPanelPalette.globPattern)
    }
  }

  private var defaultDetail: some View {
    let keys = (input ?? [:]).keys.sorted().prefix(4)
    return VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(keys), id: \.self) { key in
        HStack(alignment: .top, spacing: 6) {
          Text(key)
            .font(.system(size: type.caption, weight: .semibold, design: .monospaced))
            .foregroundStyle(AgentsPanelPalette.detailKey)
          Text(string([key]) ?? "")
            .font(.system(size: type.secondary, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
        }
      }
    }
  }

  private func diffLine(symbol: String, text: String, color: Color, opacity: Double) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Text(symbol)
        .font(.system(size: type.body, weight: .bold, design: .monospaced))
        .foregroundStyle(color)
      Text(String(text.prefix(120)))
        .font(.system(size: type.secondary, design: .monospaced))
        .foregroundStyle(color)
        .lineLimit(2)
    }
    .opacity(opacity)
  }

  private func string(_ keys: [String]) -> String? {
    for key in keys {
      if let value = input?[key] {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
      }
    }
    return nil
  }
}

// MARK: - Question card (QuestionBar, 1:1)

struct QuestionCard: View {
  let request: AgentSessionStore.QuestionRequest
  let type: AgentTypography

  @EnvironmentObject private var store: AgentSessionStore
  @State private var typedAnswer = ""
  @State private var selectedOptions: [String: Set<String>] = [:]
  @State private var wizardIndex = 0

  private var items: [AgentSessionStore.AskQuestionItem] { request.questions }
  private var isWizard: Bool { items.count > 1 }
  private var currentItem: AgentSessionStore.AskQuestionItem? {
    items.indices.contains(wizardIndex) ? items[wizardIndex] : items.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      questionBody
      if isWizard {
        wizardControls
      } else {
        singleControls
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(AgentsPanelPalette.questionAccent.opacity(0.35), lineWidth: 1))
  }

  private var header: some View {
    HStack(spacing: 7) {
      Text("?")
        .font(.system(size: type.title, weight: .bold, design: .monospaced))
        .foregroundStyle(AgentsPanelPalette.questionAccent)
      Text((request.question ?? currentItem?.payload).map(\.question) ?? "")
        .font(.system(size: type.title, weight: .medium))
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(4)
      Spacer(minLength: 2)
      if isWizard {
        Text("\(wizardIndex + 1)/\(items.count)")
          .font(.system(size: type.badge, weight: .bold, design: .monospaced))
          .foregroundStyle(.white.opacity(0.62))
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
      }
    }
  }

  @ViewBuilder
  private var questionBody: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let item = currentItem {
        ForEach(Array((item.payload.options ?? []).enumerated()), id: \.offset) { _, option in
          optionRow(item: item, option: option)
        }
        TextField(L10n.text("agents.question.other"), text: $typedAnswer)
          .font(.system(size: type.link, design: .monospaced))
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.05))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
      }
    }
    .frame(minHeight: 72, alignment: .top)
  }

  private func optionRow(item: AgentSessionStore.AskQuestionItem, option: String) -> some View {
    let selected = selectedOptions[item.payload.question]?.contains(option) ?? false
    return Button {
      withAnimation(.easeOut(duration: 0.12)) {
        var set = selectedOptions[item.payload.question] ?? []
        if item.multiSelect {
          if selected { set.remove(option) } else { set.insert(option) }
        } else {
          set = [option]
        }
        selectedOptions[item.payload.question] = set
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: item.multiSelect ? (selected ? "checkmark.square.fill" : "square") : (selected ? "record.circle" : "circle"))
          .font(.system(size: type.secondary))
          .foregroundStyle(selected ? AgentsPanelPalette.questionAccent : .white.opacity(0.4))
        Text(option)
          .font(.system(size: type.body, design: .monospaced))
          .foregroundStyle(.white.opacity(selected ? 0.9 : 0.7))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(Color.white.opacity(selected ? 0.08 : 0.02))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var wizardControls: some View {
    HStack {
      if wizardIndex > 0 {
        AgentCardButton(title: L10n.text("agents.question.back"), style: .quiet) {
          wizardIndex -= 1
        }
      }
      Spacer(minLength: 8)
      AgentCardButton(title: L10n.text("agents.question.skip"), style: .secondary) {
        store.skipQuestion(request.id)
      }
      AgentCardButton(title: L10n.text("agents.question.confirm"), style: .primary) {
        confirmWizard()
      }
    }
  }

  private var singleControls: some View {
    HStack {
      Spacer(minLength: 8)
      AgentCardButton(title: L10n.text("agents.question.skip"), style: .secondary) {
        store.skipQuestion(request.id)
      }
      AgentCardButton(title: L10n.text("agents.question.confirm"), style: .primary) {
        let answer = typedAnswer.isEmpty
          ? (selectedOptions.values.first?.sorted().first ?? "")
          : typedAnswer
        store.answerQuestion(request.id, answer: answer)
      }
    }
  }

  private func confirmWizard() {
    let answers = items.map { item in
      AgentSessionStore.QuestionAnswer(
        question: item.payload.question,
        answer: typedAnswer,
        selectedOptions: Array(selectedOptions[item.payload.question] ?? []))
    }
    store.answerQuestionMulti(request.id, answers: answers)
  }
}
