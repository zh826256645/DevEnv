#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFLIGHT_SCRIPT="$REPOSITORY_ROOT/scripts/release-runner/preflight.sh"
WORKFLOW_FILE="$REPOSITORY_ROOT/.github/workflows/release-runner-validation.yml"

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

make_fixture() {
    local fixture_root="$1"
    local architecture="${2:-arm64}"
    local xcode_version="${3:-Xcode 26.6}"
    local xcode_build="${4:-Build version 17F113}"
    local hdiutil_output="${5:-framework       : 700.100.2}"

    mkdir -p "$fixture_root/bin" "$fixture_root/runner" "$fixture_root/workspace"

    cat > "$fixture_root/bin/uname" <<EOF
#!/bin/bash
printf '%s\n' '$architecture'
EOF

    cat > "$fixture_root/bin/xcodebuild" <<EOF
#!/bin/bash
cat <<'OUTPUT'
$xcode_version
$xcode_build
OUTPUT
EOF

    cat > "$fixture_root/bin/df" <<'EOF'
#!/bin/bash
cat <<'OUTPUT'
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s1 200000000 1000000 104857600 1% /
OUTPUT
EOF

    cat > "$fixture_root/bin/hdiutil" <<EOF
#!/bin/bash
cat <<'OUTPUT'
$hdiutil_output
OUTPUT
EOF

    cat > "$fixture_root/runner/svc.sh" <<'EOF'
#!/bin/bash
printf '%s\n' 'status dev.github.actions.runner: Started'
EOF

    chmod +x \
        "$fixture_root/bin/uname" \
        "$fixture_root/bin/xcodebuild" \
        "$fixture_root/bin/df" \
        "$fixture_root/bin/hdiutil" \
        "$fixture_root/runner/svc.sh"

    git -C "$fixture_root/workspace" init -q
    git -C "$fixture_root/workspace" config user.name 'Release Runner Test'
    git -C "$fixture_root/workspace" config user.email 'release-runner-test@example.invalid'
    printf 'fixture\n' > "$fixture_root/workspace/tracked.txt"
    git -C "$fixture_root/workspace" add tracked.txt
    git -C "$fixture_root/workspace" commit -qm 'Create fixture'
}

run_preflight() {
    local fixture_root="$1"

    PATH="$fixture_root/bin:/usr/bin:/bin" \
        "$PREFLIGHT_SCRIPT" \
        --workspace "$fixture_root/workspace" \
        --runner-root "$fixture_root/runner" \
        --minimum-free-gb 50 2>&1
}

test_preflight_accepts_expected_release_host() {
    local fixture_root="$TEST_ROOT/success"
    make_fixture "$fixture_root"

    local output
    output="$(run_preflight "$fixture_root")"

    assert_contains "$output" 'Release Runner preflight passed.' 'expected release host should pass preflight'
}

test_preflight_rejects_xcode_mismatch() {
    local fixture_root="$TEST_ROOT/xcode-mismatch"
    make_fixture "$fixture_root" 'arm64' 'Xcode 26.5' 'Build version 17F90'

    local output
    local status
    set +e
    output="$(run_preflight "$fixture_root")"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail 'Xcode mismatch should fail preflight'
    assert_contains "$output" "Xcode mismatch: expected 'Xcode 26.6' and 'Build version 17F113'" 'Xcode mismatch should explain the pinned toolchain'
}

test_preflight_rejects_non_arm64_host() {
    local fixture_root="$TEST_ROOT/architecture-mismatch"
    make_fixture "$fixture_root" 'x86_64'

    local output
    local status
    set +e
    output="$(run_preflight "$fixture_root")"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail 'non-arm64 host should fail preflight'
    assert_contains "$output" 'Architecture mismatch: expected arm64, found x86_64' 'architecture mismatch should be explicit'
}

test_preflight_rejects_release_mount_residue() {
    local fixture_root="$TEST_ROOT/mount-residue"
    local mounted_image
    mounted_image=$(cat <<EOF
framework       : 700.100.2
image-path      : $fixture_root/workspace/DevEnv-unpublished.dmg
/dev/disk9s1    Apple_HFS                       /Volumes/DevEnv
EOF
)
    make_fixture "$fixture_root" 'arm64' 'Xcode 26.6' 'Build version 17F113' "$mounted_image"

    local output
    local status
    set +e
    output="$(run_preflight "$fixture_root")"
    status=$?
    set -e

    [[ $status -ne 0 ]] || fail 'release mount residue should fail preflight'
    assert_contains "$output" 'Residual release disk image or mounted volume detected' 'mount residue should explain the cleanup requirement'
}

test_workflow_exposes_controlled_release_runner_contract() {
    python3 - "$WORKFLOW_FILE" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(f"missing workflow: {path}")

text = path.read_text()
required_patterns = {
    "manual-only trigger": r"(?m)^on:\s*\n\s+workflow_dispatch:\s*$",
    "exact runner labels": r"(?ms)^\s+runs-on:\s*\n\s+- self-hosted\s*\n\s+- macOS\s*\n\s+- ARM64\s*\n\s+- release\s*$",
    "preflight invocation": r"scripts/release-runner/preflight\.sh",
    "arm64 XCTest": r"scripts/test/run-xctest-suite\.sh[\s\S]*?--destination [\"']platform=macOS,arch=arm64[\"'][\s\S]*?--test-log",
    "Release build": r"xcodebuild build[\s\S]*?-configuration Release[\s\S]*?ARCHS=arm64",
    "post-job cleanup": r"if:\s*\$\{\{ always\(\) \}\}[\s\S]*?scripts/release-runner/cleanup\.sh",
}

for description, pattern in required_patterns.items():
    if re.search(pattern, text) is None:
        raise SystemExit(f"workflow is missing {description}")

precheck_index = text.find("Inspect existing Runner workspace")
checkout_index = text.find("Check out selected commit")
preflight_index = text.find("Preflight dedicated Release Runner")
if precheck_index < 0 or not (precheck_index < checkout_index < preflight_index):
    raise SystemExit("workflow must inspect the existing Runner workspace before checkout")

for forbidden in ("pull_request:", "push:", "schedule:", "xcode-select", "RUNNER_WORKSPACE", "xcodebuild test"):
    if forbidden in text:
        raise SystemExit(f"workflow must not contain {forbidden}")
PY
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/release-runner-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

test_preflight_accepts_expected_release_host
test_preflight_rejects_xcode_mismatch
test_preflight_rejects_non_arm64_host
test_preflight_rejects_release_mount_residue
test_workflow_exposes_controlled_release_runner_contract

printf 'Release Runner contract tests passed.\n'
