#!/usr/bin/env bash
# Standalone diagnostics: resolve pinned dependencies and audit metadata only.
set -euo pipefail
export LANG=C LC_ALL=C PYTHONDONTWRITEBYTECODE=1 GIT_NO_REPLACE_OBJECTS=1
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root=/private/tmp/fleck-ci-fresh-ab-v1
base=c48749503e2ee57c0a91e577a98fe219e3f5b02f
pinned=/Applications/Xcode_26.6.app/Contents/Developer
python3 -B - "$here" <<'PY'
import os, re, sys
sys.path.insert(0, sys.argv[1])
from warm_contract import REPO, REPO_ID, OWNER
flags = {
    "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
    "GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": REPO_ID,
    "GITHUB_REF": "refs/heads/elevate/fleck-cache-resolve-preflight-v1",
    "GITHUB_ACTOR": OWNER, "GITHUB_TRIGGERING_ACTOR": OWNER,
    "GITHUB_RUN_ATTEMPT": "1", "FLECK_FRESH_QUALIFICATION": "true",
    "GITHUB_JOB": "fresh-ab-resolve-preflight",
    "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64",
}
if (any(os.environ.get(k) != v for k, v in flags.items())
    or any(k in os.environ for k in ("GH_READ_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"))
    or not re.fullmatch(r"[1-9][0-9]*", os.environ.get("GITHUB_RUN_ID", ""))
    or not re.fullmatch(r"[0-9a-f]{40}", os.environ.get("GITHUB_SHA", ""))):
    raise SystemExit("Resolve-only preflight refused [hosted-context]")
PY
[[ "$(uname -s)" = Darwin && "$(uname -m)" = arm64 &&
   "${DEVELOPER_DIR:-}" = "$pinned" && -d "$pinned" && -n "${ImageVersion:-}" ]]
export PATH="$pinned/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
xcode="$(xcodebuild -version)"
swift_version="$(swift --version)"
sdk="$(xcrun --sdk macosx --show-sdk-version)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
[[ "$xcode" = $'Xcode 26.6\nBuild version 17F113' &&
   "${swift_version%%$'\n'*}" = 'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)' &&
   "$sdk" = 26.5 && "$sdk_path" = "$pinned/"* &&
   "$(command -v swift)" = "$pinned/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]]
unset FLECK_ENHANCED_CANDIDATE FLECK_TEST_SWIFT_TARGET FLECK_BUILD_WITHOUT_SPARKLE
[[ "$(git rev-parse HEAD)" = "$GITHUB_SHA" &&
   "$(git rev-parse HEAD^)" = cfb6b181cbec2795785360b61b1dd5fdce2bdaab &&
   "$(git rev-parse HEAD^^)" = "$base" &&
   "$(git rev-parse --is-shallow-repository)" = false &&
   -z "$(git status --porcelain --untracked-files=all --ignored=matching)" ]]
umask 077
mkdir "$root"
[[ "$(cd "$root" && pwd -P)" = "$root" ]]
available="$(df -k "$root" | awk 'NR==2{print $4}')"
[[ "$available" =~ ^[0-9]+$ ]] && (( available > 12000000 ))
mkdir "$root/src"
git archive "$base" | tar -x -C "$root/src"
python3 -B "$here/warm_contract.py" seed "$root/src" > "$root/source.json"
cd "$root/src"
if ! swift package --scratch-path "$root/scratch" --cache-path "$root/package-cache" \
    --disable-automatic-resolution resolve >"$root/resolve.log" 2>&1; then
    printf '%s\n' 'Resolve-only preflight refused [swiftpm-resolve]; raw output was not published.' >&2
    exit 1
fi
if ! python3 -B "$here/warm_contract.py" readback "$root/src" "$root/source.json" >"$root/readback.log" 2>&1; then
    printf '%s\n' 'Resolve-only preflight refused [source-readback]; raw output was not published.' >&2
    exit 1
fi
python3 -B "$here/seed_audit.py" "$root/scratch" "$root/package-cache"
printf '%s\n' 'Pinned SwiftPM resolve and sanitized metadata audit passed; no compile or cache transfer.' \
    >> "$GITHUB_STEP_SUMMARY"
