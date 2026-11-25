"""Portable contracts for a guarded diagnostic; no network or compiler."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time

import transport


REPO = "elevatesoft/Fleck"
REPO_ID = "1310071245"
OWNER = "exterminatorrat"
BASE = "c48749503e2ee57c0a91e577a98fe219e3f5b02f"
ROOT = "/private/tmp/fleck-ci-fresh-ab-v1"
SEED_NS = 1795584333 * 1_000_000_000
CORE = "Sources/FleckCore/Note.swift"
APP = "Sources/FleckApp/DictationRuntimePolicy.swift"
PINNED = {
    "Package.swift": "c45d9528aff6f587e07893874a7764deaaf902aad9cfb9d38eaf8c456e131d4e",
    "Package.resolved": "04b4c3d7b6e70193fcc8a0d25d17d30ea8a0dbdf06ea1d1805a702bf0772c4c1",
    CORE: "97f55b55477e1e73a7a606eda693a5c24d0882e18655cdbef7580626159500a0",
    APP: "0fd5083d3549d74bb030279c05a3f3279418af2c25ae47182d576abe5ff8f998",
}
CORE_DECL = """
public enum FleckWarmShadowSource {
    @inline(never) public static func observedValue() -> String { "seed" }
}
"""
APP_DECL = """
enum FleckFreshABAppValue {
    @inline(never) static func observedValue() -> String { "seed" }
}
"""
CORE_TEST = r"""import FleckCore
import Foundation
import Testing

@Test func fleckWarmShadowProbe() {
    let actual = FleckWarmShadowSource.observedValue()
    let expected = ProcessInfo.processInfo.environment["FLECK_WARM_EXPECTED"]
    print("FLECK_WARM_SENTINEL actual=\(actual) expected=\(expected ?? "missing")")
    #expect(actual == expected)
}
"""
APP_TEST = r"""@testable import FleckApp
import Foundation
import Testing

