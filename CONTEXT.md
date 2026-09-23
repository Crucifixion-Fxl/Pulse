# Todo Island

Todo Island is a macOS accessory application for viewing and managing unfinished reminders from iCloud and its own on-device storage in a notch-attached surface.

## Language

**Reminder**:
An item belonging to a Reminder List, with a title and optional Due Date and Priority, that can be created, edited, completed, or deleted.
_Avoid_: Todo, task

**Pending Reminder**:
A Reminder that has not been completed. Todo Island presents only Pending Reminders in its normal list views.
_Avoid_: Open todo, incomplete task

**Completed Reminder**:
A Reminder that has been marked complete. Todo Island retains Completed Reminders in their source but does not present a completed-history view.
_Avoid_: Deleted Reminder, archived task

**Reminder List**:
A user-defined collection of Reminders owned by exactly one Reminder Source.
_Avoid_: Calendar, category

**Reminder Source**:
The system that owns a Reminder List and its Reminders. Todo Island supports the iCloud Source.
_Avoid_: Account, storage mode, provider

**iCloud Source**:
The Reminder Source backed by Apple Reminders and synchronized through iCloud.
_Avoid_: Cloud mode, Apple source, local source

**Active List**:
The iCloud Reminder List the Island currently tracks. Todo Island picks it automatically; switching and managing lists happens in Apple Reminders.
_Avoid_: Selected calendar, current category

**Island**:
The top-center surface that is visually attached to a physical display notch, or shown as a top-center capsule on a display without one.
_Avoid_: Popup, widget, panel

**Collapsed Island**:
The compact Island that shows the Active List identity and Pending Reminder count when it is visible. It is the activation surface from which an Island Preview or Pinned Island opens.
_Avoid_: Closed Island, mini popup

**Collapsed Island Visibility**:
A required per-Mac user preference choosing whether the Collapsed Island remains visible or automatically hides when idle. The available choices are Always Visible and Auto-Hide; the preference is explicitly selected during Initial Setup and can be changed later in Settings.
_Avoid_: Island mode, display mode

**Always-Visible Collapsed Island**:
A Collapsed Island that remains visible whenever the Host Display's normal full-screen rules allow it.
_Avoid_: Permanent Island, fixed Island

**Auto-Hidden Collapsed Island**:
A Collapsed Island whose visual surface fades out 200 milliseconds after the pointer leaves while its invisible Activation Zone remains available. It starts hidden without flashing, transitions directly to hidden when an Island Preview or Pinned Island closes, and temporarily remains visible for recovery states or while VoiceOver is active.
_Avoid_: Disabled Island, closed Island

**Activation Zone**:
The pointer-sensitive top-center region matching the Collapsed Island's frame. While an Auto-Hidden Collapsed Island is invisible, entering the Activation Zone immediately reveals it without intercepting clicks intended for the underlying application; an interrupted edit instead restores its Pinned Island and input focus.
_Avoid_: Invisible button, hover trap, hot corner

**Initial Setup**:
The in-Island experience in which a user must explicitly choose Collapsed Island Visibility before continuing with iCloud authorization. It appears for new and upgraded installations with no recorded choice; dismissing it records nothing and leaves a temporarily visible Collapsed Island from which setup can resume.
_Avoid_: Onboarding page, setup window

**Host Display**:
The single display that currently hosts the Island. Todo Island determines it from the display containing the pointer rather than asking the user to select one.
_Avoid_: Selected Display, main monitor, primary screen

**Island Preview**:
The expanded Island, at its full size, shown while the pointer hovers over the collapsed surface. It supports pointer-based Reminder actions without taking keyboard focus and closes 500 milliseconds after the pointer leaves.
_Avoid_: Hover mode, passive popup

**Pinned Island**:
The expanded, interactive Island entered by clicking it. It takes keyboard focus and collapses 200 milliseconds after the pointer leaves an Active List. An unfinished Reminder edit is preserved, and returning the pointer reopens the Pinned Island with its editing focus restored.
_Avoid_: Focused popup

**Locked iCloud Source**:
An iCloud Source that cannot present or modify Reminders because Apple Reminders access is unavailable. The Island offers the appropriate iCloud authorization or recovery action.
_Avoid_: Locked Island, onboarding, permission page

**Due Date**:
The optional calendar date on which a Reminder becomes due. It may additionally specify a particular time.
_Avoid_: Deadline, timestamp

**Priority**:
The optional urgency assigned to a Reminder.
_Avoid_: Importance, rank

**Next Reminder**:
The first Pending Reminder in the Active List's current displayed order, whether that Reminder List uses Automatic Reminder Order or Manual Reminder Order.
_Avoid_: First task, current todo

**Automatic Reminder Order**:
The default order of Pending Reminders: overdue, today, future, and undated, followed by Due Date and time, Priority, title, and stable identity. It applies until the first Reminder Swap or after the user restores it.
_Avoid_: Manual order, arbitrary order

**Reminder Swap**:
An exchange of positions between exactly two Pending Reminders in the same Active List. Other Reminders keep their positions, and neither Reminder moves to another Reminder List.
_Avoid_: Insert, move, cross-list move

**Manual Reminder Order**:
The user-defined positions of Pending Reminders in one Reminder List after its first Reminder Swap. It applies to the iCloud Source, persists on the current Mac, appends newly encountered Reminders, and keeps positions stable when Reminder fields change until the user restores Automatic Reminder Order.
_Avoid_: Automatic order, global order

**Recurring Reminder**:
A Reminder whose repetition rule is managed in iCloud Reminders. Todo Island can present and complete it but does not change its repetition rule.
_Avoid_: Repeating task, recurrence item

**All Done**:
The state of an Active List that contains no Pending Reminders.
_Avoid_: Empty list, zero state

**Month Calendar**:
The grid of one calendar month in the expanded Island's content area, with a marker for each date that contains Reminders and the system calendar's first weekday. Adjacent-month filler days complete its fixed six-week grid.
_Avoid_: Calendar view, date picker

**Day Schedule**:
The Reminders due on the selected date, aggregated across every accessible Reminder List: Pending Reminders first, then Completed ones due that day, then Undated ones, with each row tagged by its owning Reminder List. Pending Reminders due before the current day flow into the current day until completed.
_Avoid_: Day view, daily list, agenda

**Task Input**:
The compact field beneath the Month Calendar that creates a Pending Reminder from a title, due on the selected date. Focus persists so several tasks can be added in a row.
_Avoid_: Quick Add, new-task box, composer

**Completion Heatmap**:
The trailing twenty-four week grid of squares under the Month Calendar, one per day, tinted by how many Reminders were completed that day.
_Avoid_: Contribution graph, streak chart
