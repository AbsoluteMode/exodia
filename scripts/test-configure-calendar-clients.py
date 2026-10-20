#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("calendar_clients", Path(__file__).with_name("configure-calendar-clients.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CalendarClientsTests(unittest.TestCase):
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
