# Audio visualizer GPU animation

## Scope

The music panel's fallback when a playing track has no lyrics. Replace its
24 SwiftUI capsules and 30 Hz TimelineView with 24 Core Animation layers.
Precomputed height and corner-radius keyframes loop on the compositor;
application work occurs on playback, Reduce Motion and size changes.

The original sine frequencies share a 20π-second period. Thirty samples per
second with linear interpolation preserve the waveform within 0.6 pt, including
the minimum-height clamp. Radius follows height so short bars remain capsules.
Paused bars keep their original fixed heights. Reduce Motion uses a static frame.

[Apple's Core Animation guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html)
describes hardware composition and the distinction between model and presentation layers.

## Validation on 2026-10-15

- Apple M5, macOS 26.6.2, optimized arm64 executables.
- Separate old/new processes hosted the real component in an identical
  500 × 140 pt NSHostingView. Legacy source came from commit `5369a2e`.
- `top -l 21 -s 1 -pid PID -stats pid,cpu,mem,threads -n 1`;
  discard the initial CPU reading and three startup samples.
- Legacy application CPU: mean 6.41%, median 6.3% across 17 samples.
- Final compositor implementation: mean 0.0%, median 0.0% across 17 samples.
- This measures the component's **application process CPU**, not whole-app
  CPU, GPU consumption, WindowServer cost or battery life. A 0.0% reading is
  the sampling tool's precision, not a claim of zero system work.
- Live presentation-layer probe: 24/24 bars moved over 0.4 seconds;
  pause, Reduce Motion and resume passed. Native screenshot inspection
  confirmed rendered bars and corrected the short-bar corner-radius issue.
- 37 targeted Xcode tests passed: AudioVisualizerTests + MusicTests. They cover
  animation lifecycle, repeated updates, resizing, loop boundaries and waveform
  interpolation alongside existing playback/lyrics behavior.
- Signed Release installed at `/Applications/TodoIsland.app` and launched.
  Full music-panel interaction was not exercised against a live no-lyrics track;
  the actual rendering component was exercised in the native probe.

## Reproduce the runtime probe

From the repository root:

```sh
xcrun swiftc -O -parse-as-library \
  TodoIsland/UI/Island/AudioVisualizer.swift \
  scripts/probe-audio-visualizer.swift -o /tmp/doisland-audio-probe
/tmp/doisland-audio-probe
```

Expected: `PASS movingBars=24/24 pause=PASS reduceMotion=PASS resume=PASS`.
Use `--stay` to keep the component visible for inspection and sampling.
The probe uses only its own window and no music, reminders or user settings.

```sh
xcodebuild test -project TodoIsland.xcodeproj -scheme TodoIsland \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TodoIslandTests/AudioVisualizerTests \
  -only-testing:TodoIslandTests/MusicTests CODE_SIGNING_ALLOWED=NO
```

## Rejected experiment

Moving the small collapsed bot face to Canvas/Metal did not produce a repeatable
CPU improvement (one stable comparison was 5.39% before vs 6.31% after).
That experiment was reverted completely. No blanket drawingGroup modifier was
added to native controls or the whole island.
