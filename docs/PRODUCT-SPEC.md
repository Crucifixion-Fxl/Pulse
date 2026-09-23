# Todo Island Product Specification

## Product

Todo Island is a personal macOS accessory application that presents and manages Reminders from the iCloud Source in a Dynamic Island-style surface attached to the top center of one automatically determined Host Display.

- Product name: `Todo Island`
- Bundle identifier: `com.fxl.TodoIsland`
- Minimum system: macOS 14
- Initial delivery: personal, local build signed with `Sign to Run Locally`
- Languages: English and Simplified Chinese, selected from the system locale

The canonical product vocabulary lives in [`CONTEXT.md`](../CONTEXT.md). Architectural decisions live in [`docs/adr`](./adr).

## Product Boundaries

Todo Island reads and writes iCloud Reminders through Apple's public EventKit APIs. It requests full Reminders access because Apple does not expose a read-only authorization level. Todo Island never uploads, analyzes, or writes Reminder content to logs; Apple Reminders remains responsible for iCloud synchronization of the iCloud Source.

The product:

- is backed by the iCloud Source alone;
- presents Pending Reminders, plus the Completed Reminders due on the Day Schedule's selected date;
- tracks the Active iCloud Reminder List automatically; switching, creating, renaming, and deleting lists happens in Apple Reminders;
- creates, edits, completes, and deletes Reminders;
- edits title, optional Due Date and optional time, and Priority;
- can present and complete existing Recurring Reminders but cannot edit their repetition rules;
- requires an explicit per-Mac choice between an Always-Visible and Auto-Hidden Collapsed Island during Initial Setup, and allows that choice to be changed later in Settings;
- restores the last valid Active List and otherwise prefers iCloud; and
- does not move or copy Reminders between lists or sources.

Reminder Lists are managed entirely in Apple Reminders and are not manually reordered.

The first version does not include search, filters, notes, URLs, attachments, locations, tags, subtasks, recurrence editing, notifications, or due-date alerts. A Local Reminder's Due Date affects display and ordering but does not schedule a macOS notification.

## Reminder Ordering

EventKit does not expose the manual ordering used by Apple Reminders. Todo Island therefore does not support drag reordering and computes a stable action order:

1. overdue;
2. due today;
3. due in the future; and
4. no Due Date.

Within those groups, Reminders are ordered by due time, Priority, and title. The first item is the Next Reminder.

## Island States

### Collapsed Island

On a display with a physical notch, the Collapsed Island keeps the measured safe-area height and reserves the physical notch width as an empty center. Two equal 72-point side regions display the source glyph and truncated Active List name on the left and Pending Reminder count on the right; no text is drawn behind the camera housing. Its activation region matches the entire surface. On a display without a notch, a centered black capsule shows the source glyph, Active List name, and Pending Reminder count. Expanded surfaces have a full-width top lip with mirrored concave shoulders flowing inward into the side edges, and rounded bottom corners.

Collapsed Island Visibility is a required per-Mac preference with no preselected value during Initial Setup:

- **Always Visible** keeps the Collapsed Island visible whenever its normal Host Display and full-screen rules permit it.
- **Auto-Hide** completely hides the visual surface while preserving an Activation Zone matching the Collapsed Island's exact frame. The invisible Activation Zone observes pointer position without intercepting clicks intended for the underlying application.

For an ordinary Active List, including All Done, Auto-Hide waits 200 milliseconds after the pointer leaves and then fades the Collapsed Island out over approximately 160 milliseconds. Entering its Activation Zone immediately fades it in over approximately 160 milliseconds; remaining there for the existing 200-millisecond dwell continues into an Island Preview. Reduce Motion replaces these fades with immediate visibility changes.

Initial Setup, Locked iCloud Source, and no-list recovery remain visible. Auto-Hide is also temporarily suppressed while VoiceOver is active without changing the saved preference. Background Reminder changes never reveal a hidden Island; current content appears the next time it opens.

### Island Preview

