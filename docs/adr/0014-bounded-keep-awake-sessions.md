# Bounded keep-awake sessions

Status: accepted

## User behavior

The expanded Island places Insomnia's animated eye immediately left of weather.
Clicking it reveals inline Days / Hours / Minutes pills with staggered motion.
Enter or the return glyph starts the chosen duration (1–1,440 minutes; empty
fields default to one hour). Weather contracts to its icon while editing so the
fields stay clear of the physical camera housing. Escape or the eye retracts
input. Active sessions show a monospaced countdown and a 0.6-second hold-to-end
ring. Right-click opens status actions. Starting requires macOS administrator authorization
for that session. The eye opens during startup; the countdown appears only
after the system override has been read back successfully.

A session prevents system sleep, including lid-close sleep, with
`pmset -a disablesleep 1`. It ends at the deadline, on explicit End, when Pulse
exits, or at 10% battery. Pulse also requests an end on critical thermal state
while its process is running. Ending restores `disablesleep 0`; it does not
force immediate sleep or terminate running agents. A popover keeps the Island
open while the pointer moves into its controls or authorization is in progress.

## Recovery and privilege boundary

The design is informed by [Insomnia](https://github.com/krishhgg/Insomnia)'s
bounded sessions and recovery journal. The eye geometry, blink timing and hold-ring interaction are adapted from its
MIT-licensed UI; the license is shipped in `Resources/INSOMNIA-LICENSE.txt`.
The power service is an independent implementation focused on the three requested behaviors; it does not import its application
freezing, audio, brightness, low-power, hotspot or tmux integrations.

Each start authenticates a fixed installer via the system AppleScript
administrator authorization dialog. It installs a root-owned shell watchdog
and launchd definition. It does **not** add a sudoers rule or retain credentials.
No executable code is loaded from a user-writable path after authorization.

The root state is stored under `/Library/Application Support/Pulse/KeepAwake-UID/`:

- `watchdog.sh`: the authorized copy of the bundled watchdog.
- `config`: deadline, owner PID/UID/start time, and a private request-file path.
- `status`: read-only progress/result for the app.
- `owned`: journal written before changing the persistent system sleep flag.

`/Library/LaunchDaemons/com.fxl.Pulse.KeepAwake.UID.plist` runs the watchdog at
load and every five seconds. It survives an app crash and runs after reboot to
restore stale state. A user-writable request can only revoke the fixed lease;
it cannot extend its deadline or supply executable commands. PID start time and
UID distinguish the owning process from a reused PID.

The watchdog refuses to start if another tool already disabled sleep. After
setting the flag, it waits five seconds and reads it back: some macOS versions
revert it even after `pmset` exits successfully. The UI never treats command
success alone as an active session.

A successful end verifies that sleep is enabled, clears ownership, removes the
launch definition and unloads the job. Root-owned state remains as a diagnostic
record, overwritten on the next authorized start. A failed restore retains the
journal and job for retry. Missing/unreadable state produces a recovery warning,
not a success state. Quit/crash detection and deadline restoration can take a
few seconds; this is not a real-time safety guarantee.

## Limits and troubleshooting

- Use a stable ventilated surface, not a closed bag. Battery checks do not replace thermal protection.
- Duration starts when authorization finishes. Cancelling authorization starts no session.
- Power settings are global. Avoid running multiple tools that change `disablesleep` during a session.
- The feature does not manage display/keyboard brightness; it only controls system sleep.
- If recovery reports failure, inspect `status` and `pmset -g`. The system job keeps retrying. To recover manually, run `sudo pmset -a disablesleep 0`, then confirm `SleepDisabled 0` in `pmset -g`.
- An incompatible/pre-existing helper directory with symlinks, non-root ownership, writable ancestors or ACLs is refused before privileged writes.
- The helper does not use a hardware temperature probe. Thermal ending is observed through `ProcessInfo.thermalState` while Pulse runs; a missing owner process causes the helper to restore sleep independently.

## Verification

`KeepAwakeTests` exercises state transitions, deadlines, error handling, quoting,
and header placement. `scripts/test-keep-awake-watchdog.py` runs the shipped
shell source with fake power/process/launchd commands in temporary directories;
it cannot mutate live power settings. These tests cover restore failure/retry,
owner death/PID reuse, conflicting overrides, rejected writes and early stop.

Real-device acceptance separately requires administrator authorization, checking
`SleepDisabled` on start and end, and a physical lid-close test. Simulation and
compilation do not establish hardware behavior.

Upstream UI reference: `7ca604dd8a634c6f996ee2e8ce6ca5e9175f10b2`.

### Local acceptance — 2026-10-18

- Installed and code-signature-verified Release build: larger eye, inline duration
  pills, weather contraction, active countdown and clean idle state without an
  information icon were observed through native UI automation.
- A user-authorized one-minute session reached `active` with `SleepDisabled 1`,
  then `expired` with `SleepDisabled 0`; its ownership journal and launch
  definition were removed. A locale mismatch in process start-time comparison
  found during this check was fixed by using `LC_ALL=C` in both privileged paths.
- XCTest: 286 tests, one existing skip, zero failures. Watchdog harness: 11 passed.
- Physical lid closure, reboot recovery and the physical hold gesture were not
  exercised on this machine; their hardware behavior remains a separate check.
