import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER = (ROOT / "Scripts/run-swift-tests-with-appkit-host.sh").read_text()
VALIDATION = RUNNER[
    RUNNER.index('readonly preflight_regex='):RUNNER.index('prebuilt_mode=0')
]
EXECUTION = RUNNER[RUNNER.index('readonly list_output='):]
TARGET = "FleckAppTests.doubleClickSelectsTheWordUnderThePointer(usePlainTextView:)"
SELECTOR = r"^FleckAppTests\.doubleClick.*$"
SHARD_INITIALS = (("a", "c"), ("d", "g"), ("h", "r"), ("s", "z"))
SHARD_FIXTURE = (
    "FleckAppTests.Alpha()",
    "FleckAppTests.bravo/child()",
    "FleckAppTests.Charlie(usePlainTextView:)",
    "FleckAppTests.Delta()",
    "FleckAppTests.doubleClickSelectsTheWordUnderThePointer(usePlainTextView:)",
    "FleckAppTests.echo()",
    "FleckAppTests.Foxtrot()",
    "FleckAppTests.Golf()",
    "FleckAppTests.Hotel()",
    "FleckAppTests.india()",
    "FleckAppTests.Juliet()",
    "FleckAppTests.Kilo()",
    "FleckAppTests.Lima()",
    "FleckAppTests.Mike()",
    "FleckAppTests.November()",
    "FleckAppTests.Oscar()",
    "FleckAppTests.Papa()",
    "FleckAppTests.Quebec()",
    "FleckAppTests.Romeo()",
    "FleckAppTests.Sierra()",
    "FleckAppTests.tango()",
    "FleckAppTests.Uniform()",
    "FleckAppTests.Victor()",
    "FleckAppTests.Whiskey()",
    "FleckAppTests.xray()",
    "FleckAppTests.Yankee()",
    "FleckAppTests.Zulu()",
    "FleckCoreTests.alpha()",
    "FleckPerformanceTests.measure()",
)


def expected_shards(identifiers):
    shards = {index: [] for index in range(4)}
    for identifier in identifiers:
        if identifier.startswith("FleckAppTests."):
            initial = identifier[len("FleckAppTests.")].lower()
            for index, (first, last) in enumerate(SHARD_INITIALS):
                if first <= initial <= last:
                    shards[index].append(identifier)
                    break
            else:
                raise AssertionError(f"uncovered AppKit identifier: {identifier}")
        else:
            shards[3].append(identifier)
    return shards


MOCK_HOST = r'''
launch_host() {
  local phase="$1"
  shift
  printf '%s\t%s\n' "$phase" "$*" >> "$state_dir/trace"
  if [[ "$phase" = list ]]; then
    printf '%s\n' "$FIXTURE_IDENTIFIERS"
    return 0
  fi
  local filter='' identifier
  local count=0
  while (( $# )); do
    case "$1" in
      --filter)
        filter="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  if [[ "$filter" = '^.+$' ]]; then
    while IFS= read -r identifier; do
      [[ -n "$identifier" ]] || continue
      printf '%s\t%s\n' "$phase" "$identifier" >> "$state_dir/selection"
      count=$((count + 1))
    done <<< "$FIXTURE_IDENTIFIERS"
  else
    while IFS= read -r identifier; do
      [[ -n "$identifier" ]] || continue
      if printf '%s/\n' "$identifier" | /usr/bin/grep -Eq -- "$filter"; then
        printf '%s\t%s\n' "$phase" "$identifier" >> "$state_dir/selection"
        count=$((count + 1))
      fi
    done <<< "$FIXTURE_IDENTIFIERS"
  fi
  if [[ "$phase" = "${FIXTURE_FAIL_PHASE:-}" ]]; then
    printf '%s\n' '✘ Test run with 1 test in 0 suites failed after 0.001 seconds with 1 issue.'
    return 37
  fi
  if [[ "$phase" = "${FIXTURE_EMPTY_PHASE:-}" ]]; then
    printf '%s\n' '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.'
    return 0
  fi
  if [[ "$phase" = "${FIXTURE_SHORT_PHASE:-}" ]] && (( count > 0 )); then
    count=$((count - 1))
  fi
  if [[ "$phase" = "${FIXTURE_EXHAUST_PHASE:-}" ]]; then
    SECONDS="$isolation_deadline"
  fi
  printf '✔ Test run with %s tests in 1 suites passed after 0.001 seconds.\n' "$count"
}
'''


