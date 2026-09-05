#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$REPOSITORY_ROOT/scripts/release/build-release-artifacts.sh"
VERIFY_SCRIPT="$REPOSITORY_ROOT/scripts/release/verify-release-artifacts.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local output="$1"
    local expected="$2"
    local context="$3"

    if [[ "$output" != *"$expected"* ]]; then
        printf 'Expected output to contain: %s\nActual output:\n%s\n' "$expected" "$output" >&2
        fail "$context"
    fi
}

make_tools() {
    local fixture_root="$1"

    mkdir -p "$fixture_root/bin"

    cat > "$fixture_root/bin/hdiutil" <<'EOF'
#!/bin/bash
set -euo pipefail

command_name="${1:-}"
shift || true

case "$command_name" in
    verify)
        printf 'verify %s\n' "$1" >> "$FAKE_HDIUTIL_LOG"
        ;;
    attach)
        mount_point=''
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -mountpoint)
                    mount_point="$2"
                    shift 2
                    ;;
                *)
                    shift
                    ;;
            esac
        done
        [[ -n "$mount_point" ]]
        cp -R "$FAKE_DMG_SOURCE/." "$mount_point/"
        printf 'attach %s\n' "$mount_point" >> "$FAKE_HDIUTIL_LOG"
        ;;
    detach)
        printf 'detach %s\n' "$1" >> "$FAKE_HDIUTIL_LOG"
        ;;
    *)
        printf 'unexpected hdiutil command: %s\n' "$command_name" >&2
        exit 2
        ;;
esac
EOF

    cat > "$fixture_root/bin/codesign" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ " $* " == *' --verify '* ]]; then
    app_path="${@: -1}"
    [[ ! -e "$app_path/Contents/.signature-invalid" ]]
    exit
fi

if [[ " $* " == *' -d '* || " $* " == *' --display '* ]]; then
    printf '%s\n' 'Executable=/fixture/DevEnv' >&2
    printf '%s\n' 'Identifier=io.github.zh826256645.DevEnv' >&2
    printf '%s\n' 'Signature=adhoc' >&2
    exit
fi

printf 'unexpected codesign invocation: %s\n' "$*" >&2
exit 2
EOF

    cat > "$fixture_root/bin/file" <<'EOF'
#!/bin/bash
set -euo pipefail
path="${@: -1}"
if [[ "$path" == */Contents/MacOS/DevEnv ]]; then
    printf '%s\n' 'Mach-O 64-bit executable arm64'
else
    printf '%s\n' 'data'
fi
EOF

    cat > "$fixture_root/bin/lipo" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "${FAKE_ARCHS:-arm64}"
EOF

    chmod +x \
        "$fixture_root/bin/hdiutil" \
        "$fixture_root/bin/codesign" \
        "$fixture_root/bin/file" \
        "$fixture_root/bin/lipo"
}

make_release_fixture() {
    local fixture_root="$1"
    local bundle_version="${2:-0.1.0}"

    local volume_root="$fixture_root/volume"
    local app_root="$volume_root/DevEnv.app"
    mkdir -p "$app_root/Contents/MacOS" "$app_root/Contents/Resources"

    cat > "$app_root/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DevEnv</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.zh826256645.DevEnv</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$bundle_version</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
</dict>
</plist>
EOF

    printf '#!/bin/bash\nexit 0\n' > "$app_root/Contents/MacOS/DevEnv"
    chmod +x "$app_root/Contents/MacOS/DevEnv"
    printf 'compiled app icon assets\n' > "$app_root/Contents/Resources/Assets.car"
    printf 'app icon\n' > "$app_root/Contents/Resources/AppIcon.icns"
    ln -s /Applications "$volume_root/Applications"

    printf 'fixture disk image\n' > "$fixture_root/DevEnv-0.1.0-arm64.dmg"
    (
        cd "$fixture_root"
        shasum -a 256 DevEnv-0.1.0-arm64.dmg > DevEnv-0.1.0-arm64.dmg.sha256
    )

    : > "$fixture_root/hdiutil.log"
    make_tools "$fixture_root"
}

run_verifier() {
    local fixture_root="$1"
    shift

    PATH="$fixture_root/bin:/usr/bin:/bin" \
        FAKE_DMG_SOURCE="$fixture_root/volume" \
        FAKE_HDIUTIL_LOG="$fixture_root/hdiutil.log" \
        "$VERIFY_SCRIPT" \
        --dmg "$fixture_root/DevEnv-0.1.0-arm64.dmg" \
        --checksum "$fixture_root/DevEnv-0.1.0-arm64.dmg.sha256" \
        --version 0.1.0 \
        --build 1 \
        "$@" 2>&1
}

assert_verifier_fails() {
    local fixture_root="$1"
    local expected="$2"
    shift 2

    local output
    local status
    set +e
    output="$(run_verifier "$fixture_root" "$@")"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail "verifier should fail: $expected"
    assert_contains "$output" "$expected" "verifier failure should explain: $expected"
    assert_contains "$(<"$fixture_root/hdiutil.log")" 'detach ' 'failed verification should detach the mounted image'
}

