# Running anime character in the expanded header

The user selected the default anime character from
[TonyNa-code/desktop-pet](https://github.com/TonyNa-code/desktop-pet).
Show its right-running loop to the left of weather in the expanded header,
retaining the existing Codex bot. The character is decorative and does not
intercept clicks or claim to represent an agent's status.

Use the upstream 768x832 preview atlas at commit
`85896750a3e4198c278e443efe77e58142aa9709`, whose second row contains the eight
right-running frames. The preview has enough resolution for the 30pt Retina
character. Preserve the upstream 100ms frame timing and transparency.

Artwork is downloaded on first expansion, SHA-256 verified, decoded off the
main thread and cached in Application Support/TodoIsland/CharacterAssets.
Further launches can use the verified cache offline. Downloads coalesce across
display headers and failures are throttled for two minutes. Until artwork is
available this decorative slot stays empty. No third-party script is executed.

The repository's MIT license covers application source. Its
[asset notice](https://github.com/TonyNa-code/desktop-pet/blob/85896750a3e4198c278e443efe77e58142aa9709/ASSET_NOTICE.md)
separately asks distributors to establish artwork rights. Therefore this change
does not vendor the artwork or include it in distributed app bundles; it loads
the selected upstream artwork into the user's local cache. Public redistribution
of the artwork itself requires separately establishing permission.

A persistent native layer plays the decoded frames; no SwiftUI frame timer or
per-frame layout is used. Header positioning and fade use the existing native
transition. Playback stops on collapse, view removal or Reduce Motion. Reduce
Motion retains a still pose. Weather and quota changes do not restart the loop.

Verification covers atlas row selection, equal timing for all eight frames,
playback cancellation, header separation and collapse visibility. Installed-app
acceptance additionally requires observing different poses, opening/closing,
weather interaction and persistence across restart.

Validated on 2026-10-16: all 16 focused tests passed (3 character, 5 weather,
8 island transitions). Installed the signed Release build and used computer
interaction to observe distinct running poses, collapse/reopen, open/close the
weather popover, and restart the app. The character returned after restart and
the verified cached artwork's modification time remained unchanged. Physical
Reduce Motion was not toggled; the stopped-animation path is covered by the
native view test.
