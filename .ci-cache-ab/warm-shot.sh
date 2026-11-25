#!/usr/bin/env bash
# Owner-only disposable GitHub-hosted diagnostic. Never use a daily machine.
set -euo pipefail
export LANG=C LC_ALL=C PYTHONDONTWRITEBYTECODE=1
[[ $# = 2 ]] || exit 64
lane="$1"
stage="$2"
[[ "$lane" = seed || "$lane" = cold || "$lane" = restore ]] || exit 64
[[ "$stage" = prepare || "$stage" = measure ]] || exit 64
[[ ! ${GH_READ_TOKEN+x} && ! ${GH_TOKEN+x} && ! ${GITHUB_TOKEN+x} ]] || {
  printf '%s\n' 'Unexpected credential in compiler/test step; refusing.' >&2; exit 64;
}
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root=/private/tmp/fleck-ci-fresh-ab-v1
base=c48749503e2ee57c0a91e577a98fe219e3f5b02f
pinned="/Applications/Xcode_26.6.app/Contents/Developer"
python3 -B - "$here" "$lane" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
from warm_contract import assert_context
assert_context(os.environ, sys.argv[2])
PY
[[ "$(uname -s)" = Darwin && "$(uname -m)" = arm64 &&
   "${DEVELOPER_DIR:-}" = "$pinned" && -d "$pinned" &&
   -n "${ImageVersion:-}" ]] || {
  printf '%s\n' 'Hosted Darwin/ARM64, exact Xcode path or runner image missing.' >&2; exit 64;
}
export PATH="$pinned/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
xcode="$(xcodebuild -version)"
swift_version="$(swift --version)"
sdk="$(xcrun --sdk macosx --show-sdk-version)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
[[ "$xcode" = $'Xcode 26.6\nBuild version 17F113' &&
   "${swift_version%%$'\n'*}" = 'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)' &&
   "$sdk" = 26.5 && "$sdk_path" = "$pinned/"* &&
   "$(command -v swift)" = "$pinned/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]] || {
  printf '%s\n' 'Exact toolchain/SDK drift; no fallback.' >&2; exit 64;
}
unset FLECK_ENHANCED_CANDIDATE FLECK_TEST_SWIFT_TARGET FLECK_BUILD_WITHOUT_SPARKLE
export FLECK_NATIVE_CAPTURE_QA=0
export GIT_NO_REPLACE_OBJECTS=1
disk_check() {
  local available
  available="$(df -k "$root" | awk 'NR==2{print $4}')"
  [[ "$available" =~ ^[0-9]+$ ]] && (( available > 12000000 )) ||
    { printf '%s\n' 'Hosted disk below 12,000,000 KiB safety floor.' >&2; exit 1; }
}

if [[ "$stage" = prepare ]]; then
  [[ "$(git rev-parse HEAD)" = "$GITHUB_SHA" &&
     "$(git rev-parse HEAD^)" = "$base" &&
     "$(git rev-parse --is-shallow-repository)" = false &&
     -z "$(git status --porcelain --untracked-files=all --ignored=matching)" ]]
  umask 077
  mkdir "$root"             # fail if path exists, including an existing symlink
  [[ "$(cd "$root" && pwd -P)" = "$root" ]]
  disk_check
  mkdir "$root/src" "$root/transfer"
  git archive "$base" | tar -x -C "$root/src"
  python3 -B "$here/warm_contract.py" seed "$root/src" > "$root/source.json"
  python3 -B - "$root" "$xcode" "$swift_version" "$sdk" "$sdk_path" \
    "$(sw_vers -buildVersion)" "$(sysctl -n hw.activecpu)" "$(sysctl -n hw.memsize)" \
    "$(zstd --version)" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
keys = ["xcode", "swift", "sdk", "sdk_path", "os_build", "cpu", "mem_bytes", "zstd"]
values = dict(zip(keys, sys.argv[2:], strict=True))
values.update(image=os.environ["ImageVersion"], arch="ARM64", source=str(root / "src"),
              scratch=str(root / "scratch"), cache=str(root / "package-cache"),
              flags=["--disable-automatic-resolution", "--build-tests", "debug", "ordinary"])
with (root / "machine.json").open("x") as out:
    json.dump(values, out, sort_keys=True)
PY
  printf 'Machine/source pins recorded; allocation step UTC: %s; runner: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RUNNER_NAME:-unknown}"
  cat "$root/machine.json" "$root/source.json"; printf '\n'
  exit
fi

[[ "$(cd "$root" && pwd -P)" = "$root" ]]
disk_check
cd "$root/src"
args=(--scratch-path "$root/scratch" --cache-path "$root/package-cache" --disable-automatic-resolution)
timed() {
  local phase="$1"; shift
  local status=0
  disk_check
  /usr/bin/time -lp "$@" > "$root/$phase.log" 2>&1 || status=$?
  printf '%s phase=%s status=%s\n' "$lane" "$phase" "$status"
  grep -E '^real |^user |^sys |maximum resident set size' "$root/$phase.log" || true
  if (( status != 0 )); then tail -30 "$root/$phase.log" >&2; return "$status"; fi
}
build() {
  timed "$1" swift build "${args[@]}" --build-tests
  grep -qE '^Build complete!? ' "$root/$1.log"
}
resolve() {
  timed "$1" swift package "${args[@]}" resolve
}
probe() {
  local actual="$1" expected="$2" phase="$3" status=0
  FLECK_WARM_EXPECTED=seed FLECK_FRESH_APP_EXPECTED="$expected" \
    swift test "${args[@]}" --skip-build --no-parallel \
    --filter '[./](fleckWarmShadowProbe|fleckFreshABAppProbe)\(\)(/|$)' \
    > "$root/$phase.log" 2>&1 || status=$?
  if ! python3 -B "$here/warm_contract.py" probe "$root/$phase.log" "$actual" "$expected" "$status"; then
    tail -35 "$root/$phase.log" >&2
    return 1
  fi
}
mutate() {
  python3 -B "$here/warm_contract.py" mutate "$root/src" "$root/source.json" > "$root/changed.json"
}

case "$lane" in
  seed)
    [[ ! -e "$root/scratch" && ! -e "$root/package-cache" ]]
    resolve seed.resolve
    build seed.build
    probe seed seed seed.probe
    python3 -B "$here/warm_contract.py" readback "$root/src" "$root/source.json"
    # No manually supplied credentials or inherited local checkout are present.
    # Guard examined dependency metadata immediately before sealing.
    python3 -B "$here/seed_audit.py" "$root/scratch" "$root/package-cache"
    disk_check
    python3 -B "$here/transport.py" pack --scratch "$root/scratch" \
      --package-cache "$root/package-cache" --archive "$root/transfer/fleck-seed.tar.zst" \
      > "$root/pack.json"
    cat "$root/pack.json"
    ;;
  cold)
    mutate
    [[ ! -e "$root/scratch" && ! -e "$root/package-cache" ]]
    resolve cold.resolve
    build cold.build
    probe changed changed cold.probe
    python3 -B "$here/warm_contract.py" readback "$root/src" "$root/changed.json"
    python3 -B - "$root" >> "$GITHUB_OUTPUT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for key in ("source", "machine", "changed"):
    value = json.loads((root / (key + ".json")).read_text())
    print(key + "=" + json.dumps(value, separators=(",", ":")))
PY
    ;;
  restore)
    # This marker can only follow the separate restore-only, exact ledger check.
    [[ -f "$root/verified-envelope.json" && ! -L "$root/verified-envelope.json" ]]
    python3 -B - "$here" "$root" <<'PY'
