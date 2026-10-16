# Show local weather in the expanded header

The right wing shows a compact weather symbol, Celsius temperature, city and
condition beside the existing bot. A click opens the day's high/low, observation
time, refresh action and Open-Meteo attribution. It uses the existing native
header's position spring and delayed fade, keeping weather work off the opening
animation path.

Core Location requests a single city-scale fix after the header expands. Both
reverse geocoding and Open-Meteo receive coordinates rounded to 0.1 degrees.
Coordinates are not persisted; only the last weather snapshot and city are
cached. Refreshes are coalesced and limited to every 15 minutes, with a two-minute
retry interval after failure. Old results are marked as awaiting an update;
denied location access clears cached weather and offers Location Services settings.

Architectural references, independently implemented without source copying:

- [MenuClock](https://github.com/satsdisco/MenuClock): compact SF Symbol and
  temperature presentation, Open-Meteo, 15-minute cache.
- [WeatherDock](https://github.com/AlexStepanischev/WeatherDock): current-location
  weather, a detailed popover, bounded refreshes on opening.
- [Open-Meteo API](https://open-meteo.com/en/docs): current temperature, WMO weather
  code, day/night and daily high/low. Data attribution links to Open-Meteo in the UI.

Acceptance requires real location authorization and a live weather response in
the installed app, plus isolated decoding, cache, failure and header-routing tests.
Do not substitute sample weather when location or networking is unavailable.