Hovering for 200 milliseconds over the Collapsed Island expands an Island Preview without taking focus from the current application. The Preview shows the same full-size Month Calendar and Day Schedule as the Pinned Island and supports pointer-based actions such as completing a Reminder. The Preview closes 500 milliseconds after the pointer leaves. With Auto-Hide selected, it transitions directly to a hidden Collapsed Island without briefly rendering the collapsed surface.

The Preview opens at the nominal expanded size of 760 by 420 points, adapting down for shorter displays, so the complete calendar and Day Schedule appear immediately; pinning only adds keyboard focus and never resizes the surface.

### Pinned Island

Clicking the Island opens or converts it to a Pinned Island. The Pinned Island can become key and accepts keyboard input. When it has an Active List, it collapses 200 milliseconds after the pointer leaves; returning within that interval cancels the collapse. With Auto-Hide selected, it transitions directly to a hidden Collapsed Island without briefly rendering the collapsed surface. If a Reminder editor is unfinished, the collapse preserves its draft, and returning to the Activation Zone immediately reopens the Pinned Island and restores the field focus. Locked and no-list recovery states remain open. The header has no separate close button.

- `Escape` cancels an active edit or closes the Island.
- Clicking outside closes the Island.
- Enter or leaving an edit field saves its value.
- Escape while editing discards unsaved field changes.

The nominal expanded size is 760 by 420 points, with adaptation for smaller displays. Content scrolls instead of growing the Island without limit.

## Expanded Layout

The expanded Island contains:

1. a left sidebar of feature destinations. The first destination is Reminders; future features add a sidebar item and their own content without changing the Island shell;
2. the Reminders content area as a Month Calendar on the left and the selected date's Day Schedule on the right in both expanded states; the Day Schedule keeps a native macOS scroll container with trackpad inertia, mouse-wheel scrolling, and a clipped viewport that keeps rows inside the content area; and
3. ReUI-style dark card rows containing completion control, title, due state, list tags, and Priority badges, with animated hover and selection highlights and subtle fades at the viewport edges, plus a compact in-Island editor for the selected Reminder.

There is no header row and no Quick Add input in the expanded Island; the Active List's Pending count appears only on the Collapsed Island. The sidebar uses a 28-point rail with white 12.5-point icons, no visible text, and a white hover glow. Tooltips and accessibility labels identify each feature. Expanded content uses compact typography (14-point Reminder titles) and halved spacing; content clears the concave side shoulders of the surface. The Collapsed Island retains its 18-point accented count ring.

### Month Calendar and Day Schedule

The Month Calendar shows one month of the system calendar as a fixed six-week grid with adjacent-month filler days and weekday initials beginning at the calendar's first weekday. The selected date is filled with the accent color, today is ringed, and each date carries a dot when it contains Reminders — accented while pending ones remain and gray once only Completed ones do. Clicking any date — including an adjacent-month filler day — or pressing the left or right arrow keys selects that date, carrying the grid into the surrounding month.

The Day Schedule shows the Reminders due on the selected date across every accessible Reminder List from both Sources, so no per-list switching is required to see a whole day. The pane has no day title or section headers: the calendar already names the selected date. Pending Reminders appear first in Automatic Reminder Order within the day (timed Reminders ordered by time), followed by Completed Reminders due that day with muted struck-through titles, then undated Pending Reminders, which carry an Undated tag. Pending Reminders due before the current day flow forward onto today's schedule — shown with their original date in red — and keep flowing each day until they are completed; browsing any other date shows only that date's own Reminders. Beneath the calendar, a per-list progress summary shows each list's completed and total counts with a thin accent progress bar that turns green when the list is done for the day. The summary covers the selected date's Reminders plus the Undated pool: undated Pending Reminders count as remaining work, and undated Reminders completed today count as done, so the bars move even for lists that never use Due Dates. Each row is tagged with its owning Reminder List's name and accent color, shows its due time when one is set, and supports completion, reopening a Completed Reminder, selection, and double-click editing in the compact editor. The schedule keeps the native scroll container with clipped viewport and edge fades, and an empty selected date shows a short all-clear state.

