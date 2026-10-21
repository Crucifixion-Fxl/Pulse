# Extension marketplace UI research

Reviewed on 2026-10-21. Pulse uses a persistent Catalog sidebar and adjacent
extension details. The layout is adapted to the 760-point Island surface.

## References examined

| Reference | Evidence reviewed | Applied in Pulse |
| --- | --- | --- |
| VS Code | [Official extension guide](https://github.com/microsoft/vscode-docs/blob/main/docs/configure/extensions/extension-marketplace.md), official [list and detail screenshot](https://media.githubusercontent.com/media/microsoft/vscode-docs/main/docs/configure/extensions/images/extension-marketplace/extensions-popular.png) and [detail screenshot](https://media.githubusercontent.com/media/microsoft/vscode-docs/main/docs/configure/extensions/images/extension-marketplace/todo-highlight-details.png) | Persistent searchable list, selection highlight, adjacent extension identity and explicit management action. The screenshots are historical assets in the current documentation, used for structure rather than current styling. |
| Obsidian Community | User-provided [plugin search](https://community.obsidian.md/search?type=plugin) and [Notebook Navigator detail](https://community.obsidian.md/plugins/notebook-navigator) | Name, publisher, concise summary and primary action precede the overview. Separate identity from descriptive content. Page text was inspected; browser rendering was unavailable. |
| Vicinae | [Official repository](https://github.com/vicinaehq/vicinae), [official screenshot](https://raw.githubusercontent.com/vicinaehq/vicinae/main/extra/screenshot.png) | Compact native rows, restrained selection and stable search/footer regions. The screenshot shows its launcher, not the extension store. |
| Zed | [Extension view source](https://github.com/zed-industries/zed/blob/main/crates/extensions_ui/src/extensions_ui.rs) | Distinguish enabled/local capabilities from discovery and developer workflows. |

No third-party assets or implementations are copied into the application.

## Layout and behavior

- Opening the store replaces the feature sidebar with Catalog. The live status
  header stays in place, with the existing filled/outline store toggle.
- The 252-point sidebar contains search, Discover / Enabled, a category menu,
  five compact extension rows and page navigation. It never scrolls internally.
- The right pane immediately shows the selected extension. Selecting another
  row updates only that pane; there is no back-and-forth page navigation.
- Query, category and scope changes reset pagination. Selection falls back to
  the first visible result when necessary; empty results show a reset action.
- The detail header includes the extension icon, name, publisher, bundled
  provenance, summary and explicit Enable / Disable action. Required entries
  retain configuration guards. A missing voice runtime links to setup.
- Overview, category, identifier, update policy and source link have separate
  typographic hierarchy without nested cards or a metadata sidebar.
- Developer information uses the same detail pane and links to the real
  contribution guide. It explicitly states community publishing is unavailable.
- All routes share a stable 420-point content height and preserve the existing
  crossfade and Reduce Motion behavior. Hidden content cannot change the
  authorization page geometry or receive pointer/accessibility input.

## Scope and verification

Only existing bundled capabilities are listed. No registry, external plugin
loader, publisher accounts, fabricated ratings/downloads or publication flow
is implied. Metadata and configuration remain separate from presentation.

Tests cover search, categories, enabled-state filtering, paging, visible detail
selection, configuration persistence and guards, localization, and rendered
browse/search/detail/empty/appearance/developer states. Controller tests cover
store switching, layout, header stability and authorization isolation. These
state-driven native view tests do not constitute installed-app click-through.
