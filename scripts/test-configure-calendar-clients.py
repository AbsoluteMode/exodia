#!/usr/bin/env python3
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("calendar_clients", Path(__file__).with_name("configure-calendar-clients.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CalendarClientsTests(unittest.TestCase):
    def test_source_zip_cli_from_another_directory_keeps_custom_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source" / "scripts"
            source.mkdir(parents=True)
            script = source / "configure-calendar-clients.py"
            shutil.copyfile(module.__file__, script)
            info = root / "Info.plist"
            original = plistlib.dumps({"CFBundleIdentifier": "com.rootwise.sidekey"})
            info.write_bytes(original)
            env = {k: v for k, v in os.environ.items()
                   if k not in {"WHYTAP_CALENDAR_CLIENTS_PLIST", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"}}
            result = module.subprocess.run([sys.executable, str(script), str(info)], cwd=root.parent,
                                           env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(info.read_bytes(), original)
            result = module.subprocess.run([sys.executable, str(script), str(info), "--require-all"], cwd=root.parent,
                                           env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(info.read_bytes(), original)

    def test_overrides_do_not_require_a_git_checkout(self):
        with patch.dict(os.environ, {"WHYTAP_CALENDAR_CLIENTS_PLIST": "/fixture/env.plist"}), \
             patch.object(module.subprocess, "check_output", side_effect=AssertionError("Git must not run")):
            self.assertEqual(module.client_config_path(Path("/fixture/explicit.plist")), Path("/fixture/explicit.plist"))
            self.assertEqual(module.client_config_path(), Path("/fixture/env.plist"))

    def test_git_discovery_uses_the_script_checkout_and_source_zip_can_build(self):
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(module.subprocess, "check_output", return_value="/fixture/common\n") as git:
            self.assertEqual(module.client_config_path(), Path("/fixture/common/whytap-calendar-clients.plist"))
            self.assertEqual(git.call_args.args[0][1:3], ["-C", str(Path(module.__file__).resolve().parent.parent)])
        with patch.dict(os.environ, {}, clear=True), \
             patch.object(module.subprocess, "check_output", side_effect=module.subprocess.CalledProcessError(128, "git")):
            self.assertIsNone(module.client_config_path())
            with self.assertRaises(ValueError):
                module.configure(Path("unused"), None, require_all=True)
            module.configure(Path("unused"), None)
    def test_native_clients_are_embedded_without_changing_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info, clients = root / "Info.plist", root / "clients.plist"
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.rootwise.sidekey"}))
            values = {name: {"clientID": "fixture-" + name} for name in ["google", "microsoft", "zoom"]}
            clients.write_bytes(plistlib.dumps(values))
            module.configure(info, clients, require_all=True)
            result = plistlib.loads(info.read_bytes())
            self.assertEqual(result["CFBundleIdentifier"], "com.rootwise.sidekey")
            self.assertEqual(result["WhytapCalendarOAuthClients"], values)

    def test_confidential_clients_and_account_tokens_are_refused(self):
        for value in [
            {"microsoft": {"clientID": "fixture", "clientSecret": "fixture"}},
            {"google": {"clientID": "fixture", "accessToken": "fixture"}},
            {"zoom": {"clientID": ""}},
        ]:
            with self.assertRaises(ValueError):
                module.validated_clients(value)

    def test_public_review_approval_requires_an_explicit_string(self):
        for provider in ["google", "microsoft", "zoom"]:
            for approval in ["true", "false"]:
                value = {provider: {"clientID": "fixture", "publicAccessApproved": approval}}
                self.assertEqual(module.validated_clients(value), value)
            for approval in [True, False, 1, "TRUE", "approved", ""]:
                with self.assertRaises(ValueError):
                    module.validated_clients({provider: {"clientID": "fixture", "publicAccessApproved": approval}})

    def test_missing_registration_does_not_modify_the_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info = root / "Info.plist"
            original = plistlib.dumps({"CFBundleIdentifier": "com.rootwise.sidekey"})
            info.write_bytes(original)
            with self.assertRaises(ValueError):
                module.configure(info, root / "absent.plist", require_all=True)
            self.assertEqual(info.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
