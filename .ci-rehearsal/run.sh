#!/usr/bin/env bash
set -euo pipefail

[[ $# = 5 && ( "$1" = prepare || "$1" = native ) && "$2" = --phase &&
  ( "$3" = focus || "$3" = parity ) ]] || {
  printf '%s\n' "usage: bash run.sh <prepare|native> --phase <focus|parity> <disposable-full-repo> <pinned-selector.py>" >&2
  exit 2
}
mode="$1"
phase="$3"
repo="$4"
selector="$5"
if [[ "$phase" = focus ]]; then
  scenarios=(positive reachable)
  lanes=(focused)
else
  scenarios=(positive reachable omitted)
  lanes=(focused full)
fi
base=c48749503e2ee57c0a91e577a98fe219e3f5b02f
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fleck-pr-shadow-native.XXXXXX")"
printf 'Rehearsal scratch: %s\n' "$root"
rehearsal_start="$(date +%s)"
# The harness checkout/selector are NOT fixtures. Do not run from a daily checkout.
[[ "$(shasum -a 256 "$selector" | awk '{print $1}')" =   700639b11fec3a2b35bdaaeeeb3776bbf5882e5e9fb33cb814d25034160856fb ]]
[[ "$(git -C "$repo" rev-parse --is-shallow-repository)" = false ]]
[[ "$(git -C "$repo" rev-parse "$base^{commit}")" = "$base" ]]
export GIT_AUTHOR_NAME='Fleck CI Rehearsal' GIT_AUTHOR_EMAIL='ci-rehearsal@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
fixture_epoch="$(git -C "$repo" show -s --format=%ct "$base")"
export GIT_AUTHOR_DATE="@$((fixture_epoch + 1)) +0000"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
export PYTHONDONTWRITEBYTECODE=1

