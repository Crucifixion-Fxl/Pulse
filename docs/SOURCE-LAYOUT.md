# Source layout

- `Pulse/App`: application lifecycle, shared observable state and feature stores.
- `Pulse/Domain`: models and pure policies, including agent events and reducers.
- `Pulse/Data`: reminder persistence backends.
- `Pulse/Services`: I/O, agent transport and input event monitors.
- `Pulse/UI`: SwiftUI features grouped by panel; `UI/Wake` owns the wake renderer.
- `Pulse/Window`: AppKit window routing, sizing and transition composition.
- `Pulse/Resources/Helpers`: bundled compiled helpers.
- `Pulse/Resources/Licenses`: third-party notices shipped with the app.
- `PulseTests`: regression tests.
- `config`, `helpers`, `scripts`, `artwork`, `docs`: lowercase auxiliary directories.

Runtime script sources live in `helpers/voice` and `helpers/keep-awake` and are
copied into the app's resource root by the Xcode build phase. Swift helper build
scripts update the bundled executables in `Pulse/Resources/Helpers`.

The bundle identifier `com.fxl.TodoIsland`, existing UserDefaults keys, local
SwiftData store and agent integration paths remain stable. Directory and module
names do not migrate or reset existing user data.
