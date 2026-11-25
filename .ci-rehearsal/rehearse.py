"""Offline preparation/evidence checker for a synthetic, non-gating Fleck rehearsal."""

import argparse
from base64 import b64encode
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import sys


TARGET = "FleckAgentProtocolTests"
WIRE = Path("Tests/FleckAgentProtocolTests/AgentWireProtocolTests.swift")
EVENTS = Path("Tests/FleckAgentProtocolTests/AgentEventWireProtocolTests.swift")
ORIGINAL_SHA256 = {
    WIRE: "ce9dfdba0a6d1f71383206a50f0ff92fc090c4404d88b3d10d584b05d5f867b4",
    EVENTS: "b56120b94c845f169a5a4cabf3753c4b527e3341e6814a6a376ff7989b17bc89",
}
OUTSIDE = Path("Tests/FleckCoreTests/FleckCIShadowOutsideTargetTests.swift")
REACHABLE = "FLECK_PR_SHADOW_REACHABLE"
OTHER = "FLECK_PR_SHADOW_OUTSIDE"
MARKER = "FLECK_PR_SHADOW_CASE|"
# Macro + named declaration, limited to these exact two source files.
DECLARATION = re.compile(
    r"(?m)^([ ]*)@Test(?:\(arguments:[\s\S]*?\))?\s+"
    r"func ([A-Za-z][A-Za-z0-9_]*)\([^{}]*?\)\s*(?:throws\s*)?(?:async\s*)?"
    r"(?:throws\s*)?\{"
)
PASSED = re.compile(r"^✔ Test run with [1-9][0-9]* tests? in [0-9]+ suites? passed after ")
ISSUE = re.compile(r"^✘ .*recorded an issue(?: at |:|$)")
FAIL_SUMMARY = re.compile(r"^✘ Test run with .* failed after .* with 1 issue\.$")


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def make_fixtures(source, output):
    original = {path: (source / path).read_text(encoding="utf-8") for path in (WIRE, EVENTS)}
    if {path: sha(contents) for path, contents in original.items()} != ORIGINAL_SHA256:
        raise ValueError("unexpected test fixture source; review and pin both files again")
    (output / "positive").mkdir(parents=True)
    expected = []
    instrumented = {}
    for path, text in original.items():
        payloads = re.findall(r'(?m)^  #"(\{[^\n]+\})"#,?$', text)
        params = {
            "agentWireRequestCarriesUnsupportedVersionsForServerRejection": (
                "version", ("0", "2")),
            "agentWireResponseRejectsNonexclusivePayloads": (
                "Data(json.utf8).base64EncodedString()",
                tuple(b64encode(p.encode()).decode() for p in payloads)),
            "invalidDeclaredFrameLengthsAreRejectedImmediately": ("length", ("0", "1048577")),
            "supportedVersionsRoundTrip": ("version", ("1", "2")),
            "responsesEchoAcceptedRequestVersion": ("version", ("1", "2")),
        } if path == WIRE else {}
        matches = list(DECLARATION.finditer(text))
        if len(matches) != text.count("@Test") or len(matches) != ({WIRE: 21, EVENTS: 4}[path]):
            raise ValueError(f"unreviewed Swift test declarations: {path}")
        for match in reversed(matches):
            indent, name = match.groups()
            if ("@Test(arguments:" in match.group(0)) != (name in params):
                raise ValueError(f"unreviewed parameterization: {name}")
            expression, values = params.get(name, (None, ("single",)))
            if len(values) != (2 if name in params else 1):
                raise ValueError(f"unexpected input fixtures: {name}")
            expected.extend((name, value) for value in values)
            field = "\\(" + expression + ")" if expression else "single"
            i = match.end()
            statement = f'\n{indent}  defer {{ print("{MARKER}{name}|{field}") }}'
            text = text[:i] + statement + text[i:]
        instrumented[path] = text

    negative = instrumented[WIRE]
    anchor = f'defer {{ print("{MARKER}agentWireRequestCarriesUnsupportedVersionsForServerRejection|\\(version)") }}'
    if negative.count(anchor) != 1:
        raise ValueError("reachable assertion location is no longer unique")
    negative = negative.replace(anchor, anchor + f'\n  #expect(version != 2, "{REACHABLE}")')
    omitted_control = f'import Testing\n\n@Test func fleckShadowOutsideTargetFails() {{\n  #expect(Bool(false), "{OTHER}")\n}}\n'
    overlays = {
        "positive": instrumented,
        "reachable": {**instrumented, WIRE: negative},
        "omitted": {**instrumented, OUTSIDE: omitted_control},
    }
    manifest = {
        "kind": "synthetic-rehearsal-only",
        "original_sha256": {str(p): sha(s) for p, s in original.items()},
        "scenarios": {mode: {str(p): sha(s) for p, s in files.items()}
                      for mode, files in overlays.items()},
        "expected_cases": sorted(expected),
    }
    for mode, files in overlays.items():
        for path, contents in files.items():
            destination = output / mode / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(contents, encoding="utf-8")
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def evidence(log, expected, *, focused, status, failing=None):
    lines = log.splitlines()
    records = Counter(tuple(line[len(MARKER):].split("|")) for line in lines if line.startswith(MARKER))
    if records != Counter(map(tuple, expected)):
        raise ValueError("missing, duplicate, unexpected or wrong-parameter execution receipts")
    listed = [line.removeprefix("matched test: ") for line in lines if line.startswith("matched test: ")]
    selected = [item for item in listed if item.startswith(TARGET + ".")]
    if not focused and not any(item.startswith("FleckCoreTests.") for item in listed):
        raise ValueError("full comparator did not discover the separate Core target")
    # Map each finite source-local receipt name to one distinct native-discovered identifier.
    functions = [re.split(r"[./]", item.split("(", 1)[0])[-1] for item in selected]
    if (Counter(functions) != Counter({name: 1 for name, _ in expected})
            or len(set(selected)) != len(selected) or (focused and listed != selected)):
        raise ValueError("native discovered test IDs differ from the exact inventory")
    last = next((line for line in reversed(lines) if line.strip()), "")
    if failing is None:
        if status != 0 or not PASSED.match(last):
            raise ValueError("missing complete successful native run")
    else:
        issues = [i for i, line in enumerate(lines) if ISSUE.match(line)]
        other = REACHABLE if failing == OTHER else OTHER
        test_name = ("fleckShadowOutsideTargetFails()" if failing == OTHER
                     else "agentWireRequestCarriesUnsupportedVersionsForServerRejection(_:)")
        if (status != 1 or len(issues) != 1 or not FAIL_SUMMARY.match(last)
                or test_name not in lines[issues[0]]
                or not any(failing in line for line in lines[issues[0]:issues[0] + 3])
                or any(other in line for line in lines)):
            raise ValueError("missing complete expected assertion failure; infra is not a red control")
    return sorted(selected)


