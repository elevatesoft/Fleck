import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

import ledger
import seed_audit
import transport
import warm_contract as c


class WarmContracts(unittest.TestCase):
    def setUp(self):
        self.now = 1795584400
        self.env = {
            "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REPOSITORY": c.REPO, "GITHUB_REPOSITORY_ID": c.REPO_ID,
            "GITHUB_REF": transport.REF, "GITHUB_ACTOR": c.OWNER,
            "GITHUB_TRIGGERING_ACTOR": c.OWNER, "GITHUB_RUN_ATTEMPT": "1",
            "FLECK_FRESH_QUALIFICATION": "true", "GITHUB_JOB": "fresh-ab-seed",
            "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64", "GITHUB_RUN_ID": "123",
            "GITHUB_SHA": "a" * 40,
        }
        self.allow = {"repo": c.REPO, "ref": transport.REF,
                      "harness_sha": self.env["GITHUB_SHA"], "checked_epoch": self.now,
                      "included_cap": 10_000_000_000, "no_added_bill": True,
                      "basis": "owner-reviewed-public-10gb"}

    def test_exact_owner_first_manual_dispatch_and_recent_cap(self):
        c.assert_context(self.env, "seed")
        for key, bad in (("GITHUB_ACTOR", "other"), ("GITHUB_TRIGGERING_ACTOR", "other"),
                         ("GITHUB_REF", "refs/heads/main"), ("GITHUB_RUN_ATTEMPT", "2"),
                         ("GITHUB_EVENT_NAME", "pull_request"), ("RUNNER_ARCH", "X64")):
            with self.subTest(key=key), self.assertRaises(transport.Refusal):
                c.assert_context({**self.env, key: bad}, "seed")
        env = {**self.env, "FLECK_FRESH_ADMISSION": json.dumps(self.allow)}
        self.assertEqual(c.admission(env, self.now, "start"), 10_000_000_000)
        with self.assertRaises(transport.Refusal):
            c.admission(env, self.now+901, "start")
        for broken in ({"harness_sha": "f" * 40}, {"no_added_bill": False}, {"included_cap": 1}):
            with self.subTest(broken=broken), self.assertRaises(transport.Refusal):
                c.admission({**env, "FLECK_FRESH_ADMISSION": json.dumps({**self.allow, **broken})},
                            self.now, "start")

    def test_usage_lag_cannot_hide_live_objects_and_incomplete_listing_is_denied(self):
        usage = {"full_name": c.REPO, "active_caches_size_in_bytes": 0}
        listing = {"total_count": 1, "actions_caches": [{"id": 1, "size_in_bytes": 6_500_000_000}]}
        active = c.active_bytes(usage, listing)
        self.assertEqual(active, 6_500_000_000)
        with self.assertRaises(transport.Refusal):
            c.admit_headroom(10_000_000_000, active)
        with self.assertRaises(transport.Refusal):
            c.active_bytes(usage, {**listing, "total_count": 101})
        with self.assertRaises(transport.Refusal):
            c.active_bytes(usage, {"total_count": 2, "actions_caches": listing["actions_caches"] * 2})

    def test_cap_api_402_only_on_reviewed_basis_and_no_credentials_in_error(self):
        error = HTTPError("https://api.github.com/example", 402, "Payment Required", {}, None)
        with patch.dict("os.environ", GH_READ_TOKEN="fake-secret"), patch.object(ledger, "build_opener") as opener:
            opener.return_value.open.side_effect = error
            self.assertIsNone(ledger.api("cache/storage-limit", documented_cap=True))
            for path, allowed in (("caches", True), ("cache/storage-limit", False)):
                with self.assertRaisesRegex(transport.Refusal, "HTTP 402") as failure:
                    ledger.api(path, documented_cap=allowed)
                self.assertNotIn("fake-secret", str(failure.exception))

    def test_value_probe_requires_named_stale_assertion_not_infra(self):
        core = "FLECK_WARM_SENTINEL actual=seed expected=seed"
        good = "FLECK_FRESH_APP actual=changed expected=changed"
        c.probe_receipt("\n".join((core, good, "✔ Test run with 2 tests in 0 suites passed after 0.1 seconds.")),
                        "changed", "changed", 0)
        stale = "\n".join((core, "FLECK_FRESH_APP actual=seed expected=changed",
                           "✘ Test fleckFreshABAppProbe() recorded an issue at Probe.swift:8:5:",
                           "↳ FLECK_FRESH_APP_ASSERT",
                           "✘ Test run with 2 tests in 0 suites failed after 0.1 seconds with 1 issue."))
        c.probe_receipt(stale, "seed", "changed", 1)
        for status, data in ((143, stale), (1, stale.replace("FLECK_FRESH_APP_ASSERT", "unrelated")),
                             (1, stale.replace(core, core + "\n" + core))):
            with self.assertRaises(transport.Refusal):
                c.probe_receipt(data, "seed", "changed", status)

    def test_dependency_origin_chain_must_end_in_a_pinned_public_repo(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            remote = root / "bare"
            checkout = root / "editable"
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            subprocess.run(["git", "-C", str(remote), "remote", "add", "origin",
                            "https://github.com/example/upstream"], check=True)
            subprocess.run(["git", "clone", "-q", str(remote), str(checkout)],
                           check=True, stderr=subprocess.PIPE)
            pins = [{"location": "https://github.com/example/upstream"}]
            seed_audit.audit([root], pins)
            subprocess.run(["git", "-C", str(remote), "config", "--local", "http.extraheader",
                            "fake-secret"], check=True)
            with self.assertRaises(transport.Refusal):
                seed_audit.audit([root], pins)


if __name__ == "__main__":
    unittest.main()
