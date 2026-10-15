import AppKit
import SwiftUI

@main struct Probe {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 500, height: 140),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "TodoIsland audio rendering probe"
    window.contentView = NSHostingView(
      rootView: AudioVisualizer(isPlaying: true).frame(width: 500, height: 140).background(.black))
    window.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      func find(_ v: NSView) -> AudioVisualizerView? {
        if let v = v as? AudioVisualizerView { return v }
        return v.subviews.lazy.compactMap { find($0) }.first
      }
      guard let view = find(window.contentView!) else { fatalError("Missing visualizer") }
      let first = view.bars.map { $0.presentation()?.bounds.height ?? -1 }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        let second = view.bars.map { $0.presentation()?.bounds.height ?? -1 }
        let moving = zip(first, second).filter { abs($0 - $1) > 0.1 }.count
        precondition(moving >= 20, "Bars did not animate")
        view.configure(isPlaying: false, reduceMotion: false)
        view.layout()
        precondition(view.bars.allSatisfy { $0.animationKeys()?.isEmpty != false })
        for (i, bar) in view.bars.enumerated() {
          precondition(bar.bounds.height == 6 + CGFloat(i % 5) * 2)
        }
        view.configure(isPlaying: true, reduceMotion: true)
        view.layout()
        precondition(view.bars.allSatisfy { $0.animationKeys()?.isEmpty != false })
        view.configure(isPlaying: true, reduceMotion: false)
        view.layout()
        precondition(view.bars.allSatisfy { $0.animationKeys()?.isEmpty == false })
        print("PASS movingBars=\(moving)/24 pause=PASS reduceMotion=PASS resume=PASS")
        fflush(stdout)
        if !CommandLine.arguments.contains("--stay") { app.terminate(nil) }
      }
    }
    app.run()
  }
}
