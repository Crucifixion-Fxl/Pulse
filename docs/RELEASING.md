# Releasing Pulse

Prerequisites: Apple Silicon, macOS 14+, Xcode 26+, command-line developer tools,
and network access for the checksum-pinned wake sound. No signing certificate is
needed for the ad-hoc distribution path.

1. Run `make test` and inspect the actual changed behavior in the app.
2. Run `make dmg`. The app version comes from Xcode's `MARKETING_VERSION` unless
   overridden with `make dmg VERSION=1.6.0`.
3. Verify the `.sha256` in `dist`, mount the DMG and confirm `Pulse.app` plus the
   `/Applications` link. Test launch from a copied bundle.
4. Commit and push the release source, then push a matching `vMAJOR.MINOR.PATCH`
   tag. Tags are immutable release identities; use a new patch tag for fixes.
5. Check the **Release DMG** workflow and the actual Release asset list. A local
   DMG or passing build alone is not evidence that assets were published.

The release workflow takes its version from the tag, calls `make dmg`, verifies
checksum, mounted contents and signature, and uploads both files. Re-running the
same tag replaces its assets. A manual workflow dispatch packages the checked-out
branch into an Actions artifact without creating a Release.

`macos-26` is an arm64 runner; the workflow also checks `uname -m` and the packager
checks the app and helper architectures. See [GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Builds are ad-hoc signed and not notarized. The app keeps its existing bundle ID
and storage paths. Optional Xiaozhi runtime/configuration remains on the user's
Mac and is not included in the DMG. The release does not include credentials.
