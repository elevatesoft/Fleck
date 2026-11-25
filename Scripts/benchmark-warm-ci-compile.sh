#!/usr/bin/env bash
# Experimental runner-only benchmark. Never replaces required CI.
set -euo pipefail
export LANG=C LC_ALL=C
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS &&
   "${RUNNER_ARCH:-}" == ARM64 && "${GITHUB_EVENT_NAME:-}" == workflow_dispatch &&
   -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" && -n "${GITHUB_SHA:-}" &&
   "$(git rev-parse HEAD)" == "$GITHUB_SHA" && -z "$(git status --porcelain)" ]]
readonly original_commit="$(git rev-parse HEAD)"
readonly expected_seed_parent=ed06c3ce5f80d7767d0339377693765aed44bb64
[[ "$(git rev-parse HEAD^)" == "$expected_seed_parent" ]]
unset FLECK_ENHANCED_CANDIDATE FLECK_TEST_SWIFT_TARGET
root="$(mktemp -d "$RUNNER_TEMP/fleck-warm-shadow.XXXXXX")"
readonly root
df_available() { /bin/df -k "$root" | /usr/bin/awk 'NR==2{print $4}'; }
check_disk() {
  local k; k="$(df_available)"
  [[ "$k" =~ ^[0-9]+$ ]] && (( k > 12000000 ))
}
check_disk
/bin/mkdir "$root/src"
git archive "$original_commit" | /usr/bin/tar -x -C "$root/src"
cd "$root/src"
readonly source='Sources/FleckCore/Note.swift'
readonly sentinel='Tests/FleckCoreTests/FleckWarmShadowSentinel.swift'
[[ -f "$source" && ! -L "$source" && ! -e "$sentinel" ]]
readonly lock="$(shasum -a 256 Package.resolved | awk '{print $1}')"
printf 'warm-shadow commit=%s lock=%s\n' "$original_commit" "$lock"
sw_vers; xcodebuild -version; swift --version; xcrun --sdk macosx --show-sdk-version
printf 'cpu=%s memory_bytes=%s initial_available_kib=%s\n' "$(sysctl -n hw.activecpu)" "$(sysctl -n hw.memsize)" "$(df_available)"
cat >> "$source" <<'SWIFT'

public enum FleckWarmShadowSource {
    @inline(never) public static func observedValue() -> String { "seed" }
}
SWIFT
cat > "$sentinel" <<'SWIFT'
import FleckCore
import Foundation
import Testing

@Test func fleckWarmShadowProbe() {
    let actual = FleckWarmShadowSource.observedValue()
    let expected = ProcessInfo.processInfo.environment["FLECK_WARM_EXPECTED"]
    print("FLECK_WARM_SENTINEL actual=\(actual) expected=\(expected ?? "missing")")
    #expect(actual == expected)
}
SWIFT

phase() {
  local stage="$1"; shift
  local status=0
  check_disk
  /usr/bin/time -lp "$@" > "$root/$stage.log" 2>&1 || status=$?
  printf 'warm-shadow phase=%s exit=%s available_kib=%s\n' "$stage" "$status" "$(df_available)"
  grep -E '^real |^user |^sys |maximum resident set size' "$root/$stage.log" || true
  if (( status != 0 )); then tail -25 "$root/$stage.log" >&2; return "$status"; fi
}
scope_args() {
  args=(--scratch-path "$root/$1/scratch" --cache-path "$root/$1/cache" --disable-automatic-resolution)
}
compile() {
  local arm="$1" stage="$2"
  scope_args "$arm"
  phase "$stage" swift build "${args[@]}" --build-tests
  grep -qE '^Build complete!? ' "$root/$stage.log"
}
verify_sentinel_receipt() {
  local log="$1" expected="$2" observed="$3" outcome="$4" status="$5"
  [[ "$(grep -Fc 'FLECK_WARM_SENTINEL actual=' "$log")" == 1 ]] || return 1
  grep -Fxq "FLECK_WARM_SENTINEL actual=$observed expected=$expected" "$log" || return 1
  if [[ "$outcome" == pass ]]; then
    (( status == 0 )) &&
      grep -qE 'Test run with 1 test(s)? in [0-9]+ suites? passed' "$log"
  else
    [[ "$outcome" == fail ]] && (( status != 0 )) &&
      grep -qE 'Test run with 1 test(s)? in [0-9]+ suites? failed .*1 issue' "$log"
  fi
}
check_sentinel() {
  local arm="$1" expected="$2" observed="$3" outcome="$4" label="$5" status=0
  scope_args "$arm"
  FLECK_WARM_EXPECTED="$expected" swift test "${args[@]}" --skip-build --no-parallel \
    --filter '[./]fleckWarmShadowProbe\(\)(/|$)' >"$root/$label.log" 2>&1 || status=$?
  if ! verify_sentinel_receipt "$root/$label.log" "$expected" "$observed" "$outcome" "$status"; then
    tail -25 "$root/$label.log" >&2
    return 1
  fi
  printf 'warm-shadow sentinel phase=%s actual=%s expected=%s outcome=%s status=%s\n' \
    "$label" "$observed" "$expected" "$outcome" "$status"
}

for arm in warm clean; do
  scope_args "$arm"
  phase "$arm.resolve" swift package "${args[@]}" resolve
  [[ -z "$(find "$root/$arm/scratch" -type f \( -name build.db -o -name '*.swiftmodule' \) -print -quit)" ]]
done
compile warm warm.seed.compile
check_sentinel warm seed seed pass warm.seed.sentinel

# Change one real Swift source value. Preserve file owner/mode semantics and keep the same absolute source path.
seed_sha="$(shasum -a 256 "$source" | awk '{print $1}')"
/usr/bin/sed 's/observedValue() -> String { "seed" }/observedValue() -> String { "changed" }/' "$source" >"$root/new-source"
[[ "$(/usr/bin/grep -Fc 'observedValue() -> String { "changed" }' "$root/new-source")" == 1 ]]
/bin/cat "$root/new-source" > "$source"
readonly changed_sha="$(shasum -a 256 "$source" | awk '{print $1}')"
[[ "$changed_sha" != "$seed_sha" ]]
printf 'warm-shadow mutation old=%s changed=%s\n' "$seed_sha" "$changed_sha"
check_sentinel warm changed seed fail warm.stale.negative

[[ "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ ]]
if (( 10#$GITHUB_RUN_ID % 2 == 0 )); then order=(warm clean); else order=(clean warm); fi
for arm in "${order[@]}"; do
  [[ "$(shasum -a 256 "$source" | awk '{print $1}')" == "$changed_sha" ]]
  [[ "$(shasum -a 256 Package.resolved | awk '{print $1}')" == "$lock" ]]
  compile "$arm" "$arm.changed.compile"
  check_sentinel "$arm" changed changed pass "$arm.changed.sentinel"
  printf 'warm-shadow arm=%s scratch_kib=%s\n' "$arm" "$(du -sk "$root/$arm" | awk '{print $1}')"
done
[[ "$(shasum -a 256 "$source" | awk '{print $1}')" == "$changed_sha" ]]
[[ "$(shasum -a 256 Package.resolved | awk '{print $1}')" == "$lock" ]]
