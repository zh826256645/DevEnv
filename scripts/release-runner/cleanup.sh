#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../release/release-common.sh
source "$SCRIPT_DIR/../release/release-common.sh"

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
controlled_mounts="$(printf '%s\n' "$mount_info" | awk -v controlled_prefix="$temp_root/" '
    /^image-path[[:space:]]*:/ {
        image_path = $0
        sub(/^[^:]*:[[:space:]]*/, "", image_path)
        image_name = image_path
        sub(/^.*\//, "", image_name)
        controlled = index(image_path, controlled_prefix) == 1
        next
    }
    /^\/dev\// && controlled {
        mount_point = $0
        if (sub(/^.*\t/, "", mount_point) && mount_point ~ /^\//) {
            print image_name "\t" mount_point
        }
    }
')"
while IFS=$'\t' read -r image_name volume; do
    [[ -n "$image_name" && -n "$volume" ]] || continue
    version="${image_name#DevEnv-}"
    version="${version%-arm64.dmg}"
    [[ "$image_name" == "DevEnv-${version}-arm64.dmg" ]] || continue
    release_is_semantic_version "$version" || continue
    printf 'Detaching controlled release volume: %s\n' "$volume"
    hdiutil detach "$volume"
done <<< "$controlled_mounts"

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
