"""Local Git/temporary-archive release provenance checks; no credentials or network."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release-provenance.py"
SPEC = importlib.util.spec_from_file_location("release_provenance", SCRIPT)
provenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provenance)


class ReleaseProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="exodia-provenance-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        for directory in ("Sources", "Resources", "scripts", "build"):
            (self.root / directory).mkdir()
        (self.root / ".gitignore").write_text("build/\n")
        (self.root / "Sources/App.swift").write_text("let version = 1\n")
        (self.root / "VERSION").write_text("2.2.0\n")
        self.git("init", "-q")
        for key, value in (("user.name", "Release Fixture"), ("user.email", "fixture@example.invalid"),
                           ("commit.gpgsign", "false"), ("core.fsmonitor", "false"),
                           ("core.hooksPath", "/dev/null")):
            self.git("config", key, value)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture source")
        self.sha = provenance.clean_revision(self.root)
        self.archive = self.root / "build/Exodia-2.2.0-build1452.dmg"
        self.archive.write_bytes(b"test archive")
        self.args = argparse.Namespace(project_root=self.root, archive=self.archive, manifest=None,
            source_sha=self.sha, version="2.2.0", build=1452, flavor="prod", distribution="community")
        self.manifest = Path(str(self.archive) + ".manifest.json")

    def git(self, *arguments):
        result = subprocess.run(["git", "-C", str(self.root), *arguments], check=True,
                                capture_output=True, text=True,
                                env={"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
                                     "GIT_CONFIG_GLOBAL": "/dev/null"})
        return result.stdout.strip()

    def test_valid_receipt_binds_source_metadata_and_archive_bytes(self):
        self.assertEqual(provenance.seal(self.args), self.sha)
        self.assertEqual(provenance.verify(self.args), self.sha)
        value = json.loads(self.manifest.read_text())
        self.assertEqual(value["archive_sha256"], hashlib.sha256(b"test archive").hexdigest())
        self.assertEqual(value["source_revision"], self.sha)
        self.assertEqual(value["archive_size"], len(b"test archive"))
        self.assertEqual(self.manifest.stat().st_mode & 0o777, 0o600)

    def test_wrong_manifest_source_revision_is_rejected(self):
        provenance.seal(self.args)
        value = json.loads(self.manifest.read_text())
        value["source_revision"] = "0" * 40
        self.manifest.write_text(json.dumps(value))
        with self.assertRaisesRegex(provenance.InvalidProvenance, "does not match HEAD"):
            provenance.verify(self.args)

    def test_new_head_rejects_old_archive_and_cannot_seal_old_capture(self):
        provenance.seal(self.args)
        (self.root / "Sources/App.swift").write_text("let version = 2\n")
        self.git("add", "Sources")
        self.git("commit", "-qm", "new source")
        with self.assertRaisesRegex(provenance.InvalidProvenance, "changed during"):
            provenance.seal(self.args)
        with self.assertRaisesRegex(provenance.InvalidProvenance, "does not match HEAD"):
            provenance.verify(self.args)

    def test_tampered_archive_with_same_length_is_rejected(self):
        provenance.seal(self.args)
        self.archive.write_bytes(b"best archive")
        with self.assertRaisesRegex(provenance.InvalidProvenance, "archive bytes"):
            provenance.verify(self.args)

    def test_dirty_or_untracked_build_inputs_are_rejected(self):
        (self.root / "Sources/App.swift").write_text("let version = 3\n")
        with self.assertRaisesRegex(provenance.InvalidProvenance, "commit build-input changes"):
            provenance.clean_revision(self.root)
        self.git("checkout", "--", "Sources/App.swift")
        (self.root / "Resources/new-resource.txt").write_text("new resource")
        with self.assertRaisesRegex(provenance.InvalidProvenance, "commit build-input changes"):
            provenance.seal(self.args)
        self.assertFalse(self.manifest.exists())

    def test_wrong_release_metadata_is_rejected(self):
        provenance.seal(self.args)
        value = json.loads(self.manifest.read_text())
        value["build"] = 1453
        self.manifest.write_text(json.dumps(value))
        with self.assertRaisesRegex(provenance.InvalidProvenance, "metadata"):
            provenance.verify(self.args)

    def test_staged_copy_can_be_checked_against_original_receipt(self):
        provenance.seal(self.args)
        staging = self.root / "build/staging"
        staging.mkdir()
        copy = staging / self.archive.name
        shutil.copyfile(self.archive, copy)
        self.args.archive = copy
        self.args.manifest = self.manifest
        self.assertEqual(provenance.verify(self.args), self.sha)

    def test_missing_receipt_fails_without_creating_one(self):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            status = provenance.main(["verify", "--project-root", str(self.root), "--archive", str(self.archive),
                "--version", "2.2.0", "--build", "1452", "--flavor", "prod", "--distribution", "community"])
        self.assertEqual(status, 1)
        self.assertFalse(self.manifest.exists())


if __name__ == "__main__":
    unittest.main()
