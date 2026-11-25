"""Local-only sealed cache transport helpers for the disposable Fleck A/B.

No network, cache publication, Swift build or consumer activation occurs here.
Trusted same-run job outputs must supply the expected digest and byte count.
"""

import argparse
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import unicodedata


ROOTS = {"scratch", "package-cache"}
REF = "refs/heads/elevate/fleck-ci-fresh-ab-v1"
ARCHIVE_NAME = "fleck-seed.tar.zst"
PACKED_MAX = 1_500_000_000
WRAPPER_MAX = 1_600_000_000
RAW_MAX = 6_000_000_000
MEMBERS_MAX = 150_000
BUFFER_SIZE = 1 << 20
SHA256 = re.compile(r"[0-9a-f]{64}")
SHA1 = re.compile(r"[0-9a-f]{40}")


class Refusal(ValueError):
    """The experiment must stop rather than accept an unproven input."""


def path_parts(value):
    parts = value.split("/")
    if (not value or "\\" in value or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or any(p in {"", ".", ".."} for p in parts)):
        raise Refusal("unsafe archive member path")
    return tuple(parts)


def symlink_target(parts, value, members):
    if not value or "\\" in value or value.startswith("/") or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise Refusal("unsafe symbolic link target")
    target = list(parts[:-1])
    components = value.split("/")
    for index, component in enumerate(components):
        if component in {"", "."}:
            raise Refusal("ambiguous symbolic link target")
        if component == "..":
            if len(target) <= 1:
                raise Refusal("symbolic link outside its archive root")
            target.pop()
        else:
            target.append(component)
            if index < len(components) - 1:
                entry = members.get(tuple(target))
                # Do not collapse /../ across a symlink, missing name or non-directory.
                if entry is None or not entry.isdir():
                    raise Refusal("symbolic link traverses a non-directory")
    return tuple(target)


def mtime_ns(member):
    try:
        seconds = Decimal(str(member.pax_headers.get("mtime", member.mtime)))
        nanoseconds = seconds * 1_000_000_000
        if (not nanoseconds.is_finite() or not 0 <= nanoseconds <= (1 << 63) - 1
                or nanoseconds != nanoseconds.to_integral_value()):
            raise Refusal("unsupported archive mtime")
        return int(nanoseconds)
    except (ArithmeticError, ValueError) as error:
        raise Refusal("unsupported archive mtime") from error


def validated_members(tar):
    by_path, aliases = {}, set()
    for member in tar:
        parts = path_parts(member.name)
        alias = tuple(unicodedata.normalize("NFC", p).casefold() for p in parts)
        if parts[0] not in ROOTS or alias in aliases:
            raise Refusal("unknown root or duplicate/aliasing archive member")
        if len(by_path) >= MEMBERS_MAX:
            raise Refusal("too many archive members")
        if (member.type not in {tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE,
                                tarfile.LNKTYPE, tarfile.SYMTYPE}
                or member.mode & ~0o777 or getattr(member, "sparse", None)
                or set(member.pax_headers) - {"mtime", "path", "linkpath"}):
            raise Refusal("unsupported archive member type, mode, or sparse layout")
        if (not member.isreg() and member.size) or not 0 <= member.size <= RAW_MAX:
            raise Refusal("invalid archive member size")
        mtime_ns(member)
        aliases.add(alias)
        by_path[parts] = member

    tar.fileobj.seek(tar.offset)
    padding = tar.fileobj.read(tarfile.RECORDSIZE + 1)
    if (not 1024 <= len(padding) <= tarfile.RECORDSIZE
            or len(padding) % tarfile.BLOCKSIZE or any(padding)):
        raise Refusal("unexpected tar termination or trailing data")
    if ("scratch",) not in by_path:
        raise Refusal("missing scratch root")
    for parts, member in by_path.items():
        if len(parts) == 1 and not member.isdir():
            raise Refusal("archive roots must be directories")
        if len(parts) > 1 and (parts[:-1] not in by_path or not by_path[parts[:-1]].isdir()):
            raise Refusal("archive member has a missing or non-directory parent")
        if member.issym() or member.islnk():
            target = symlink_target(parts, member.linkname, by_path) if member.issym() else path_parts(member.linkname)
            dest = by_path.get(target)
            if (target[0] != parts[0] or target == parts[:len(target)] or dest is None
                    or not (dest.isreg() or (member.issym() and dest.isdir()))):
                raise Refusal("unproven or cyclic archive link")
            if any(not by_path[target[:i]].isdir() for i in range(1, len(target))):
                raise Refusal("archive link passes through a non-directory")
            if member.islnk() and (member.mode != dest.mode or mtime_ns(member) != mtime_ns(dest)):
                raise Refusal("hard link metadata differs from its target")
    return by_path


