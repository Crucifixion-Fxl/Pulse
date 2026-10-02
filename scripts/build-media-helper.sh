#!/bin/zsh
# Rebuilds the MediaRemote helper dylib after editing helpers/MediaRemoteHelper.swift.
# The compiled dylib is committed at TodoIsland/Resources/MediaRemoteHelper.dylib
# so the app bundle picks it up as a resource (the file-synchronized project
# has no separate helper target). Run from the repo root:
#   scripts/build-media-helper.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc -swift-version 5 -O \
  helpers/MediaRemoteHelper.swift \
  -o TodoIsland/Resources/MediaRemoteHelper.dylib
codesign --force --sign - TodoIsland/Resources/MediaRemoteHelper.dylib
echo "built TodoIsland/Resources/MediaRemoteHelper.dylib"
