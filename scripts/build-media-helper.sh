#!/bin/zsh
# Rebuilds the MediaRemote helper dylib after editing helpers/MediaRemoteHelper.swift.
# The compiled dylib is committed at Pulse/Resources/Helpers/MediaRemoteHelper.dylib
# so the app bundle picks it up as a resource (the file-synchronized project
# has no separate helper target). Run from the repo root:
#   scripts/build-media-helper.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc -emit-library -swift-version 5 -O -target arm64-apple-macos14.0 \
  helpers/MediaRemoteHelper.swift \
  -o Pulse/Resources/Helpers/MediaRemoteHelper.dylib
codesign --force --sign - Pulse/Resources/Helpers/MediaRemoteHelper.dylib
echo "built Pulse/Resources/Helpers/MediaRemoteHelper.dylib"
