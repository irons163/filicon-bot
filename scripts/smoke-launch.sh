#!/bin/zsh
set -euo pipefail

script_name=${0:t}
project_dir=${0:A:h:h}
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  print "usage: $script_name [PATH/TO/Filicon.app]"
  exit 0
fi
app_input=${1:-$project_dir/dist/Filicon.app}
startup_timeout=${STARTUP_TIMEOUT_SECONDS:-15}
stability_seconds=${STABILITY_SECONDS:-3}

die() {
  print -u2 -- "$script_name: $*"
  exit 2
}

[[ "$startup_timeout" =~ '^[1-9][0-9]*$' ]] \
  || die "STARTUP_TIMEOUT_SECONDS must be a positive integer"
[[ "$stability_seconds" =~ '^[1-9][0-9]*$' ]] \
  || die "STABILITY_SECONDS must be a positive integer"
[[ "$app_input" == *.app && -d "$app_input" && ! -L "$app_input" ]] \
  || die "expected an existing, non-symlink .app bundle: $app_input"

app_path=${app_input:A}
info_plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/Filicon"
[[ -f "$info_plist" && -x "$executable" ]] \
  || die "bundle is missing Info.plist or the Filicon executable: $app_path"

bundle_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist" 2>/dev/null || true)
[[ "$bundle_id" == com.filicon.app ]] \
  || die "refusing to launch a bundle whose identifier is not com.filicon.app"

existing_output=$(/usr/bin/pgrep -x Filicon 2>/dev/null || true)
[[ -z "$existing_output" ]] \
  || die "Filicon is already running; quit it before the launch smoke test"

launched_pid=
cleanup() {
  if [[ -n "$launched_pid" ]] && /bin/kill -0 "$launched_pid" 2>/dev/null; then
    /bin/kill -TERM "$launched_pid" 2>/dev/null || true
    for _ in {1..20}; do
      /bin/kill -0 "$launched_pid" 2>/dev/null || return
      /bin/sleep 0.1
    done
  fi
}
trap cleanup EXIT INT TERM

/usr/bin/open -n "$app_path"
launch_started_epoch=$(/bin/date +%s)
deadline=$(( launch_started_epoch + startup_timeout ))
while (( $(/bin/date +%s) <= deadline )); do
  candidate_output=$(/usr/bin/pgrep -x Filicon 2>/dev/null || true)
  candidates=()
  if [[ -n "$candidate_output" ]]; then candidates=(${(f)candidate_output}); fi
  if (( ${#candidates} == 1 )); then
    launched_pid=$candidates[1]
    break
  fi
  (( ${#candidates} <= 1 )) \
    || die "launch produced more than one Filicon process"
  /bin/sleep 0.1
done
[[ -n "$launched_pid" ]] || die "Filicon did not start within ${startup_timeout}s"

/bin/sleep "$stability_seconds"
/bin/kill -0 "$launched_pid" 2>/dev/null \
  || die "Filicon exited during the ${stability_seconds}s stability window"

/usr/bin/osascript -e 'tell application id "com.filicon.app" to quit' >/dev/null 2>&1 || true
for _ in {1..50}; do
  if ! /bin/kill -0 "$launched_pid" 2>/dev/null; then
    launched_pid=
    print "Launch smoke passed: $app_path"
    exit 0
  fi
  /bin/sleep 0.1
done

die "Filicon launched successfully but did not terminate cleanly after a quit request"