Reminders without a Due Date always appear in the Undated section of the Day Schedule, whatever list they belong to.

The last valid Active List is restored on launch. If it no longer exists, the app falls back to the first available iCloud Reminder List. Lists are ordered alphabetically inside each source group.

Todo Island does not manage lists: creating, renaming, deleting, and switching Reminder Lists happen in Apple Reminders. Externally created duplicate iCloud names remain supported and are distinguished by stable identity, source, and color.

When neither the selected date nor the Undated section has any Reminder, the Day Schedule shows a short all-clear state.

Completing a Reminder immediately changes its leading circle to a green checkmark, then removes it from the visible Pending Reminders after 200 milliseconds. Deleting a Reminder requires confirmation. Completed Reminders remain in their Reminder List; the Day Schedule shows those due on the selected date in its Completed section, where they can be reopened, and no other completed-history view exists.

## Keyboard Operations

- `Up Arrow` and `Down Arrow`: change the selected Reminder
- `Left Arrow` and `Right Arrow`: select the previous or next date in the Pinned Island
- `Return`: edit the selected Reminder
- `Space`: complete the selected Reminder
- `Delete`: request deletion of the selected Reminder
- `Escape`: cancel editing or close the Pinned Island

Every operation also has a mouse-accessible equivalent.

## Appearance

The Island uses a black surface, white primary text, and gray secondary text. The Active List's Reminders color is the interaction accent. Overdue dates use red.

The application icon is an original black notch silhouette with a colored checkmark. The implementation must not copy boring.notch artwork or source code.

When the Island grows between presentation states, the surface follows a damped spring pinned at the top edge and horizontal center: it overshoots its final size and settles with a small elastic wobble. Collapsing stays critically damped without overshoot. Reduce Motion keeps immediate state changes.

Todo Island supports VoiceOver, keyboard navigation, increased contrast where applicable, and Reduce Motion. Reduce Motion replaces geometry-heavy spring transitions with restrained fades or immediate state changes. VoiceOver temporarily keeps the Collapsed Island visible even when Auto-Hide is selected; the menu-bar Open Island action remains an accessible path and no new global shortcut is introduced.

## Displays and Full Screen

Only the automatically determined Host Display hosts an Island. The application does not ask the user to select a display. A Host Display with a physical notch uses the notch-attached layout; one without a notch uses the top-center capsule fallback.

Whenever Host Display detection runs, the display containing the mouse pointer is selected. Whether that display has a physical notch affects the Island geometry and full-screen behavior, not its eligibility to become the Host Display.

While the Island is collapsed, the pointer must remain on a different display for approximately 350 milliseconds before that display becomes the Host Display. Brief boundary crossings do not move the Island. An Island Preview or Pinned Island locks its Host Display until it collapses, at which point detection resumes.

An Auto-Hidden Collapsed Island's Activation Zone follows the same Host Display selection and migration rules. It does not create a second Island or a fixed trigger on the built-in display.

If the Host Display is disconnected, the Island immediately moves to the pointer's remaining display. This forced migration preserves the current presentation state, editing draft, and keyboard focus.

A normal collapsed Host Display change uses a brief fade out on the old display and fade in on the new display. With Reduce Motion enabled, the Island changes displays immediately.

- On a physical-notch display, the Island remains available in full-screen spaces.
- On a display without a notch, the collapsed fallback capsule hides while an application is full screen. That display remains the Host Display, and neither the capsule nor an Auto-Hide Activation Zone is available until full screen ends.
- A first-launch authorization Island or a Pinned Island explicitly opened by the user can appear above a full-screen application. When it collapses, the normal hiding rule resumes.
- Screen attachment, removal, resolution changes, and Host Display changes recalculate the Island geometry.

## Application Surfaces

Todo Island is an accessory application with no Dock icon. Its menu-bar icon opens a menu containing:

- Open Island;
- Settings;
- Launch at Login;
- About; and
- Quit.

Settings contains:

