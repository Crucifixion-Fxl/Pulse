#!/bin/sh
set -eu
resources="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
mkdir -p "$resources"
install -m 644 "${SRCROOT:?}/helpers/voice/xiaozhi_voice_bridge.py" "$resources/xiaozhi_voice_bridge.py"
install -m 755 "${SRCROOT:?}/helpers/keep-awake/KeepAwakeWatchdog.sh" "$resources/KeepAwakeWatchdog.sh"
