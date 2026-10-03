# Todo Island

Todo Island is a native macOS 14+ menu-bar application that presents and manages pending reminders from iCloud or Todo Island's private local storage in a Dynamic Island-style surface on the display where the pointer is currently working.

## Download

Grab `TodoIsland-<version>.dmg` from [GitHub Releases](https://github.com/Crucifixion-Fxl/TodoIsland/releases/latest), drag **TodoIsland.app** to **Applications**, and launch. Builds are ad-hoc signed — if Gatekeeper complains, right-click the app → **Open**, or run:

```sh
xattr -cr /Applications/TodoIsland.app
```

## Features

- **Dynamic Island surface** — a collapsed bar in the menu-bar/notch area, a hover preview, and a pinned expanded surface, following the display the pointer works on (notch-aware on built-in displays).
- **Month calendar + completion heatmap** — a six-week grid with per-List accent dots under each date (one dot per List with pending items; gray means only completed ones remain) and a 24-week completion heatmap.
- **Liquid interactions** — the date-selection bead slides between days, the sidebar indicator flows between icons, and switching happens on hover.
- **Completion celebration** — checking a task bursts confetti at the checkmark; the row holds until it finishes, then fades while the rows below slide up.
- **Day Schedule grouped by List** — same-List tasks stay together, ordered like the Lists themselves, with overdue items greeting today.
- **Quick Add** — the Task Input creates a reminder on the selected day in any List; the first click on the hover preview pins the Island and puts the caret in the field.
- **AI usage dashboard** — today's tokens with an input/output/cache split, a fifteen-day trend, and per-subscription weekly quota cards (sample data until real providers land).
- **Music panel** — the system Now Playing (any player, e.g. NetEase Cloud Music) with artwork, progress, and controls on the left; time-synced lyrics with translations on the right, fetched from NetEase with an LRCLIB fallback.
- **List management** — iCloud Reminders plus a private local source with per-List accents, renaming, and deletion summaries.
- **Keyboard support** — arrows move the selection or shift the day, Return edits, Space completes, ⌘N focuses the Task Input, ESC dismisses.
- **Stay modes** — always visible or auto-hide with a notch activation zone; configurable in Settings.

## Open and run

1. Open `TodoIsland.xcodeproj` in Xcode 26 or newer.
2. Select the `TodoIsland` scheme and **My Mac** destination.
3. Run the application.
4. Pick the Collapsed Island stay mode in **Settings → Island** (defaults to always visible).
5. Grant Reminders access for iCloud or choose **Use Local** to work without that permission.

The checked-in project uses `Sign to Run Locally`, the bundle identifier `com.fxl.TodoIsland`, the App Sandbox, and the Reminders calendar entitlement. Configure a Personal Team or Developer ID only when distributing to another Mac.

## Build from Terminal

```sh
xcodebuild \
  -project TodoIsland.xcodeproj \
  -scheme TodoIsland \
  -configuration Debug \
  -derivedDataPath /tmp/TodoIslandDerivedData \
  build
```

## Test

```sh
xcodebuild \
  -project TodoIsland.xcodeproj \
  -scheme TodoIsland \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/TodoIslandDerivedData \
  test
```

## Documentation

- [`CONTEXT.md`](CONTEXT.md) defines the product language.
- [`docs/PRODUCT-SPEC.md`](docs/PRODUCT-SPEC.md) contains the accepted product specification.
- [`docs/adr`](docs/adr) records architectural decisions.

## Privacy and source boundary

iCloud Reminder content is accessed through EventKit. Todo Island Local lists and reminders are stored in a sandboxed, versioned SwiftData store in Application Support with CloudKit synchronization disabled. Todo Island has no backend, analytics SDK, or content logging.

The Island implementation is original code informed by the public architectural approach of boring.notch. No GPLv3 source or artwork from boring.notch is copied into this project.
