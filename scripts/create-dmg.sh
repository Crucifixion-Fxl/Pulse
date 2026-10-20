#!/bin/sh
# Local and CI use this exact packaging path.
set -eu
app_bundle="${1:?usage: create-dmg.sh <Pulse.app> <output-directory>}"
output_dir="${2:?usage: create-dmg.sh <Pulse.app> <output-directory>}"
plist="$app_bundle/Contents/Info.plist"
[ -f "$plist" ] || { echo "Missing app: $app_bundle" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
case "$version" in
  ''|*[!0-9A-Za-z.-]*) echo 'Invalid bundle version' >&2; exit 1 ;;
esac
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
[ "$executable" = Pulse ] || { echo 'Expected Pulse executable' >&2; exit 1; }
[ "$(/usr/bin/lipo -archs "$app_bundle/Contents/MacOS/$executable")" = arm64 ] || {
  echo 'Expected an arm64-only app' >&2; exit 1;
}
for helper in AgentHookBridge MediaRemoteHelper.dylib; do
  /usr/bin/lipo -verify_arch arm64 "$app_bundle/Contents/Resources/$helper"
done
/usr/bin/codesign --verify --deep --strict "$app_bundle"
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
staging_dir=$(/usr/bin/mktemp -d /private/tmp/Pulse-dmg.XXXXXX)
trap '/bin/rm -rf "$staging_dir"' EXIT HUP INT TERM
/usr/bin/ditto "$app_bundle" "$staging_dir/Pulse.app"
/bin/ln -s /Applications "$staging_dir/Applications"
name="Pulse-$version-arm64.dmg"
/usr/bin/hdiutil create -volname "Pulse $version" -srcfolder "$staging_dir" -ov -format UDZO "$output_dir/$name"
# Relative filenames make `shasum -c` work after downloading both assets.
(cd "$output_dir" && /usr/bin/shasum -a 256 "$name" > "$name.sha256")
echo "Created $output_dir/$name and $name.sha256"
