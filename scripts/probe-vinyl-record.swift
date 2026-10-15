// swiftc TodoIsland/UI/Island/VinylRecordView.swift scripts/probe-vinyl-record.swift -o /tmp/vinyl-probe
import AppKit

@main @MainActor struct Probe {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 360, height: 324),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "TodoIsland vinyl motion probe"
    window.backgroundColor = .black
    let view = VinylRecordLayerView(frame: CGRect(x: 0, y: 0, width: 360, height: 324))
    view.configure(isPlaying: true, reduceMotion: false)
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    Task { @MainActor in
      func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
      func angle(_ layer: CALayer) -> Double {
        (layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
      }
      await wait(0.25)
      let earlyY = view.platter.presentation()!.position.y
      let earlyArm = angle(view.arm)
      await wait(1.0)
      precondition(view.platter.presentation()!.position.y > earlyY + 20, "Record did not rise")
      precondition(abs(angle(view.arm) - earlyArm) < 0.01, "Arm moved before record settled")
      await wait(1.5)
      precondition(abs(angle(view.arm)) > 0.03, "Arm did not approach record")
      precondition(abs(angle(view.record)) < 0.01, "Record spun before stylus landed")
      await wait(1.5)
      let spinning = angle(view.record)
      await wait(0.3)
      precondition(abs(angle(view.record) - spinning) > 0.1, "Record did not spin")
      let spinStart = view.record.animation(forKey: "spin")!.beginTime
      view.configure(isPlaying: true, reduceMotion: false)
      precondition(view.record.animation(forKey: "spin")!.beginTime == spinStart,
                   "Unchanged snapshot restarted rotation")
      view.configure(isPlaying: false, reduceMotion: false)
      await wait(1.3)
      let paused = angle(view.record)
      await wait(0.3)
      precondition(abs(angle(view.record) - paused) < 0.001, "Paused record still moving")
      precondition(abs(angle(view.arm)) < 0.001, "Arm failed to park")
      view.configure(isPlaying: true, reduceMotion: false)
      await wait(0.3)
      view.configure(isPlaying: false, reduceMotion: false)
      await wait(1.4)
      precondition(view.record.animation(forKey: "spin") == nil, "Cancelled start resumed later")
      view.configure(isPlaying: true, reduceMotion: true)
      await wait(0.2)
      precondition(view.record.animationKeys()?.isEmpty != false, "Reduce Motion still animates")
      precondition(abs(angle(view.arm) - Double(VinylRecordLayerView.playingAngle)) < 0.001)
      view.configure(isPlaying: true, reduceMotion: false)
      await wait(2.6)
      let resumed = angle(view.record)
      await wait(0.3)
      precondition(abs(angle(view.record) - resumed) > 0.1, "Resume failed")
      print("PASS rise / arm-after-rise / spin-after-landing / steady updates / coast-to-pause / arm park / interrupted start / Reduce Motion / resume")
      fflush(stdout)
      if !CommandLine.arguments.contains("--stay") { app.terminate(nil) }
    }
    app.run()
  }
}
