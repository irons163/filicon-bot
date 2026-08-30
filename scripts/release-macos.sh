#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
version=${VERSION:?Set VERSION, for example 1.0.0}
build_number=${BUILD_NUMBER:?Set BUILD_NUMBER, for example 100}
channel=${UPDATE_CHANNEL:-stable}
minimum_system=${MINIMUM_SYSTEM_VERSION:-14.0}
release_tier=${RELEASE_TIER:-production}

die() {
  print -u2 -- "release-macos.sh: $*"
  exit 2
}

require_safe_https_base_url() {
  local value=$1
  local remainder=${value#https://}
  local authority=${remainder%%/*}
  [[ "$remainder" != "$value" && -n "$authority" ]] \
    || die "FEED_BASE_URL must be an absolute HTTPS URL with a host"
  [[ "$value" != *'@'* && "$value" != *'?'* && "$value" != *'#'* \
      && "$value" != *'\\'* && "$value" != *[[:space:]]* ]] \
    || die "FEED_BASE_URL must be credential-free HTTPS without query or fragment"
}

require_update_signing_key() {
  local encoded=${FILICON_UPDATE_PRIVATE_KEY_BASE64:-}
  [[ -n "$encoded" ]] || die "FILICON_UPDATE_PRIVATE_KEY_BASE64 is required when FEED_BASE_URL is set"
  local decoded
  decoded=$(mktemp "${TMPDIR:-/tmp}/filicon-update-key.XXXXXX")
  chmod 600 "$decoded"
  if ! print -rn -- "$encoded" | /usr/bin/base64 -D > "$decoded" 2>/dev/null; then
    /bin/rm -f -- "$decoded"
    die "FILICON_UPDATE_PRIVATE_KEY_BASE64 is not valid base64"
  fi
  local byte_count=$(/usr/bin/wc -c < "$decoded" | tr -d '[:space:]')
  /bin/rm -f -- "$decoded"
  [[ "$byte_count" == 32 ]] \
    || die "FILICON_UPDATE_PRIVATE_KEY_BASE64 must decode to a 32-byte Ed25519 private key"
}

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' ]] || {
  print -u2 "VERSION must be a semantic version such as 1.0.0"
  exit 2
}
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] || {
  print -u2 "BUILD_NUMBER must be a positive integer"
  exit 2
}
[[ "$channel" == stable || "$channel" == nightly || "$channel" == dogfood ]] || {
  print -u2 "UPDATE_CHANNEL must be stable, nightly, or dogfood"
  exit 2
}
[[ "$minimum_system" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || {
  print -u2 "MINIMUM_SYSTEM_VERSION must be a dotted numeric macOS version"
  exit 2
}
[[ "$release_tier" == production || "$release_tier" == local ]] \
  || die "RELEASE_TIER must be production or local"

sign_identity=${SIGN_IDENTITY:--}
notary_profile=${NOTARY_PROFILE:-}
feed_base_url=${FEED_BASE_URL:-}

# A locally generated feed key is kept in Keychain. CI can still provide the
# explicit base64 secret, but a release with a configured feed may safely use
# the local Keychain item by default.
if [[ -n "$feed_base_url" && -z ${FILICON_UPDATE_PRIVATE_KEY_BASE64:-} ]]; then
  keychain_update_key=$("$script_dir/read-update-feed-key.swift" --for-release 2>/dev/null || true)
  if [[ -n "$keychain_update_key" ]]; then
    export FILICON_UPDATE_PRIVATE_KEY_BASE64="$keychain_update_key"
  fi
fi

if [[ "$release_tier" == production ]]; then
  [[ "$sign_identity" == "Developer ID Application:"* ]] \
    || die "production releases require SIGN_IDENTITY='Developer ID Application: …'"
  [[ -n "$notary_profile" ]] \
    || die "production releases require NOTARY_PROFILE"
  [[ -n "$feed_base_url" ]] \
    || die "production releases require FEED_BASE_URL"
  [[ -n ${FILICON_UPDATE_PRIVATE_KEY_BASE64:-} ]] \
    || die "production releases require FILICON_UPDATE_PRIVATE_KEY_BASE64"
  command -v xcrun >/dev/null || die "xcrun is required for production releases"
  command -v spctl >/dev/null || die "spctl is required for production releases"
  xcrun --find notarytool >/dev/null || die "notarytool is unavailable"
  xcrun --find stapler >/dev/null || die "stapler is unavailable"
  /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -F -- "$sign_identity" >/dev/null \
    || die "SIGN_IDENTITY is not available in the signing keychain"
fi

# Optional local-tier signing services must also fail before the release
# directory or app bundle is touched. This keeps a typo from producing a
# partially notarized/feedless artifact that resembles a publishable build.
if [[ -n "$notary_profile" && "$sign_identity" == "-" ]]; then
  die "NOTARY_PROFILE requires a non-ad-hoc SIGN_IDENTITY"
fi
if [[ -n "$feed_base_url" ]]; then
  require_safe_https_base_url "$feed_base_url"
  require_update_signing_key
fi
if [[ -n ${RELEASE_NOTES_URL:-} ]]; then
  notes_remainder=${RELEASE_NOTES_URL#https://}
  notes_authority=${notes_remainder%%/*}
  [[ "$notes_remainder" != "$RELEASE_NOTES_URL" && -n "$notes_authority" \
      && "$RELEASE_NOTES_URL" != *'@'* && "$RELEASE_NOTES_URL" != *'?'* \
      && "$RELEASE_NOTES_URL" != *'#'* && "$RELEASE_NOTES_URL" != *'\\'* \
      && "$RELEASE_NOTES_URL" != *[[:space:]]* ]] \
    || die "RELEASE_NOTES_URL must be credential-free HTTPS without query or fragment"
fi

release_dir="$project_dir/dist/release-$version-$build_number"
app_path="$project_dir/dist/Filicon.app"
zip_path="$release_dir/Filicon-$version-$build_number.zip"
dmg_path="$release_dir/Filicon-$version-$build_number.dmg"

if [[ -e "$release_dir" ]]; then
  [[ -d "$release_dir" && ! -L "$release_dir" ]] \
    || die "release destination is not a regular directory: $release_dir"
  first_release_entry=$(find "$release_dir" -mindepth 1 -maxdepth 1 -print -quit)
  [[ -z "$first_release_entry" ]] \
    || die "release destination is not empty; refusing to mix artifacts: $release_dir"
fi
mkdir -p "$release_dir"
packaged_update_feed_url=
packaged_update_public_key=
if [[ -n "$feed_base_url" ]]; then
  packaged_update_feed_url="${feed_base_url%/}/$channel.json"
  packaged_update_public_key=$("$script_dir/derive-update-public-key.swift" "$FILICON_UPDATE_PRIVATE_KEY_BASE64") \
    || die "could not derive the packaged Ed25519 public key"
fi
SIGN_IDENTITY="$sign_identity" VERSION="$version" BUILD_NUMBER="$build_number" \
  FILICON_UPDATE_FEED_URL="$packaged_update_feed_url" \
  FILICON_UPDATE_PUBLIC_KEY_BASE64="$packaged_update_public_key" \
  "$script_dir/package-app.sh"

if [[ -n "$notary_profile" ]]; then
  if [[ "$sign_identity" == "-" ]]; then
    print -u2 "SIGN_IDENTITY must be a Developer ID Application identity when NOTARY_PROFILE is set"
    exit 2
  fi
  temporary_zip="$release_dir/notarization-upload.zip"
  /usr/bin/ditto -c -k --keepParent "$app_path" "$temporary_zip"
  xcrun notarytool submit "$temporary_zip" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$app_path"
  rm -f "$temporary_zip"
else
  print "Local release tier: producing an explicitly non-notarized artifact"
fi

# Re-verify after any optional notarization/stapling step.  package-app.sh
# verifies the freshly assembled bundle; this second check ensures the final
# release bundle still contains the expected plist metadata, nested XPC
# service, entitlements, and strict code signature.
"$script_dir/verify-package.sh" --app "$app_path" --version "$version" --build "$build_number"
if [[ ${RUN_LAUNCH_SMOKE:-0} == 1 ]]; then
  "$script_dir/smoke-launch.sh" "$app_path"
fi

/usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/filicon-dmg.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
cp -R "$app_path" "$staging_dir/Filicon.app"
hdiutil create -fs HFS+ -srcfolder "$staging_dir" -volname Filicon -format UDZO "$dmg_path"

if [[ "$sign_identity" != "-" ]]; then
  codesign --force --timestamp --sign "$sign_identity" "$dmg_path"
fi
if [[ -n "$notary_profile" ]]; then
  xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg_path"
fi

if [[ -n "$feed_base_url" ]]; then
  "$script_dir/generate-update-feed.swift" \
    "$channel" "$version" "$build_number" "$minimum_system" \
    "$feed_base_url" "$zip_path" "$release_dir/$channel.json"
else
  print "Local release tier: FEED_BASE_URL is unset; update feed generation was skipped"
fi

codesign --verify --deep --strict --verbose=1 "$app_path"
if [[ -n "$notary_profile" ]]; then
  spctl --assess --type execute --verbose=2 "$app_path"
  xcrun stapler validate "$app_path"
  xcrun stapler validate "$dmg_path"
fi
release_verify_args=(
  --zip "$zip_path"
  --dmg "$dmg_path"
  --version "$version"
  --build "$build_number"
)
if [[ "$release_tier" == production ]]; then
  release_verify_args+=(--require-gatekeeper)
fi
"$script_dir/verify-release-artifacts.sh" "${release_verify_args[@]}"

manifest_path="$release_dir/SHA256SUMS"
manifest_inputs=("${zip_path:t}" "${dmg_path:t}")
if [[ -f "$release_dir/$channel.json" ]]; then
  manifest_inputs+=("$channel.json")
fi
(
  cd "$release_dir"
  /usr/bin/shasum -a 256 "${manifest_inputs[@]}"
) > "$manifest_path"
print "Created release artifacts in $release_dir"