def measure(file):
    digest = hashlib.sha256()
    length = 0
    while chunk := file.read(BUFFER_SIZE):
        digest.update(chunk)
        length += len(chunk)
    return {"bytes": length, "sha256": digest.hexdigest()}


def run_bounded(args, source, dest, limit, reason):
    command = shutil.which("zstd")
    if not command:
        raise Refusal("pinned runner zstd is unavailable")
    with subprocess.Popen([command, *args], stdin=source, stdout=subprocess.PIPE) as process:
        total = 0
        try:
            while chunk := process.stdout.read(BUFFER_SIZE):
                total += len(chunk)
                if total > limit:
                    raise Refusal(reason)
                dest.write(chunk)
            exit_code = process.wait()
            if exit_code:
                raise Refusal(f"zstd exited {exit_code}")
        finally:
            if process.poll() is None:
                process.kill()
    return total


def owned_directory(path, *, private=False):
    if path.resolve(strict=True) != path.absolute() or not path.is_dir() or path.is_symlink():
        raise Refusal("directory is not a real canonical path")
    metadata = path.stat()
    if metadata.st_uid != os.getuid() or (private and metadata.st_mode & 0o077):
        raise Refusal("directory is not owned/private")


class RawTarIO:
    """Bound tar production and cap individual untrusted PAX/metadata reads."""

    def __init__(self, file):
        self.file = file
        self.written = 0

    def read(self, size):
        if not 0 <= size <= 8 * BUFFER_SIZE:
            raise Refusal("archive metadata read exceeds bound")
        return self.file.read(size)

    def write(self, data):
        self.written += len(data)
        if self.written > RAW_MAX:
            raise Refusal("uncompressed seed exceeds limit")
        return self.file.write(data)

    def __getattr__(self, name):
        return getattr(self.file, name)


def validate_seed_entries(source):
    for directory, children, files in os.walk(source, followlinks=False):
        for child in [*children, *files]:
            kind = (Path(directory) / child).lstat().st_mode
            if not (stat.S_ISDIR(kind) or stat.S_ISREG(kind) or stat.S_ISLNK(kind)):
                raise Refusal("unsupported seed filesystem entry")


def pack_filter(source, name):
    def sanitize(member):
        parts = path_parts(member.name)
        if parts[0] != name:
            raise Refusal("archive root drift")
        metadata = source.joinpath(*parts[1:]).lstat()
        sec, nano = divmod(metadata.st_mtime_ns, 1_000_000_000)
        member.mtime = sec
        member.pax_headers["mtime"] = f"{sec}.{nano:09d}"
        member.uid = member.gid = 0
        member.uname = member.gname = ""
        # tarfile itself silently skips socket objects before invoking a filter.
        if not (member.isreg() or member.isdir() or member.issym() or member.islnk()):
            raise Refusal("unsupported seed filesystem entry")
        return member
    return sanitize


def pack(roots, archive):
    archive = Path(archive)
    owned_directory(archive.parent, private=True)
    if archive.name != ARCHIVE_NAME or list(archive.parent.iterdir()) or not {"scratch"} <= roots.keys() <= ROOTS:
        raise Refusal("unexpected pack roots or nonempty transfer quarantine")
    roots = {name: Path(source) for name, source in roots.items()}
    for source in roots.values():
        owned_directory(source)
        if source == archive.parent or source in archive.parent.parents:
            raise Refusal("transfer may not be inside seed scratch")
    with tempfile.TemporaryDirectory(prefix=".seal-", dir=archive.parent.parent) as work:
        raw, sealed = Path(work) / "payload.tar", Path(work) / ARCHIVE_NAME
        started = time.monotonic()
        with raw.open("xb") as raw_file, tarfile.open(
            fileobj=RawTarIO(raw_file), mode="w|", format=tarfile.PAX_FORMAT, dereference=False,
        ) as tar:
            for name, source in sorted(roots.items()):
                validate_seed_entries(source)
                tar.add(source, arcname=name, filter=pack_filter(source, name))
        raw_bytes = raw.stat().st_size
        if raw_bytes > RAW_MAX:
            raise Refusal("uncompressed seed exceeds limit")
        with raw.open("rb") as raw_file, tarfile.open(fileobj=RawTarIO(raw_file), mode="r:") as tar:
            validated_members(tar)
        checked = time.monotonic()
        with raw.open("rb") as inp, sealed.open("xb") as out:
            run_bounded(("-q", "-1", "-T1", "-c"), inp, out, PACKED_MAX,
                        "sealed seed exceeds packed size limit")
        compressed = time.monotonic()
        sealed.chmod(0o600)
        with sealed.open("rb") as inp:
            receipt = measure(inp)
        # Same filesystem: fails without overwriting an existing blob.
        os.link(sealed, archive, follow_symlinks=False)
    return {**receipt, "uncompressed_bytes": raw_bytes, "seconds": {
        "tar_creation_and_member_check": checked - started,
        "inner_zstd_compression": compressed - checked,
    }}