- Reminders authorization status and the appropriate in-Island authorization or Open System Settings action;
- a Collapsed Island segmented control labeled `Always Visible` and `Auto-Hide` in English and `常驻显示` and `自动隐藏` in Simplified Chinese;
- Launch at Login;
- full-screen hiding behavior;
- About; and
- Quit.

Launch at Login is disabled by default.

## In-Island Authorization

Authorization controls the iCloud Source.

On first launch, Todo Island opens a Pinned Initial Setup Island. Its Collapsed Island Visibility section presents two unselected cards: `Always Visible — Keep the Collapsed Island visible.` and `Auto-Hide — Hide it when the pointer leaves; move to the top center to reveal it.` In Simplified Chinese they read `常驻显示：折叠灵动岛始终保持可见` and `自动隐藏：鼠标离开后隐藏，移到屏幕顶部中央即可唤醒`. The user must select one before the Allow Access action becomes available.

After the visibility choice, Initial Setup explains why full Reminders access is required for iCloud, states that Reminder content stays on the device, and offers the Allow Access action. The application does not use a separate setup window. The macOS authorization prompt remains a system-owned surface triggered by Allow Access.

An existing installation with no saved Collapsed Island Visibility choice presents the required choice once after upgrading. If its current source and authorization are already usable, only the new visibility choice is shown. If recovery is required, its existing recovery controls resume immediately after the choice. The app does not repeat previously completed source setup.

The visibility choice is saved independently from Reminder Source and authorization. If access is granted, the same Pinned Island immediately replaces its authorization content with the Active List and its Reminders. If access is denied or restricted, the visibility choice remains saved, only the iCloud Source is locked, and Open System Settings remains available. Resetting authorization or reauthorizing does not ask for the visibility choice again. The application does not repeatedly prompt.

The user may dismiss Initial Setup with Escape or by clicking outside it before choosing visibility. No choice is recorded; the Collapsed Island remains temporarily visible and reopens Initial Setup on the next interaction or launch. Dismissing it does not quit the application.

After Auto-Hide has been selected, an ordinary subsequent launch starts with the Collapsed Island already hidden and does not flash it first. If the pointer is already within the Activation Zone, it is revealed immediately. The menu-bar Open Island action always opens a Pinned Island; no global keyboard shortcut is added.

Changing Collapsed Island Visibility in Settings saves and applies it immediately. Selecting Always Visible reveals a hidden Collapsed Island immediately. Selecting Auto-Hide while the pointer is outside waits 200 milliseconds before hiding, but never dismisses an Island Preview or Pinned Island currently in use; the new preference takes effect when that Island next collapses.

After launch, the app restores the last valid Active List. If it is unavailable or none has been saved, the app automatically uses the first available iCloud Reminder List.

If no iCloud Reminder List is available, the empty state offers New iCloud List, Open Reminders, and Check Again actions.

If access is revoked while Todo Island is running and an iCloud list is active, the Island preserves its current presentation state and replaces only the iCloud content with the locked state. The Island does not expand itself or take focus solely because authorization changed.

If authorization is revoked while editing an iCloud Reminder, the unsaved draft remains in memory but cannot be saved. If access returns, Todo Island refetches the Reminder, validates that the draft still has a valid target, and lets the user explicitly save it. Authorization restoration never writes a draft automatically.

The app uses:

- `requestFullAccessToReminders()` on macOS 14 or newer;
- `NSRemindersFullAccessUsageDescription`; and
- the sandbox calendar personal-information entitlement.

Public EventKit does not expose a strict iCloud-only flag. Todo Island therefore keeps its current best-effort match for the iCloud CalDAV source and does not silently include Google, Exchange, or other accounts. If no strict match is available, the iCloud Source presents its normal no-list and recovery actions rather than broadening the source boundary.

## Data Refresh and Identity

A source-aware Reminder repository presents a shared application interface over a long-lived EventKit store for iCloud and app-owned persistence for Local. Both backends produce the same immutable presentation snapshots; fetched EventKit objects and persistence models are not retained as UI state.

