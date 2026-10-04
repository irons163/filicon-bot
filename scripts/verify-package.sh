#!/bin/zsh
set -euo pipefail

script_name=${0:t}
project_dir=${0:A:h:h}

die() {
  print -u2 -- "$script_name: $*"
  exit 2
}

usage() {
  print -u2 -- "usage: $script_name --app PATH --version VERSION --build BUILD_NUMBER [--xcode-debug]"
  exit 2
}

app_input=
expected_version=
expected_build=
xcode_debug=false
while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || usage
      app_input=$2
      shift 2
      ;;
    --version)
      (( $# >= 2 )) || usage
      expected_version=$2
      shift 2
      ;;
    --build)
      (( $# >= 2 )) || usage
      expected_build=$2
      shift 2
      ;;
    --xcode-debug)
      xcode_debug=true
      shift
      ;;
    -h|--help)
      print "usage: $script_name --app PATH --version VERSION --build BUILD_NUMBER [--xcode-debug]"
      exit 0
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$app_input" && -n "$expected_version" && -n "$expected_build" ]] || usage
[[ "$expected_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' ]] \
  || die "--version must be a semantic version (got ${(q)expected_version})"
[[ "$expected_build" =~ '^[1-9][0-9]*$' ]] \
  || die "--build must be a positive integer (got ${(q)expected_build})"

command -v /usr/bin/codesign >/dev/null || die "codesign is required"
command -v /usr/bin/plutil >/dev/null || die "plutil is required"
command -v /usr/libexec/PlistBuddy >/dev/null || die "PlistBuddy is required"

[[ "$app_input" == *.app ]] || die "--app must name an explicit .app bundle: $app_input"
[[ -d "$app_input" && ! -L "$app_input" ]] \
  || die "app bundle is missing or is a symlink: $app_input"
app_path=${app_input:A}
[[ -d "$app_path/Contents" ]] || die "missing app Contents directory: $app_path/Contents"

info_plist="$app_path/Contents/Info.plist"
xpc_bundle="$app_path/Contents/XPCServices/FiliconLocalToolService.xpc"
xpc_info="$xpc_bundle/Contents/Info.plist"
app_entitlements_source=${APP_ENTITLEMENTS:-$project_dir/Support/Filicon.entitlements}
xpc_entitlements_source=${XPC_ENTITLEMENTS:-$project_dir/Support/LocalToolService.entitlements}

lint_plist() {
  local plist=$1
  [[ -f "$plist" && ! -L "$plist" ]] || die "missing plist: $plist"
  /usr/bin/plutil -lint "$plist" >/dev/null || die "invalid plist: $plist"
}

expect_plist_value() {
  local plist=$1
  local key=$2
  local wanted=$3
  local actual
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)
  [[ "$actual" == "$wanted" ]] \
    || die "$plist: expected $key=$wanted, found ${(q)actual}"
}

expect_regular_executable() {
  local path=$1
  [[ -f "$path" && ! -L "$path" && -x "$path" ]] \
    || die "missing or non-executable required product: $path"
}

lint_plist "$info_plist"
[[ -d "$xpc_bundle" && ! -L "$xpc_bundle" ]] \
  || die "missing or symlinked XPC bundle: $xpc_bundle"
lint_plist "$xpc_info"

expect_plist_value "$info_plist" CFBundleIdentifier com.filicon.app
expect_plist_value "$info_plist" CFBundleName Filicon
expect_plist_value "$info_plist" CFBundleExecutable Filicon
expect_plist_value "$info_plist" CFBundlePackageType APPL
expect_plist_value "$info_plist" CFBundleShortVersionString "$expected_version"
expect_plist_value "$info_plist" CFBundleVersion "$expected_build"
expect_plist_value "$xpc_info" CFBundleIdentifier com.filicon.app.LocalToolService
expect_plist_value "$xpc_info" CFBundleName "Filicon Local Tool Service"
expect_plist_value "$xpc_info" CFBundleExecutable FiliconLocalToolXPCService
expect_plist_value "$xpc_info" CFBundlePackageType 'XPC!'
expect_plist_value "$xpc_info" CFBundleShortVersionString "$expected_version"
expect_plist_value "$xpc_info" CFBundleVersion "$expected_build"

expect_regular_executable "$app_path/Contents/MacOS/Filicon"
expect_regular_executable "$app_path/Contents/Helpers/FiliconLocalToolHelper"
expect_regular_executable "$app_path/Contents/Helpers/FiliconUpdateHelper"
expect_regular_executable "$xpc_bundle/Contents/MacOS/FiliconLocalToolXPCService"

# SwiftPM package and native Xcode both ship the same offline math resource bundle.
math_bundle="$app_path/Contents/Resources/Filicon_FiliconRichContent.bundle"
[[ -d "$math_bundle" && ! -L "$math_bundle" ]] || die "missing offline math resource bundle"
math_root="$math_bundle/Contents/Resources/KaTeX"
[[ -d "$math_root" ]] || math_root="$math_bundle/KaTeX"
ruby "$project_dir/scripts/verify-katex.rb" "$math_root" \
  || die "offline math resource verification failed"

[[ -f "$app_entitlements_source" ]] \
  || die "missing app entitlements source: $app_entitlements_source"
[[ -f "$xpc_entitlements_source" ]] \
  || die "missing XPC entitlements source: $xpc_entitlements_source"
lint_plist "$app_entitlements_source"
lint_plist "$xpc_entitlements_source"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/filicon-package-verify.XXXXXX")
trap 'rm -rf -- "$tmp_dir"' EXIT

dump_signed_entitlements() {
  local signed_path=$1
  local output_path=$2
  /usr/bin/codesign -d --entitlements :- "$signed_path" >"$output_path" 2>"$output_path.stderr" \
    || die "codesign could not read entitlements: $signed_path"
  [[ -s "$output_path" ]] || die "signed product has no entitlements: $signed_path"
  lint_plist "$output_path"
}

expect_signed_entitlement() {
  local signed_plist=$1
  local source_plist=$2
  local key=$3
  local wanted actual
  wanted=$(/usr/libexec/PlistBuddy -c "Print :$key" "$source_plist" 2>/dev/null || true)
  [[ -n "$wanted" ]] || die "entitlement source is missing $key: $source_plist"
  actual=$(/usr/libexec/PlistBuddy -c "Print :$key" "$signed_plist" 2>/dev/null || true)
  [[ "$actual" == "$wanted" ]] \
    || die "signed entitlements mismatch for $key: expected ${(q)wanted}, found ${(q)actual}"
}

app_signed_entitlements="$tmp_dir/app-entitlements.plist"
xpc_signed_entitlements="$tmp_dir/xpc-entitlements.plist"
dump_signed_entitlements "$app_path" "$app_signed_entitlements"
dump_signed_entitlements "$xpc_bundle" "$xpc_signed_entitlements"

# Compare every entitlement declared by the package sources.  This keeps the
# verifier aligned with Support/*.entitlements without hard-coding a stale
# subset, while allowing signing tools to add harmless metadata outside the
# declared set.
for entitlement_key in \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.device.audio-input; do
  expect_signed_entitlement "$app_signed_entitlements" "$app_entitlements_source" "$entitlement_key"
done
for entitlement_key in \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write; do
  expect_signed_entitlement "$xpc_signed_entitlements" "$xpc_entitlements_source" "$entitlement_key"
done

# Do not ship DerivedData access exceptions or debugger attachment rights.
# Native Xcode Debug is the only mode allowed to carry the exact read-only
# app-bundle exception; it still must pass all the normal checks above.
python3 "$project_dir/scripts/verify-package-entitlements.py" \
  "$app_signed_entitlements" "$xpc_signed_entitlements" "$app_path" "$xcode_debug"

/usr/bin/codesign --verify --deep --strict --verbose=1 "$app_path" \
  || die "deep strict code-signature verification failed: $app_path"

print "Verified package: $app_path"
print "  version=$expected_version build=$expected_build"
print "  executables=Filicon, FiliconLocalToolHelper, FiliconLocalToolXPCService, FiliconUpdateHelper"
print "  entitlements=app and XPC matched Support/*.entitlements"
print "  codesign=deep strict"
