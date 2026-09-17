#!/bin/zsh
set -euo pipefail
project_dir=${0:A:h:h}
app_input=${1:?usage: smoke-xcode-xpc.sh PATH/TO/Filicon.app}
[[ -d "$app_input" && ! -L "$app_input" && "$app_input" == *.app ]] || exit 2
app_path=${app_input:A}
# Must start with an unmodified native Debug bundle, not one re-signed by XCTest.
"$project_dir/scripts/verify-package.sh" --app "$app_path" --version 0.1.0 --build 1 --xcode-debug
cd "$project_dir"
swift build --product FiliconLocalToolHelper >/dev/null
bin_dir=$(swift build --show-bin-path)
mkdir -p "$project_dir/DerivedData"
smoke_dir=$(mktemp -d "$project_dir/DerivedData/FiliconXPCSmoke.XXXXXX")
# Keep this diagnostic copy for inspection. Never change the user's app or data.
smoke_app="$smoke_dir/Filicon.app"
ditto "$app_path" "$smoke_app"
swiftc -parse-as-library -I "$bin_dir/Modules" \
  "$project_dir/scripts/xpc-smoke.swift" \
  "$bin_dir"/FiliconLocalTools.build/*.o "$bin_dir"/FiliconDomain.build/*.o \
  -o "$smoke_app/Contents/MacOS/Filicon"

# The one permitted exception must follow this new, isolated app path. Start
# from shipping entitlements, never from testmanager's expanded signature.
entitlements="$smoke_dir/service.entitlements"
cp "$project_dir/Support/LocalToolService.entitlements" "$entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.files.absolute-path.read-only array' "$entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-only:0 string $smoke_app/" "$entitlements"
codesign --force --sign - --options runtime --entitlements "$entitlements" \
  "$smoke_app/Contents/XPCServices/FiliconLocalToolService.xpc"
codesign --force --sign - --options runtime --entitlements "$project_dir/Support/Filicon.entitlements" "$smoke_app"
"$project_dir/scripts/verify-package.sh" --app "$smoke_app" --version 0.1.0 --build 1 --xcode-debug

# Save a real app-scoped bookmark in a legacy bare client, then validate
# recovery in the packaged app identity. Never use user grants. Recompiling
# at the same path alone does not reliably invalidate a bookmark on macOS.
fixture_dir=$(mktemp -d "$smoke_dir/bookmark-fixture.XXXXXX")
cp "$smoke_app/Contents/MacOS/Filicon" "$smoke_dir/LegacyFilicon"
codesign --force --sign - --identifier com.filicon.fixture.legacy "$smoke_dir/LegacyFilicon"
"$smoke_dir/LegacyFilicon" --seed "$fixture_dir"
swiftc -D BOOKMARK_REBUILT -parse-as-library -I "$bin_dir/Modules" \
  "$project_dir/scripts/xpc-smoke.swift" \
  "$bin_dir"/FiliconLocalTools.build/*.o "$bin_dir"/FiliconDomain.build/*.o \
  -o "$smoke_app/Contents/MacOS/Filicon"
codesign --force --sign - --options runtime --entitlements "$project_dir/Support/Filicon.entitlements" "$smoke_app"
"$project_dir/scripts/verify-package.sh" --app "$smoke_app" --version 0.1.0 --build 1 --xcode-debug

# Bound a broken IPC handshake without leaving a diagnostic process running.
"$smoke_app/Contents/MacOS/Filicon" --renew "$fixture_dir" &
smoke_pid=$!
trap 'kill -TERM "$smoke_pid" 2>/dev/null || true' EXIT INT TERM
for _ in {1..30}; do
  if ! kill -0 "$smoke_pid" 2>/dev/null; then
    wait "$smoke_pid"
    trap - EXIT INT TERM
    print "Diagnostic app retained: $smoke_app"
    exit 0
  fi
  sleep 1
done
print -u2 'STRICT XPC FAILED: 30-second timeout'
exit 1
