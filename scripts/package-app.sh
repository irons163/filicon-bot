#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h:A}
configuration=${CONFIGURATION:-release}

die() {
  print -u2 -- "package-app.sh: $*"
  exit 2
}

[[ "$configuration" == release || "$configuration" == debug ]] \
  || die "CONFIGURATION must be release or debug (got ${(q)configuration})"

version=${VERSION:-0.1.0}
build_number=${BUILD_NUMBER:-1}
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' ]] \
  || die "VERSION must be a semantic version such as 1.0.0 (got ${(q)version})"
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] \
  || die "BUILD_NUMBER must be a positive integer (got ${(q)build_number})"

# BUNDLE_PATH is intentionally constrained to this workspace.  The package
# script removes the old bundle before copying freshly built products, so a
# typo here must never turn into an arbitrary recursive delete.  Relative
# paths are interpreted relative to the project root for reproducibility.
if [[ ${BUNDLE_PATH+x} == x ]]; then
  [[ -n "$BUNDLE_PATH" ]] || die "BUNDLE_PATH cannot be empty"
  bundle_input=$BUNDLE_PATH
else
  bundle_input="$project_dir/dist/Filicon.app"
fi
if [[ "$bundle_input" == /* ]]; then
  bundle_candidate="$bundle_input"
else
  bundle_candidate="$project_dir/$bundle_input"
fi
[[ ! -L "$bundle_candidate" ]] \
  || die "BUNDLE_PATH must not be a symlink: ${(q)bundle_input}"
bundle_dir=${bundle_candidate:A}
[[ "$bundle_dir" != / && "$bundle_dir" != "$project_dir" ]] \
  || die "BUNDLE_PATH cannot be the filesystem root or workspace root"
case "$bundle_dir" in
  "$project_dir"/*) ;;
  *) die "BUNDLE_PATH must stay inside the workspace: $bundle_dir" ;;
esac
[[ "$bundle_dir:t" == *.app ]] \
  || die "BUNDLE_PATH must name an explicit .app bundle: $bundle_dir"

# Never remove an existing bundle unless it is recognizably Filicon.  An
# empty directory left by an interrupted package is safe to replace; any
# non-empty unknown directory is treated as user data and rejected.
if [[ -e "$bundle_dir" || -L "$bundle_dir" ]]; then
  [[ -d "$bundle_dir" && ! -L "$bundle_dir" ]] \
    || die "refusing to replace a non-directory bundle path: $bundle_dir"
  existing_info="$bundle_dir/Contents/Info.plist"
  if [[ -f "$existing_info" ]]; then
    /usr/bin/plutil -lint "$existing_info" >/dev/null \
      || die "existing bundle has an invalid Info.plist: $existing_info"
    existing_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$existing_info" 2>/dev/null || true)
    existing_name=$(/usr/bin/plutil -extract CFBundleName raw -o - "$existing_info" 2>/dev/null || true)
    existing_exec=$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$existing_info" 2>/dev/null || true)
    [[ "$existing_id" == com.filicon.app && "$existing_name" == Filicon && "$existing_exec" == Filicon ]] \
      || die "refusing to replace an existing non-Filicon app: $bundle_dir"
  else
    first_entry=$(find "$bundle_dir" -mindepth 1 -maxdepth 1 -print -quit)
    [[ -z "$first_entry" ]] \
      || die "refusing to replace an unrecognized existing bundle: $bundle_dir"
  fi
fi

contents_dir="$bundle_dir/Contents"
sign_identity=${SIGN_IDENTITY:--}
entitlements="$project_dir/Support/Filicon.entitlements"
local_tool_entitlements="$project_dir/Support/LocalToolService.entitlements"
[[ -f "$entitlements" ]] || die "missing app entitlements: $entitlements"
[[ -f "$local_tool_entitlements" ]] || die "missing XPC entitlements: $local_tool_entitlements"
/usr/bin/plutil -lint "$entitlements" >/dev/null \
  || die "invalid app entitlements plist: $entitlements"
/usr/bin/plutil -lint "$local_tool_entitlements" >/dev/null \
  || die "invalid XPC entitlements plist: $local_tool_entitlements"

command -v swift >/dev/null || die "swift is required"
command -v codesign >/dev/null || die "codesign is required"
command -v /usr/libexec/PlistBuddy >/dev/null || die "PlistBuddy is required"

cd "$project_dir"
python3 scripts/localization_audit.py
# `--show-bin-path` reports a directory but does not guarantee that the named
# product was built. Build every executable explicitly before resolving the
# output directory so a clean checkout can never package a stale/missing app.
swift build -c "$configuration" --product Filicon
bin_dir=$(swift build -c "$configuration" --show-bin-path)
for product in FiliconLocalToolHelper FiliconLocalToolXPCService FiliconUpdateHelper; do
  swift build -c "$configuration" --product "$product"
done

for executable in Filicon FiliconLocalToolHelper FiliconLocalToolXPCService FiliconUpdateHelper; do
  [[ -x "$bin_dir/$executable" ]] \
    || die "$executable was not produced at $bin_dir/$executable"
done

# All path guards above are deliberately before this recursive removal.
/bin/rm -rf -- "$bundle_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Helpers" "$contents_dir/Resources"
cp "$bin_dir/Filicon" "$contents_dir/MacOS/Filicon"
cp "$bin_dir/FiliconLocalToolHelper" "$contents_dir/Helpers/FiliconLocalToolHelper"
cp "$bin_dir/FiliconUpdateHelper" "$contents_dir/Helpers/FiliconUpdateHelper"
cp "$project_dir/Support/Info.plist" "$contents_dir/Info.plist"
for localization_dir in "$project_dir"/Sources/Filicon/Resources/*.lproj; do
  cp -R "$localization_dir" "$contents_dir/Resources/"
done
cp -R "$project_dir/Sources/Filicon/Resources/PetAvatars" "$contents_dir/Resources/"

# Production release jobs inject the real feed and public verification key.
# They are intentionally absent from source control and never replaced with
# placeholder endpoints or keys.
update_feed_url=${FILICON_UPDATE_FEED_URL:-}
update_public_key=${FILICON_UPDATE_PUBLIC_KEY_BASE64:-}
if [[ -n "$update_feed_url" || -n "$update_public_key" ]]; then
  [[ -n "$update_feed_url" && -n "$update_public_key" ]] \
    || die "FILICON_UPDATE_FEED_URL and FILICON_UPDATE_PUBLIC_KEY_BASE64 must be provided together"
  update_remainder=${update_feed_url#https://}
  update_authority=${update_remainder%%/*}
  [[ "$update_remainder" != "$update_feed_url" && -n "$update_authority" \
      && "$update_feed_url" != *'@'* && "$update_feed_url" != *[[:space:]]* ]] \
    || die "FILICON_UPDATE_FEED_URL must be credential-free HTTPS"
  decoded_update_key=$(mktemp "${TMPDIR:-/tmp}/filicon-update-public-key.XXXXXX")
  if ! print -rn -- "$update_public_key" | /usr/bin/base64 -D > "$decoded_update_key" 2>/dev/null; then
    /bin/rm -f -- "$decoded_update_key"
    die "FILICON_UPDATE_PUBLIC_KEY_BASE64 is not valid base64"
  fi
  update_key_bytes=$(/usr/bin/wc -c < "$decoded_update_key" | tr -d '[:space:]')
  /bin/rm -f -- "$decoded_update_key"
  [[ "$update_key_bytes" == 32 ]] || die "FILICON_UPDATE_PUBLIC_KEY_BASE64 must decode to 32 bytes"
  /usr/bin/plutil -insert FiliconUpdateFeedURL -string "$update_feed_url" "$contents_dir/Info.plist"
  /usr/bin/plutil -insert FiliconUpdatePublicKeyBase64 -string "$update_public_key" "$contents_dir/Info.plist"
fi

xpc_bundle="$contents_dir/XPCServices/FiliconLocalToolService.xpc"
mkdir -p "$xpc_bundle/Contents/MacOS"
cp "$bin_dir/FiliconLocalToolXPCService" "$xpc_bundle/Contents/MacOS/FiliconLocalToolXPCService"
cp "$project_dir/Support/LocalToolService-Info.plist" "$xpc_bundle/Contents/Info.plist"

/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$contents_dir/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$contents_dir/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$xpc_bundle/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$xpc_bundle/Contents/Info.plist"

sign_args=(--force --options runtime --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
  sign_args+=(--timestamp)
fi
codesign "${sign_args[@]}" "$contents_dir/Helpers/FiliconLocalToolHelper"
codesign "${sign_args[@]}" "$contents_dir/Helpers/FiliconUpdateHelper"
codesign "${sign_args[@]}" --entitlements "$local_tool_entitlements" "$xpc_bundle/Contents/MacOS/FiliconLocalToolXPCService"
codesign "${sign_args[@]}" --entitlements "$local_tool_entitlements" "$xpc_bundle"
codesign "${sign_args[@]}" --entitlements "$entitlements" "$bundle_dir"
"$script_dir/verify-package.sh" --app "$bundle_dir" --version "$version" --build "$build_number"
print "Artifact: $bundle_dir"
print "Verify: $script_dir/verify-package.sh --app $bundle_dir --version $version --build $build_number"
print "Launch smoke: $script_dir/smoke-launch.sh $bundle_dir"
