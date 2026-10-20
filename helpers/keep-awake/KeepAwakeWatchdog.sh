#!/bin/sh
# Pulse's bounded, root-owned sleep lease. Invoked by launchd, never by sourcing
# a user-writable file. Only the fixed state directory is written as root.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# Match process identity across the user locale and launchd environment.
LC_ALL=C
export LC_ALL
base=$1
label=$2
plist="/Library/LaunchDaemons/$label.plist"
status() { printf '%s\n' "$1" > "$base/status.next"; mv -f "$base/status.next" "$base/status"; }
sleep_disabled() { /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }'; }
cleanup() {
  # Remove the persistent launch definition before unloading this invocation.
  rm -f "$plist"
  /bin/launchctl bootout "system/$label" >/dev/null 2>&1 || true
}
restore() {
  reason=$1
  if [ -f "$base/owned" ]; then
    status restoring
    if ! /usr/bin/pmset -a disablesleep 0 || [ "$(sleep_disabled)" != 0 ]; then
      status restore-failed
      exit 0 # Keep the launch job and journal: retry on the next tick/login.
    fi
    rm -f "$base/owned"
  fi
  status "$reason"
  cleanup
  exit 0
}
# Config is root-owned data, not shell source. Five fixed lines, no evaluation.
{
  IFS= read -r deadline
  IFS= read -r owner_pid
  IFS= read -r owner_uid
  IFS= read -r owner_started
  IFS= read -r request
} < "$base/config"
phase=$(cat "$base/status")
case "$phase" in
  starting|restoring|restore-failed) restore interrupted ;;
  active|armed) ;;
  *) cleanup; exit 0 ;;
esac
now=$(/bin/date +%s)
[ "$now" -lt "$deadline" ] || restore expired
# Process start time and UID prevent a recycled PID from keeping the lease alive.
actual_uid=$(/bin/ps -p "$owner_pid" -o uid= | /usr/bin/tr -d ' ') || actual_uid=
actual_started=$(/bin/ps -p "$owner_pid" -o lstart=) || actual_started=
[ "$actual_uid" = "$owner_uid" ] && [ "$actual_started" = "$owner_started" ] || restore owner-exited
# The user-owned request can only revoke the lease, never extend it or run code.
[ -f "$request" ] && [ ! -L "$request" ] || restore stopped
[ "$(/usr/bin/head -c 16 "$request")" = running ] || restore stopped
battery=$(/usr/bin/pmset -g batt)
if printf '%s\n' "$battery" | /usr/bin/grep -q "'Battery Power'"; then
  percent=$(printf '%s\n' "$battery" | /usr/bin/sed -nE 's/.*[[:space:]]([0-9]+)%;.*/\1/p' | /usr/bin/head -n 1)
  case "$percent" in ''|*[!0-9]*) restore battery-unavailable ;; esac
  [ "$percent" -gt 10 ] || restore low-battery
fi
if [ "$phase" = armed ]; then
  # Never take ownership of another utility's existing sleep override.
  [ "$(sleep_disabled)" = 0 ] || { status conflict; cleanup; exit 0; }
  status starting
  : > "$base/owned" # Journal BEFORE mutating persistent power settings.
  /usr/bin/pmset -a disablesleep 1 || restore start-failed
  # Some macOS versions revert this setting shortly after a successful command.
  /bin/sleep 5
  [ "$(sleep_disabled)" = 1 ] || restore unsupported
  # A stop, deadline or crash during authorization/startup must not become active.
  now=$(/bin/date +%s)
  [ "$now" -lt "$deadline" ] || restore expired
  [ -f "$request" ] && [ "$(/usr/bin/head -c 16 "$request")" = running ] || restore stopped
  status active
else
  [ "$(sleep_disabled)" = 1 ] || restore interrupted
fi
