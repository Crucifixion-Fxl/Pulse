#!/bin/sh
set -eu

# Keep licensed audio out of the source tree. Cache only in Xcode DerivedData.
cue_cache="${DERIVED_FILE_DIR:?}/voice-wake-expand.wav"
cue_output="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/voice-wake-expand.wav"
cue_sha256="45c29c247750296c9b7c83e2442597d6a300408504fe31745ad1bb4cc1ff7ce1"

verify_cue() {
  [ -f "$1" ] && [ "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" = "$cue_sha256" ]
}

if ! verify_cue "$cue_cache"; then
  /bin/mkdir -p "$(/usr/bin/dirname "$cue_cache")"
  cue_temp="$(/usr/bin/mktemp "${cue_cache}.XXXXXX")"
  trap '/bin/rm -f "$cue_temp"' EXIT HUP INT TERM
  /usr/bin/curl --fail --location --silent --show-error --retry 2 \
    --connect-timeout 10 --max-time 60 \
    'https://assets.mixkit.co/active_storage/sfx/913/913.wav' -o "$cue_temp"
  if ! verify_cue "$cue_temp"; then
    echo 'error: Wake sound checksum mismatch; refusing to bundle changed audio.' >&2
    exit 1
  fi
  /bin/mv "$cue_temp" "$cue_cache"
fi
/bin/mkdir -p "$(/usr/bin/dirname "$cue_output")"
/usr/bin/install -m 644 "$cue_cache" "$cue_output"