When EventKit reports a store change, the app coalesces notifications and refetches iCloud lists and, when applicable, Pending Reminders for the Active List. It also refetches iCloud after authorization changes and when the application becomes active. Local mutations update Local snapshots directly.

EventKit identifiers are treated as recoverable references rather than permanent identities. Missing identifiers result in refetch and fallback behavior, not corrupted local state.

Application identities are namespaced by Reminder Source so identical raw identifiers cannot collide across backends. Local lists and Reminders use app-generated persistent UUIDs, and the persisted Active List reference includes its source. Persistence models are always mapped to domain snapshots before reaching UI state.

Local data is stored in a versioned SwiftData store at an app-owned URL in Todo Island's sandboxed Application Support container. CloudKit synchronization is explicitly disabled. The data can participate in normal user backup such as Time Machine, but the initial Local Source does not include import, export, or a separate backup workflow.

If the Local store cannot initialize or migrate, only the Local Source becomes unavailable. Todo Island preserves the original store, keeps iCloud operational, and presents Retry and Show in Finder recovery actions. It never silently resets the store. The initial product has no bulk Delete All Local Data action; users delete Local Reminder Lists individually.

## Architecture

- Swift 6
- AppKit window, menu-bar, activation, display, and focus coordination
- SwiftUI Island, authorization, editor, and settings views
- source-aware Reminder repository over EventKit and app-owned Local persistence
- versioned SwiftData persistence for Local with injectable in-memory test storage
- ServiceManagement launch-at-login integration
- Swift Testing or XCTest for deterministic logic
- no third-party runtime dependencies
- no private Reminders database or private framework integration

The Island shell is an independent implementation informed by boring.notch's public architectural approach: a transparent borderless panel at the top center, explicit display geometry, a custom black shape, and animated collapsed and expanded states. GPLv3 source from boring.notch is not copied.

## First-Version Definition of Done

- The Xcode project opens and builds without errors.
- A locally signed `.app` launches on the current Mac.
- Unit tests cover Reminder ordering, presentation mapping, Island state transitions, and display geometry.
- The application has no Dock icon and its menu-bar entry remains usable when the Island cannot be shown.
- In-Island authorization correctly handles not-determined, full-access, denied, and restricted iCloud states.
- The app reads and performs the agreed CRUD operations against real iCloud Reminders and its own Local Reminders.
- Local list creation, renaming, deletion, first-use Default Local List creation, and stable automatic colors work without Reminders permission.
- Local completion retains hidden Completed Reminders, and Local list deletion confirms both Pending and Completed counts.
- A Local persistence failure leaves iCloud usable and never silently destroys the Local store.
- Compact editing, 200-millisecond completion feedback, and confirmed deletion work.
- External Reminders changes appear after EventKit change notifications.
- Collapsed, Preview, and Pinned states follow the agreed focus behavior and shortcuts.
- Initial Setup requires an explicit visibility choice, upgrade prompting preserves existing source state, and Settings can change the per-Mac choice.
- Auto-Hide preserves click-through Activation Zone behavior, exact exit and reveal timing, draft restoration, recovery-state visibility, and VoiceOver and Reduce Motion exceptions.
- Physical-notch and no-notch layouts are manually checked on available displays.
- Full-screen and display-configuration behavior is manually checked.
- English and Simplified Chinese layouts are checked for truncation.
- VoiceOver labels and Reduce Motion behavior are checked.
- All automated tests pass.

## Planned Implementation Sequence

1. Create the native Xcode project, targets, entitlements, local signing, and test harness.
2. Implement source-aware domain snapshots, automatic ordering, EventKit and Local mapping, and unit tests.
3. Implement Local persistence plus iCloud authorization, list filtering, CRUD, refresh, and failure states.
4. Implement the AppKit Island window, display geometry, state and focus coordination.
5. Implement the SwiftUI collapsed, Preview, Pinned, calendar, and editor surfaces.
6. Implement menu-bar, in-Island authorization, settings, launch at login, localization, accessibility, and artwork.
7. Build, run automated tests, and perform real EventKit and display acceptance checks.