def verify(arguments):
    manifest = json.loads(arguments.manifest.read_text())
    expected = manifest["expected_cases"]
    baseline = None
    scenarios = [("positive", "focused", None), ("reachable", "focused", REACHABLE)]
    if arguments.phase == "parity":
        scenarios += [
            ("positive", "full", None), ("reachable", "full", REACHABLE),
            ("omitted", "focused", None), ("omitted", "full", OTHER),
        ]
    for scenario, route, failure in scenarios:
        stem = arguments.logs / (scenario + "-" + route)
        ids = evidence(stem.with_suffix(".log").read_text(), expected,
                       focused=route == "focused",
                       status=int(stem.with_suffix(".status").read_text()),
                       failing=failure)
        if baseline is None:
            baseline = ids
        elif ids != baseline:
            raise ValueError(f"canonical native test ID drift: {stem.name}")
    print(json.dumps({
        "rehearsal": "focused-smoke-confirmed" if arguments.phase == "focus" else "parity-confirmed",
        "canonical_ids": baseline,
        "exact_case_receipts_each": len(expected),
        "deliberately_wrong_route": ("not run in focused smoke" if arguments.phase == "focus"
                                     else "focused-pass/full-fail was flagged"),
        "required_ci_or_branch_protection": "not tested",
    }, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    make = sub.add_parser("make")
    make.add_argument("--source", type=Path, required=True)
    make.add_argument("--output", type=Path, required=True)
    audit = sub.add_parser("verify")
    audit.add_argument("--phase", choices=("focus", "parity"), required=True)
    audit.add_argument("--manifest", type=Path, required=True)
    audit.add_argument("--logs", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "make":
            make_fixtures(args.source, args.output)
        else:
            verify(args)
    except (ValueError, OSError, KeyError) as error:
        print(f"rehearsal evidence rejected: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
