import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("routing", Path(__file__).with_name("computer_use_routing_logger.py"))
routing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(routing)


class RoutingDiagnosticsTests(unittest.TestCase):
    def test_inventory_distinguishes_active_helper_filters_and_excludes_payloads(self):
        def tap(identifier, owner, target, options=0, enabled=True):
            return {
                "id": identifier, "owner_pid": owner, "target_pid": target,
                "options": options, "enabled": enabled, "location": 3, "mask": 0x1C00,
                "untrusted_extra_payload": "must never enter a diagnostic record",
            }

        taps = [tap(1, 20, 30), tap(2, 20, 30), tap(3, 20, 0, options=1),
                tap(4, 20, 30, enabled=False), tap(5, 99, 30)]
        proc_text = (
            f"{os.getuid()} 20 1 Tue Oct 20 16:00:00 2026 {routing.HELPER}\n"
            f"{os.getuid()} 30 1 Tue Oct 20 15:00:00 2026 /Applications/Whytap.app/Contents/MacOS/Sidekey\n"
        )

        def command(args, **kwargs):
            return SimpleNamespace(stdout=proc_text if args[0] == "/bin/ps" else json.dumps(taps))

        with patch.object(routing.subprocess, "run", side_effect=command):
            result = routing.snapshot()
        self.assertEqual(result["counts"]["computer_use_active_per_app_keyboard_filters"], 2)
        self.assertEqual(result["counts"]["computer_use_taps"], 4)
        self.assertEqual(result["helper_processes"][0]["pid"], 20)
        self.assertNotIn("must never enter", json.dumps(result))
        self.assertNotIn(routing.HELPER, json.dumps(result))

    def test_capture_is_bounded_and_preserves_only_five_incidents(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(routing, "DATA", Path(directory)), \
                patch.object(routing, "status", return_value={"healthy": True}), \
                patch.object(routing, "snapshot", return_value={"counts": {}}):
            (routing.DATA / "routing.jsonl").write_bytes(b'{"kind":"heartbeat"}\n' * 150000)
            for _ in range(6):
                result = routing.capture("diagnostic_check")
                capture = Path(result["capture"])
                self.assertLessEqual((capture / "preceding-routing.jsonl").stat().st_size, routing.MAX_LOG_BYTES)
                for line in (capture / "preceding-routing.jsonl").read_text().splitlines():
                    json.loads(line)
            self.assertEqual(len(list((routing.DATA / "incidents").iterdir())), 5)

    def test_failed_capture_leaves_no_empty_incident(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(routing, "DATA", Path(directory)), \
                patch.object(routing, "snapshot", side_effect=TimeoutError), \
                patch.object(routing, "status", return_value={}):
            with self.assertRaises(TimeoutError):
                routing.capture("diagnostic_check")
            self.assertEqual(list((routing.DATA / "incidents").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