if [[ "$mode" = native ]]; then
  # No parity job is installed by this overlay; do not execute it on this ref.
  [[ "$phase" = focus ]] || { printf '%s\n' 'Native parity requires a separately reviewed lane.' >&2; exit 2; }
  [[ "${GITHUB_ACTIONS:-}" = true && "${GITHUB_EVENT_NAME:-}" = workflow_dispatch &&
    "${GITHUB_REPOSITORY:-}" = elevatesoft/Fleck &&
    "${GITHUB_REF:-}" = refs/heads/elevate/fleck-pr-shadow-rehearsal &&
    "${GITHUB_ACTOR:-}" = exterminatorrat &&
    "${GITHUB_JOB:-}" = pr-shadow-focus-rehearsal &&
    "${FLECK_SHADOW_QUALIFICATION_ONLY:-}" = true &&
    "${RUNNER_OS:-}" = macOS && "${RUNNER_ARCH:-}" = ARM64 &&
    "$(uname -s)" = Darwin && "$(uname -m)" = arm64 ]]
  readonly pinned_dir="/Applications/Xcode_26.6.app/Contents/Developer"
  [[ "${DEVELOPER_DIR:-}" = "$pinned_dir" && -d "$pinned_dir" ]] ||
    { printf '%s\n' 'Exact Xcode 26.6 path unavailable; no fallback.' >&2; exit 2; }
  export PATH="$pinned_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
  xcode_version="$(xcodebuild -version)"
  swift_version="$(swift --version)"
  sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
  sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  swift_path="$(command -v swift)"
  printf 'Xcode:\n%s\nSwift:\n%s\nSDK: %s %s\nSwift binary: %s\n' \
    "$xcode_version" "$swift_version" "$sdk_version" "$sdk_path" "$swift_path"
  [[ "$xcode_version" = $'Xcode 26.6\nBuild version 17F113' &&
    "${swift_version%%$'\n'*}" = 'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)' &&
    "$sdk_version" = 26.5 && "$sdk_path" = "$pinned_dir/"* &&
    "$swift_path" = "$pinned_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]] ||
    { printf '%s\n' 'Hosted SDK/toolchain drift; no build or fallback.' >&2; exit 2; }
  sw_vers
fi

wire="Tests/FleckAgentProtocolTests/AgentWireProtocolTests.swift"
events="Tests/FleckAgentProtocolTests/AgentEventWireProtocolTests.swift"
outside="Tests/FleckCoreTests/FleckCIShadowOutsideTargetTests.swift"
git -C "$repo" worktree add --quiet --detach "$root/writer" "$base"
python3 -B "$here/rehearse.py" make --source "$root/writer" --output "$root/overlays"
for scenario in "${scenarios[@]}"; do
  git -C "$root/writer" checkout --quiet --detach "$base"
  cp "$root/overlays/$scenario/$wire" "$root/writer/$wire"
  cp "$root/overlays/$scenario/$events" "$root/writer/$events"
  git -C "$root/writer" add -- "$wire" "$events"
  if [[ "$scenario" = omitted ]]; then
    cp "$root/overlays/$scenario/$outside" "$root/writer/$outside"
    git -C "$root/writer" add -- "$outside"
  fi
  tree="$(git -C "$root/writer" write-tree)"
  topic="$(git -C "$repo" -c commit.gpgSign=false commit-tree "$tree" -p "$base" -m "Synthetic rehearsal: $scenario")"
  merge="$(git -C "$repo" -c commit.gpgSign=false commit-tree "$tree" -p "$base" -p "$topic" -m "Synthetic merge: $scenario")"
  # Move writer off staged files without touching any connected branch.
  git -C "$root/writer" checkout --quiet --detach "$topic"
  printf '{"action":"synchronize","pull_request":{"base":{"ref":"main","sha":"%s"},"head":{"sha":"%s"}}}\n'     "$base" "$topic" > "$root/$scenario.event.json"
  for lane in "${lanes[@]}"; do
    git -C "$repo" worktree add --quiet --detach "$root/$scenario-$lane" "$merge"
  done
done

mkdir "$root/logs" "$root/builds"
for scenario in "${scenarios[@]}"; do
  for lane in "${lanes[@]}"; do
    stem="$scenario-$lane"
    source="$root/$stem"
    before="$(date +%s)"
    merge="$(git -C "$source" rev-parse HEAD)"
    python3 -B "$selector" --repository "$source" --event-name pull_request       --event-file "$root/$scenario.event.json" --source-commit "$merge" > "$root/logs/$stem.proposal.json"
    if [[ "$scenario" = omitted ]]; then expected=full; else expected=focused; fi
    python3 -B - "$root/logs/$stem.proposal.json" "$expected" "$merge" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["proposal"] == sys.argv[2], data
if sys.argv[2] == "focused":
    assert data["target"] == "FleckAgentProtocolTests" and data["source_commit"] == sys.argv[3], data
else:
    assert data["reason"] == "outside_exact_regular_test_modifications", data
print(json.dumps(data, sort_keys=True))
PY
    if [[ "$mode" = prepare ]]; then continue; fi

    # The deliberate wrong route is isolated to the omitted-focused control,
    # which cannot alter or impersonate the actual fail-closed proposal.
    set +e
    (
      unset FLECK_ENHANCED_CANDIDATE FLECK_TEST_APPKIT_PREFLIGHT_SELECTOR \
        FLECK_TEST_SWIFT_TARGET FLECK_TEST_SWIFT_BUILD_SYSTEM \
        FLECK_TEST_SWIFT_CONFIGURATION FLECK_PERF_PREBUILT_RECEIPT \
        FLECK_GLASS_SYNTHETIC_CAPTURE_DIR
      export FLECK_NATIVE_CAPTURE_QA=0
      if [[ "$lane" = focused ]]; then
        if [[ "$scenario" = omitted ]]; then
          printf '%s\n' 'CONTROL ONLY: overriding a full proposal to prove parity alarm.'
        fi
        export FLECK_TEST_SWIFT_BUILD_SYSTEM=swiftbuild
        export FLECK_TEST_SWIFT_TARGET=FleckAgentProtocolTests
      fi
      # In target mode ^.+$ runs every test in the independently built target
      # bundle; evidence rejects off-target IDs. With no target it runs all.
      bash "$source/Scripts/run-swift-tests-with-appkit-host.sh" \
        "$source" "$root/builds/$stem" '^.+$'
    ) 2>&1 | tee "$root/logs/$stem.log"
    statuses=("${PIPESTATUS[@]}")
    set -e
    [[ "${statuses[1]}" = 0 ]]
    printf '%s\n' "${statuses[0]}" > "$root/logs/$stem.status"
    printf '%s selector-through-native execution seconds: %s\n' "$stem" "$(( $(date +%s) - before ))"
    [[ "$(git -C "$source" rev-parse HEAD)" = "$merge" ]]
    git -C "$source" diff --exit-code HEAD --

    # Fail fast on startup, bundle, discovery, timing-receipt or seed problems.
    python3 -B - "$here" "$root" "$scenario" "$lane" <<'PY'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
import rehearse
root, scenario, lane = pathlib.Path(sys.argv[2]), *sys.argv[3:]
stem = root / "logs" / f"{scenario}-{lane}"
expected = json.loads((root / "overlays/manifest.json").read_text())["expected_cases"]
failure = (rehearse.REACHABLE if scenario == "reachable" else
           rehearse.OTHER if (scenario, lane) == ("omitted", "full") else None)
rehearse.evidence(stem.with_suffix(".log").read_text(), expected,
                  focused=lane == "focused", status=int(stem.with_suffix(".status").read_text()),
                  failing=failure)
PY
    if [[ "$scenario" = positive && "$lane" = focused ]]; then
      printf 'positive-focused verified UTC: %s; harness start to verified completion seconds: %s\n'         "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(( $(date +%s) - rehearsal_start ))"
    fi
  done
done
if [[ "$mode" = native ]]; then
  python3 -B "$here/rehearse.py" verify --phase "$phase" --manifest "$root/overlays/manifest.json" --logs "$root/logs"
else
  printf '%s\n' 'Prepared synthetic identities only; no Swift build, dispatch, or native result.'
fi
