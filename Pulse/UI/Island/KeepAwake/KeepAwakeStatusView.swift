import SwiftUI

/// Insomnia's eye / inline pills / countdown vocabulary, sized for the notch's
/// right wing. Weather contracts to its icon while the three pills are open.
struct KeepAwakeStatusView: View {
  @ObservedObject var store: KeepAwakeStore
  let isActive: Bool
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var editing = false
  @State private var visiblePills = false
  @State private var showsStatus = false
  @State private var days = ""
  @State private var hours = ""
  @State private var minutes = ""
  @FocusState private var focused: Int?

  private var running: Bool { store.phase == .active }
  private var totalMinutes: Int? {
    let texts = [days, hours, minutes]
    guard texts.allSatisfy({ $0.isEmpty || ($0.count <= 2 && $0.allSatisfy(\.isNumber)) }),
      let d = Int(days.isEmpty ? "0" : days), let h = Int(hours.isEmpty ? "0" : hours),
      let m = Int(minutes.isEmpty ? "0" : minutes), h <= 23, m <= 59 else { return nil }
    if texts.allSatisfy(\.isEmpty) { return 60 }
    let total = d * 1440 + h * 60 + m
    return (1...1440).contains(total) ? total : nil
  }

  var body: some View {
    HStack(spacing: editing ? 6 : 4) {
      Button {
        if store.phase == .idle { setEditing(!editing) }
        else { showsStatus.toggle() }
      } label: {
        AwakeEyeMarkView(isRunning: running || store.phase == .starting,
          reduceMotion: reduceMotion, size: 25)
          .frame(width: 26, height: 28).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(L10n.text("awake.title"))
      .accessibilityValue(L10n.text("awake.phase.\(store.phase)"))
      .help(L10n.text("awake.title"))
      if editing {
        durationPill("awake.days", value: $days, index: 0)
        durationPill("awake.hours", value: $hours, index: 1)
        durationPill("awake.minute-field", value: $minutes, index: 2)
        Button(action: start) {
          Image(systemName: "return").font(.system(size: 10, weight: .medium))
            .frame(width: 16, height: 24)
        }.buttonStyle(.plain).disabled(totalMinutes == nil)
          .accessibilityLabel(L10n.text("awake.start"))
      } else if running || store.phase == .stopping {
        Button { showsStatus.toggle() } label: {
          Text(store.countdown).font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: 48)
        }.buttonStyle(.plain)
        if running { AwakeHoldToEndButton(reduceMotion: reduceMotion) { store.stop() } }
      } else if store.phase.isBusy {
        ProgressView().controlSize(.mini).frame(width: 18)
      } else if store.phase == .recoveryRequired {
        Button { showsStatus.toggle() } label: {
          Image(systemName: "exclamationmark.circle")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }.buttonStyle(.plain).accessibilityLabel(L10n.text("awake.status"))
      }
    }
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    .environment(\.colorScheme, .dark)
    .accessibilityHidden(!isActive)
    .contextMenu {
      Text(L10n.text("awake.title"))
      Text(L10n.text("awake.phase.\(store.phase)"))
      if let key = store.messageKey { Text(L10n.text(key)) }
      if running { Button(L10n.text("awake.stop")) { store.stop() } }
      Divider()
      Button(L10n.text("awake.status")) { showsStatus = true }
    }
    .popover(isPresented: $showsStatus, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        Text(L10n.text("awake.phase.\(store.phase)")).font(.headline)
        if let session = store.session {
          HStack { Text(L10n.text("awake.ends")); Text(session.deadline, style: .time) }
            .font(.system(size: 12))
        }
        if let key = store.messageKey { Text(L10n.text(key)).font(.system(size: 12)) }
        Text(L10n.text("awake.note")).font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(16).frame(width: 270).preferredColorScheme(.dark)
    }
    .onExitCommand { setEditing(false) }
    .onChange(of: showsStatus) { _, _ in updateHold() }
    .onChange(of: store.phase) { _, phase in
      if phase != .idle { editing = false; focused = nil }
      updateHold()
    }
    .onChange(of: isActive) { _, active in
      if !active { setEditing(false); showsStatus = false }
    }
    .onDisappear { model.setKeepAwakeControlsPresented(false); model.setKeepAwakeInputExpanded(false) }
    .task(id: editing) {
      visiblePills = false
      guard editing else { return }
      await Task.yield()
      guard !Task.isCancelled else { return }
      visiblePills = true
      focused = 1
    }
  }

  private func durationPill(_ key: String, value: Binding<String>, index: Int) -> some View {
    TextField(L10n.text(key), text: value)
      .textFieldStyle(.plain).multilineTextAlignment(.center)
      .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
      .frame(width: 40, height: 21)
      .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
        focused == index ? Color(red: 0.56, green: 0.62, blue: 0.76) : .white.opacity(0.1),
        lineWidth: focused == index ? 1.3 : 0.5))
      .focused($focused, equals: index)
      .accessibilityLabel(L10n.text(key))
      .onSubmit(start)
      .scaleEffect(visiblePills || reduceMotion ? 1 : 0.55, anchor: .leading)
      .opacity(visiblePills ? 1 : 0)
      .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.72).delay(Double(index) * 0.04), value: visiblePills)
  }

  private func setEditing(_ value: Bool) {
    guard store.phase == .idle || !value else { return }
    editing = value
    model.setKeepAwakeInputExpanded(value)
    if !value { focused = nil }
    updateHold()
  }
  private func updateHold() {
    model.setKeepAwakeControlsPresented(editing || showsStatus || store.phase.isBusy)
    model.setKeepAwakeInputExpanded(editing)
  }
  private func start() {
    guard let totalMinutes else { return }
    Task { await store.start(minutes: totalMinutes) }
  }
}
