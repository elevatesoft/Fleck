"""Check obvious credential and local-repository paths before sealing public seed."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from transport import Refusal
from warm_contract import check


GIT_KEYS = {
    "core.repositoryformatversion", "core.filemode", "core.bare",
    "core.logallrefupdates", "core.ignorecase", "core.precomposeunicode",
    "core.symlinks", "remote.origin.url", "remote.origin.fetch",
    "remote.origin.mirror", "extensions.objectformat",
}
# SwiftPM 6.3.3 GitRepositoryProvider's exact git clone -c profile.
# Never allow a hook path or a truthy synonym for core.fsmonitor.
SWIFTPM_CLONE_VALUES = {"core.fsmonitor": "false", "core.longpaths": "true"}
CREDENTIAL_NAMES = {".netrc", ".git-credentials", ".ssh", ".aws",
                    "credentials.json", ".npmrc", ".env"}


def normalize(value):
    # Fixed public HTTPS host, no auth, directives, port, fragment or query.
    check(isinstance(value, str) and re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value),
          "git-origin-syntax")
    return value.removesuffix(".git").lower()


def validate_origin_graph(items, allowed):
    def confirmed(config, ancestors):
        check(config not in ancestors, "git-origin-cycle")
        origin = items.get(config)
        check(origin, "git-origin-missing")
        if origin.startswith("https://"):
            check(normalize(origin) in allowed, "git-origin-not-pinned")
            return
        local = Path(origin.removeprefix("file://"))
        check(local.is_absolute() and not any(ch in origin for ch in ("%", "#", "?", "\n", "\r")),
              "git-local-origin-syntax")
        root = local.resolve(strict=True)
        check(root == local and (root / "config") in items,
              "git-local-origin-outside-roots")
        confirmed(root / "config", ancestors | {config})
    check(items, "git-config-empty")
    for config in items:
        confirmed(config, set())


def parse_config(raw):
    origins = []
    seen_profile = set()
    for entry in raw.rstrip(b"\0").split(b"\0"):
        key, separator, value = entry.decode().partition("\n")
        plain_branch = ((re.fullmatch(r"branch\.[A-Za-z0-9_./-]+\.remote", key) and value == "origin")
                        or (re.fullmatch(r"branch\.[A-Za-z0-9_./-]+\.merge", key)
                            and re.fullmatch(r"refs/heads/[A-Za-z0-9_./-]+", value)))
        if key in SWIFTPM_CLONE_VALUES:
            check(separator and key not in seen_profile and value == SWIFTPM_CLONE_VALUES[key],
                  "git-clone-profile-value")
            seen_profile.add(key)
            continue
        check(separator and (key in GIT_KEYS or plain_branch), "git-config-key")
        if key == "remote.origin.url":
            origins.append(value)
    check(len(origins) == 1, "git-origin-count")
    return origins[0]


def audit(roots, pins):
    allowed = {normalize(pin["location"]) for pin in pins}
    check(allowed, "pin-inventory-empty")
    roots = tuple(Path(path).resolve(strict=True) for path in roots)
    configs = {}
    for root in roots:
        for current, dirs, files in os.walk(root, followlinks=False):
            current = Path(current)
            for name in [*dirs, *files]:
                check(name not in CREDENTIAL_NAMES, "credential-like-name")
                path = current / name
                if name == ".git" and not path.is_dir():
                    check(path.is_file() and not path.is_symlink() and path.stat().st_size <= 4096,
                          "git-indirection-entry")
                    data = path.read_text().strip()
                    check(data.startswith("gitdir: "), "git-indirection-syntax")
                    dest = (current / data[8:]).resolve(strict=True)
                    check(any(dest.is_relative_to(root) for root in roots), "git-indirection-outside-roots")
                if name != "config" or not (current / "HEAD").is_file() or not (current / "objects").is_dir():
                    continue
                check(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65536,
                      "git-config-file")
                raw = subprocess.run(["git", "config", "--no-includes", "--file", str(path), "--null", "--list"],
                                     capture_output=True, check=True).stdout
                configs[path] = parse_config(raw)
    validate_origin_graph(configs, allowed)


# Only fixed reason codes may cross the public log boundary.
REASONS = {
    "git-origin-syntax", "git-origin-cycle", "git-origin-missing",
    "git-origin-not-pinned", "git-local-origin-syntax", "git-local-origin-outside-roots",
    "git-config-empty", "git-origin-count", "pin-inventory-empty",
    "credential-like-name", "git-indirection-entry", "git-indirection-syntax",
    "git-indirection-outside-roots", "git-config-file", "git-clone-profile-value",
    "git-config-key",
}


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("audit-arguments")
        audit(sys.argv[1:], json.loads(Path("Package.resolved").read_text())["pins"])
        print("Selected dependency metadata passed public-lock and credential-path checks.")
    except (ValueError, OSError, KeyError, RuntimeError, subprocess.CalledProcessError) as failure:
        reason = "audit-input-or-io"
        if isinstance(failure, Refusal) and len(failure.args) == 1 and failure.args[0] in REASONS:
            reason = failure.args[0]
        raise SystemExit(f"seed dependency metadata audit refused [{reason}]; no cache publication") from None