def write_prevalidated_tree(tar, members, stage):
    directories = sorted((p for p, m in members.items() if m.isdir()), key=len)
    for parts in directories:
        stage.joinpath(*parts).mkdir(mode=0o700)
    for parts, member in members.items():
        if member.isreg():
            dest = stage.joinpath(*parts)
            with tar.extractfile(member) as inp, dest.open("xb") as out:
                shutil.copyfileobj(inp, out, BUFFER_SIZE)
            dest.chmod(member.mode)
            ns = mtime_ns(member)
            os.utime(dest, ns=(ns, ns))
    for parts, member in members.items():
        dest = stage.joinpath(*parts)
        if member.islnk():
            os.link(stage.joinpath(*path_parts(member.linkname)), dest, follow_symlinks=False)
        if member.issym():
            dest.symlink_to(member.linkname)
            ns = mtime_ns(member)
            os.utime(dest, ns=(ns, ns), follow_symlinks=False)
    for parts in reversed(directories):
        dest, member = stage.joinpath(*parts), members[parts]
        ns = mtime_ns(member)
        dest.chmod(member.mode)
        os.utime(dest, ns=(ns, ns))


def unpack(archive, destination, expected_sha, expected_bytes, *, raw_limit=RAW_MAX):
    archive, destination = Path(archive), Path(destination)
    owned_directory(archive.parent, private=True)
    owned_directory(destination.parent, private=True)
    if os.path.lexists(destination):
        raise Refusal("restore destination already exists")
    if archive.name != ARCHIVE_NAME or set(archive.parent.iterdir()) != {archive}:
        raise Refusal("transfer quarantine must contain exactly one expected blob")
    if (not isinstance(expected_sha, str) or not SHA256.fullmatch(expected_sha)
            or type(expected_bytes) is not int or not 0 < expected_bytes <= PACKED_MAX
            or type(raw_limit) is not int or not 0 < raw_limit <= RAW_MAX):
        raise Refusal("unproven trusted size, digest, or uncompressed limit")
    metadata = archive.lstat()
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
            or metadata.st_mode & 0o111 or metadata.st_nlink != 1):
        raise Refusal("restored path is not one inert owned regular file")
    descriptor = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as inp:
        opened = os.fstat(inp.fileno())
        if (opened.st_ino, opened.st_dev, opened.st_mode) != (metadata.st_ino, metadata.st_dev, metadata.st_mode):
            raise Refusal("transfer blob changed before validation")
        if opened.st_size != expected_bytes:
            raise Refusal("unexpected sealed blob size")
        started = time.monotonic()
        receipt = measure(inp)
        verified = time.monotonic()
        if receipt["bytes"] != expected_bytes or receipt["sha256"] != expected_sha:
            raise Refusal("sealed blob digest or length mismatch")
        inp.seek(0)
        with tempfile.TemporaryDirectory(prefix=".verify-", dir=destination.parent) as work:
            raw, stage = Path(work) / "payload.tar", Path(work) / "staged"
            with raw.open("xb") as out:
                raw_bytes = run_bounded(("-q", "-d", "-c"), inp, out, raw_limit,
                                        "uncompressed restore exceeds limit")
            inflated = time.monotonic()
            finished = os.fstat(inp.fileno())
            if (finished.st_size, finished.st_mtime_ns, finished.st_ctime_ns) != (
                    opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns):
                raise Refusal("transfer blob changed during validation")
            with raw.open("rb") as raw_file, tarfile.open(fileobj=RawTarIO(raw_file), mode="r:") as tar:
                members = validated_members(tar)
                checked = time.monotonic()
                stage.mkdir(mode=0o700)
                write_prevalidated_tree(tar, members, stage)
            if os.path.lexists(destination):
                raise Refusal("restore destination appeared during validation")
            # Not the active build path; reviewed consumer activates verified roots separately.
            os.rename(stage, destination)
    return {**receipt, "uncompressed_bytes": raw_bytes, "members": len(members), "seconds": {
        "inner_digest": verified - started,
        "inner_zstd_to_private_spool": inflated - verified,
        "tar_member_preflight": checked - inflated,
        "materialization": time.monotonic() - checked,
    }}


