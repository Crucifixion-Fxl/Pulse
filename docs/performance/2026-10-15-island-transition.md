# Island expansion and collapse on Core Animation

## Implementation

Replaced the main-thread display-link spring that resized `NSWindow` on every
frame with `IslandTransitionView`. The hosting hierarchy is laid out at its
destination size; Core Animation animates the silhouette mask and content
opacity. A temporary outgoing Retina snapshot bridges the content change.
Native controls remain mounted, preserving their first responder and draft.
The panel is resized at preparation and completion only. Snapshot contents are
released at completion. Reduce Motion continues to use immediate transitions.

Animated preparation is deferred beyond the model publisher's `willSet` turn.
Synchronous window resizing inside that publisher can force SwiftUI layout to
publish an old pane height back into the model. Generation checks discard
pending work and completions superseded by another transition.

Core Animation handles the animation/compositing work; CPU work still includes
initial layout, outgoing image capture, and independent content updates. See
[Apple's Core Animation overview](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html).

## Isolated benchmark

Apple M5, macOS 26.6.2, optimized arm64 build. Ten alternating transitions,
1.2 seconds apart, between 340 × 32 and 760 × 360 points. Identical SwiftUI
content: 12 reminder labels, 196 heatmap cells, a title and text field.

| Measurement | Previous display-link spring | Compositor transition |
| --- | ---: | ---: |
| Window frame writes | 295 | 20 |
| Hosting view layout calls | 503 | 48 |
| Process CPU time | 1.742593 s | 0.379903 s |

This single isolated run measured approximately 78% less process CPU time and
90% fewer layout calls. It does not measure whole-app CPU usage, WindowServer
cost, GPU utilization, frame rate, energy use, or battery life.

Reproduce from the repository root:

```sh
git show 8b5a7ad:Pulse/Window/IslandFrameSpring.swift > /tmp/IslandFrameSpring-before.swift
xcrun swiftc -O -parse-as-library -DLEGACY \
  Pulse/Domain/IslandState.swift \
  Pulse/UI/Island/IslandSurfaceShape.swift \
  /tmp/IslandFrameSpring-before.swift scripts/probe-island-transition.swift \
  -o /tmp/island-transition-old
/tmp/island-transition-old

xcrun swiftc -O -parse-as-library \
  Pulse/Domain/IslandState.swift \
  Pulse/UI/Island/IslandSurfaceShape.swift \
  Pulse/Window/IslandTransitionView.swift scripts/probe-island-transition.swift \
  -o /tmp/island-transition-new
/tmp/island-transition-new
```

The probe uses synthetic content and does not access reminders or app settings.
Add `--loop` for visual inspection; terminate the probe when finished.

## Behaviour verification

- 52 focused tests pass across `IslandTransitionTests`, `IslandStateTests`,
  `DisplayGeometryTests`, `CollapsedIslandVisibilityTests` and
  `AuthorizationFlowTests`.
- Native-window tests observe the presentation-layer silhouette moving while
  window frame and content layout remain fixed. They also verify rapid reversal,
  height retargeting, pending/running cancellation, native text-field focus,
  snapshot release, and correction of an externally displaced window.
- Signed Release installed and launched from `/Applications/TodoIsland.app`.
  A temporary local IPC question triggered the real app's expansion. The AI
  panel was visible, and clicking the reminders sidebar showed its calendar,
  heatmap, task list and input field. SessionEnd removed the temporary question
  and session; the app returned to the collapsed bar. No reminder was changed.
- Live interactive animation was also inspected using the standalone probe.
  No frame-rate or GPU-counter trace was collected. Multiple physical displays
  and a live OS Reduce Motion toggle were not exercised in this run.
