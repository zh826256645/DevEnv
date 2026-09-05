#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPOSITORY_ROOT/scripts/test/run-xctest-suite.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_fixture() {
    local root="$1"
    mkdir -p "$root/bin" "$root/developer/usr/bin"

    cat > "$root/bin/xcode-select" <<EOF
#!/bin/bash
printf '%s\n' '$root/developer'
EOF

    cat > "$root/bin/xcodebuild" <<'EOF'
#!/bin/bash
set -euo pipefail
derived_data=''
while [[ $# -gt 0 ]]; do
    if [[ "$1" == '-derivedDataPath' ]]; then
        derived_data="$2"
        shift 2
    else
        shift
    fi
done
[[ -n "$derived_data" ]]
app="$derived_data/Build/Products/Debug/DevEnv.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/PlugIns/DevEnvTests.xctest"
touch "$app/Contents/MacOS/DevEnv.debug.dylib"
printf '%s\n' '** TEST BUILD SUCCEEDED **'
EOF

    cat > "$root/developer/usr/bin/xctest" <<'EOF'
#!/bin/bash
case "${XCTEST_FIXTURE_MODE:-pass}" in
pass)
    printf "%s\n" "Test Suite 'All tests' passed." "Executed 2 tests, with 0 failures (0 unexpected) in 0.010 seconds"
    ;;
zero)
    printf "%s\n" "Test Suite 'All tests' passed." "Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds"
    ;;
fail)
    printf "%s\n" "Test Suite 'All tests' failed." "Executed 2 tests, with 1 failure (0 unexpected) in 0.010 seconds"
    exit 1
    ;;
esac
EOF

    chmod +x "$root/bin/xcode-select" "$root/bin/xcodebuild" "$root/developer/usr/bin/xctest"
}

run_fixture() {
    local root="$1"
    local mode="$2"
    PATH="$root/bin:/usr/bin:/bin" \
    XCTEST_FIXTURE_MODE="$mode" \
        "$RUNNER" \
        --project DevEnv.xcodeproj \
        --scheme DevEnv \
        --destination 'platform=macOS,arch=arm64' \
        --derived-data "$root/DerivedData" \
        --source-packages "$root/SourcePackages" \
        --test-log "$root/DevEnvTests.log" 2>&1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xctest-runner-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
make_fixture "$TEST_ROOT"

pass_output="$(run_fixture "$TEST_ROOT" pass)" || fail 'successful XCTest output should pass'
[[ "$pass_output" == *'Executed 2 tests, with 0 failures'* ]] || fail 'successful run should preserve XCTest results'

set +e
zero_output="$(run_fixture "$TEST_ROOT" zero)"
zero_status=$?
failed_output="$(run_fixture "$TEST_ROOT" fail)"
failed_status=$?
set -e

[[ $zero_status -ne 0 ]] || fail 'zero discovered tests must fail the release gate'
[[ "$zero_output" == *'zero tests'* ]] || fail 'zero-test failure should explain the gate'
[[ $failed_status -ne 0 ]] || fail 'XCTest failures must propagate'
[[ "$failed_output" == *'1 failure'* ]] || fail 'failed test output should be retained'

printf 'Direct XCTest runner contract tests passed.\n'
