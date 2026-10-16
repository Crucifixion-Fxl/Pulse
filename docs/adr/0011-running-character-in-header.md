# Removed: decorative anime character in the expanded header

Status: removed at the user's request on 2026-10-17. The daily character was
judged not useful. The earlier implementation and provenance remain in Git history.

The header now places weather directly beside the existing Codex bot, with an
8pt gap. Both native compositor and SwiftUI fallback layouts use the same spacing.
No character slot, daily rotation timer, artwork decoder, character assets or
export tooling remain in the application. Weather interaction and the existing
quota/bot animations retain their behavior.

Verification on 2026-10-17: 13 focused tests passed (5 weather, 8 island
transitions). A clean signed Release was installed and matched the build's
executable hash. The installed bundle contains no character resources. Computer
interaction confirmed the expanded header has no anime character, weather is
right-aligned beside the bot, and the weather popover still opens/closes.
