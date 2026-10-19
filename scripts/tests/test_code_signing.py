import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import code_signing

spec = importlib.util.spec_from_file_location("release_provenance", SCRIPTS / "release-provenance.py")
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)
CERTIFICATE = SCRIPTS.parent / "Resources/community-signing.cer"


class CommunitySigningTests(unittest.TestCase):
    def test_missing_key_and_different_key_fail_without_ad_hoc_fallback(self):
        policy = code_signing.certificate_policy(CERTIFICATE)
        for output in ("0 valid identities found", '1) ' + "0" * 40 + ' "Other"'):
            with self.subTest(output=output), patch.object(subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 0, stdout=output, stderr="")):
                with self.assertRaises(code_signing.SigningError):
                    code_signing.require_identity(policy)

    def test_available_pinned_key_is_selected_by_fingerprint(self):
        policy = code_signing.certificate_policy(CERTIFICATE)
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, stdout='1) ' + policy["identity"] + ' "Local signer"', stderr="")):
            code_signing.require_identity(policy)

    def test_certificate_policy_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            link = Path(folder) / "public.cer"
            link.symlink_to(CERTIFICATE)
            with self.assertRaises(code_signing.SigningError):
                code_signing.certificate_policy(link)

    def verify_fixture(self, wrong_architecture=None, wrong_bundle=False):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Exodia.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "wrong.bundle" if wrong_bundle else "com.rootwise.sidekey",
                "CFBundleExecutable": "Sidekey"}))

            def command(arguments, **kwargs):
                if "--verify" in arguments:
                    self.assertIn("--all-architectures", arguments)
                    self.assertTrue(any(item.startswith("-R=identifier") for item in arguments))
                    return subprocess.CompletedProcess(arguments, 0)
                architecture = arguments[arguments.index("--arch") + 1]
                prefix = next(item.split("=", 1)[1] for item in arguments
                              if item.startswith("--extract-certificates="))
                data = CERTIFICATE.read_bytes() if architecture != wrong_architecture else b"different public leaf"
                Path(prefix + "0").write_bytes(data)
                return subprocess.CompletedProcess(arguments, 0)

            with patch.object(subprocess, "check_output", return_value="arm64 x86_64"), \
                    patch.object(subprocess, "run", side_effect=command):
                return code_signing.verify_app(app, CERTIFICATE, "com.rootwise.sidekey")

    def test_all_architectures_use_pinned_public_certificate(self):
        result = self.verify_fixture()
        self.assertEqual(result["architectures"], ["arm64", "x86_64"])
        self.assertEqual(result["certificate_sha256"], hashlib.sha256(CERTIFICATE.read_bytes()).hexdigest())

    def test_wrong_non_host_architecture_certificate_is_rejected(self):
        with self.assertRaisesRegex(code_signing.SigningError, "unexpected signing certificate"):
            self.verify_fixture(wrong_architecture="x86_64")

    def test_wrong_bundle_id_is_rejected(self):
        with self.assertRaises(code_signing.SigningError):
            self.verify_fixture(wrong_bundle=True)


class SigningProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "Resources").mkdir()
        (self.root / "build").mkdir()
        (self.root / "scripts").mkdir()
        for script in ("code_signing.py", "release-provenance.py"):
            shutil.copyfile(SCRIPTS / script, self.root / "scripts" / script)
        shutil.copyfile(CERTIFICATE, self.root / "Resources/community-signing.cer")
        (self.root / ".gitignore").write_text("build/\n")
        commands = [["init", "-q"], ["config", "user.name", "Signing Fixture"],
                    ["config", "user.email", "fixture@example.invalid"],
                    ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", "/dev/null"],
                    ["add", "."], ["commit", "-qm", "fixture"]]
        for command in commands:
            subprocess.run(["git", "-C", str(self.root), *command], check=True, capture_output=True)
        self.archive = self.root / "build/Exodia-9.9.9-build42.dmg"
        self.archive.write_bytes(b"immutable archive fixture")
        self.args = argparse.Namespace(project_root=self.root, archive=self.archive,
            manifest=None, version="9.9.9", build=42, flavor="prod", distribution="community",
            source_sha=provenance.clean_revision(self.root))
        provenance.seal(self.args)

    def tearDown(self):
        self.temporary.cleanup()

    def test_manifest_binds_public_certificate_policy(self):
        receipt = json.loads(provenance.manifest_path(self.args).read_text())
        self.assertEqual(receipt["schema_version"], 2)
        self.assertEqual(receipt["code_signing"], code_signing.community_policy(self.root))
        self.assertEqual(provenance.verify(self.args), self.args.source_sha)

    def test_first_cli_capture_does_not_dirty_a_clean_checkout(self):
        environment = dict(os.environ)
        environment.pop("PYTHONDONTWRITEBYTECODE", None)
        result = subprocess.run(["/usr/bin/python3", str(self.root / "scripts/release-provenance.py"),
            "capture", "--project-root", str(self.root)], env=environment,
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), self.args.source_sha)
        self.assertFalse((self.root / "scripts/__pycache__").exists())
        self.assertEqual(provenance.clean_revision(self.root), self.args.source_sha)

    def test_tampered_signer_receipt_is_rejected_before_archive_publication(self):
        path = provenance.manifest_path(self.args)
        receipt = json.loads(path.read_text())
        receipt["code_signing"]["certificate_sha256"] = "0" * 64
        path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(provenance.InvalidProvenance, "metadata"):
            provenance.verify(self.args)

    def test_archive_byte_change_is_rejected(self):
        self.archive.write_bytes(b"changed archive")
        with self.assertRaisesRegex(provenance.InvalidProvenance, "archive bytes"):
            provenance.verify(self.args)


if __name__ == "__main__":
    unittest.main()
