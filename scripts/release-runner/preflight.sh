#!/bin/bash

set -euo pipefail

EXPECTED_XCODE_VERSION='Xcode 26.6'
EXPECTED_XCODE_BUILD='Build version 17F113'
EXPECTED_ARCHITECTURE='arm64'
DEFAULT_MINIMUM_FREE_GB=50

usage() {
    cat <<'USAGE'
Usage: preflight.sh --workspace PATH --runner-root PATH [--minimum-free-gb NUMBER]

Validates the dedicated Apple Silicon Release Runner before a controlled build.
USAGE
}

fail() {
    printf 'Release Runner preflight failed: %s\n' "$1" >&2
    exit 1
}

workspace=''
runner_root=''
minimum_free_gb="$DEFAULT_MINIMUM_FREE_GB"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace)
            [[ $# -ge 2 ]] || fail '--workspace requires a path'
            workspace="$2"
            shift 2
            ;;
        --runner-root)
            [[ $# -ge 2 ]] || fail '--runner-root requires a path'
            runner_root="$2"
            shift 2
            ;;
        --minimum-free-gb)
            [[ $# -ge 2 ]] || fail '--minimum-free-gb requires a number'
            minimum_free_gb="$2"
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

[[ -n "$workspace" ]] || fail '--workspace is required'
[[ -n "$runner_root" ]] || fail '--runner-root is required'
[[ -d "$workspace" ]] || fail "workspace does not exist: $workspace"
[[ -d "$runner_root" ]] || fail "Runner root does not exist: $runner_root"
[[ "$minimum_free_gb" =~ ^[0-9]+$ ]] || fail '--minimum-free-gb must be a non-negative integer'

workspace="$(cd "$workspace" && pwd -P)"
runner_root="$(cd "$runner_root" && pwd -P)"

architecture="$(uname -m)"
if [[ "$architecture" != "$EXPECTED_ARCHITECTURE" ]]; then
    fail "Architecture mismatch: expected $EXPECTED_ARCHITECTURE, found $architecture"
fi

if [[ -n "${RUNNER_OS:-}" && "$RUNNER_OS" != 'macOS' ]]; then
    fail "GitHub Runner OS mismatch: expected macOS, found $RUNNER_OS"
fi

if [[ -n "${RUNNER_ARCH:-}" && "$RUNNER_ARCH" != 'ARM64' ]]; then
    fail "GitHub Runner architecture mismatch: expected ARM64, found $RUNNER_ARCH"
fi

xcode_output="$(xcodebuild -version 2>&1)" || fail "unable to read Xcode version: $xcode_output"
xcode_version="$(printf '%s\n' "$xcode_output" | sed -n '1p')"
xcode_build="$(printf '%s\n' "$xcode_output" | sed -n '2p')"
if [[ "$xcode_version" != "$EXPECTED_XCODE_VERSION" || "$xcode_build" != "$EXPECTED_XCODE_BUILD" ]]; then
    fail "Xcode mismatch: expected '$EXPECTED_XCODE_VERSION' and '$EXPECTED_XCODE_BUILD'; found '$xcode_version' and '$xcode_build'"
fi

runner_service="$runner_root/svc.sh"
[[ -x "$runner_service" ]] || fail "Runner service control script is missing or not executable: $runner_service"
service_status="$($runner_service status 2>&1)" || fail "Runner service status check failed: $service_status"
if ! printf '%s\n' "$service_status" | grep -Eiq 'started|running'; then
    fail "Runner service is not running: $service_status"
fi

if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "workspace is not a Git checkout: $workspace"
fi
workspace_changes="$(git -C "$workspace" status --porcelain=v1 --untracked-files=all)"
if [[ -n "$workspace_changes" ]]; then
    fail "workspace is not clean:\n$workspace_changes"
fi

available_kb="$(df -Pk "$workspace" | awk 'NR == 2 { print $4 }')"
[[ "$available_kb" =~ ^[0-9]+$ ]] || fail "unable to determine free disk space for $workspace"
minimum_free_kb=$((minimum_free_gb * 1024 * 1024))
if (( available_kb < minimum_free_kb )); then
    available_gb=$((available_kb / 1024 / 1024))
    fail "Insufficient disk space: require at least ${minimum_free_gb} GiB, found ${available_gb} GiB"
fi

mount_info="$(hdiutil info 2>&1)" || fail "unable to inspect mounted disk images: $mount_info"
runner_work_root="$runner_root/_work"
if printf '%s\n' "$mount_info" | grep -Fq "$runner_work_root/" \
    || printf '%s\n' "$mount_info" | grep -Eq '/Volumes/DevEnv([^[:alnum:]_]|$)'; then
    fail 'Residual release disk image or mounted volume detected; detach it before starting the workflow'
fi

printf '%s\n' "Architecture: $architecture"
printf '%s\n' "$xcode_version" "$xcode_build"
printf '%s\n' "Runner service: running"
printf '%s\n' "Workspace: clean ($workspace)"
printf '%s\n' "Available disk: $((available_kb / 1024 / 1024)) GiB"
printf '%s\n' 'Release mounts: none'
printf '%s\n' 'Release Runner preflight passed.'