@Test func fleckFreshABAppProbe() {
    let actual = FleckFreshABAppValue.observedValue()
    let expected = ProcessInfo.processInfo.environment["FLECK_FRESH_APP_EXPECTED"]
    print("FLECK_FRESH_APP actual=\(actual) expected=\(expected ?? "missing")")
    #expect(actual == expected, "FLECK_FRESH_APP_ASSERT")
}
"""


def check(condition, message):
    if not condition:
        raise transport.Refusal(message)


def assert_context(env, lane):
    flags = {
        "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": REPO_ID,
        "GITHUB_REF": transport.REF, "GITHUB_ACTOR": OWNER,
        "GITHUB_TRIGGERING_ACTOR": OWNER, "GITHUB_RUN_ATTEMPT": "1",
        "FLECK_FRESH_QUALIFICATION": "true", "GITHUB_JOB": f"fresh-ab-{lane}",
        "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64",
    }
    check(lane in {"seed", "cold", "restore"} and all(env.get(k) == v for k, v in flags.items()),
          "manual owner/ref/repository/job context is not proven")
    check(re.fullmatch(r"[1-9][0-9]*", env.get("GITHUB_RUN_ID", ""))
          and transport.SHA1.fullmatch(env.get("GITHUB_SHA", "")),
          "run/harness identity is not proven")


def admission(env, now, stage):
    # Authenticated owner context gives provenance; it does not make an old
    # or incorrect owner billing statement a platform observation.
    supplied = env.get("FLECK_FRESH_ADMISSION", "")
    check(len(supplied.encode()) <= 2048, "owner admission is oversize")
    record = json.loads(supplied)
    check(isinstance(record, dict) and set(record) == {
        "repo", "ref", "harness_sha", "checked_epoch", "included_cap",
        "no_added_bill", "basis",
    }, "owner admission shape is not proven")
    check(record["repo"] == REPO and record["ref"] == transport.REF
          and record["harness_sha"] == env["GITHUB_SHA"], "owner admission scope changed")
    age = now - record["checked_epoch"] if type(record["checked_epoch"]) is int else -1
    check(0 <= age <= {"start": 900, "save": 2700, "restore": 5400}[stage],
          "owner admission missing, future-dated or stale; no cache activity")
    cap = record["included_cap"]
    check(record["no_added_bill"] is True and type(cap) is int
          and 2_000_000_000 < cap <= 10_000_000_000
          and record["basis"] in {"owner-verified-cap", "owner-reviewed-public-10gb"}
          and (record["basis"] != "owner-reviewed-public-10gb" or cap == 10_000_000_000),
          "owner cap/no-charge basis not established")
    return cap


def active_bytes(usage, listing):
    # Usage can lag by minutes. Require complete live list too, and take max.
    check(isinstance(usage, dict) and str(usage.get("full_name", "")).lower() == REPO.lower(),
          "usage response is not the expected repository")
    value = usage.get("active_caches_size_in_bytes")
    entries = listing.get("actions_caches") if isinstance(listing, dict) else None
    count = listing.get("total_count") if isinstance(listing, dict) else None
    check(type(value) is int and value >= 0 and isinstance(entries, list)
          and type(count) is int and len(entries) == count <= 100,
          "cache ledger is incomplete or malformed")
    sizes, ids = [], set()
    for entry in entries:
        check(isinstance(entry, dict) and type(entry.get("id")) is int and entry["id"] > 0
              and entry["id"] not in ids and type(entry.get("size_in_bytes")) is int
              and entry["size_in_bytes"] > 0, "cache ledger entry unproven")
        sizes.append(entry["size_in_bytes"])
        ids.add(entry["id"])
    return max(value, sum(sizes))


def admit_headroom(cap, active):
    check(active + transport.WRAPPER_MAX <= min(8_000_000_000, cap - 2_000_000_000),
          "headroom does not cover the single bounded cache reserve")


def identity(env, archive_sha):
    result = {"ref": env["GITHUB_REF"], "run": env["GITHUB_RUN_ID"],
              "attempt": env["GITHUB_RUN_ATTEMPT"], "harness_sha": env["GITHUB_SHA"],
              "archive_sha256": archive_sha}
    result["key"] = "fleck-fresh-ab-v1-r{run}-a{attempt}-{harness_sha}-{archive_sha256}".format(**result)
    transport.require_identity(result)
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def stable_hash(value):
    return sha(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def snapshot(source):
    content, mtimes = {}, {}
    for folder, dirs, names in os.walk(source, followlinks=False):
        paths = [Path(folder) / n for n in [*dirs, *names]]
        for path in paths:
            name = str(path.relative_to(source))
            meta = path.lstat()
            if stat.S_ISDIR(meta.st_mode):
                continue
            check(stat.S_ISREG(meta.st_mode) or stat.S_ISLNK(meta.st_mode), "unexpected source entry")
            data = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
            content[name] = [meta.st_mode, sha(data)]
            mtimes[name] = meta.st_mtime_ns
    check(content, "source is empty")
    return content, mtimes


def seed(source):
    for name, digest in PINNED.items():
        path = source / name
        check(path.is_file() and not path.is_symlink() and sha(path.read_bytes()) == digest,
              f"base blob drift: {name}")
    for name, addition in ((CORE, CORE_DECL), (APP, APP_DECL)):
        with (source / name).open("ab") as out:
            out.write(addition.encode())
        os.utime(source / name, ns=(SEED_NS, SEED_NS))
    for name, contents in (
        ("Tests/FleckCoreTests/FleckWarmShadowSentinel.swift", CORE_TEST),
        ("Tests/FleckAppTests/FleckFreshABAppSentinel.swift", APP_TEST),
    ):
        with (source / name).open("xb") as out:
            out.write(contents.encode())
        os.utime(source / name, ns=(SEED_NS, SEED_NS))
    content, mtimes = snapshot(source)
    return {"base": BASE, "tree": stable_hash(content), "input_mtimes": stable_hash(mtimes)}


def mutate(source, expected):
    content, mtimes = snapshot(source)
    check(expected == {"base": BASE, "tree": stable_hash(content), "input_mtimes": stable_hash(mtimes)},
          "source bytes/mode/mtime do not match its seed")
    p = source / APP
    needle = APP_DECL.encode()
    data = p.read_bytes()
    check(data.count(needle) == 1, "App fixture is not uniquely pinned")
    p.write_bytes(data.replace(needle, needle.replace(b'"seed"', b'"changed"'), 1))
    changed, later = snapshot(source)
    check(changed.keys() == content.keys() and
          {k for k in content if content[k] != changed[k]} == {APP} and later[APP] > mtimes[APP]
          and {k for k in mtimes if mtimes[k] != later[k]} == {APP},
          "unexpected changed file, mode or mtime")
    return {"base": BASE, "seed_tree": expected["tree"], "tree": stable_hash(changed)}


def probe_receipt(log, app_actual, app_expected, code):
    expect = "FLECK_FRESH_APP actual=" + app_actual + " expected=" + app_expected
    check(log.splitlines().count(expect) == 1
          and log.count("FLECK_FRESH_APP actual=") == 1
          and log.splitlines().count("FLECK_WARM_SENTINEL actual=seed expected=seed") == 1
          and log.count("FLECK_WARM_SENTINEL actual=") == 1,
          "native value evidence is not exact")
    summary = r"(?m)^[✔✘] Test run with 2 tests in [0-9]+ suites? "
    if app_actual == app_expected:
        check(code == 0 and re.search(summary + "passed after ", log),
              "two named native probes did not complete successfully")
    else:
        issues = [i for i, line in enumerate(log.splitlines()) if line.startswith("✘ ") and "recorded an issue" in line]
        lines = log.splitlines()
        check(code == 1 and re.search(summary + r"failed after .* with 1 issue\.$", log)
              and len(issues) == 1 and "fleckFreshABAppProbe()" in lines[issues[0]]
              and any("FLECK_FRESH_APP_ASSERT" in line for line in lines[issues[0]:issues[0] + 3]),
              "stale control is not the exact App assertion failure")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("seed", "mutate", "probe", "readback"))
    parser.add_argument("path", type=Path)
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    if args.command == "seed" and not args.arguments:
        result = seed(args.path)
    elif args.command == "mutate" and len(args.arguments) == 1:
        result = mutate(args.path, transport.read_json(Path(args.arguments[0])))
    elif args.command == "readback" and len(args.arguments) == 1:
        recorded = transport.read_json(Path(args.arguments[0]))
        content, mtimes = snapshot(args.path)
        check(recorded["base"] == BASE and recorded["tree"] == stable_hash(content)
              and ("input_mtimes" not in recorded or recorded["input_mtimes"] == stable_hash(mtimes)),
              "runtime source identity drift")
        result = recorded
    elif args.command == "probe" and len(args.arguments) == 3:
        actual, expected, status = args.arguments
        probe_receipt(args.path.read_text(), actual, expected, int(status))
        result = {"app_actual": actual, "app_expected": expected, "core": "seed", "status": int(status)}
    else:
        parser.error("invalid command arguments")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(f"warm-shot refused: {error}") from error
