# Read system playback through MediaRemote and control NetEase through its native menu

Todo Island reads the system Now Playing buffer through the private MediaRemote framework, implemented independently per ADR 0002. On macOS 26, mediaremoted denies the app's direct XPC request. A resident `/usr/bin/perl` process loads `MediaRemoteHelper.dylib`, observes playback notifications, polls every 0.5 seconds and streams JSON snapshots to the app. Playback requests reach that child through signals.

The initial control path replayed captured keyboard media events. Reconstructing those events after an app restart is unreliable: the helper can receive a toggle signal and post the event successfully while NetEase continues playing. A working internal AVPlayer test does not verify this external-player path.

For each command, the helper now resolves the current Now Playing PID. If its bundle identifier is `com.netease.163music`, it uses the player's native Control menu through Accessibility. Enabling the CEF accessibility tree exposes closed-menu children; the helper finds only the direct play/pause, next or previous item and invokes its action without activating the player. It uses the existing Accessibility grant. An accepted menu action never also emits a media key, which would risk toggling twice. Other players, or a native action that could not be dispatched, retain the previous media-key fallback.

The Control-menu approach was independently implemented after consulting the [CloudMusicFocus design description](https://github.com/eruimisshy/CloudMusicFocus#工作原理); no source code was copied.

The helper source lives at `helpers/MediaRemoteHelper.swift`. Rebuild it with `scripts/build-media-helper.sh`; the resulting dylib in `Pulse/Resources/` is committed with its source. The app is ad-hoc signed without App Sandbox; EventKit retains its normal TCC authorization.

## Playback regression verification

Use the installed Release app and a real NetEase track, not an internal favorite:

1. Restart Todo Island without pressing a hardware media key.
2. Click to open the island and select Music. Press Space once; confirm NetEase changes from playing to paused and elapsed time stops.
3. Press Space again; confirm elapsed time resumes. Repeat after closing and reopening the island.
4. Check the helper log for `CONTROL route=netease-menu key=16 handled=true`. There must be no fallback `POST key=16` for an accepted native action.
5. Check keyboard isolation separately: text-field spaces and modified Space combinations must not toggle music; holding Space must not toggle repeatedly.

The regression crosses a separately hosted helper, TCC and an external CEF app. A unit test of key-event dispatch cannot establish that playback actually changed; retain this real-player verification when changing the helper.
