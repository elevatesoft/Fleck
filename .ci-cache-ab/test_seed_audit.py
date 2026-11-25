"""Portable Git-config profile regressions; no repository writes or Swift."""
import subprocess
import unittest

from seed_audit import parse_config


class SeedConfigTests(unittest.TestCase):
    def parse(self, extra="", *, bare=False):
        decl = "true" if bare else "false"
        origin = "https://github.com/apple/swift-log.git" if bare else "/private/tmp/mirror"
        fetch = "+refs/*:refs/*" if bare else "+refs/heads/*:refs/remotes/origin/*"
        content = (f"[core]\n repositoryformatversion = 0\n bare = {decl}\n"
                   f" symlinks = true\n{extra}\n[remote \"origin\"]\n url = {origin}\n"
                   f" fetch = {fetch}\n")
        if bare:
            content += " mirror = true\n"
        else:
            content += '[branch "main"]\n remote = origin\n merge = refs/heads/main\n'
        raw = subprocess.run(
            ["git", "config", "--no-includes", "--file", "/dev/stdin", "--null", "--list"],
            input=content.encode(), capture_output=True, check=True,
        ).stdout
        return parse_config(raw)

    def test_accepts_pinned_swiftpm_generated_values_in_both_clone_profiles(self):
        for bare in (False, True):
            with self.subTest(bare=bare):
                self.assertEqual(self.parse(" fsmonitor = false\n longpaths = true", bare=bare),
                                 "https://github.com/apple/swift-log.git" if bare else "/private/tmp/mirror")

    def test_rejects_nonliteral_fsmonitor_and_sanitizes_error(self):
        for value in ("/private/fixture/not-to-log", "true", "yes", "0", ""):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, r"^git-clone-profile-value$"):
                    self.parse(f" fsmonitor = {value}\n longpaths = true")

    def test_rejects_nonliteral_longpaths(self):
        for value in ("false", "TRUE", "yes", "1", "/private/fixture/not-to-log"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, r"^git-clone-profile-value$"):
                    self.parse(f" fsmonitor = false\n longpaths = {value}")

    def test_rejects_duplicate_pinned_key_even_when_values_match(self):
        with self.assertRaisesRegex(ValueError, r"^git-clone-profile-value$"):
            self.parse(" fsmonitor = false\n fsmonitor = false\n longpaths = true")

    def test_unlisted_key_stays_refused_without_revealing_it(self):
        with self.assertRaisesRegex(ValueError, r"^git-config-key$"):
            self.parse(" hooksPath = /private/fixture/not-to-log")

    def test_legacy_allowed_clone_profile_unchanged(self):
        self.assertEqual(self.parse(), "/private/tmp/mirror")


if __name__ == "__main__":
    unittest.main()
