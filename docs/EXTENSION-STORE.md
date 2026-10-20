# Extension store

Open the grid button next to the weather in the expanded header. The collapsed
bar and sidebar have no store icon. The store replaces the feature area and hides the normal
status header. Its top-right close button (or Escape) restores the previous
panel. If that panel was disabled, the first enabled panel opens instead.

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