import json, os, pathlib, sys
sys.path.insert(0, sys.argv[1])
import transport
from warm_contract import check, identity
root = pathlib.Path(sys.argv[2])
seed = transport.read_json(root / "verified-envelope.json")
check(seed["identity"] == identity(os.environ, seed["identity"]["archive_sha256"]),
      "verified restored seed identity changed")
for key in ("source", "machine"):
    check(transport.read_json(root / (key + ".json")) == seed[key]
          == json.loads(os.environ["FLECK_COLD_" + key.upper()]),
          "seed, cold and restore machines or source differ")
bad = root / "corrupt"
bad.mkdir(mode=0o700)
archive = root / "transfer" / transport.ARCHIVE_NAME
with archive.open("rb") as inp, (bad / transport.ARCHIVE_NAME).open("xb") as out:
    out.write(inp.read(1))
try:
    transport.unpack(bad / transport.ARCHIVE_NAME, root / "bad-output",
                     seed["identity"]["archive_sha256"], seed["bytes"])
except transport.Refusal as error:
    check(str(error) == "unexpected sealed blob size", "corruption did not hit the intended check")
else:
    raise transport.Refusal("truncated blob unexpectedly passed validation")
check(not (root / "bad-output").exists(), "bad archive materialized output")
print("Truncated local control rejected before decoding.")
result = transport.unpack(archive, root / "prepared", seed["identity"]["archive_sha256"], seed["bytes"])
check({p.name for p in (root / "prepared").iterdir()} == transport.ROOTS,
      "expected restored root set changed")
check(not any(os.path.lexists(root / name) for name in transport.ROOTS), "active scratch already present")
for name in sorted(transport.ROOTS):
    os.rename(root / "prepared" / name, root / name)
print(json.dumps(result, sort_keys=True))
PY
    probe seed seed restore.seed.probe
    mutate
    python3 -B - "$root/changed.json" <<'PY'
import json, os, pathlib, sys
if json.loads(pathlib.Path(sys.argv[1]).read_text()) != json.loads(os.environ["FLECK_COLD_CHANGED"]):
    raise SystemExit("Cold/restore changed source identity differs; no comparison.")
PY
    probe seed changed restore.stale.probe
    resolve restore.resolve
    build restore.changed.build
    probe changed changed restore.changed.probe
    python3 -B "$here/warm_contract.py" readback "$root/src" "$root/changed.json"
    ;;
esac
test "$(shasum -a 256 Package.resolved | awk '{print $1}')" = 04b4c3d7b6e70193fcc8a0d25d17d30ea8a0dbdf06ea1d1805a702bf0772c4c1
printf '%s lane verified at %s\n' "$lane" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
