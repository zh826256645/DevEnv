#!/bin/bash

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW_FILE="$REPOSITORY_ROOT/.github/workflows/release.yml"
CI_WORKFLOW_FILE="$REPOSITORY_ROOT/.github/workflows/ci.yml"
XCTEST_RUNNER="$REPOSITORY_ROOT/scripts/test/run-xctest-suite.sh"

python3 - "$WORKFLOW_FILE" "$CI_WORKFLOW_FILE" "$XCTEST_RUNNER" <<'PY'
from pathlib import Path
import re
import sys

workflow_path = Path(sys.argv[1])
ci_path = Path(sys.argv[2])
xctest_runner_path = Path(sys.argv[3])
if not workflow_path.exists():
    raise SystemExit(f"missing workflow: {workflow_path}")
if not xctest_runner_path.exists():
    raise SystemExit(f"missing XCTest runner: {xctest_runner_path}")

text = workflow_path.read_text()
ci_text = ci_path.read_text()
xctest_runner_text = xctest_runner_path.read_text()

required_patterns = {
    "manual workflow inputs": r"(?ms)^on:\s*\n\s+workflow_dispatch:\s*\n\s+inputs:\s*\n.*?mode:\s*\n.*?type:\s*choice\s*\n.*?options:\s*\n\s+- dry-run\s*\n\s+- release\s*\n.*?version:\s*\n.*?required:\s*true\s*\n.*?target_sha:\s*\n.*?required:\s*true",
    "read-only default permission": r"(?ms)^permissions:\s*\n\s+contents:\s*read\s*$",
    "serialized release runs": r"(?ms)^concurrency:\s*\n\s+group:\s*release\s*\n\s+cancel-in-progress:\s*false\s*$",
    "dedicated release runner": r"(?ms)^\s+build-and-verify:\s*\n.*?runs-on:\s*\n\s+- self-hosted\s*\n\s+- macOS\s*\n\s+- ARM64\s*\n\s+- release\s*$",
    "build job read permission": r"(?ms)^\s+build-and-verify:\s*\n.*?permissions:\s*\n\s+contents:\s*read\s*$",
    "full SHA validation": r"TARGET_SHA[^\n]*\^\[0-9a-fA-F\]\{40\}\$",
    "remote master validation": r"git/ref/heads/master[\s\S]*?remote_master_sha[\s\S]*?TARGET_SHA",
    "exact target checkout": r"uses:\s*actions/checkout@[0-9a-f]{40}[\s\S]*?ref:\s*\$\{\{ inputs\.target_sha \}\}[\s\S]*?persist-credentials:\s*false",
    "locked v0.1.0 metadata": r"EXPECTED_RELEASE_VERSION:\s*0\.1\.0[\s\S]*?EXPECTED_RELEASE_BUILD:\s*[\"']?1[\"']?[\s\S]*?RELEASE_VERSION[\s\S]*?EXPECTED_RELEASE_VERSION[\s\S]*?builds != \{expected_build\}",
    "release runner preflight": r"scripts/release-runner/preflight\.sh",
    "locked dependency resolution": r"xcodebuild -resolvePackageDependencies[\s\S]*?-disableAutomaticPackageResolution[\s\S]*?-onlyUsePackageVersionsFromResolvedFile[\s\S]*?git diff --quiet",
    "all arm64 XCTest": r"scripts/test/run-xctest-suite\.sh[\s\S]*?--destination [\"']platform=macOS,arch=arm64[\"'][\s\S]*?--test-log",
    "artifact build script": r"scripts/release/build-release-artifacts\.sh[\s\S]*?--version[\s\S]*?--build[\s\S]*?--output-dir",
    "temporary distribution artifact": r"(?m)uses:\s*actions/upload-artifact@[0-9a-f]{40}[\s\S]*?DevEnv-.*-arm64\.dmg[\s\S]*?retention-days:\s*(?:[1-9]|[1-8][0-9])\s*$",
    "restricted diagnostics retention": r"(?m)--test-log [\"']\$RUNNER_TEMP/release-runner-logs/DevEnvTests\.log[\"'][\s\S]*?uses:\s*actions/upload-artifact@[0-9a-f]{40}[\s\S]*?release-runner-logs[\s\S]*?DevEnv\.app\.dSYM[\s\S]*?retention-days:\s*90\s*$",
    "release-only publish job": r"(?ms)^\s+publish-release:\s*\n\s+name:.*\n\s+if:\s*\$\{\{[^\n]*inputs\.mode == 'release'[^\n]*\}\}",
    "publish dependency": r"(?ms)^\s+publish-release:\s*\n.*?needs:\s*build-and-verify",
    "publish dedicated runner": r"(?ms)^\s+publish-release:\s*\n.*?runs-on:\s*\n\s+- self-hosted\s*\n\s+- macOS\s*\n\s+- ARM64\s*\n\s+- release\s*$",
    "publish write permission": r"(?ms)^\s+publish-release:\s*\n.*?permissions:\s*\n\s+contents:\s*write\s*$",
    "existing tag guard": r"git/matching-refs/tags/\$TAG_NAME[\s\S]*?refusing to overwrite existing tag",
    "existing release guard": r"releases\?per_page=100[\s\S]*?refusing to overwrite existing release",
    "annotated tag creation": r"repos/\$GITHUB_REPOSITORY/git/tags[\s\S]*?repos/\$GITHUB_REPOSITORY/git/refs",
    "locked release notes": r"RELEASE_NOTES_FILE:\s*docs/releases/v\$\{\{ needs\.build-and-verify\.outputs\.version \}\}\.md[\s\S]*?\[\[ -s \"\$RELEASE_NOTES_FILE\" \]\][\s\S]*?--notes-file \"\$RELEASE_NOTES_FILE\"",
    "draft prerelease creation": r"gh release create[\s\S]*?--notes-file \"\$RELEASE_NOTES_FILE\"[\s\S]*?--draft[\s\S]*?--prerelease",
    "draft prerelease verification": r"release_state=.*releases\?per_page=100[\s\S]*?select\(\.tag_name == .*TAG_NAME.*\)[\s\S]*?\[\.draft, \.prerelease\]",
    "post-job cleanup": r"if:\s*\$\{\{ always\(\) \}\}[\s\S]*?scripts/release-runner/cleanup\.sh",
}

