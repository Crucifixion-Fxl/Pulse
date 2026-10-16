# Daily anime character in the expanded header

The expanded header now reads **weather → daily character → Codex bot**. Both
native-compositor and SwiftUI fallback layouts preserve the same 8pt/12pt gaps.
The character is decorative; weather remains clickable. Collapse hides it and
stops its Core Animation loop. Reduce Motion retains a still pose.

## Weekly schedule

Use the Mac's local calendar weekday, Monday through Sunday:
Sigewinne, Furina, Navia, Nahida, Clorinde, Emilie, Chasca. Sigewinne and Chasca
run; the other five use their original walking loops. Restarting does not change
the day's character. A calendar-based midnight timer plus day/time-zone/clock
and wake notifications refresh the selection. Tests inject dates without
changing the workstation's clock. An older asynchronous decode cannot overwrite
a newer requested character. Only the current character's decoded frames are kept.

## Artwork and playback

Source: https://github.com/Senkin219/GI-Character-Spine at
`4c4e667f87edd4fbba85ad26b781d82f757af537`.
The bundled manifest records paths, chosen right-facing skins, original action
names, durations and sheet digests. Artwork belongs to miHoYo / HoYoverse and
is credited separately from application-source licensing in the bundled notice.
This supersedes the earlier eight-frame TonyNa atlas and runtime download cache.

The original Spine loops are rendered using the author's compatible miHoYo
extension/physics parser at >=60 samples/second, keeping the original speed.
Secondary motion is aligned to the loop and warmed for four cycles. One fixed
bounding box per whole loop avoids per-frame resizing/jitter; visible alpha
bounds avoid invisible geometry shrinking the character. Explicit skins are
required for complete hair and hats on Furina, Navia, Clorinde and Chasca.
Each transparent frame is 128×128, enough for the 30pt Retina header character.
See `scripts/characters/README.md` for reproducible preparation/export.

Bundled SHA-256 verified sheets work immediately offline. Frames decode on a
utility task; a persistent native layer plays the frames without a SwiftUI frame
timer, browser runtime or per-frame layout. Unrelated quota/weather updates do
not restart the animation. Each closing frame receives the same time as every
other frame. The previous downloaded artwork is no longer read.

## Verification

Seven-day selection, weekly rollover, time-zone changes, DST midnights, simulated
live day changes and fresh-store consistency are tested. Each shipped sheet is
checked for correct digest, dimensions, transparency, distinct frames and <=16.67ms
pose intervals. Native-layer tests verify duration, character replacement and
stopping on collapse/detach. Header tests assert weather < character < bot.

Export inspection confirms all seven characters have complete hair/hat/body
rendering. For every clip, the last→first mean absolute pixel difference is below
the largest adjacent-frame difference; no additional loop-seam jump was found.
Installed-app visual verification and test results are recorded after execution.

Validated 2026-10-17: all 19 focused tests passed (6 daily-character, 5 weather,
8 island-transition tests). Signed Release installed at `/Applications/TodoIsland.app`;
installed/build executable SHA-256 matched. Computer interaction confirmed the
Saturday Emilie between weather and bot, distinct walking poses, weather popover
interaction, collapse/reopen, and the same character after process restart.
The app remains open for inspection. Actual wall-clock midnight and physical
Reduce Motion were not awaited/toggled; their selection/stop paths are covered
by tests. Frame sampling is verified; display-presented FPS was not measured.
