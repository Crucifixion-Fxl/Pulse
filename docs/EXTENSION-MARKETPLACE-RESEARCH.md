# Extension marketplace UI research

Reviewed on 2026-10-21. The previous screen grouped settings into boxes; it did
not let people discover an extension, search for it, or inspect its identity.
This revision treats each existing capability as a catalog entry and gives
extension browsing its own information architecture.

## References examined on GitHub

| Project | Evidence | Pattern used in Pulse |
| --- | --- | --- |
| VS Code | [Marketplace guide](https://github.com/microsoft/vscode-docs/blob/main/docs/configure/extensions/extension-marketplace.md) | Search by name/metadata, browse filtered extensions, open a details page, manage enabled state separately from discovery. |
| Eclipse Open VSX | [Card](https://github.com/eclipse-openvsx/openvsx/blob/main/webui/src/components/extension-card.tsx), [search field](https://github.com/eclipse-openvsx/openvsx/blob/main/webui/src/components/extension-searchfield.tsx), [registry](https://github.com/eclipse-openvsx/openvsx) | Clear icon/title/summary hierarchy, publisher identity, category pills, visible search focus and a clear-search action. |
| Zed | [Extension UI](https://github.com/zed-industries/zed/blob/main/crates/extensions_ui/src/extensions_ui.rs), [extension contributions](https://github.com/zed-industries/extensions) | Keep local installed capabilities separate from registry results and developer extensions; provide a distinct developer entry point. |

These are interaction and layout references, not copied implementations or
assets. Pulse remains a native SwiftUI interface tailored to a 760-point Island.

## Design decisions

- A persistent search field filters name, identifier, publisher and keywords.
  Search supports multiple terms and Chinese/English discovery keywords.
- Discover and Enabled views answer different questions. Enabled means active in
  Pulse, not downloaded. The current catalog contains bundled capabilities only.
- Five categories: All, Productivity, Status, Appearance, Voice AI.
- Two columns of four compact cards per page preserve the user's no-scrollbar
  preference. Search/filter changes reset pagination, and empty results offer
  a clear-filter action.
- Cards show icon, title, a short summary, publisher, bundled provenance and a
  real configuration action. No fabricated ratings, downloads, community
  packages, remote loading states or install success messages.
- Details retain context: back returns to the same query, category and page.
  Description, publisher, extension ID, distribution and update policy have
  separate hierarchy. Existing settings remain functional.
- The developer page explains contribution opportunities and planned publishing.
  It links to actual repository documentation. Community installation and
  publishing are explicitly unavailable in this UI-only stage.
- All routes share a stable content height. The live status header and the
  filled/outline store toggle remain unchanged. Hidden catalog content must
  never affect the authorization screen's geometry or keyboard input.

## What this does not implement

There is no package registry, third-party loader, plugin SDK, publisher account,
version upload or public installation workflow yet. Metadata and existing
capabilities are separated from the view so a future catalog can use the same
presentation structure, but that is not a claim of a supported plugin API.
