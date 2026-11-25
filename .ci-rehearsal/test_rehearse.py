from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest


SPEC = importlib.util.spec_from_file_location("rehearse", Path(__file__).with_name("rehearse.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VerificationContractTests(unittest.TestCase):
    expected = [("wire", "0"), ("wire", "2"), ("event", "single")]
    matched = ("matched test: FleckAgentProtocolTests.Wire/wire(_:)", "matched test: FleckAgentProtocolTests.event()")
    markers = tuple(MODULE.MARKER + name + "|" + value for name, value in expected)
    passed = "✔ Test run with 2 tests in 1 suite passed after 0.001 seconds."
    failed = "✘ Test run with 2 tests in 1 suite failed after 0.001 seconds with 1 issue."

    def check(self, lines, *, focused=True, status=0, failing=None):
        return MODULE.evidence("\n".join(lines), self.expected, focused=focused, status=status, failing=failing)

    def test_pass_requires_real_listed_ids_and_every_encoded_value(self):
        ids = self.check((*self.matched, *self.markers, self.passed))
        self.assertEqual(ids, sorted(x.removeprefix("matched test: ") for x in self.matched))
        for records in (self.markers[:-1], self.markers + self.markers[:1],
                        (self.markers[0], self.markers[1].replace("|2", "|1"), self.markers[2])):
            with self.assertRaisesRegex(ValueError, "receipts"):
                self.check((*self.matched, *records, self.passed))

    def test_focused_run_must_not_claim_another_target(self):
        lines = (*self.matched, "matched test: FleckCoreTests.note()", *self.markers, self.passed)
        self.check(lines, focused=False)
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.check(lines)

    def test_known_failing_case_is_different_from_infra(self):
        with self.assertRaisesRegex(ValueError, "assertion"):
            self.check((*self.matched, *self.markers, "SIGTERM", self.failed),
                       status=1, failing=MODULE.REACHABLE)
        known = ("✘ Test agentWireRequestCarriesUnsupportedVersionsForServerRejection(_:) recorded an issue at Wire.swift:5:5: Expectation failed",
                 "↳ " + MODULE.REACHABLE)
        self.check((*self.matched, *self.markers, *known, self.failed), status=1, failing=MODULE.REACHABLE)
        with self.assertRaisesRegex(ValueError, "assertion"):
            self.check((*self.matched, *self.markers, *known, self.failed),
                       status=143, failing=MODULE.REACHABLE)

    def test_focus_phase_does_not_claim_or_substitute_for_parity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"expected_cases": self.expected}))
            positive = (*self.matched, *self.markers, self.passed)
            issue = ("✘ Test agentWireRequestCarriesUnsupportedVersionsForServerRejection(_:) recorded an issue at Wire.swift:5:5:",
                     "↳ " + MODULE.REACHABLE)
            reachable = (*self.matched, *self.markers, *issue, self.failed)
            for specimen, status, lines in (
                ("positive", 0, positive), ("reachable", 1, reachable),
            ):
                (root / f"{specimen}-focused.log").write_text("\n".join(lines))
                (root / f"{specimen}-focused.status").write_text(str(status))
            output = io.StringIO()
            with redirect_stdout(output):
                MODULE.verify(SimpleNamespace(phase="focus", logs=root, manifest=manifest))
            self.assertEqual(json.loads(output.getvalue())["rehearsal"], "focused-smoke-confirmed")
            self.assertEqual(json.loads(output.getvalue())["deliberately_wrong_route"], "not run in focused smoke")
            with self.assertRaises(FileNotFoundError):
                MODULE.verify(SimpleNamespace(phase="parity", logs=root, manifest=manifest))

    def test_misclassified_omitted_failure_cannot_be_a_green_full_control(self):
        focused = (*self.matched, *self.markers, self.passed)
        outside = ("✘ Test fleckShadowOutsideTargetFails() recorded an issue at Control.swift:4:3:",
                   "↳ " + MODULE.OTHER)
        full = (*self.matched, "matched test: FleckCoreTests.fleckShadowOutsideTargetFails()", *self.markers,
                *outside, self.failed)
        self.check(focused)
        with self.assertRaisesRegex(ValueError, "successful"):
            self.check(full, focused=False)
        self.check(full, focused=False, status=1, failing=MODULE.OTHER)


if __name__ == "__main__":
    unittest.main()
