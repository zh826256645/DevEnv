#!/bin/bash

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

EXPECTED_BUNDLE_IDENTIFIER='io.github.zh826256645.DevEnv'
EXPECTED_ARCHITECTURE='arm64'
EXPECTED_EXECUTABLE_NAME='DevEnv'
EXPECTED_PACKAGE_TYPE='APPL'
EXPECTED_MINIMUM_SYSTEM_VERSION='15.0'
EXPECTED_ICON_NAME='AppIcon'

usage() {
    cat <<'USAGE'
Usage: verify-release-artifacts.sh \
  --dmg PATH \
  --checksum PATH \
  --version VERSION \
  --build BUILD

Mounts and validates the final DevEnv arm64 DMG and its SHA-256 file.
USAGE
}

fail() {
    printf 'Release artifact verification failed: %s\n' "$1" >&2
    exit 1
}

dmg_path=''
checksum_path=''
expected_version=''
expected_build=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            [[ $# -ge 2 ]] || fail '--dmg requires a path'
            dmg_path="$2"
            shift 2
            ;;
        --checksum)
            [[ $# -ge 2 ]] || fail '--checksum requires a path'
            checksum_path="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || fail '--version requires a value'
            expected_version="$2"
            shift 2
            ;;
        --build)
            [[ $# -ge 2 ]] || fail '--build requires a value'
            expected_build="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ -n "$dmg_path" ]] || fail '--dmg is required'
[[ -n "$checksum_path" ]] || fail '--checksum is required'
[[ -n "$expected_version" ]] || fail '--version is required'
[[ -n "$expected_build" ]] || fail '--build is required'
release_is_semantic_version "$expected_version" || fail "invalid version: $expected_version"
release_is_build_number "$expected_build" || fail "invalid build: $expected_build"
[[ -f "$dmg_path" ]] || fail "DMG is missing: $dmg_path"
[[ -f "$checksum_path" ]] || fail "SHA-256 file is missing: $checksum_path"

dmg_path="$(cd "$(dirname "$dmg_path")" && pwd -P)/$(basename "$dmg_path")"
checksum_path="$(cd "$(dirname "$checksum_path")" && pwd -P)/$(basename "$checksum_path")"

expected_dmg_name="DevEnv-${expected_version}-arm64.dmg"
expected_checksum_name="${expected_dmg_name}.sha256"
[[ "$(basename "$dmg_path")" == "$expected_dmg_name" ]] \
    || fail "DMG filename mismatch: expected $expected_dmg_name, found $(basename "$dmg_path")"
[[ "$(basename "$checksum_path")" == "$expected_checksum_name" ]] \
    || fail "SHA-256 filename mismatch: expected $expected_checksum_name, found $(basename "$checksum_path")"

checksum_line_count="$(awk 'END { print NR }' "$checksum_path")"
[[ "$checksum_line_count" == '1' ]] || fail 'SHA-256 file must contain exactly one checksum line'

checksum_line=''
checksum_hash=''
checksum_name=''
checksum_extra=''
IFS= read -r checksum_line < "$checksum_path" || fail 'unable to read SHA-256 file'
read -r checksum_hash checksum_name checksum_extra <<< "$checksum_line"
[[ "$checksum_hash" =~ ^[[:xdigit:]]{64}$ ]] || fail 'SHA-256 file contains an invalid digest'
[[ "$checksum_name" == "$expected_dmg_name" ]] \
    || fail "SHA-256 filename entry mismatch: expected $expected_dmg_name, found ${checksum_name:-<empty>}"
[[ -z "$checksum_extra" ]] || fail 'SHA-256 file contains unexpected trailing fields'
[[ "$checksum_line" == "$checksum_hash  $expected_dmg_name" ]] \
    || fail 'SHA-256 file must use the controlled digest and filename format'

actual_hash="$(shasum -a 256 "$dmg_path" | awk '{ print $1 }')"
normalized_checksum_hash="$(printf '%s' "$checksum_hash" | tr '[:upper:]' '[:lower:]')"
normalized_actual_hash="$(printf '%s' "$actual_hash" | tr '[:upper:]' '[:lower:]')"
[[ "$normalized_checksum_hash" == "$normalized_actual_hash" ]] \
    || fail "SHA-256 mismatch: expected $checksum_hash, found $actual_hash"

verification_root="$(mktemp -d "${TMPDIR:-/tmp}/devenv-release-verify.XXXXXX")"
mount_point="$verification_root/volume"
mkdir -p "$mount_point"
mounted=0

cleanup() {
    local status=$?

    if [[ $mounted -eq 1 ]]; then
        if ! hdiutil detach "$mount_point" >/dev/null 2>&1; then
            printf 'Release artifact verification cleanup failed: unable to detach %s\n' "$mount_point" >&2
            if [[ $status -eq 0 ]]; then
                status=1
            fi
        fi
    fi

    rm -rf "$verification_root"
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_output=''
if ! verify_output="$(hdiutil verify "$dmg_path" 2>&1)"; then
    fail "DMG container verification failed: $verify_output"
fi

attach_output=''
if ! attach_output="$(hdiutil attach "$dmg_path" \
    -readonly \
    -nobrowse \
    -noautoopen \
    -owners on \
    -mountpoint "$mount_point" 2>&1)"; then
    fail "unable to mount DMG read-only: $attach_output"
fi
mounted=1

app_path="$mount_point/DevEnv.app"
applications_link="$mount_point/Applications"
[[ -d "$app_path" && ! -L "$app_path" ]] || fail 'DevEnv.app is missing or is not an App Bundle directory'
[[ -L "$applications_link" ]] || fail 'Applications symlink is missing'
applications_target="$(readlink "$applications_link")"
[[ "$applications_target" == '/Applications' ]] \
    || fail "Applications symlink target mismatch: expected /Applications, found $applications_target"

actual_entries="$(find "$mount_point" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
expected_entries=$(printf '%s\n' 'Applications' 'DevEnv.app')
[[ "$actual_entries" == "$expected_entries" ]] \
    || fail "DMG structure mismatch: expected only DevEnv.app and Applications; found: ${actual_entries:-<empty>}"

info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail 'App Bundle Info.plist is missing'

plist_value() {
    local key="$1"
    local value

    if ! value="$(plutil -extract "$key" raw -o - "$info_plist" 2>/dev/null)"; then
        fail "App Bundle metadata is missing $key"
    fi
    printf '%s' "$value"
}

bundle_identifier="$(plist_value CFBundleIdentifier)"
bundle_version="$(plist_value CFBundleShortVersionString)"
bundle_build="$(plist_value CFBundleVersion)"
executable_name="$(plist_value CFBundleExecutable)"
package_type="$(plist_value CFBundlePackageType)"
minimum_system_version="$(plist_value LSMinimumSystemVersion)"
icon_name="$(plist_value CFBundleIconName)"
icon_file="$(plist_value CFBundleIconFile)"

[[ "$bundle_identifier" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
    || fail "Bundle ID mismatch: expected $EXPECTED_BUNDLE_IDENTIFIER, found $bundle_identifier"
[[ "$bundle_version" == "$expected_version" ]] \
    || fail "Version mismatch: expected $expected_version, found $bundle_version"
[[ "$bundle_build" == "$expected_build" ]] \
    || fail "Build mismatch: expected $expected_build, found $bundle_build"
[[ "$executable_name" == "$EXPECTED_EXECUTABLE_NAME" ]] \
    || fail "Executable metadata mismatch: expected $EXPECTED_EXECUTABLE_NAME, found ${executable_name:-<empty>}"
[[ "$package_type" == "$EXPECTED_PACKAGE_TYPE" ]] \
    || fail "Package type mismatch: expected $EXPECTED_PACKAGE_TYPE, found $package_type"
[[ "$minimum_system_version" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] \
    || fail "Minimum system version mismatch: expected $EXPECTED_MINIMUM_SYSTEM_VERSION, found $minimum_system_version"
[[ "$icon_name" == "$EXPECTED_ICON_NAME" ]] \
    || fail "App Icon name mismatch: expected $EXPECTED_ICON_NAME, found $icon_name"
[[ "$icon_file" == "$EXPECTED_ICON_NAME" ]] \
    || fail "App Icon file mismatch: expected $EXPECTED_ICON_NAME, found $icon_file"
[[ -s "$app_path/Contents/Resources/Assets.car" ]] \
    || fail 'Compiled asset catalog is missing'
[[ -s "$app_path/Contents/Resources/AppIcon.icns" ]] \
    || fail 'Compiled App Icon is missing'

executable_path="$app_path/Contents/MacOS/$executable_name"
[[ -f "$executable_path" ]] || fail "App executable is missing: $executable_path"
[[ -x "$executable_path" ]] || fail "App executable is not executable: $executable_path"

if [[ -n "$(find "$app_path" \( \
    -name '*.xctest' \
    -o -name '*XCTest*.dylib' \
    -o -name 'XCTest*.framework' \
    -o -name 'XCUnit.framework' \
    -o -name 'XCUIAutomation.framework' \
    -o -name 'XCTAutomationSupport.framework' \
    -o -name 'Testing.framework' \
    \) -print -quit)" ]]; then
    fail 'App Bundle contains test-only content'
fi

mach_o_count=0
while IFS= read -r -d '' candidate; do
    file_description="$(file -b "$candidate")"
    if [[ "$file_description" != *'Mach-O'* ]]; then
        continue
    fi

    mach_o_count=$((mach_o_count + 1))
    architectures="$(lipo -archs "$candidate" | xargs)"
    [[ "$architectures" == "$EXPECTED_ARCHITECTURE" ]] \
        || fail "Architecture mismatch: expected $EXPECTED_ARCHITECTURE, found $architectures in $candidate"
done < <(find "$app_path" -type f -print0)

[[ $mach_o_count -gt 0 ]] || fail 'App Bundle does not contain a Mach-O executable'

signature_output=''
if ! signature_output="$(codesign --verify --deep --strict --verbose=2 "$app_path" 2>&1)"; then
    fail "App Bundle signature verification failed: $signature_output"
fi

signature_details=''
if ! signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"; then
    fail "unable to inspect App Bundle signature: $signature_details"
fi
[[ "$signature_details" == *'Signature=adhoc'* ]] \
    || fail 'App Bundle is not ad-hoc signed'

if ! detach_output="$(hdiutil detach "$mount_point" 2>&1)"; then
    fail "unable to detach verified DMG: $detach_output"
fi
mounted=0

printf '%s\n' "SHA-256: $actual_hash"
printf '%s\n' "Bundle: $bundle_identifier $bundle_version ($bundle_build)"
printf '%s\n' "Architecture: $EXPECTED_ARCHITECTURE only"
printf '%s\n' 'Signature: ad-hoc, deep and strict verification passed'
printf '%s\n' 'DMG contents: DevEnv.app and Applications -> /Applications'
printf '%s\n' 'Release artifact verification passed.'
