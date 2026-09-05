#!/bin/bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: cleanup.sh --workspace PATH --temp-root PATH

Removes unpublished Release Runner artifacts after a controlled workflow.
USAGE
}

fail() {
    printf 'Release Runner cleanup failed: %s\n' "$1" >&2
    exit 1
}

workspace=''
temp_root=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workspace)
            [[ $# -ge 2 ]] || fail '--workspace requires a path'
            workspace="$2"
            shift 2
            ;;
        --temp-root)
            [[ $# -ge 2 ]] || fail '--temp-root requires a path'
            temp_root="$2"
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
[[ -n "$temp_root" ]] || fail '--temp-root is required'
[[ -d "$workspace" ]] || fail "workspace does not exist: $workspace"
[[ -d "$temp_root" ]] || fail "temporary root does not exist: $temp_root"

workspace="$(cd "$workspace" && pwd -P)"
temp_root="$(cd "$temp_root" && pwd -P)"

if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "refusing to clean a non-Git workspace: $workspace"
fi

mount_info="$(hdiutil info 2>&1)" || fail "unable to inspect mounted disk images: $mount_info"
printf '%s\n' "$mount_info" \
    | awk -F '\t' '/\/Volumes\/DevEnv([^[:alnum:]_]|$)/ { print $NF }' \
    | while IFS= read -r volume; do
        [[ -n "$volume" ]] || continue
        printf 'Detaching release volume: %s\n' "$volume"
        hdiutil detach "$volume"
    done

for artifact in \
    "$temp_root/ReleaseRunnerDerivedData" \
    "$temp_root/SourcePackages" \
    "$temp_root/DevEnvTests.xcresult" \
    "$temp_root/release-runner-logs" \
    "$temp_root/release-artifacts"; do
    if [[ -e "$artifact" ]]; then
        printf 'Removing unpublished artifact: %s\n' "$artifact"
        rm -rf "$artifact"
    fi
done

git -C "$workspace" reset --hard HEAD >/dev/null
git -C "$workspace" clean -ffd >/dev/null

printf '%s\n' 'Release Runner cleanup completed.'
