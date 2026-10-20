#!/bin/zsh
# Rebuilds the agent hook bridge after editing helpers/AgentHookBridge/main.swift.
# The compiled binary is committed at Pulse/Resources/Helpers/AgentHookBridge
# so the app bundle picks it up as a resource (the file-synchronized project
# has no separate helper target); AgentHookConfigInstaller stages it from there
# into ~/Library/Application Support/TodoIsland/agent-bridge. Run from the repo
# root:
#   scripts/build-agent-bridge.sh
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc -swift-version 5 -O \
  helpers/AgentHookBridge/main.swift \
  -o Pulse/Resources/Helpers/AgentHookBridge
codesign --force --sign - Pulse/Resources/Helpers/AgentHookBridge
echo "built Pulse/Resources/Helpers/AgentHookBridge"