class AppKitPreflightTests(unittest.TestCase):
    def run_fixture(
        self,
        preflight=None,
        fail_phase="",
        empty_phase="",
        request="^.+$",
        ci=False,
        identifiers=f"{TARGET}\nFleckCoreTests.unrelated()",
        short_phase="",
        exhaust_phase="",
    ):
        # Execute the runner's actual validation and post-build phase code. Only
        # LaunchServices is replaced, so these controls also run without macOS.
        with tempfile.TemporaryDirectory(prefix="fleck-preflight-") as directory:
            env = os.environ.copy()
            env.pop("FLECK_TEST_APPKIT_PREFLIGHT_SELECTOR", None)
            env.pop("GITHUB_ACTIONS", None)
            env.update(
                state_dir=directory,
                identifier_regex=request,
                FIXTURE_IDENTIFIERS=identifiers,
                FIXTURE_FAIL_PHASE=fail_phase,
                FIXTURE_EMPTY_PHASE=empty_phase,
                FIXTURE_SHORT_PHASE=short_phase,
                FIXTURE_EXHAUST_PHASE=exhaust_phase,
                host_watchdog_seconds="4800",
            )
            if ci:
                env["GITHUB_ACTIONS"] = "true"
            if preflight is not None:
                env["FLECK_TEST_APPKIT_PREFLIGHT_SELECTOR"] = preflight
            result = subprocess.run(
                ["/bin/bash", "-c", "set -euo pipefail\n" + MOCK_HOST + VALIDATION + EXECUTION],
                env=env, text=True, capture_output=True,
            )
            trace = Path(directory, "trace")
            calls = [line.split("\t", 1) for line in trace.read_text().splitlines()] if trace.exists() else []
            selection_path = Path(directory, "selection")
            selections = {}
            if selection_path.exists():
                for line in selection_path.read_text().splitlines():
                    phase, identifier = line.split("\t", 1)
                    selections.setdefault(phase, []).append(identifier)
            return result, calls, selections

    def test_unset_preflight_preserves_single_full_run(self):
        result, calls, _ = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([phase for phase, _ in calls], ["list", "run"])
        self.assertEqual(calls[-1][1], "--filter ^.+$ --no-parallel")

    def test_unset_preflight_preserves_focused_request(self):
        result, calls, _ = self.run_fixture(request=r"^FleckCoreTests\.unrelated\(\)$")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([phase for phase, _ in calls], ["list", "run"])
        self.assertEqual(
            calls[-1][1], r"--filter ^(FleckCoreTests\.unrelated\(\)/) --no-parallel",
        )
        self.assertIn("matched test count: 1", result.stdout)

    def test_passing_preflight_reuses_list_and_keeps_full_filter(self):
        result, calls, _ = self.run_fixture(SELECTOR)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([phase for phase, _ in calls], ["list", "preflight", "run"])
        self.assertIn(r"doubleClickSelectsTheWordUnderThePointer\(usePlainTextView:\)/", calls[1][1])
        self.assertNotIn("unrelated", calls[1][1])
        self.assertEqual(calls[-1][1], "--filter ^.+$ --no-parallel")
        self.assertIn("matched test count: 1", result.stdout)
        self.assertIn("matched test count: 2", result.stdout)

    def test_failing_preflight_propagates_and_stops_full_run(self):
        result, calls, _ = self.run_fixture(SELECTOR, fail_phase="preflight")
        self.assertEqual(result.returncode, 37)
        self.assertEqual([phase for phase, _ in calls], ["list", "preflight"])

    def test_zero_match_preflight_stops_before_execution(self):
        result, calls, _ = self.run_fixture(r"^FleckAppTests\.missing\(\)$")
        self.assertEqual(result.returncode, 3)
        self.assertEqual([phase for phase, _ in calls], ["list"])
        self.assertIn("matched zero tests", result.stderr)

    def test_invalid_or_unbounded_preflight_fails_before_listing(self):
        for selector in ("", "unanchored", "^[$", "^.+$", "^.*$", "^" + "a" * 160 + "$"):
            with self.subTest(selector=selector):
                result, calls, _ = self.run_fixture(selector)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, [])

    def test_preflight_cannot_replace_a_focused_request(self):
        result, calls, _ = self.run_fixture(SELECTOR, request=SELECTOR)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])

    def test_preflight_keeps_nonempty_completion_gate(self):
        result, calls, _ = self.run_fixture(SELECTOR, empty_phase="preflight")
        self.assertEqual(result.returncode, 1)
        self.assertEqual([phase for phase, _ in calls], ["list", "preflight"])
        self.assertIn("without a final non-empty passing test summary", result.stderr)

    def test_passing_preflight_does_not_mask_full_run_failure(self):
        result, calls, _ = self.run_fixture(SELECTOR, fail_phase="run")
        self.assertEqual(result.returncode, 37)
        self.assertEqual([phase for phase, _ in calls], ["list", "preflight", "run"])

    def test_hosted_isolation_partitions_full_graph_case_insensitively(self):
        result, calls, selections = self.run_fixture(
            SELECTOR, ci=True, identifiers="\n".join(SHARD_FIXTURE),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [phase for phase, _ in calls],
            ["list", "preflight", "run-shard-0", "run-shard-1", "run-shard-2", "run-shard-3"],
        )
        expected = expected_shards(SHARD_FIXTURE)
        for index in range(4):
            with self.subTest(shard=index):
                self.assertEqual(
                    sorted(selections.get(f"run-shard-{index}", [])),
                    sorted(expected[index]),
                )
                self.assertIn(
                    f"matched test count: {len(expected[index])}", result.stdout,
                )
        selected = [
            identifier
            for index in range(4)
            for identifier in selections.get(f"run-shard-{index}", [])
        ]
        self.assertEqual(sorted(selected), sorted(SHARD_FIXTURE))
        self.assertEqual(len(selected), len(set(selected)))
        shard_arguments = [arguments for phase, arguments in calls[2:]]
        self.assertEqual(len(set(shard_arguments)), 4)
        for arguments in shard_arguments:
            self.assertTrue(arguments.endswith(" --no-parallel"), arguments)

    def test_hosted_request_without_preflight_keeps_single_full_run(self):
        result, calls, _ = self.run_fixture(ci=True, identifiers="\n".join(SHARD_FIXTURE))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([phase for phase, _ in calls], ["list", "run"])
        self.assertEqual(calls[-1][1], "--filter ^.+$ --no-parallel")

    def test_hosted_isolation_rejects_duplicate_inventory_before_first_shard(self):
        result, calls, _ = self.run_fixture(
            SELECTOR,
            ci=True,
            identifiers="\n".join(SHARD_FIXTURE + ("FleckAppTests.Hotel()",)),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("run-shard-0", [phase for phase, _ in calls])
        self.assertIn("inventor", result.stderr)

    def test_hosted_isolation_rejects_uncovered_inventory_before_first_shard(self):
        result, calls, _ = self.run_fixture(
            SELECTOR,
            ci=True,
            identifiers="\n".join(SHARD_FIXTURE + ("UnknownModuleTests.alpha()",)),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("run-shard-0", [phase for phase, _ in calls])
        self.assertIn("inventor", result.stderr)

    def test_hosted_isolation_rejects_incomplete_group_before_first_shard(self):
        result, calls, _ = self.run_fixture(
            SELECTOR,
            ci=True,
            identifiers="\n".join(
                identifier for identifier in SHARD_FIXTURE
                if identifier not in expected_shards(SHARD_FIXTURE)[0]
            ),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("run-shard-0", [phase for phase, _ in calls])
        self.assertIn("inventor", result.stderr)

    def test_failing_shard_fails_closed_before_later_shards(self):
        for index in range(4):
            with self.subTest(shard=index):
                result, calls, _ = self.run_fixture(
                    SELECTOR,
                    ci=True,
                    identifiers="\n".join(SHARD_FIXTURE),
                    fail_phase=f"run-shard-{index}",
                )
                self.assertEqual(result.returncode, 37)
                self.assertEqual(
                    [phase for phase, _ in calls],
                    ["list", "preflight"] + [f"run-shard-{shard}" for shard in range(index + 1)],
                )

    def test_zero_test_shard_fails_closed_before_later_shards(self):
        for index in range(4):
            with self.subTest(shard=index):
                result, calls, _ = self.run_fixture(
                    SELECTOR,
                    ci=True,
                    identifiers="\n".join(SHARD_FIXTURE),
                    empty_phase=f"run-shard-{index}",
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(
                    [phase for phase, _ in calls],
                    ["list", "preflight"] + [f"run-shard-{shard}" for shard in range(index + 1)],
                )
                self.assertIn("without a final non-empty passing test summary", result.stderr)

    def test_short_shard_summary_fails_closed_before_later_shards(self):
        for index in range(4):
            with self.subTest(shard=index):
                result, calls, _ = self.run_fixture(
                    SELECTOR,
                    ci=True,
                    identifiers="\n".join(SHARD_FIXTURE),
                    short_phase=f"run-shard-{index}",
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(
                    [phase for phase, _ in calls],
                    ["list", "preflight"] + [f"run-shard-{shard}" for shard in range(index + 1)],
                )
                self.assertIn(f"run-shard-{index}", result.stderr)
                self.assertNotIn(
                    "without a final non-empty passing test summary", result.stderr,
                )

    def test_expired_watchdog_stops_before_next_shard(self):
        result, calls, _ = self.run_fixture(
            SELECTOR,
            ci=True,
            identifiers="\n".join(SHARD_FIXTURE),
            exhaust_phase="run-shard-0",
        )
        self.assertEqual(result.returncode, 124)
        self.assertEqual([phase for phase, _ in calls], ["list", "preflight", "run-shard-0"])
        self.assertIn("exceeded the shared watchdog budget", result.stderr)


if __name__ == "__main__":
    unittest.main()
