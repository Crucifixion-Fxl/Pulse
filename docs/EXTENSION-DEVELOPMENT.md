# Contributing extensions to Pulse

Pulse currently ships a built-in extension catalog. Community package publishing,
a public plugin SDK and third-party installation are not available yet. The
Developers page in the app introduces that future direction without accepting
uploads or claiming that packages can already be published.

## What developers can contribute today

Contributions are reviewed as source changes in this repository:

- Sidebar features and header status items.
- Bot appearances and voice-wake effects.
- Voice integrations implementing `VoiceSessionProvider` and registered in
  `VoiceProviderRegistry`.

`Pulse/Domain/ExtensionCatalog.swift` describes the built-in catalog, including
stable IDs, titles, categories, search keywords and the corresponding existing
capability. `ExtensionPreferences` persists enabled features and selected styles.
These are internal application interfaces, not a stable third-party SDK.

Add English and Simplified Chinese strings for the extension summary and detail.
Keep metadata factual: declare the real publisher, setup requirements and source.
Do not invent marketplace metrics or present a configuration switch as a download.

Test searching, filters, enable/disable or selection, persistence, and the actual
rendered interface. Preserve the last enabled sidebar feature and the required
bot status item. See [Agent Guidelines](../AGENTS.md) for repository requirements.

## Planned community flow

The intended UI supports a publisher identity, an extension listing with a stable
ID, a details page and versioned releases. A registry, runtime contract, package
validation and publication workflow must be designed and implemented before any
external package can be installed or published. No date or compatibility promise
is made by the current interface.