for description, pattern in required_patterns.items():
    if re.search(pattern, text) is None:
        raise SystemExit(f"release workflow is missing {description}")

if text.count("git/ref/heads/master") < 2:
    raise SystemExit("remote master must be rechecked before both build and publication")
if text.count("scripts/release-runner/cleanup.sh") < 2:
    raise SystemExit("both self-hosted jobs must clean their Runner artifacts")
first_master_check = text.find("git/ref/heads/master")
first_checkout = text.find("uses: actions/checkout@")
if first_master_check < 0 or first_checkout < 0 or first_master_check > first_checkout:
    raise SystemExit("target_sha must be proven equal to remote master before caller-selected code is checked out")
if first_master_check > text.find("source scripts/release/release-common.sh"):
    raise SystemExit("caller-selected repository code must not run before the target is proven to be remote master")
if "always() && steps.validate-checkout.outcome == 'success'" not in text:
    raise SystemExit("build cleanup must not execute repository code for a rejected or incomplete checkout")

if "runs-on: macos-26" not in ci_text:
    raise SystemExit("CI must use the arm64 macOS 26 image with the locked Xcode 26.6 toolchain")
for expected_toolchain_contract in (
    'EXPECTED_XCODE_VERSION: "26.6"',
    'EXPECTED_XCODE_BUILD: "17F113"',
    'unexpected Xcode toolchain',
):
    if expected_toolchain_contract not in ci_text:
        raise SystemExit(f"CI is missing locked toolchain contract: {expected_toolchain_contract}")
if "bash scripts/tests/release-workflow-contract-tests.sh" not in ci_text:
    raise SystemExit("CI must run the release workflow contract tests")
if "bash scripts/tests/xctest-runner-contract-tests.sh" not in ci_text:
    raise SystemExit("CI must run the direct XCTest runner contract tests")
if "scripts/test/run-xctest-suite.sh" not in ci_text:
    raise SystemExit("CI must use the direct XCTest runner")

xctest_runner_patterns = {
    "build-for-testing": r"xcodebuild build-for-testing",
    "direct XCTest executable": r"DEVELOPER_DIR_PATH.*usr/bin/xctest",
    "host app library injection": r"DYLD_INSERT_LIBRARIES=.*APP_LIBRARY",
    "isolated class execution": r"-XCTest \"DevEnvTests\.\$test_class\"",
    "test result logging": r"tee -a \"\$TEST_LOG\"",
}
for description, pattern in xctest_runner_patterns.items():
    if re.search(pattern, xctest_runner_text) is None:
        raise SystemExit(f"XCTest runner is missing {description}")

class_block = re.search(r"TEST_CLASSES=\(\n([\s\S]*?)\n\)", xctest_runner_text)
if class_block is None:
    raise SystemExit("XCTest runner is missing its isolated test class list")
configured_classes = set(re.findall(r"^\s+([A-Za-z0-9_]+Tests)\s*$", class_block.group(1), re.MULTILINE))
declared_classes = set()
for source in (xctest_runner_path.parents[2] / "DevEnvTests").glob("*.swift"):
    declared_classes.update(re.findall(
        r"\b(?:final\s+)?class\s+([A-Za-z0-9_]+Tests)\s*:\s*XCTestCase",
        source.read_text(),
    ))
if configured_classes != declared_classes:
    raise SystemExit(
        f"XCTest runner class list mismatch: configured={sorted(configured_classes)}, "
        f"declared={sorted(declared_classes)}"
    )

for forbidden in ("pull_request:", "push:", "schedule:", "continue-on-error:", "xcode-select", "release-distribution", "xcodebuild test"):
    if forbidden in text:
        raise SystemExit(f"release workflow must not contain {forbidden}")

for line_number, line in enumerate(text.splitlines(), start=1):
    match = re.search(r"\buses:\s*([^\s]+)", line)
    if match is None:
        continue
    reference = match.group(1)
    if re.fullmatch(r"actions/(?:checkout|upload-artifact|download-artifact)@[0-9a-f]{40}", reference) is None:
        raise SystemExit(f"external action is not pinned to a full commit SHA on line {line_number}: {reference}")

build_index = text.find("build-and-verify:")
publish_index = text.find("publish-release:")
tag_guard_index = text.find("refusing to overwrite existing tag", publish_index)
release_guard_index = text.find("refusing to overwrite existing release", publish_index)
tag_create_index = text.find("git/tags", publish_index)
release_create_index = text.find("gh release create", publish_index)
if min(build_index, publish_index, tag_guard_index, release_guard_index, tag_create_index, release_create_index) < 0:
    raise SystemExit("unable to verify release write ordering")
if not (build_index < publish_index < tag_guard_index < tag_create_index < release_create_index):
    raise SystemExit("Tag and Release writes must occur only after successful build gates and collision guards")
if not (publish_index < release_guard_index < tag_create_index):
    raise SystemExit("existing Release guard must run before annotated Tag creation")
PY

printf 'Release workflow contract tests passed.\n'