def before_save(usage, listing, packed_bytes, included_cap):
    if not isinstance(usage, dict) or not isinstance(listing, dict):
        raise Refusal("cache usage/listing shape is unproven")
    active = usage.get("active_caches_size_in_bytes")
    if (type(active) is not int or active < 0 or type(packed_bytes) is not int
            or not 0 < packed_bytes <= PACKED_MAX or type(included_cap) is not int
            or not 0 < included_cap <= 10_000_000_000
            or active + WRAPPER_MAX > min(included_cap - 2_000_000_000, 8_000_000_000)):
        raise Refusal("cache headroom or sealed size not established")
    if type(listing.get("total_count")) is not int or listing["total_count"] != 0 or listing.get("actions_caches") != []:
        raise Refusal("pre-save exact-ref/key listing is not empty")
    return {"active_bytes": active, "packed_bytes": packed_bytes, "reservation_bytes": WRAPPER_MAX}


def require_identity(identity):
    if (not isinstance(identity, dict) or identity.get("ref") != REF or not all(
            isinstance(identity.get(k), str) and re.fullmatch(r"[1-9][0-9]*", identity[k])
            for k in ("run", "attempt")
    ) or not isinstance(identity.get("harness_sha"), str) or not SHA1.fullmatch(identity["harness_sha"])
            or not isinstance(identity.get("archive_sha256"), str)
            or not SHA256.fullmatch(identity["archive_sha256"])):
        raise Refusal("unproven cache run/ref/harness/archive identity")
    key = ("fleck-fresh-ab-v1-r{run}-a{attempt}-{harness_sha}-{archive_sha256}").format(**identity)
    if identity.get("key") != key or len(key) > 512:
        raise Refusal("cache key is not bound to its expected identity")


def after_save(listing, identity):
    require_identity(identity)
    if not isinstance(listing, dict):
        raise Refusal("cache listing shape is unproven")
    entries = listing.get("actions_caches")
    if type(listing.get("total_count")) is not int or listing["total_count"] != 1 or not isinstance(entries, list) or len(entries) != 1:
        raise Refusal("post-save exact-ref/key listing is not singular")
    entry = entries[0]
    if (not isinstance(entry, dict) or entry.get("key") != identity["key"] or entry.get("ref") != identity["ref"]
            or type(entry.get("id")) is not int or entry["id"] <= 0
            or not isinstance(entry.get("version"), str) or not entry["version"]
            or type(entry.get("size_in_bytes")) is not int or not 0 < entry["size_in_bytes"] <= WRAPPER_MAX):
        raise Refusal("cache entry scope, ID, version, or size is unproven")
    return {**identity, "id": entry["id"], "version": entry["version"], "stored_bytes": entry["size_in_bytes"]}


def exact_restore(receipt, seed, observed, hit, matched_key, live_listing):
    require_identity(seed)
    require_identity(observed)
    live = after_save(live_listing, seed)
    if (seed != observed or receipt != live
            or hit != "true" or matched_key != seed["key"]):
        raise Refusal("cache restore is not the proven same-attempt exact hit")
    return live


def read_json(path):
    with path.open(encoding="utf-8") as file:
        return json.load(file)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    seal = commands.add_parser("pack")
    seal.add_argument("--scratch", type=Path, required=True)
    seal.add_argument("--package-cache", type=Path)
    seal.add_argument("--archive", type=Path, required=True)
    restore = commands.add_parser("unpack")
    restore.add_argument("--archive", type=Path, required=True)
    restore.add_argument("--destination", type=Path, required=True)
    restore.add_argument("--sha256", required=True)
    restore.add_argument("--bytes", type=int, required=True)
    quota = commands.add_parser("before-save")
    quota.add_argument("--usage", type=Path, required=True)
    quota.add_argument("--listing", type=Path, required=True)
    quota.add_argument("--packed-bytes", type=int, required=True)
    quota.add_argument("--confirmed-cap", type=int, required=True)
    published = commands.add_parser("after-save")
    published.add_argument("--listing", type=Path, required=True)
    published.add_argument("--identity", type=Path, required=True)
    exact = commands.add_parser("exact-restore")
    for option in ("receipt", "identity", "observed", "listing"):
        exact.add_argument("--" + option, type=Path, required=True)
    exact.add_argument("--hit", required=True)
    exact.add_argument("--matched-key", required=True)
    opts = parser.parse_args()
    if opts.command == "pack":
        roots = {"scratch": opts.scratch}
        if opts.package_cache is not None:
            roots["package-cache"] = opts.package_cache
        result = pack(roots, opts.archive)
    elif opts.command == "unpack":
        result = unpack(opts.archive, opts.destination, opts.sha256, opts.bytes)
    elif opts.command == "before-save":
        result = before_save(read_json(opts.usage), read_json(opts.listing),
                             opts.packed_bytes, opts.confirmed_cap)
    elif opts.command == "after-save":
        result = after_save(read_json(opts.listing), read_json(opts.identity))
    else:
        result = exact_restore(read_json(opts.receipt), read_json(opts.identity),
                               read_json(opts.observed), opts.hit, opts.matched_key,
                               read_json(opts.listing))
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, RecursionError) as error:
        raise SystemExit(f"sealed transport refused: {error}") from error
