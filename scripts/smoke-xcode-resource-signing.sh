#!/bin/zsh
# Build an isolated snapshot; never modify this checkout or launch Filicon.
set -euo pipefail
project_dir=${0:A:h:h}
[[ $# == 0 ]] || { print -u2 'usage: smoke-xcode-resource-signing.sh'; exit 2; }
review_dir=$(mktemp -d "${TMPDIR:-/tmp}/filicon-resource-signing.XXXXXX")
fixture_dir="$review_dir/project with spaces"
derived_dir="$review_dir/DerivedData with spaces"
mkdir -p "$fixture_dir"
print -r -- "Resource-signing evidence (retained): $review_dir"
# Include the current working tree, including uncommitted fixes, but none of
# its .git, dist, DerivedData, .build, app data, credentials or local config.
(cd "$project_dir" && /usr/bin/tar --exclude=xcuserdata --exclude='*.xcuserstate' -cf - Package.swift Package.resolved Sources Support scripts Filicon.xcodeproj Filicon.xcworkspace) \
  | (cd "$fixture_dir" && /usr/bin/tar -xf -)
app_bundle="$derived_dir/Build/Products/Debug/Filicon.app"
source_resources="$fixture_dir/Sources/Filicon/Resources"
built_resources="$app_bundle/Contents/Resources"
manifest="$built_resources/FiliconResources.sha256"

build_and_verify() {
  local step=$1
  if ! /usr/bin/xcodebuild -workspace "$fixture_dir/Filicon.xcworkspace" \
      -scheme 'Filicon App' -configuration Debug -derivedDataPath "$derived_dir" \
      CODE_SIGN_IDENTITY=- build > "$review_dir/$step-build.log" 2>&1; then
    print -u2 -- "BUILD FAILED: $step; see $review_dir/$step-build.log"
    return 1
  fi
  if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle" \
      > "$review_dir/$step-signature.log" 2>&1; then
    print -u2 -- "SIGNATURE FAILED: $step; see $review_dir/$step-signature.log"
    return 1
  fi
  [[ -f "$manifest" ]] || { print -u2 'Missing resource signing manifest'; return 1; }
  print -r -- "PASS: $step (build + deep strict signature)"
}

build_and_verify baseline
# Settle first-build Info.plist/embedded-product work before resource-only tests.
build_and_verify settled
digest_before=$(< "$manifest")
mtime_before=$(/usr/bin/stat -f %m "$manifest")
build_and_verify unchanged
[[ "$(< "$manifest")" == "$digest_before" && "$(/usr/bin/stat -f %m "$manifest")" == "$mtime_before" ]] \
  || { print -u2 'No-op build rewrote the resource digest'; exit 1; }

for language in en zh-Hant zh-Hans fr es ja ko; do
  digest_before=$(< "$manifest")
  print -r -- "\"Filicon signing fixture\" = \"$language incremental\";" \
    >> "$source_resources/$language.lproj/Localizable.strings"
  build_and_verify "strings-$language"
  [[ "$(< "$manifest")" != "$digest_before" ]] || { print -u2 'Changed resource did not change digest'; exit 1; }
  built_value=$(/usr/libexec/PlistBuddy -c 'Print :"Filicon signing fixture"' "$built_resources/$language.lproj/Localizable.strings")
  [[ "$built_value" == "$language incremental" ]] || { print -u2 'Bundle still contains old strings'; exit 1; }
done

# Folder-reference membership is also significant: adding/removing an asset
# must trigger signing, even though no project file or Swift source changed.
fixture_asset="$source_resources/PetAvatars/signing-fixture.txt"
print -r -- 'isolated resource membership fixture' > "$fixture_asset"
build_and_verify asset-added
[[ -f "$built_resources/PetAvatars/signing-fixture.txt" ]] || exit 1
# Remove only the exact fixture file this script just created, never user data.
/bin/rm "$fixture_asset"
build_and_verify asset-removed
[[ ! -e "$built_resources/PetAvatars/signing-fixture.txt" ]] || { print -u2 'Removed fixture remains in bundle'; exit 1; }
build_and_verify final-unchanged
print -r -- "PASS: seven localization-only builds, asset membership and no-op builds. Evidence: $review_dir"
