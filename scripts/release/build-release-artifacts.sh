#!/bin/bash

set -euo pipefail
export LC_ALL=C

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=release-common.sh
source "$REPOSITORY_ROOT/scripts/release/release-common.sh"

PROJECT_PATH="$REPOSITORY_ROOT/DevEnv.xcodeproj"
SCHEME='DevEnv'
RESOLVED_FILE="$PROJECT_PATH/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
VERIFY_SCRIPT="$REPOSITORY_ROOT/scripts/release/verify-release-artifacts.sh"
EXPECTED_BUNDLE_IDENTIFIER='io.github.zh826256645.DevEnv'
EXPECTED_ARCHITECTURE='arm64'

usage() {
    cat <<'USAGE'
Usage: build-release-artifacts.sh \
  --version VERSION \
  --build BUILD \
  --output-dir PATH \
  --derived-data PATH \
  --source-packages PATH

Builds the arm64 Release App from the Xcode project's version settings, applies
an ad-hoc Bundle signature, creates the simple DMG, and verifies all artifacts.
USAGE
}

fail() {
    printf 'Release artifact build failed: %s\n' "$1" >&2
    exit 1
}

expected_version=''
expected_build=''
output_dir=''
derived_data_path=''
source_packages_path=''

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --output-dir)
            [[ $# -ge 2 ]] || fail '--output-dir requires a path'
            output_dir="$2"
            shift 2
            ;;
        --derived-data)
            [[ $# -ge 2 ]] || fail '--derived-data requires a path'
            derived_data_path="$2"
            shift 2
            ;;
        --source-packages)
            [[ $# -ge 2 ]] || fail '--source-packages requires a path'
            source_packages_path="$2"
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

[[ -n "$expected_version" ]] || fail '--version is required'
[[ -n "$expected_build" ]] || fail '--build is required'
[[ -n "$output_dir" ]] || fail '--output-dir is required'
[[ -n "$derived_data_path" ]] || fail '--derived-data is required'
[[ -n "$source_packages_path" ]] || fail '--source-packages is required'
release_is_semantic_version "$expected_version" || fail "invalid version: $expected_version"
release_is_build_number "$expected_build" || fail "invalid build: $expected_build"
[[ -f "$RESOLVED_FILE" ]] || fail "locked dependency file is missing: $RESOLVED_FILE"
[[ -x "$VERIFY_SCRIPT" ]] || fail "release verifier is missing or not executable: $VERIFY_SCRIPT"

mkdir -p "$output_dir" "$derived_data_path" "$source_packages_path"
output_dir="$(cd "$output_dir" && pwd -P)"
derived_data_path="$(cd "$derived_data_path" && pwd -P)"
source_packages_path="$(cd "$source_packages_path" && pwd -P)"

dmg_name="DevEnv-${expected_version}-arm64.dmg"
checksum_name="${dmg_name}.sha256"
dsym_name='DevEnv.app.dSYM'
final_dmg="$output_dir/$dmg_name"
final_checksum="$output_dir/$checksum_name"
final_dsym="$output_dir/$dsym_name"

for artifact in "$final_dmg" "$final_checksum" "$final_dsym"; do
    [[ ! -e "$artifact" ]] || fail "refusing to overwrite existing artifact: $artifact"
done

temporary_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$temporary_parent"
temporary_root="$(mktemp -d "$temporary_parent/devenv-release-build.XXXXXX")"
chmod 700 "$temporary_root"

cleanup() {
    local status=$?
    rm -rf "$temporary_root"
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s\n' 'Building DevEnv Release App for arm64...'
xcodebuild build \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS,arch=$EXPECTED_ARCHITECTURE" \
    -derivedDataPath "$derived_data_path" \
    -clonedSourcePackagesDirPath "$source_packages_path" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    ARCHS="$EXPECTED_ARCHITECTURE" \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO

built_app="$derived_data_path/Build/Products/Release/DevEnv.app"
built_dsym="$derived_data_path/Build/Products/Release/DevEnv.app.dSYM"
[[ -d "$built_app" ]] || fail "Release App was not produced: $built_app"
[[ -d "$built_dsym" ]] || fail "Release dSYM was not produced: $built_dsym"

payload_dir="$temporary_root/payload"
mkdir -p "$payload_dir"
staged_app="$payload_dir/DevEnv.app"
ditto "$built_app" "$staged_app"
ln -s /Applications "$payload_dir/Applications"

printf '%s\n' 'Applying complete ad-hoc App Bundle signature...'
codesign --force --deep --sign - --timestamp=none "$staged_app"
if ! signature_output="$(codesign --verify --deep --strict --verbose=2 "$staged_app" 2>&1)"; then
    fail "App Bundle signature verification failed before packaging: $signature_output"
fi

info_plist="$staged_app/Contents/Info.plist"
[[ -f "$info_plist" ]] || fail 'Release App Info.plist is missing'
executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist")"
[[ "$executable_name" == 'DevEnv' ]] || fail "unexpected App executable name: $executable_name"
executable_path="$staged_app/Contents/MacOS/$executable_name"
[[ -f "$executable_path" && -x "$executable_path" ]] || fail "Release App executable is missing or not executable: $executable_path"

bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
bundle_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
bundle_build="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
[[ "$bundle_identifier" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] \
    || fail "Bundle ID mismatch: expected $EXPECTED_BUNDLE_IDENTIFIER, found $bundle_identifier"
[[ "$bundle_version" == "$expected_version" ]] \
    || fail "Version mismatch: expected $expected_version, found $bundle_version"
[[ "$bundle_build" == "$expected_build" ]] \
    || fail "Build mismatch: expected $expected_build, found $bundle_build"

executable_architectures="$(lipo -archs "$executable_path" | xargs)"
[[ "$executable_architectures" == "$EXPECTED_ARCHITECTURE" ]] \
    || fail "Architecture mismatch: expected $EXPECTED_ARCHITECTURE, found $executable_architectures"

staged_dsym="$temporary_root/$dsym_name"
ditto "$built_dsym" "$staged_dsym"
executable_uuid="$(dwarfdump --uuid "$executable_path" | awk '$3 == "(arm64)" { print $2 }')"
dsym_uuid="$(dwarfdump --uuid "$staged_dsym" | awk '$3 == "(arm64)" { print $2 }')"
[[ -n "$executable_uuid" ]] || fail 'unable to read the arm64 UUID from the Release executable'
[[ -n "$dsym_uuid" ]] || fail 'unable to read the arm64 UUID from the Release dSYM'
[[ "$executable_uuid" == "$dsym_uuid" ]] \
    || fail "dSYM UUID mismatch: executable $executable_uuid, dSYM $dsym_uuid"

staged_dmg="$temporary_root/$dmg_name"
printf '%s\n' 'Creating simple compressed DMG...'
hdiutil create \
    -srcfolder "$payload_dir" \
    -volname DevEnv \
    -fs HFS+ \
    -format UDZO \
    "$staged_dmg"

staged_checksum="$temporary_root/$checksum_name"
(
    cd "$temporary_root"
    shasum -a 256 "$dmg_name" > "$checksum_name"
)

"$VERIFY_SCRIPT" \
    --dmg "$staged_dmg" \
    --checksum "$staged_checksum" \
    --version "$expected_version" \
    --build "$expected_build"

mv "$staged_dsym" "$final_dsym"
mv "$staged_dmg" "$final_dmg"
mv "$staged_checksum" "$final_checksum"

printf '%s\n' "Release DMG: $final_dmg"
printf '%s\n' "SHA-256: $final_checksum"
printf '%s\n' "dSYM: $final_dsym"
printf '%s\n' 'Release artifacts built and verified.'
