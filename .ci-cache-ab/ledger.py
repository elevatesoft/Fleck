"""Read only GitHub cache metadata, isolated from compiler/test steps."""
import argparse
import json
import os
from pathlib import Path
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

import transport
import warm_contract as contract


class NeverForward(HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, newurl):
        return None


def api(path, query=None, *, documented_cap=False):
    address = "https://api.github.com/repos/" + contract.REPO + "/actions/" + path
    if query:
        address += "?" + urlencode(query)
    # Job-local actions:read token only; not argv, logs, fixtures or child env.
    token = os.environ.get("GH_READ_TOKEN", "")
    contract.check(bool(token), "built-in Actions read token unavailable")
    request = Request(address, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2026-03-10",
    }, method="GET")
    try:
        with build_opener(NeverForward()).open(request, timeout=15) as response:
            body = response.read(1_048_577)
            contract.check(len(body) <= 1_048_576, "cache REST response exceeded limit")
            return json.loads(body)
    except HTTPError as error:
        if documented_cap and path == "cache/storage-limit" and error.code == 402:
            print("Storage limit endpoint returned HTTP 402; using owner-attested public allowance only.")
            return None
        # Report observed HTTP status, never response body, URL auth, or token.
        raise transport.Refusal(f"GitHub {path} read returned HTTP {error.code}") from None
    except URLError:
        raise transport.Refusal(f"GitHub {path} unavailable via verified HTTPS") from None


def cap_and_usage(stage):
    env = os.environ
    cap = contract.admission(env, int(time.time()), stage)
    basis = json.loads(env["FLECK_FRESH_ADMISSION"])["basis"]
    configured = api("cache/storage-limit", documented_cap=basis == "owner-reviewed-public-10gb")
    if configured is not None:
        gb = configured.get("max_cache_size_gb") if isinstance(configured, dict) else None
        contract.check(type(gb) is int and gb > 0, "effective repository cap response unproven")
        cap = min(cap, gb * 1_000_000_000)
    else:
        contract.check(basis == "owner-reviewed-public-10gb", "configured cap not verified")
    usage = api("cache/usage")
    full = api("caches", {"per_page": 100})
    return cap, contract.active_bytes(usage, full)


def exact(key):
    return api("caches", {"per_page": 100, "ref": transport.REF, "key": key})


def output(key, value):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        out.write(f"{key}={json.dumps(value, separators=(',', ':')) if not isinstance(value, str) else value}\n")


def trusted_seed():
    envelope = json.loads(os.environ["FLECK_CACHE_SEED"])
    receipt = json.loads(os.environ["FLECK_CACHE_RECEIPT"])
    identity = contract.identity(os.environ, envelope["identity"]["archive_sha256"])
    contract.check(identity == envelope["identity"], "seed is not same exact run/attempt/ref/harness")
    contract.check(type(envelope["bytes"]) is int and 0 < envelope["bytes"] <= transport.PACKED_MAX,
                   "seed packed size is unproven")
    return envelope, receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=("admit", "before-save", "after-save", "restore-plan", "verify-restore"))
    parser.add_argument("lane", choices=("seed", "cold", "restore"))
    args = parser.parse_args()
    contract.assert_context(os.environ, args.lane)
    root = Path(contract.ROOT)
    if args.stage == "admit":
        cap, active = cap_and_usage("restore" if args.lane == "restore" else "start")
        if args.lane != "restore":
            contract.admit_headroom(cap, active)
        print(f"Cache budget preflight: active {active} bytes, confirmed ceiling {cap} bytes.")
    elif args.stage == "before-save":
        contract.check(args.lane == "seed", "save authorization is seed-only")
        packed = transport.read_json(root / "pack.json")
        identity = contract.identity(os.environ, packed["sha256"])
        archive = root / "transfer" / transport.ARCHIVE_NAME
        contract.check(set(archive.parent.iterdir()) == {archive}
                       and archive.is_file() and not archive.is_symlink(), "only one sealed blob is allowed")
        with archive.open("rb") as file:
            checked = transport.measure(file)
        contract.check(checked == {"bytes": packed["bytes"], "sha256": packed["sha256"]},
                       "blob bytes changed after sealing")
        cap, active = cap_and_usage("save")
        decision = transport.before_save({"active_caches_size_in_bytes": active},
                                         exact(identity["key"]), checked["bytes"], cap)
        envelope = {"identity": identity, "bytes": checked["bytes"],
                    "source": transport.read_json(root / "source.json"),
                    "machine": transport.read_json(root / "machine.json")}
        (root / "seed-envelope.json").write_text(json.dumps(envelope))
        print(f"One immutable entry reserved: packed {decision['packed_bytes']} bytes; reserve {decision['reservation_bytes']}.")
        output("key", identity["key"])
        output("allow", "true")
    elif args.stage == "after-save":
        contract.check(args.lane == "seed", "save receipt is seed-only")
        envelope = transport.read_json(root / "seed-envelope.json")
        receipt = transport.after_save(exact(envelope["identity"]["key"]), envelope["identity"])
        cap, active = cap_and_usage("save")
        contract.check(active <= min(cap - 2_000_000_000, 8_000_000_000), "active cache usage no longer fits budget")
        output("envelope", envelope)
        output("receipt", receipt)
        print(f"Exact cache ID verified: {receipt['id']}; wrapper bytes delta {receipt['stored_bytes'] - envelope['bytes']}.")
    else:
        contract.check(args.lane == "restore", "restore proof is restore-only")
        envelope, receipt = trusted_seed()
        identity = envelope["identity"]
        listing = exact(identity["key"])
        contract.check(transport.read_json(root / "source.json") == envelope["source"]
                       and transport.read_json(root / "machine.json") == envelope["machine"],
                       "seed/consumer source, toolchain, image or canonical paths differ")
        if args.stage == "restore-plan":
            contract.check(transport.after_save(listing, identity) == receipt,
                           "seed cache does not match the fresh exact-ref record")
            output("key", identity["key"])
        else:
            transport.exact_restore(receipt, identity, contract.identity(os.environ, identity["archive_sha256"]),
                                    os.environ.get("FLECK_CACHE_HIT"), os.environ.get("FLECK_CACHE_MATCHED"), listing)
            # A verified marker blocks native restore if this independent step failed.
            with (root / "verified-envelope.json").open("x") as file:
                json.dump(envelope, file)
            print(f"Exact restored cache object and seed identity verified: {receipt['id']}.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError) as error:
        raise SystemExit(f"cache ledger refused: {error}") from error
