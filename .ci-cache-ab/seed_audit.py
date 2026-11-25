"""Check obvious credential and local-repository paths before sealing public seed."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from warm_contract import check


GIT_KEYS = {
    "core.repositoryformatversion", "core.filemode", "core.bare",
    "core.logallrefupdates", "core.ignorecase", "core.precomposeunicode",
    "core.symlinks", "remote.origin.url", "remote.origin.fetch",
    "remote.origin.mirror", "extensions.objectformat",
}
CREDENTIAL_NAMES = {".netrc", ".git-credentials", ".ssh", ".aws",
                    "credentials.json", ".npmrc", ".env"}


def normalize(value):
    # Fixed public HTTPS host, no auth, directives, port, fragment or query.
    check(isinstance(value, str) and re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value),
          "git origin is not a known public checkout")
    return value.removesuffix(".git").lower()


def validate_origin_graph(items, allowed):
    def confirmed(config, ancestors):
        check(config not in ancestors, "git origin cycle")
        origin = items.get(config)
        check(origin, "git origin is missing or not audited")
        if origin.startswith("https://"):
            check(normalize(origin) in allowed, "git origin is not in pinned public lockfile")
            return
        local = Path(origin.removeprefix("file://"))
        check(local.is_absolute() and not any(ch in origin for ch in ("%", "#", "?", "\n", "\r")),
              "git local origin is not canonical")
        root = local.resolve(strict=True)
        check(root == local and (root / "config") in items,
              "git local origin is outside audited bare repositories")
        confirmed(root / "config", ancestors | {config})
    check(items, "no git dependency metadata was audited")
    for config in items:
        confirmed(config, set())


def audit(roots, pins):
    allowed = {normalize(pin["location"]) for pin in pins}
    check(allowed, "empty lockfile pin inventory")
    roots = tuple(Path(path).resolve(strict=True) for path in roots)
    configs = {}
    for root in roots:
        for current, dirs, files in os.walk(root, followlinks=False):
            current = Path(current)
            for name in [*dirs, *files]:
                check(name not in CREDENTIAL_NAMES, "unexpected credential/config name in seed")
                path = current / name
                if name == ".git" and not path.is_dir():
                    check(path.is_file() and not path.is_symlink() and path.stat().st_size <= 4096,
                          "unexpected git worktree indicator")
                    data = path.read_text().strip()
                    check(data.startswith("gitdir: "), "unknown git worktree indicator")
                    dest = (current / data[8:]).resolve(strict=True)
                    check(any(dest.is_relative_to(root) for root in roots), "git metadata escapes selected roots")
                if name != "config" or not (current / "HEAD").is_file() or not (current / "objects").is_dir():
                    continue
                check(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65536,
                      "unexpected git configuration path or size")
                raw = subprocess.run(["git", "config", "--no-includes", "--file", str(path), "--null", "--list"],
                                     capture_output=True, check=True).stdout
                origins = []
                for entry in raw.rstrip(b"\0").split(b"\0"):
                    key, separator, value = entry.decode().partition("\n")
                    plain_branch = ((re.fullmatch(r"branch\.[A-Za-z0-9_./-]+\.remote", key) and value == "origin")
                                    or (re.fullmatch(r"branch\.[A-Za-z0-9_./-]+\.merge", key)
                                        and re.fullmatch(r"refs/heads/[A-Za-z0-9_./-]+", value)))
                    check(separator and (key in GIT_KEYS or plain_branch), "unexpected Git configuration key in seed")
                    if key == "remote.origin.url":
                        origins.append(value)
                check(len(origins) == 1, "git origin is missing or ambiguous")
                configs[path] = origins[0]
    validate_origin_graph(configs, allowed)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("expected exactly the two experiment roots")
        audit(sys.argv[1:], json.loads(Path("Package.resolved").read_text())["pins"])
        print("Selected dependency metadata passed public-lock and credential-path checks.")
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError):
        raise SystemExit("seed dependency metadata audit refused; no cache publication") from None