test_verifier_accepts_complete_release_artifacts() {
    local fixture_root="$TEST_ROOT/success"
    make_release_fixture "$fixture_root"

    local output
    output="$(run_verifier "$fixture_root")"

    assert_contains "$output" 'Release artifact verification passed.' 'complete release artifacts should pass'
    assert_contains "$(<"$fixture_root/hdiutil.log")" 'verify ' 'verification should validate the DMG container'
    assert_contains "$(<"$fixture_root/hdiutil.log")" 'attach ' 'verification should mount the final DMG'
    assert_contains "$(<"$fixture_root/hdiutil.log")" 'detach ' 'verification should detach the final DMG'
}

test_verifier_rejects_version_mismatch() {
    local fixture_root="$TEST_ROOT/version-mismatch"
    make_release_fixture "$fixture_root" '0.1.1'

    assert_verifier_fails "$fixture_root" 'Version mismatch: expected 0.1.0, found 0.1.1'
}

test_verifier_rejects_architecture_mismatch() {
    local fixture_root="$TEST_ROOT/architecture-mismatch"
    make_release_fixture "$fixture_root"

    FAKE_ARCHS=x86_64 assert_verifier_fails "$fixture_root" 'Architecture mismatch: expected arm64, found x86_64'
}

test_verifier_rejects_missing_applications_link() {
    local fixture_root="$TEST_ROOT/missing-link"
    make_release_fixture "$fixture_root"
    rm "$fixture_root/volume/Applications"

    assert_verifier_fails "$fixture_root" 'Applications symlink is missing'
}

test_verifier_rejects_damaged_signature() {
    local fixture_root="$TEST_ROOT/signature-damaged"
    make_release_fixture "$fixture_root"
    touch "$fixture_root/volume/DevEnv.app/Contents/.signature-invalid"

    assert_verifier_fails "$fixture_root" 'App Bundle signature verification failed'
}

test_verifier_rejects_xctest_content() {
    local fixture_root="$TEST_ROOT/xctest-content"
    make_release_fixture "$fixture_root"
    mkdir -p "$fixture_root/volume/DevEnv.app/Contents/PlugIns/DevEnvTests.xctest"

    assert_verifier_fails "$fixture_root" 'App Bundle contains test-only content'
}

test_verifier_rejects_checksum_mismatch_without_mounting() {
    local fixture_root="$TEST_ROOT/checksum-mismatch"
    make_release_fixture "$fixture_root"
    printf '%064d  %s\n' 0 'DevEnv-0.1.0-arm64.dmg' > "$fixture_root/DevEnv-0.1.0-arm64.dmg.sha256"

    local output
    local status
    set +e
    output="$(run_verifier "$fixture_root")"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail 'checksum mismatch should fail verification'
    assert_contains "$output" 'SHA-256 mismatch' 'checksum mismatch should be explicit'
    [[ ! -s "$fixture_root/hdiutil.log" ]] || fail 'checksum mismatch should fail before mounting the DMG'
}

test_verifier_accepts_semantic_version_build_metadata() {
    local output
    local status
    set +e
    output="$($VERIFY_SCRIPT \
        --dmg "$TEST_ROOT/missing.dmg" \
        --checksum "$TEST_ROOT/missing.dmg.sha256" \
        --version '1.2.3+build.1' \
        --build 2 2>&1)"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail 'missing DMG should still fail validation'
    assert_contains "$output" 'DMG is missing' 'valid SemVer build metadata should pass version parsing'
}

test_verifier_rejects_invalid_semantic_version() {
    local output
    local status
    set +e
    output="$($VERIFY_SCRIPT \
        --dmg "$TEST_ROOT/missing.dmg" \
        --checksum "$TEST_ROOT/missing.dmg.sha256" \
        --version '01.2.3' \
        --build 2 2>&1)"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail 'invalid semantic version should fail validation'
    assert_contains "$output" 'invalid version: 01.2.3' 'semantic version validation should reject leading zeros'
}

test_build_script_exposes_release_artifact_contract() {
    [[ -x "$BUILD_SCRIPT" ]] || fail "missing executable build script: $BUILD_SCRIPT"

    local help_output
    help_output="$($BUILD_SCRIPT --help)"
    assert_contains "$help_output" '--version VERSION' 'build script should require the expected project version'
    assert_contains "$help_output" '--build BUILD' 'build script should require the expected project build'
    assert_contains "$help_output" '--output-dir PATH' 'build script should expose the artifact output directory'
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/release-artifact-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

[[ -x "$VERIFY_SCRIPT" ]] || fail "missing executable verifier: $VERIFY_SCRIPT"

test_verifier_accepts_complete_release_artifacts
test_verifier_rejects_version_mismatch
test_verifier_rejects_architecture_mismatch
test_verifier_rejects_missing_applications_link
test_verifier_rejects_damaged_signature
test_verifier_rejects_xctest_content
test_verifier_rejects_checksum_mismatch_without_mounting
test_verifier_accepts_semantic_version_build_metadata
test_verifier_rejects_invalid_semantic_version
test_build_script_exposes_release_artifact_contract

printf 'Release artifact contract tests passed.\n'
