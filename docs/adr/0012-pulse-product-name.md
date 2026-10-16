# Rename the product to Pulse

Accepted 2026-10-17. The user chose **Pulse** as the name for the broader
workspace encompassing reminders, AI agents, music, clipboard and weather.

The application, localized menus/settings/permission descriptions, Xcode project,
application target, shared scheme and GitHub repository use Pulse. New builds
produce `Pulse.app` with executable `Pulse`. Existing release artifacts retain
their original filenames until a new release is published.

Keep `com.fxl.TodoIsland`, the Swift module `TodoIsland` (including SwiftData model
identity), Application Support/TodoIsland, preferences keys, helper paths, socket
names and agent-hook environment variables unchanged. These are compatibility
identities, not product branding. Source/test directory names and the test target
also stay stable. Existing reminder lists are user data and are not renamed;
only the default name for newly created local lists changes to Pulse.

The working checkout path remains unchanged to avoid disrupting active sessions.

Verification: 50 focused tests passed for local reminders, local-source app
behavior, authorization and agent-hook configuration. The built bundle has
Pulse as its display name, product name and executable, with both English and
Chinese localization checked. A signed Release was installed as
`/Applications/Pulse.app`; its executable hash matched the build. Computer
interaction confirmed the running application is named Pulse and the existing
reminder list, heatmap, agent status, quota and weather remain visible without
repeating initial setup. Login-after-reboot behavior was not exercised.
