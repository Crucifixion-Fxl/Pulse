# Pulse

Pulse is a native macOS 14+ workspace in the menu bar: reminders, AI agent activity and usage, music, clipboard history, and local weather, gathered in a Dynamic Island-style surface that follows the display you are working on.

## Download

Download available builds from [GitHub Releases](https://github.com/Crucifixion-Fxl/Pulse/releases/latest). New builds produce **Pulse.app**; older releases may still be named **TodoIsland.app**. Drag the app into **Applications** to install.

This project was previously called Todo Island. Pulse keeps the existing app identity and local data locations, so existing reminders, settings and agent integrations continue to work after upgrading.

## Features

- **Dynamic Island surface** — a collapsed bar in the menu-bar/notch area, a hover preview, and a pinned expanded surface, following the display the pointer works on (notch-aware on built-in displays).
- **Month calendar + completion heatmap** — a six-week grid with per-List accent dots under each date (one dot per List with pending items; gray means only completed ones remain) and a 24-week completion heatmap.
- **Liquid interactions** — the date-selection bead slides between days, the sidebar indicator flows between icons, and switching happens on hover.
- **Completion feedback** — the circle fills and the checkmark draws in, the title fades, and the row closes smoothly without recentering the list. Successful completions can be undone in reverse order for eight seconds; text editing keeps its own undo.
- **Day Schedule grouped by List** — same-List tasks stay together, ordered like the Lists themselves, with overdue items greeting today.
- **Quick Add** — the Task Input creates a reminder on the selected day in any List; the first click on the hover preview pins the Island and puts the caret in the field.
- **AI agent activity** — live coding-agent sessions and requests for attention.
- **AI wake animation** — hold plain Space for about 0.8 seconds to unfold a deep-black core surrounded by a dense, flowing white particle cloud. Release early to cancel; after waking, Escape or another hold restores the original island. Short Space keeps text entry and playback controls. With the [Xiaozhi voice runtime](docs/XIAOZHI-VOICE.md) installed and bound, waking starts a cloud voice conversation; the white rim follows microphone and speaker amplitude. Escape ends capture and playback. Global use requires Accessibility permission via the menu's **Enable Hold Space in Other Apps…** action; in-app use and the menu preview work without it.
- **Clipboard history** — recent clipboard content in a dedicated panel.
- **Timed Keep Awake** — an animated eye with inline duration pills to the left of weather keeps the Mac running with the lid closed for a chosen duration. Each session requests administrator authorization; an independent system job restores sleep at the deadline or after Pulse exits. [Behavior and recovery](docs/adr/0014-bounded-keep-awake-sessions.md).
- **Local weather** — current-city conditions beside the bot, with a clickable detail panel.
- **AI usage dashboard** — today's tokens with an input/output/cache split, a fifteen-day trend, and per-subscription weekly quota cards (sample data until real providers land).
- **Music panel** — the system Now Playing (any player, e.g. NetEase Cloud Music) with artwork, progress, and controls on the left; time-synced lyrics with translations on the right, fetched from NetEase with an LRCLIB fallback.
- **List management** — iCloud Reminders plus a private local source with per-List accents, renaming, and deletion summaries.
- **Keyboard support** — arrows move the selection or shift the day, Return edits, Space completes, ⌘N focuses the Task Input, ESC dismisses.
- **Stay modes** — always visible or auto-hide with a notch activation zone; configurable in Settings.

## Open and run

1. Open `Pulse.xcodeproj` in Xcode 26 or newer.
2. Select the `Pulse` scheme and **My Mac** destination.
3. Run the application.
4. Pick the Collapsed Island stay mode in **Settings → Island** (defaults to always visible).
5. Grant Reminders access for iCloud or choose **Use Local** to work without that permission.

The checked-in project uses `Sign to Run Locally`, the bundle identifier `com.fxl.TodoIsland`, the App Sandbox, and the Reminders calendar entitlement. Configure a Personal Team or Developer ID only when distributing to another Mac.

## Build from Terminal

```sh
xcodebuild \
  -project Pulse.xcodeproj \
  -scheme Pulse \
  -configuration Debug \
  -derivedDataPath /tmp/PulseDerivedData \
  build
```

## Test

```sh
xcodebuild \
  -project Pulse.xcodeproj \
  -scheme Pulse \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PulseDerivedData \
  test
```

## Documentation

- [`CONTEXT.md`](CONTEXT.md) defines the product language.
- [`docs/PRODUCT-SPEC.md`](docs/PRODUCT-SPEC.md) contains the accepted product specification.
- [`docs/adr`](docs/adr) records architectural decisions.

## Privacy and source boundary

iCloud Reminder content is accessed through EventKit. Pulse Local lists and reminders are stored in a sandboxed, versioned SwiftData store in Application Support with CloudKit synchronization disabled. Pulse has no analytics SDK or content logging. Optional Xiaozhi voice sends microphone audio to the Xiaozhi cloud during an active voice session.

The Island implementation is original code informed by the public architectural approach of boring.notch. No GPLv3 source or artwork from boring.notch is copied into this project.

The Keep Awake eye geometry, blink timing and hold-to-end interaction are adapted
from [Insomnia](https://github.com/krishhgg/Insomnia) (MIT, © 2026 Krish Garg).
The [license](TodoIsland/Resources/INSOMNIA-LICENSE.txt) is included in the app.
