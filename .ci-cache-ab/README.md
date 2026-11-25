# Fresh-mac cache A/B: local transport scaffold

Additive local patch based on exact public main
`c48749503e2ee57c0a91e577a98fe219e3f5b02f`. **No remote workflow is installed.**
The low-level transport helper has no network/Swift/activation operations.
Separate branch-only driver, bounded ledger reads and workflow orchestration
are staged locally below. No protected check consumes this code.

## Portable validation and boundaries

```sh
cd .ci-cache-ab
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v
python3 -B transport.py --help
```

Python standard library and an independently pinned/verified installed
`zstd` executable only. Seal uses PAX tar and single-thread fast zstd, caps
the sealed blob at 1.5 GB and raw tar at 6 GB decimal. Restore admits only
one regular non-executable cache blob in a private canonical transfer
directory. It checks trusted size and SHA-256 before decoding the inner
archive; limits decoded disk use and metadata reads, then validates every
member before writing any inner directory. Materialization is to a new
private staging target only; there is no active scratch promotion. Modes,
nanosecond mtimes and proven internal links are recreated; unsupported
archive special metadata, path/case aliases, ambiguous link traversal, invalid
termination and existing output are refused. The scratch source must have
quiesced before a pack. No archive can be assumed to contain no credentials;
a separately reviewed source/payload inventory is required before publishing.
macOS filesystem reflection, real Swift scratch layout and transfer sizes have
not been tested.

The helper reports inner tar/packing, zstd, digest, member validation and
materialization times. The seekable raw spool lets us validate all members
before materializing, but has a disk/I/O cost: budget current trees + up to
6 GB raw spool + restored tree/build growth and margin. See actual compressed/
uncompressed byte receipts and wall time; do not call overhead free.

## Staged orchestration, not authorized to run by this patch

The branch overlay adds three diagnostic-only jobs and an optional empty-by-
default `fresh_ab_admission` input; existing workflow jobs are byte-for-byte
unchanged. Only an owner-originated first-attempt manual dispatch on exact
`refs/heads/elevate/fleck-ci-fresh-ab-v1` in `elevatesoft/Fleck` with legacy
qualification true and nonempty exact admission can schedule them. On that
branch the normal required lanes skip, with the separate stock metadata job
still eligible. Do not merge this branch overlay or make its jobs required.

- Seed and cold use independent fresh standard `macos-26` allocations; restore
  is a third fresh allocation and waits for **both** exact seed and cold
  receipts for source/toolchain comparison without re-running cold. Compare
  queue/seed dependency wait separately from allocated restore-lane elapsed.
  All jobs refuse toolchain, image, architecture, runtime context, disk,
  canonical path, base blob/tree, dependency lock or admission drift.
- Actual Swift driver is staged, never executed in development of this patch.
  It uses the existing ordinary-default compile and Core sentinel, plus an
  isolated runtime App marker in real `DictationRuntimePolicy.swift` and an App
  test fixture. Only that marker changes; fresh identical tree bytes and
  untouched Core/lock read back. The restore lane checks both seed values,
  proves a one-byte corrupt local specimen is refused before inner decode,
  proves old binary reports stale App value with the exact intended assertion
  while Core remains correct, then rebuilds and verifies both edited outputs.
  A missing/malformed/incompatible package cache, hosted App test startup,
  source manifest, literal Swift result or valid archive is a stop, not a
  fallback or success. Real host layout, routes, step times and portability
  await a separately authorized hosted validation.
- The official single save/restore action pin is
  `caa296126883cff596d87d8935842f9db880ef25` and its sole path is
  `/private/tmp/fleck-ci-fresh-ab-v1/transfer/fleck-seed.tar.zst`. No artifacts,
  restore prefixes or consumer save. `ledger.py` requires zero exact-ref entries
  and headroom immediately before save, then exactly one live cache ID/scope,
  and exact action outputs + fresh live object proof before inner validation.
  Allocation jobs use tokens only in read steps. The native code refuses a
  `GH_READ_TOKEN`, `GH_TOKEN` or `GITHUB_TOKEN` in its environment. Build inputs
  are public pinned source only; obvious credential names, unreadable Git
  configs, unknown config directives, and Git remotes that cannot be traced to
  pinned public lock entries are refused. This is not a general secrets scan.

### No-added-bill preflight

An actual operator first verifies the allowed headroom independently with
owner auth, exact public repository, documented included 10 GB cache policy
and current settings, and never sends an owner token to a runner. Provide
only this non-secret owner assertion as the exact workflow input after a
fresh read (values placeholders, not an executed command):

```json
{"repo":"elevatesoft/Fleck","ref":"refs/heads/elevate/fleck-ci-fresh-ab-v1","harness_sha":"EXACT_REVIEWED_BRANCH_SHA","checked_epoch":0,"included_cap":10000000000,"no_added_bill":true,"basis":"owner-reviewed-public-10gb"}
```

The owner assertion is required and scoped, not an API/billing proof. Use
`owner-verified-cap` if a configured cap was actually confirmed. The runner
accepts an admission at start only within 15 minutes, rechecks save within
45 minutes, and independently reads the real repo cap/usage/complete cache
ledger without printing any token. The usage API can lag ~5 minutes, so budget
uses the greater of usage and complete live list; over 100/incomplete entries
fail closed. The effective configured cap can only reduce the owner ceiling.
Only actual HTTP 402 from the storage-limit endpoint can use the particular
owner-reviewed public-10GB basis; a bad shape, 401/403/404, missing Actions
read access, rate limit, unavailable list, or uncertain live cap means **no
save**, no secret transfer and no settings change. The built-in
`github.token` with `actions: read` is scoped to ledger steps, passed via
environment only, never to a child compiler, URLs, logs, or fixtures. If the
installation cannot read the live cache list/quota this way, the hosted driver
cannot validate that ledger. Do not fix this by injecting a personal token,
using a privileged trigger, raising permissions, or omitting the check.

Maximum sealed size 1.5 GB; wrapper reserve 1.6 GB and total active+reserve
≤8 GB with ≥2 GB margin below applicable included cap; separate from public
compute and artifact billing. No storage policy/eviction/deletion/billing
change. A validation failure after save may leave the single approved object,
with no automated retry or cleanup.

Record each GitHub allocated job start, queue/seed waits, first steps,
fresh resolve/build/probe durations and machine specs. Outer save/restore
timings and wrapper bytes are separate from inner hash/decompress/inspect/
materialize counts; no same-VM compile-only speed claim. Methods and API
permissions: [cache REST](https://docs.github.com/en/rest/actions/cache),
[cache trust](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching),
[Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
