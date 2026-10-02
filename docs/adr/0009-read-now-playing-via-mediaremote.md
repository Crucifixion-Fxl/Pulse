# Control playback through a perl-hosted media-key bridge

Todo Island reads the system Now Playing buffer through the private MediaRemote framework, re-implemented from scratch per ADR 0002's no-copy rule, because the system buffer is the only source that covers 网易云音乐 (NeteaseMusic) — the player actually in use — which offers no AppleScript interface.

Three macOS 26 realities shape the design, each verified against the live player:

1. mediaremoted denies its now-playing XPC to non-platform binaries, so the app spawns a resident `/usr/bin/perl` (trust-cached) that loads the bundled `MediaRemoteHelper.dylib`; the helper observes notifications, polls elapsed at 0.5 s, and streams JSON lines over stdout. Commands travel as signals (SIGUSR1/SIGUSR2/SIGINFO) — kill from parent to child is always permitted.
2. 网易云音乐's CEF shell ignores every MRMediaRemoteSendCommand variant, so playback control synthesizes the keyboard media keys (NX_SYSDEFINED, subtype 8), the one path it honors. Posting those events requires the Accessibility (PostEvent) TCC grant for Todo Island — a one-time manual user action.
3. The app-sandbox entitlement is dropped: it blocked neither the child's XPC nor spawning, but sandbox-internal file and event-posting behaviour proved needlessly fragile (an unreadable temp file channel; sandboxed CGEventPost). The app is ad-hoc signed personal software; EventKit keeps working through its normal TCC prompt.

The helper source lives at `helpers/MediaRemoteHelper.swift`, rebuilt with `scripts/build-media-helper.sh` into `TodoIsland/Resources/`. `TodoIsland --media-harness-test` runs a transport self-check inside the real process.
