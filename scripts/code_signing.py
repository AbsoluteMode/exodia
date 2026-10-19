#!/usr/bin/env python3
"""Pinned community code identity. Reads public certificates; never exports keys."""
# WHY: .project-docs/decisions/2026-10-19-stable-code-identity.md
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


class SigningError(ValueError):
    pass


def certificate_policy(certificate: Path) -> dict[str, str]:
    if certificate.is_symlink() or not certificate.is_file():
        raise SigningError("the pinned community signing certificate is missing")
    data = certificate.read_bytes()
    if not 128 <= len(data) <= 65536 or data[:1] != b"\x30":
        raise SigningError("the pinned community certificate must be DER encoded")
    return {"kind": "certificate", "certificate_sha256": hashlib.sha256(data).hexdigest(),
            "identity": hashlib.sha1(data).hexdigest().upper()}


def community_policy(root: Path) -> dict[str, str]:
    policy = certificate_policy(root / "Resources/community-signing.cer")
    return {key: policy[key] for key in ("kind", "certificate_sha256")}


def require_identity(policy: dict[str, str]) -> None:
    result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                            capture_output=True, text=True, check=False)
    fingerprints = re.findall(r"^\s*\d+\)\s+([0-9A-Fa-f]{40})\s", result.stdout, re.MULTILINE)
    if result.returncode or policy["identity"] not in {item.upper() for item in fingerprints}:
        raise SigningError("the private key for the pinned signing certificate is unavailable; "
                           "restore that identity in Keychain before building (no ad-hoc fallback)")


def verify_app(app: Path, certificate: Path, bundle_id: str) -> dict:
    policy = certificate_policy(certificate)
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        executable_name = info["CFBundleExecutable"]
        if (info["CFBundleIdentifier"] != bundle_id
                or not re.fullmatch(r"[A-Za-z0-9._-]+", bundle_id)
                or not isinstance(executable_name, str) or "/" in executable_name):
            raise SigningError("application identity does not match the signing policy")
        executable = app / "Contents/MacOS" / executable_name
        architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    except (OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        raise SigningError("could not read the packaged application identity") from error
    if not architectures or any(item not in {"arm64", "x86_64", "arm64e"} for item in architectures):
        raise SigningError("unexpected packaged executable architecture")
    requirement = f'identifier "{bundle_id}" and certificate leaf = H"{policy["identity"]}"'
    result = subprocess.run(["codesign", "--verify", "--deep", "--strict", "--all-architectures",
                             "-R=" + requirement, str(app)], capture_output=True, check=False)
    if result.returncode:
        raise SigningError("application signature does not satisfy the pinned certificate policy")
    # Verify the full public certificate digest too, for every architecture.
    with tempfile.TemporaryDirectory(prefix="exodia-public-signature-") as directory:
        for architecture in architectures:
            prefix = str(Path(directory) / (architecture + "-cert-"))
            result = subprocess.run(["codesign", "--display", "--arch", architecture,
                                     "--extract-certificates=" + prefix, str(app)],
                                    capture_output=True, check=False)
            leaf = Path(prefix + "0")
            if (result.returncode or not leaf.is_file()
                    or hashlib.sha256(leaf.read_bytes()).hexdigest() != policy["certificate_sha256"]):
                raise SigningError("packaged architecture has an unexpected signing certificate")
    return {**policy, "bundle_id": bundle_id, "architectures": sorted(architectures)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    identity = subcommands.add_parser("identity")
    identity.add_argument("--certificate", type=Path, required=True)
    identity.add_argument("--require-private-key", action="store_true")
    identity.add_argument("--json", action="store_true")
    verify = subcommands.add_parser("verify")
    verify.add_argument("--certificate", type=Path, required=True)
    verify.add_argument("--app", type=Path, required=True)
    verify.add_argument("--bundle-id", required=True)
    args = parser.parse_args()
    try:
        if args.command == "identity":
            result = certificate_policy(args.certificate)
            if args.require_private_key:
                require_identity(result)
            print(json.dumps(result, sort_keys=True) if args.json else result["identity"])
        else:
            print(json.dumps(verify_app(args.app, args.certificate, args.bundle_id), sort_keys=True))
    except (SigningError, OSError, subprocess.SubprocessError):
        error = sys.exc_info()[1]
        message = str(error) if isinstance(error, SigningError) else "could not validate community code identity"
        print("ERROR: " + message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
