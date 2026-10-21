# Extension store

Open the grid button next to the weather in the expanded header. The collapsed
bar and sidebar have no store icon. The store replaces only the feature area;
the status header stays visible in place. The grid icon becomes filled while
selected. Clicking the same icon again (or Escape) restores the previous
panel. If that panel was disabled, the first enabled panel opens instead.
Weather uses its natural text width, with 6pt gaps to Keep Awake and the store.
The store crossfades while the panel expands to its measured content height,
with a continuously scrolling extension list. The underlying panel stays mounted.
Reduce Motion switches the content immediately;
hidden panels do not receive pointer or accessibility input.
The store is hidden and cannot be opened from the reminder authorization screen.

While the store is open, the feature sidebar is replaced by a persistent Catalog
sidebar with search, a category icon rail to the left of the results,
Discover / Enabled views. Selecting a row updates the detail pane on the right. Filtering selects the first matching result if the previous selection no longer
matches, and resets list scroll position. Empty results clear the detail pane and offer a filter reset.
The category rail stays fixed while the list scrolls. There are no page controls,
scrollbar indicators or developer icon. The current
entries are bundled capabilities, not downloadable community plugins. Search
and navigation preserve the existing configuration behavior. See the
[UI research](EXTENSION-MARKETPLACE-RESEARCH.md) and
[contribution guide](EXTENSION-DEVELOPMENT.md).

- Reminders, Agents, Music and Clipboard can be enabled independently. The last
  enabled bar cannot be disabled.
- Main quota, other quotas, weather and Keep Awake can be hidden. The bot stays
  enabled so every configuration retains a visible status item. Compact mode
  keeps its existing quota/bot layout; extra status items appear on expansion.
- Orb, Robot and Cat share the same activity, hover, playback and alert behavior.
- Black hole and Aurora share hold/release/cancel, voice amplitude and Reduce
  Motion behavior. A changed effect applies to the next wake.
- Voice providers own microphone/playback and report lifecycle, TTS state,
  amplitude and errors via `VoiceSessionProvider`. The store reads
  `VoiceProviderRegistry.providers`; adding a descriptor and implementation does
  not require editing the store UI. Xiaozhi is the initial provider. Missing
  runtime leaves the visual effect active and displays a setup hint; the store
  links to installation and binding instructions.

Preferences are stored in the existing application's UserDefaults under
`pulse-extension-preferences-v1`. Unknown bar/status IDs are discarded; an empty
bar list recovers to Reminders. Downloads and third-party plugins are out of
scope for this first built-in catalog.
