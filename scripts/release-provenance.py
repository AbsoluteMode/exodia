#!/usr/bin/env python3
"""Bind a local release archive to committed build inputs; not remote attestation."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
# Provenance must not create untracked build inputs while checking cleanliness.
sys.dont_write_bytecode = True
from code_signing import community_policy

BUILD_INPUTS = ("Sources", "Resources", "Package.swift", "Package.resolved", "VERSION", "scripts")
BUNDLE_IDS = {"prod": "com.rootwise.sidekey", "beta": "com.rootwise.sidekey.beta"}


class InvalidProvenance(ValueError):
    pass


def git(root: Path, *arguments: str) -> str:
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    result = subprocess.run(["git", "-c", "core.fsmonitor=false", "-C", str(root), *arguments], env=environment,
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise InvalidProvenance("release provenance requires a readable Git checkout")
    return result.stdout.strip()


def clean_revision(root: Path) -> str:
    if Path(git(root, "rev-parse", "--show-toplevel")).resolve() != root.resolve():
        raise InvalidProvenance("project root must be the Git checkout root")
    revision = git(root, "rev-parse", "--verify", "HEAD^{commit}")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise InvalidProvenance("could not resolve the release source commit")
    if git(root, "status", "--porcelain=v1", "--untracked-files=all", "--", *BUILD_INPUTS):
        raise InvalidProvenance("commit build-input changes before building or publishing a release")
    return revision


def archive_digest(path: Path) -> tuple[str, int]:
    if path.is_symlink() or not path.is_file():
        raise InvalidProvenance("release archive must be a regular file")
    before = path.stat()
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    after = path.stat()
    identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
    if identity(before) != identity(after):
        raise InvalidProvenance("release archive changed while checking its digest")
    return digest.hexdigest(), after.st_size


def metadata(args: argparse.Namespace) -> dict:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?", args.version):
        raise InvalidProvenance("release version must be a semantic version")
    if args.build <= 0:
        raise InvalidProvenance("release build must be a positive integer")
    bundle = "Exodia" if args.flavor == "prod" else "Exodia-Beta"
    expected_name = f"{bundle}-{args.version}-build{args.build}.dmg"
    if args.archive.name != expected_name:
        raise InvalidProvenance("archive name does not match release version, build and flavor")
    signing = community_policy(args.project_root) if args.distribution == "community" else {"kind": "developer-id"}
    return {"schema_version": 2, "archive": expected_name, "version": args.version,
            "build": args.build, "flavor": args.flavor, "bundle_id": BUNDLE_IDS[args.flavor],
            "distribution": args.distribution, "architectures": ["arm64", "x86_64"], "code_signing": signing}


def manifest_path(args: argparse.Namespace) -> Path:
    return args.manifest or Path(str(args.archive) + ".manifest.json")


def seal(args: argparse.Namespace) -> str:
    revision = clean_revision(args.project_root)
    if revision != args.source_sha:
        raise InvalidProvenance("source commit changed during the release build; rebuild from a clean commit")
    value = metadata(args)
    digest, size = archive_digest(args.archive)
    value.update(source_revision=revision, archive_sha256=digest, archive_size=size)
    # Recheck after hashing, before recording the receipt.
    if clean_revision(args.project_root) != revision:
        raise InvalidProvenance("source commit changed while sealing the archive")
    destination = manifest_path(args)
    temporary = None
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=".release-manifest-", dir=destination.parent)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, indent=2)
            handle.write("\n")
        os.replace(temporary, destination)
        temporary = None
    finally:
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)
    return revision


def verify(args: argparse.Namespace) -> str:
    path = manifest_path(args)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 65536:
        raise InvalidProvenance("a valid build-time archive manifest is required; rebuild the release")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise InvalidProvenance("archive manifest must be an object")
    expected = metadata(args)
    if any(type(value.get(key)) is not type(item) or value.get(key) != item for key, item in expected.items()):
        raise InvalidProvenance("archive manifest metadata does not match the requested release")
    revision = clean_revision(args.project_root)
    if value.get("source_revision") != revision:
        raise InvalidProvenance("archive source commit does not match HEAD; rebuild the release")
    digest, size = archive_digest(args.archive)
    if value.get("archive_sha256") != digest or type(value.get("archive_size")) is not int or value["archive_size"] != size:
        raise InvalidProvenance("archive bytes do not match the build-time manifest")
    if clean_revision(args.project_root) != revision:
        raise InvalidProvenance("source commit changed while verifying the archive")
    return revision


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    for command in ("capture", "seal", "verify"):
        child = subcommands.add_parser(command)
        child.add_argument("--project-root", type=Path, required=True)
        if command != "capture":
            child.add_argument("--archive", type=Path, required=True)
            child.add_argument("--manifest", type=Path)
            child.add_argument("--version", required=True)
            child.add_argument("--build", type=int, required=True)
            child.add_argument("--flavor", choices=BUNDLE_IDS, required=True)
            child.add_argument("--distribution", choices=("community", "developer-id"), required=True)
        if command == "seal":
            child.add_argument("--source-sha", required=True)
    args = parser.parse_args(argv)
    try:
        result = clean_revision(args.project_root) if args.command == "capture" else globals()[args.command](args)
    except (InvalidProvenance, OSError, ValueError):
        # Do not echo private checkout paths, content, environment or credentials.
        exception = sys.exc_info()[1]
        message = str(exception) if isinstance(exception, InvalidProvenance) else "could not read release provenance data"
        print("ERROR: " + message, file=sys.stderr)
        return 1
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
