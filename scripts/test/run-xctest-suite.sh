#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: run-xctest-suite.sh \
  --project <path> \
  --scheme <name> \
  --destination <destination> \
  --derived-data <path> \
  --source-packages <path> \
  --test-log <path>
EOF
}

PROJECT_PATH=""
SCHEME=""
DESTINATION=""
DERIVED_DATA=""
SOURCE_PACKAGES=""
TEST_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    --project)
        PROJECT_PATH="${2:-}"
        shift 2
        ;;
    --scheme)
        SCHEME="${2:-}"
        shift 2
        ;;
    --destination)
        DESTINATION="${2:-}"
        shift 2
        ;;
    --derived-data)
        DERIVED_DATA="${2:-}"
        shift 2
        ;;
    --source-packages)
        SOURCE_PACKAGES="${2:-}"
        shift 2
        ;;
    --test-log)
        TEST_LOG="${2:-}"
        shift 2
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        printf 'Unknown argument: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
done

for value_name in PROJECT_PATH SCHEME DESTINATION DERIVED_DATA SOURCE_PACKAGES TEST_LOG; do
    if [[ -z "${!value_name}" ]]; then
        printf 'Missing required argument for %s\n' "$value_name" >&2
        usage >&2
        exit 2
    fi
done

mkdir -p "$(dirname "$TEST_LOG")" "$DERIVED_DATA" "$SOURCE_PACKAGES"
: > "$TEST_LOG"

xcodebuild build-for-testing \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    2>&1 | tee -a "$TEST_LOG"

APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/DevEnv.app"
APP_LIBRARY="$APP_BUNDLE/Contents/MacOS/DevEnv.debug.dylib"
TEST_BUNDLE="$APP_BUNDLE/Contents/PlugIns/DevEnvTests.xctest"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
XCTEST_EXECUTABLE="$DEVELOPER_DIR_PATH/usr/bin/xctest"
PLATFORM_FRAMEWORKS="$DEVELOPER_DIR_PATH/Platforms/MacOSX.platform/Developer/Library/Frameworks"
PROFILE_PATH="$DERIVED_DATA/DevEnvTests-%p.profraw"

[[ -d "$APP_BUNDLE" ]] || { printf 'Missing test host app: %s\n' "$APP_BUNDLE" >&2; exit 1; }
[[ -f "$APP_LIBRARY" ]] || { printf 'Missing test host library: %s\n' "$APP_LIBRARY" >&2; exit 1; }
[[ -d "$TEST_BUNDLE" ]] || { printf 'Missing XCTest bundle: %s\n' "$TEST_BUNDLE" >&2; exit 1; }
[[ -x "$XCTEST_EXECUTABLE" ]] || { printf 'Missing XCTest executable: %s\n' "$XCTEST_EXECUTABLE" >&2; exit 1; }

framework_path="$APP_BUNDLE/Contents/Frameworks:$PLATFORM_FRAMEWORKS"
if [[ -n "${DYLD_FRAMEWORK_PATH:-}" ]]; then
    framework_path="$framework_path:$DYLD_FRAMEWORK_PATH"
fi

DYLD_INSERT_LIBRARIES="$APP_LIBRARY" \
DYLD_FRAMEWORK_PATH="$framework_path" \
LLVM_PROFILE_FILE="$PROFILE_PATH" \
NSUnbufferedIO=YES \
    "$XCTEST_EXECUTABLE" "$TEST_BUNDLE" 2>&1 | tee -a "$TEST_LOG"

python3 - "$TEST_LOG" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(errors="replace")
summaries = re.findall(
    r"Executed ([0-9]+) tests?, with ([0-9]+) failures? \(([0-9]+) unexpected\)",
    text,
)
if not summaries:
    raise SystemExit("XCTest output did not contain an executed-test summary")
executed, failures, unexpected = (int(value) for value in summaries[-1])
if executed == 0:
    raise SystemExit("XCTest reported zero tests; refusing to pass the release gate")
if failures != 0 or unexpected != 0:
    raise SystemExit(
        f"XCTest summary reported {failures} failures ({unexpected} unexpected)"
    )
print(f"Verified XCTest execution: {executed} tests, 0 failures.")
PY
