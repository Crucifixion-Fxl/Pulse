# Xiaozhi voice on the Island

Hold plain Space until the Island wakes. **Interface sci fi expand or zoom**
(Mixkit item 913, approximately 0.65 seconds) plays once
through the current system output before the microphone opens. Speak when
**Listening** appears. Short presses do not play the cue; Escape cancels both
the cue and pending voice startup.
Release Space and continue the conversation. Wait until **Listening** before the
next turn: microphone upload pauses while Xiaozhi thinks or speaks, preventing
background sound and playback echo from interrupting its reply. **Escape** (or another hold) ends
capture, playback, and the network session. Short Space retains its normal action.
The menu's **Start Voice Conversation** action invokes the same behavior.

Global Space needs macOS Accessibility permission for the installed Pulse app.
Use the menu's **Enable Global Hold Space** action to request it. After replacing
an ad-hoc build, an old permission entry may no longer match the new signature;
re-add the current `/Applications/Pulse.app` in Privacy & Security → Accessibility.
Local Space inside Pulse and the menu action remain available without this global
permission. Keep a stable signing identity for local updates as described in
[the release guide](RELEASING.md#local-updates-and-macos-permissions).

The Xcode build downloads and verifies the wake sound into DerivedData, then
bundles it in the application. The first build needs access to assets.mixkit.co;
subsequent builds reuse the verified cache. Playback needs no network access.
The audio is excluded from the source repository because the Mixkit Sound Effects
Free License permits use in an end product but prohibits redistribution with
source files. See `Pulse/Resources/Licenses/VOICE-WAKE-NOTICE.txt` for provenance.

Audio input and output follow the macOS defaults independently, including headphones.
Connecting, disconnecting, or choosing another default device during a conversation
reopens the local audio streams and resamplers without reconnecting the cloud session.
Saved device names from the standalone client do not override these defaults.

The white rim responds to microphone and actual speaker PCM amplitude with a
fast attack and soft release. The opaque black core, surrounding atmosphere,
and particle flow retain their existing animation. Reduced Motion limits rim
movement. A short caption distinguishes connecting, listening, thinking, speaking,
and errors. This is independent of the coding-agent panel.

## Local runtime prerequisite

This initial integration uses a separately installed, bound
[py-xiaozhi](https://github.com/huangjunsen0406/py-xiaozhi) runtime. It does not
include a Python distribution or a language model in the app bundle.

Expected layout under `~/Library/Application Support/PulseVoice/`:

```text
py-xiaozhi/
  .venv/bin/python     # Python 3.12 with the client's audio/network dependencies
  src/                # py-xiaozhi source
  libs/               # bundled Opus and optional WebRTC AEC
  ...
data/
  config/config.json  # official device configuration
  config/efuse.json   # bound device identity
```

Complete device binding using the standalone client's official setup flow first.
Use its existing identity, rather than copying credentials into Pulse source or
creating a new device for each conversation. Close the standalone client before
using Pulse so the two clients do not compete for one device's connection.

The tested runtime includes a local TLS correction: `ActivationHttpClient`,
`OtaConfigClient`, and `WebsocketProtocol` must use `ssl.create_default_context()`
with certificate and hostname verification enabled. Do not disable verification.
The client runtime must also have PortAudio available and a working Opus loader.

Choose the voice and model in the [official console](https://xiaozhi.me/console/agents).
Pulse uses that device's settings; it does not override the selected voice.
The current trial was verified with **湾湾小何** and **小智 Lite**.

## Process and privacy boundary

- Pulse requests macOS microphone access on the first completed wake gesture.
- A private child process runs the bundled `xiaozhi_voice_bridge.py`. It imports
  the installed client's transport and audio components, refreshes the existing
  device configuration, and opens the official TLS WebSocket.
- Recognition, model inference, and synthesis run in the Xiaozhi cloud. This is
  **not offline inference**. Microphone audio is sent only while the session is active.
- The pipe carries state, bounded amplitude values, and stable error codes.
  Credentials, conversation text, and raw audio are not written to Pulse logs.
- No local network listener is opened. MCP advertises an empty tool list; camera,
  screenshot, file access, and remote tool execution are not exposed.
- AEC remains enabled for local audio processing. Conversation turns use server
  automatic endpoint detection, with microphone upload gated during thinking and
  playback. Queued microphone packets are invalidated at each turn boundary.
  Listening resumes after decoded PCM, resampling buffers, and scheduled device
  playback have drained. Input network backlog is bounded to half a second.
- Escape, sleep, session lock, screen change, quit, parent-pipe closure, a network
  failure, or three minutes without a recognized turn ends the worker. A stuck
  worker is force-terminated two seconds after a user stop.
- Missing runtime, binding, or microphone permission produces an inline error.
  Reopen after resolving it. No automatic background reconnect starts recording.

## Verification

```sh
python3 scripts/test-xiaozhi-bridge.py
xcodebuild -project Pulse.xcodeproj -scheme Pulse -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:PulseTests/VoiceWakeTests \
  -only-testing:PulseTests/AIWakeGestureTests \
  -only-testing:PulseTests/BlackHoleWakeViewTests \
  -only-testing:PulseTests/AIWakeShortcutTests test
```

Also test a real voice round trip, repeated wake/exit, and verify no worker remains
after Escape. A successful build alone does not verify microphone permission,
cloud account availability, or audible playback.

Protocol reference: [Xiaozhi WebSocket documentation](https://github.com/78/xiaozhi-esp32/blob/main/docs/websocket.md).
