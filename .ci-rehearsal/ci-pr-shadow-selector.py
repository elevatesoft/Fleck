"""Propose an advisory PR-only test scope; never drive a required CI check.

An eventual driver must invoke this policy from a trusted base revision and use
an exact, fully fetched pull_request merge checkout before restoring anything.
Re-pin that pristine source for the actual test run; do not restore caches into
the source tree or accept ignored Swift inputs/configuration. No workflow
consumes this advisory proposal.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


POLICY = "agent-protocol-tests-v1"
TARGET = "FleckAgentProtocolTests"
ALLOWED = frozenset({
    b"Tests/FleckAgentProtocolTests/AgentEventWireProtocolTests.swift",
    b"Tests/FleckAgentProtocolTests/AgentWireProtocolTests.swift",
})
PR_ACTIONS = frozenset({"opened", "synchronize", "reopened"})
SHA = re.compile(r"[0-9a-f]{40}")
REGULAR_MODIFICATION = re.compile(rb":100644 100644 ([0-9a-f]{40}) ([0-9a-f]{40}) M")
ZERO_SHA = b"0" * 40


class Unproven(ValueError):
    """The input is not sufficient for a positive proposal."""


def git(repository, *args, missing_config_ok=False):
    result = subprocess.run(
        ("git", "--no-replace-objects", "-c", "core.fsmonitor=false", *args),
        cwd=repository,
        env={**os.environ, "GIT_NO_LAZY_FETCH": "1", "GIT_OPTIONAL_LOCKS": "0"},
        capture_output=True,
        check=False,
    )
    if result.returncode == 1 and missing_config_ok and not result.stderr:
        return b""
    if result.returncode or result.stderr:
        raise Unproven("git_state_unproven")
    return result.stdout


def complete_repository(repository):
    if git(repository, "rev-parse", "--is-shallow-repository") != b"false\n":
        return False
    # Reject partial repositories rather than asking Git to fetch missing objects.
    if git(repository, "config", "--get-regexp",
           r"^(extensions\.partialclone|remote\..*\.promisor)$",
           missing_config_ok=True):
        return False
    return True


def oid(value):
    if not isinstance(value, str) or not SHA.fullmatch(value) or value == "0" * 40:
        raise Unproven("event_identity_unproven")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Unproven("event_payload_unproven")
        result[key] = value
    return result


def pr_identity(event_path):
    event = json.loads(Path(event_path).read_text(encoding="utf-8"),
                       object_pairs_hook=unique_object)
    if not isinstance(event, dict) or event.get("action") not in PR_ACTIONS:
        raise Unproven("pr_event_unrecognized")
    pr = event.get("pull_request")
    base = pr.get("base") if isinstance(pr, dict) else None
    head = pr.get("head") if isinstance(pr, dict) else None
    if not isinstance(base, dict) or base.get("ref") != "main" or not isinstance(head, dict):
        raise Unproven("pr_base_or_head_unproven")
    return oid(base.get("sha")), oid(head.get("sha"))


def exact_changes(raw):
    # No prefixes, globs, shell interpretation, or API changed-files lists.
    # All production source, shared fixtures, package manifests and locks,
    # resources, tests outside this pair, scripts and workflow paths are out.
    if not raw or not raw.endswith(b"\0"):
        raise Unproven("change_set_empty_or_malformed")
    records = raw[:-1].split(b"\0")
    if len(records) % 2:
        raise Unproven("change_set_empty_or_malformed")
    changes = {}
    for header, path in zip(records[::2], records[1::2]):
        match = REGULAR_MODIFICATION.fullmatch(header)
        if path not in ALLOWED or path in changes or not match:
            raise Unproven("outside_exact_regular_test_modifications")
        before, after = match.groups()
        if ZERO_SHA in (before, after) or before == after:
            raise Unproven("change_set_empty_or_malformed")
        changes[path] = before, after
    return changes


def tree_changes(repository, before, after):
    return exact_changes(git(
        repository, "diff", "--raw", "-z", "--no-abbrev", "--no-renames",
        "--no-relative", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none",
        before, after, "--",
    ))


def propose(repository, event_name, event_path, source_commit):
    fallback = {"policy": POLICY, "proposal": "full"}
    if event_name != "pull_request":
        return {**fallback, "reason": "not_pull_request"}
    try:
        source_commit = oid(source_commit)
        base, head = pr_identity(event_path)
        if not complete_repository(repository):
            raise Unproven("repository_not_complete")
        checkout = git(repository, "rev-parse", "--verify", "HEAD^{commit}").decode("ascii").strip()
        if checkout != source_commit or git(
            repository, "status", "--porcelain=v1", "-z", "--untracked-files=all",
            "--ignored=matching", "--ignore-submodules=none",
        ):
            raise Unproven("checkout_identity_unproven")
        # A clean status can hide changes under these index flags (or sparse checkout).
        indexed = git(repository, "ls-files", "-v", "-z")
        if not indexed.endswith(b"\0") or any(
            not entry.startswith(b"H ") for entry in indexed[:-1].split(b"\0")
        ):
            raise Unproven("checkout_index_unproven")
        parents = git(repository, "rev-list", "--parents", "-n", "1", source_commit).split()
        if base == head or parents != [commit.encode("ascii") for commit in (source_commit, base, head)]:
            raise Unproven("pr_parent_identity_unproven")
        for commit in (base, head):
            if git(repository, "cat-file", "-t", commit) != b"commit\n":
                raise Unproven("pr_parent_identity_unproven")
        if git(repository, "merge-base", "--all", base, head).split() != [base.encode("ascii")]:
            raise Unproven("pr_base_not_current_ancestor")
        proposed = tree_changes(repository, base, head)
        if proposed != tree_changes(repository, base, source_commit):
            raise Unproven("tested_tree_differs_from_head")
        for blob in sorted({blob for pair in proposed.values() for blob in pair}):
            if git(repository, "cat-file", "-t", blob.decode("ascii")) != b"blob\n":
                raise Unproven("test_blob_unproven")
        source_tree = git(repository, "rev-parse", "--verify", "HEAD^{tree}").decode("ascii").strip()
        return {
            "policy": POLICY, "proposal": "focused", "target": TARGET,
            "source_commit": source_commit, "source_tree": oid(source_tree),
            "base_commit": base, "head_commit": head,
            "paths": [path.decode("ascii") for path in sorted(proposed)],
        }
    except Unproven as error:
        return {**fallback, "reason": str(error)}
    except (OSError, ValueError, TypeError, RecursionError):
        return {**fallback, "reason": "input_unreadable_or_malformed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--event-file", required=True)
    parser.add_argument("--source-commit", required=True)
    args = parser.parse_args()
    print(json.dumps(propose(args.repository, args.event_name, args.event_file,
                             args.source_commit), sort_keys=True))


if __name__ == "__main__":
    main()
