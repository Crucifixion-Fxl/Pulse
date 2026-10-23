# README artwork

`pulse-overview.gif` is a four-scene, 22-second looping tour of Reminders,
Agents, Music and Clipboard. `pulse-overview.png` places the same four scenes
in one static image. Both READMEs embed the GIF and link to the static version.

The 1200 × 700 GIF uses 1,100 frames at 50 fps (20 ms per frame). A deterministic
Core Graphics composition keeps the product in a quiet pool of blue-violet
light, with no surrounding title, tabs or decorative borders. Native panes
enter in a short stagger as the island changes height. The orb anticipates
transitions with a glance, nods during music, then takes a brief close-up with
a head tilt and double blink before returning to its header position. The
loop starts on the full Reminders view so its first frame is useful on its own.

This is an editorial product film made from native view captures. The pane
entrances, island morph and mascot close-up are demonstration choreography,
not a screen recording or a claim about the app's exact motion. The mascot
keeps the production orb's flat white face and black capsule-eye proportions.
A shared GIF palette keeps the background and typography stable between frames.
Gifsicle then optimizes frame differences losslessly, preserving all 1,100
frames and their 20 ms timing without leaving trails in the dark background.

The renderer hosts the production `IslandRootView` in a separate process.
Reminders and completion history are in-memory fixtures; agent events use
`demo-*` identifiers and `/demo/` paths; quotas use `SampleAIUsageProvider`;
music titles and lyrics are original fixture text; the cover uses Pulse's
existing icon; clipboard entries are invented, including
the reserved `example.com` domain. It does not launch the application delegate,
start the agent server, read Apple Reminders, monitor the clipboard, or capture
the desktop. Weather and Keep Awake are omitted from this tour. A fixture-only
extension is appended to a temporary copy of `AppModel.swift` to populate the
music favorites rail. It is not compiled into the shipping app and does not
load a personal playlist or contact its service.

Regenerate from the repository root on macOS with Xcode 26+, Python 3, ffmpeg
and gifsicle:

```sh
python3 scripts/render-readme.py
```

The build, intermediate frames and isolated demo preferences are temporary.
Calendar dates follow the render day. Inspect every scene before publishing,
particularly when production views or their service initialization change.
These images illustrate the UI with sample data; they are not evidence of
live integrations or a recording of real account activity.

The former `extension-store.png` remains available for the extension-store
documentation; it is no longer the product overview.
