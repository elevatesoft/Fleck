import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

import transport


@unittest.skipUnless(shutil.which("zstd"), "zstd is required for transport tests")
class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.quarantine = self.root / "quarantine"
        self.quarantine.mkdir(mode=0o700)
        self.scratch = self.root / "scratch"
        self.scratch.mkdir(mode=0o700)
        self.archive = self.quarantine / "fleck-seed.tar.zst"
        self.dest = self.root / "activated"

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def unpack(self, sha=None, size=None, **kwargs):
        return transport.unpack(
            self.archive, self.dest, sha if sha is not None else self.sha(self.archive),
            size if size is not None else self.archive.stat().st_size, **kwargs,
        )

    def create_blob(self, items, suffix=b""):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as output:
            for name, kind, data in items:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.mode = 0o700 if kind == tarfile.DIRTYPE else 0o600
                if kind == tarfile.REGTYPE:
                    entry.size = len(data)
                    output.addfile(entry, io.BytesIO(data))
                else:
                    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                        entry.linkname = data
                    output.addfile(entry)
        self.archive.write_bytes(subprocess.check_output(["zstd", "-q", "-1", "-c"], input=raw.getvalue() + suffix))
        self.archive.chmod(0o600)

    def test_packed_blob_restores_bytes_modes_and_exact_mtime(self):
        app = self.scratch / "app"
        app.write_bytes(b"data")
        app.chmod(0o745)
        time_ns = 1_709_876_543_321_987_654
        os.utime(app, ns=(time_ns, time_ns))
        observed = app.stat().st_mtime_ns
        (self.scratch / "debug").symlink_to("app")
        os.link(app, self.scratch / "hard")
        result = transport.pack({"scratch": self.scratch}, self.archive)
        self.assertEqual(result["sha256"], self.sha(self.archive))
        self.assertEqual(result["bytes"], self.archive.stat().st_size)
        restored = self.unpack()
        self.assertEqual(restored["sha256"], result["sha256"])
        out = self.dest / "scratch/app"
        self.assertEqual(out.read_bytes(), b"data")
        self.assertEqual(out.stat().st_mode & 0o777, 0o745)
        self.assertEqual(out.stat().st_mtime_ns, observed)
        self.assertEqual((self.dest / "scratch/debug").readlink(), Path("app"))
        self.assertEqual((self.dest / "scratch/hard").stat().st_ino, out.stat().st_ino)

    def test_bad_digest_or_late_corruption_is_never_activated(self):
        (self.scratch / "one").write_bytes(b"abc")
        result = transport.pack({"scratch": self.scratch}, self.archive)
        data = self.archive.read_bytes()
        self.archive.write_bytes(data[:-1] + bytes([data[-1] ^ 1]))
        with self.assertRaisesRegex(transport.Refusal, "digest"):
            self.unpack(sha=result["sha256"])
        self.assertFalse(self.dest.exists())
        self.assertEqual(set(self.root.iterdir()), {self.quarantine, self.scratch})

    def test_wrong_size_type_or_quarantine_members_are_refused(self):
        (self.scratch / "one").write_bytes(b"abc")
        transport.pack({"scratch": self.scratch}, self.archive)
        with self.assertRaisesRegex(transport.Refusal, "size"):
            self.unpack(size=self.archive.stat().st_size - 1)
        poison = self.quarantine / "unexpected"
        poison.write_bytes(b"")
        with self.assertRaisesRegex(transport.Refusal, "exactly one"):
            self.unpack()
        poison.unlink()
        self.archive.chmod(0o700)
        with self.assertRaisesRegex(transport.Refusal, "inert"):
            self.unpack()
        self.assertFalse(self.dest.exists())

    def test_prevalidated_members_cannot_escape_or_alias_another_path(self):
        cases = [
            [("scratch/../outside", tarfile.REGTYPE, b"")],
            [("scratch/current", tarfile.SYMTYPE, "../../outside")],
            [("scratch/legitimate", tarfile.REGTYPE, b"x"),
             ("scratch/actual-dir", tarfile.DIRTYPE, ""),
             ("scratch/link-dir", tarfile.SYMTYPE, "actual-dir"),
             ("scratch/current", tarfile.SYMTYPE, "link-dir/../legitimate")],
            [("scratch/up", tarfile.LNKTYPE, "package-cache/other")],
            [("scratch/current", tarfile.SYMTYPE, "dir"),
             ("scratch/current/latent", tarfile.REGTYPE, b"")],
            [("scratch/Same", tarfile.REGTYPE, b"_"), ("scratch/same", tarfile.REGTYPE, b"X")],
            [("scratch/dup", tarfile.REGTYPE, b"_"), ("scratch/dup", tarfile.REGTYPE, b"X")],
            [("scratch/fifo", tarfile.FIFOTYPE, "")],
        ]
        for members in cases:
            with self.subTest(members=members):
                self.create_blob([("scratch", tarfile.DIRTYPE, ""), *members])
                with self.assertRaises(transport.Refusal):
                    self.unpack()
                self.assertFalse(self.dest.exists())

    def test_trailing_unvalidated_tar_data_is_refused(self):
        self.create_blob([("scratch", tarfile.DIRTYPE, ""),
                          ("scratch/one", tarfile.REGTYPE, b"x")], suffix=b"unvalidated")
        with self.assertRaisesRegex(transport.Refusal, "trailing"):
            self.unpack()
        self.assertFalse(self.dest.exists())

    def test_existing_destination_and_uncompressed_budget_fail_closed(self):
        self.create_blob([("scratch", tarfile.DIRTYPE, ""), ("scratch/one", tarfile.REGTYPE, b"x")])
        self.dest.mkdir()
        (self.dest / "retain").write_bytes(b"existing")
        with self.assertRaisesRegex(transport.Refusal, "destination"):
            self.unpack()
        self.assertEqual((self.dest / "retain").read_bytes(), b"existing")
        (self.dest / "retain").unlink()
        self.dest.rmdir()
        with self.assertRaisesRegex(transport.Refusal, "uncompressed"):
            self.unpack(raw_limit=512)
        self.assertFalse(self.dest.exists())

    def test_pack_refuses_unsafe_members_without_publishing(self):
        (self.scratch / "escape").symlink_to("../outside")
        with self.assertRaises(transport.Refusal):
            transport.pack({"scratch": self.scratch}, self.archive)
        self.assertEqual(list(self.quarantine.iterdir()), [])

    def test_cache_receipts_are_bounded_same_ref_same_attempt_and_exact_hit(self):
        identity = {"ref": "refs/heads/elevate/fleck-ci-fresh-ab-v1", "run": "123",
                    "attempt": "1", "harness_sha": "a" * 40, "archive_sha256": "b" * 64}
        identity["key"] = f"fleck-fresh-ab-v1-r123-a1-{identity['harness_sha']}-{identity['archive_sha256']}"
        before = {"total_count": 0, "actions_caches": []}
        after = {"total_count": 1, "actions_caches": [
            {"id": 8, "key": identity["key"], "ref": identity["ref"],
             "version": "version", "size_in_bytes": 1250}]}
        transport.before_save({"active_caches_size_in_bytes": 42}, before, 1000, 10_000_000_000)
        receipt = transport.after_save(after, identity)
        transport.exact_restore(receipt, identity, identity, "true", identity["key"], after)
        for observed, hit, key in ((identity, "false", identity["key"]),
                                   (identity, "true", identity["key"] + "-fallback"),
                                   ({**identity, "attempt": "2"}, "true", identity["key"])):
            with self.assertRaises(transport.Refusal):
                transport.exact_restore(receipt, identity, observed, hit, key, after)
        with self.assertRaises(transport.Refusal):
            transport.before_save({"active_caches_size_in_bytes": 7_500_000_000},
                                  before, 1000, 10_000_000_000)
        with self.assertRaises(transport.Refusal):
            transport.before_save({"active_caches_size_in_bytes": 0}, after, 1000, 10_000_000_000)
        with self.assertRaises(transport.Refusal):
            transport.after_save({**after, "total_count": 2}, identity)
        with self.assertRaises(transport.Refusal):
            transport.after_save(after, {**identity, "archive_sha256": "c" * 64})
        with self.assertRaises(transport.Refusal):
            transport.exact_restore({**receipt, "id": 99}, identity, identity, "true", identity["key"], after)


if __name__ == "__main__":
    unittest.main()
