import AppKit
import QuartzCore
import SwiftUI

@MainActor final class ProbeModel: ObservableObject { @Published var expanded = false }
struct ProbeContent: View {
  @ObservedObject var model: ProbeModel
  var body: some View {
    GeometryReader { proxy in
      Group {
        if model.expanded {
          VStack(spacing: 8) {
            Text("TodoIsland GPU transition").font(.title2)
            HStack(alignment: .top) {
              VStack {
                ForEach(0..<12) { i in
                  Text("Reminder \(i)").frame(maxWidth: .infinity, alignment: .leading)
                }
              }
              LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 14)) {
                ForEach(0..<196) { i in
                  RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(Double(i % 5 + 1) / 5))
                    .frame(height: 12)
                }
              }
            }
            TextField("New task", text: .constant("Focus survives the transition"))
          }.padding(24)
        } else {
          HStack {
            Text("Codex 75%")
            Spacer()
            Text("● ●")
          }.padding(.horizontal, 16)
        }
      }.foregroundStyle(.white).frame(width: proxy.size.width, height: proxy.size.height)
        .background(.black).clipShape(
          IslandSurfaceShape(
            shoulderInset: model.expanded ? 8 : 0, topShoulderDepth: model.expanded ? 8 : 0,
            bottomRadius: model.expanded ? 36 : 18))
    }
  }
}
@MainActor final class CountWindow: NSWindow {
  var writes = 0
  override func setFrame(_ f: NSRect, display: Bool) {
    writes += 1
    super.setFrame(f, display: display)
  }
}
@MainActor final class CountHost: NSHostingView<ProbeContent> {
  var layouts = 0
  override func layout() {
    layouts += 1
    super.layout()
  }
}
@main struct Probe {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let model = ProbeModel()
    let host = CountHost(rootView: ProbeContent(model: model))
    host.sizingOptions = []
    host.wantsLayer = true
    let window = CountWindow(
      contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    let collapsed = CGRect(x: 410, y: 700, width: 340, height: 32)
    let expanded = CGRect(x: 200, y: 372, width: 760, height: 360)
    #if LEGACY
      window.contentView = host
      window.setFrame(collapsed, display: true)
      let spring = IslandFrameSpring()
    #else
      let transition = IslandTransitionView(content: host)
      window.contentView = transition
      transition.transition(to: collapsed, state: .collapsed, collapsedRadius: 18, animated: false)
    #endif
    window.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
      window.writes = 0
      host.layouts = 0
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      let start =
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
          usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
      @MainActor func cycle(_ i: Int) {
        if i == 10 && !CommandLine.arguments.contains("--loop") {
          getrusage(RUSAGE_SELF, &usage)
          let end =
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
              usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
          print(
            "RESULT transitions=10 frameWrites=\(window.writes) layouts=\(host.layouts) cpuSeconds=\(end-start)"
          )
          fflush(stdout)
          app.terminate(nil)
          return
        }
        let open = i % 2 == 0
        let target = open ? expanded : collapsed
        let state: IslandPresentationState = open ? .pinned : .collapsed
        #if LEGACY
          spring.animate(
            on: window, from: window.frame, to: target, response: state.motionProfile.response,
            dampingFraction: state.motionProfile.dampingFraction
          ) { window.setFrame($0, display: false) }
        #else
          transition.transition(to: target, state: state, collapsedRadius: 18, animated: true)
        #endif
        model.expanded = open
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { cycle(i + 1) }
      }
      cycle(0)
    }
    app.run()
  }
}
