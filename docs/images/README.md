# README artwork

`pulse-overview.gif` is a four-scene, 17-second looping tour of Reminders,
Agents, Music and Clipboard. `pulse-overview.png` places the same four scenes
in one static image. Both READMEs embed the GIF and link to the static version.

The 1200 × 760 GIF uses 425 frames at 25 fps. A deterministic Core Graphics
composition adds eased horizontal transitions, a moving scene indicator and
a collapse/reopen loop. This is an editorial product tour using native view
captures, not a screen recording or a claim about exact app transition timing.
A shared GIF palette keeps the background and typography stable between frames.

The renderer hosts the production `IslandRootView` in a separate process.
Reminders and completion history are in-memory fixtures; agent events use
`demo-*` identifiers and `/demo/` paths; quotas use `SampleAIUsageProvider`;
lyrics are original fixture text; clipboard entries are invented, including
the reserved `example.com` domain. It does not launch the application delegate,
start the agent server, read Apple Reminders, monitor the clipboard, or capture
the desktop. Weather and Keep Awake are omitted from this tour. The music
favorites rail accurately shows its unconfigured state.

Regenerate from the repository root on macOS with Xcode 26+, Python 3 and ffmpeg:

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
