#!/usr/bin/env bash
# Shadow benchmark only. Does not replace Fleck's required tests or packaging.
set -euo pipefail
export LANG=C LC_ALL=C
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == macOS && ${RUNNER_ARCH:-} == ARM64 &&
   ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${GITHUB_REF:-} == refs/heads/elevate/fleck-cold-compile-ab-c487495 &&
   -n ${RUNNER_TEMP:-} && -n ${GITHUB_SHA:-} && "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]]
[[ -z "$(git status --porcelain)" ]]
unset FLECK_ENHANCED_CANDIDATE FLECK_TEST_SWIFT_TARGET
root="$(mktemp -d "$RUNNER_TEMP/fleck-compile-ab.XXXXXX")"
free_kib="$(/bin/df -k "$root" | /usr/bin/awk 'NR==2{print $4}')"
[[ "$free_kib" =~ ^[0-9]+$ ]] && (( free_kib > 12000000 ))
sw_vers; xcodebuild -version; swift --version
printf 'sdk=%s cpu=%s active_cpu=%s mem_bytes=%s\n' "$(xcrun --sdk macosx --show-sdk-version)" \
  "$(sysctl -n hw.ncpu)" "$(sysctl -n hw.activecpu)" "$(sysctl -n hw.memsize)"
swift build --help | awk '/--jobs/{print;getline;print}'
lock="$(shasum -a 256 Package.resolved | awk '{print $1}')"
printf 'compile-ab input commit=%s lock_sha256=%s\n' "$GITHUB_SHA" "$lock"
for a in default j2; do
  printf 'resolve phase arm=%s\n' "$a"
  /usr/bin/time -lp swift package --scratch-path "$root/$a/scratch" --cache-path "$root/$a/cache" \
    --disable-automatic-resolution resolve
  if [[ -n "$(find "$root/$a/scratch" -type f \( -name build.db -o -name '*.swiftmodule' \) -print -quit)" ]]; then
    echo 'unexpected existing compiled products before timing' >&2; exit 1
  fi
done
# Deterministic pseudo-random order based on the allocated GitHub run ID.
[[ ${GITHUB_RUN_ID:-} =~ ^[0-9]+$ ]]
if (( 10#$GITHUB_RUN_ID % 2 == 0 )); then order=(default j2); else order=(j2 default); fi
sampler=''
trap '[[ -z "$sampler" ]] || kill "$sampler" 2>/dev/null || true' EXIT
for a in "${order[@]}"; do
  build=(swift build --build-tests --disable-automatic-resolution
    --scratch-path "$root/$a/scratch" --cache-path "$root/$a/cache")
  if [[ "$a" == j2 ]]; then build+=(--jobs 2); fi
  : > "$root/$a/sample"
  printf 'compile phase arm=%s\n' "$a"
  (
    while :; do
      {
        date +%s
        ps -Ao comm=,rss= | awk '$1 ~ /(^|\/)swift-frontend$/ { c++; rss+=$2 } END { print "frontends=" c+0, "frontend_rss_kib=" rss+0 }'
        vm_stat | awk '/^Pageouts:|^Swapouts:|^Pages occupied by compressor:/'
      } >>"$root/$a/sample"
      sleep 5
    done
  ) &
  sampler=$!
  set +e
  /usr/bin/time -lp "${build[@]}" >"$root/$a/build.log" 2>&1
  status=$?
  set -e
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  sampler=''
  printf 'compile phase arm=%s exit=%s\n' "$a" "$status"
  grep -E '^Build complete|^real |maximum resident set size' "$root/$a/build.log" || true
  awk '
    /^frontends=/ {split($1,a,"="); split($2,b,"="); if(a[2]+0>c)c=a[2]+0; if(b[2]+0>r)r=b[2]+0}
    /^Swapouts:/ {n=1;last=$2}
    END { print "sampled_peak_frontends="c+0, "sampled_peak_frontend_rss_kib="r+0, "observed_final_vm_swapouts="(n?last:"unavailable") }' "$root/$a/sample"
  if (( status != 0 )); then tail -25 "$root/$a/build.log" >&2; exit "$status"; fi
  grep -qE '^Build complete!? ' "$root/$a/build.log"
  test "$lock" = "$(shasum -a 256 Package.resolved | awk '{print $1}')"
done
[[ -z "$(git status --porcelain)" ]]
