#!/bin/zsh
set -euo pipefail

script_name=${0:t}
script_dir=${0:A:h}

die() {
  print -u2 -- "$script_name: $*"
  exit 2
}

usage() {
  print -u2 -- "usage: $script_name --zip PATH --dmg PATH --version VERSION --build BUILD [--require-gatekeeper]"
  exit 2
}

zip_input=
dmg_input=
version=
build=
require_gatekeeper=0
while (( $# > 0 )); do
  case "$1" in
    --zip) (( $# >= 2 )) || usage; zip_input=$2; shift 2 ;;
    --dmg) (( $# >= 2 )) || usage; dmg_input=$2; shift 2 ;;
    --version) (( $# >= 2 )) || usage; version=$2; shift 2 ;;
    --build) (( $# >= 2 )) || usage; build=$2; shift 2 ;;
    --require-gatekeeper) require_gatekeeper=1; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ -n "$zip_input" && -n "$dmg_input" && -n "$version" && -n "$build" ]] || usage
[[ -f "$zip_input" && ! -L "$zip_input" ]] || die "ZIP is missing or symlinked: $zip_input"
[[ -f "$dmg_input" && ! -L "$dmg_input" ]] || die "DMG is missing or symlinked: $dmg_input"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/filicon-release-verify.XXXXXX")
mount_point="$temporary_root/mounted"
zip_root="$temporary_root/zip"
mkdir -p "$mount_point" "$zip_root"
mounted=0
cleanup() {
  if (( mounted == 1 )); then
    hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$temporary_root"
}
trap cleanup EXIT

/usr/bin/ditto -x -k "$zip_input" "$zip_root"
zip_app="$zip_root/Filicon.app"
[[ -d "$zip_app" && ! -L "$zip_app" ]] || die "ZIP does not contain Filicon.app at its root"
"$script_dir/verify-package.sh" --app "$zip_app" --version "$version" --build "$build"

hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dmg_input" >/dev/null
mounted=1
dmg_app="$mount_point/Filicon.app"
[[ -d "$dmg_app" && ! -L "$dmg_app" ]] || die "DMG does not contain Filicon.app at its root"
"$script_dir/verify-package.sh" --app "$dmg_app" --version "$version" --build "$build"

if (( require_gatekeeper == 1 )); then
  spctl --assess --type execute --verbose=2 "$zip_app"
  spctl --assess --type execute --verbose=2 "$dmg_app"
  xcrun stapler validate "$zip_app"
  xcrun stapler validate "$dmg_input"
fi

print "Verified clean-install artifacts: ZIP and read-only DMG"
