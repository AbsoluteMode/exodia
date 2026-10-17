"""Behavioral checks for customization helpers; all writes use temporary stores."""
import argparse
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/customize.py"
SPEC = importlib.util.spec_from_file_location("whytap_customize", SCRIPT)
customize = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(customize)


def dashboard():
    return {"id": "example", "title": "Example", "widgets": [
        {"id": "cpu", "kind": "progress", "title": "CPU", "progress": 0.5}
    ]}


class CustomizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()

    def write_dashboard(self, value):
        path = self.directory / "snapshot.json"
        path.write_text(json.dumps(value))
        return path

    def call(self, args):
        with redirect_stdout(io.StringIO()):
            return customize.main(args)

    def test_discovery_is_machine_readable_and_does_not_execute_commands(self):
        output = io.StringIO()
        with patch.object(customize.subprocess, "run") as run, redirect_stdout(output):
            self.assertEqual(customize.main(["discover", "--json"]), 0)
        self.assertIn("hover", json.loads(output.getvalue())["change_kinds"])
        run.assert_not_called()

    def test_test_filter_is_one_argument_not_shell_code(self):
        requested = "HoverTests; touch /tmp/must-not-execute"
        with patch.object(customize.subprocess, "run") as run:
            run.return_value.returncode = 9
            self.assertEqual(self.call(["test", "--filter", requested]), 9)
        self.assertEqual(run.call_args.args[0], ["swift", "test", "--filter", requested])
        self.assertNotIn("shell", run.call_args.kwargs)

    def test_build_and_run_dry_run_never_launch(self):
        with patch.object(customize.subprocess, "run") as run:
            for command in ("build", "run", "test"):
                self.assertEqual(self.call([command, "--dry-run"]), 0)
        run.assert_not_called()

    def test_scaffold_rejects_existing_output_without_overwriting(self):
        output = self.directory / "draft"
        output.mkdir()
        sentinel = output / "keep.txt"
        sentinel.write_text("preserve")
        with self.assertRaises(ValueError):
            customize.make_output(str(output), "draft")
        self.assertEqual(sentinel.read_text(), "preserve")

    def test_scaffold_rejects_symlink_parent(self):
        real = self.directory / "real"
        real.mkdir()
        alias = self.directory / "alias"
        alias.symlink_to(real, target_is_directory=True)
        with self.assertRaises(ValueError):
            customize.make_output(str(alias / "draft"), "draft")
        self.assertFalse((real / "draft").exists())

    def test_hover_scaffold_rejects_duplicate_and_invalid_identifiers(self):
        for identifier in ("settings", "class", "../escape", "has-hyphen"):
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                customize.scaffold_hover(argparse.Namespace(id=identifier, title="Example", output=str(self.directory / identifier)))

    def test_hover_title_is_escaped_in_generated_swift(self):
        output = self.directory / "draft"
        requested = 'Text "quoted" \\(neverInterpolate)'
        with redirect_stdout(io.StringIO()):
            customize.scaffold_hover(argparse.Namespace(id="sampleTool", title=requested, output=str(output)))
        source = (output / "SampleToolContent.swift").read_text()
        self.assertIn('Text(' + json.dumps(requested) + ')', source)
        self.assertEqual(json.loads((output / "integration.json").read_text())["state"], "draft-not-installed")

    def test_dashboard_scaffold_is_valid_but_not_reported_live(self):
        output = self.directory / "draft"
        with redirect_stdout(io.StringIO()):
            customize.scaffold_dashboard(argparse.Namespace(id="custom-status", title="Custom status", output=str(output)))
        value, _ = customize.validate_dashboard(output / "custom-status.json")
        self.assertNotIn("updatedAt", value)
        self.assertEqual(value["widgets"][0]["value"], "Not connected")

    def test_dashboard_rejects_reserved_id_duplicate_ids_and_bad_measurements(self):
        malformed = []
        value = dashboard(); value["id"] = "server-status"; malformed.append(value)
        value = dashboard(); value["widgets"] *= 2; malformed.append(value)
        value = dashboard(); value["widgets"][0]["progress"] = 1.1; malformed.append(value)
        value = dashboard(); value["widgets"][0]["progress"] = True; malformed.append(value)
        value = dashboard(); value["widgets"][0]["kind"] = "shell"; malformed.append(value)
        value = dashboard(); value["updatedAt"] = "not-a-timestamp"; malformed.append(value)
        value = dashboard(); value["preferredWidth"] = 1; malformed.append(value)
        value = dashboard(); value["widgets"][0]["points"] = [{"label": "x", "value": float("inf")}]; malformed.append(value)
        for value in malformed:
            with self.subTest(value=value), self.assertRaises(ValueError):
                customize.validate_dashboard(self.write_dashboard(value))

    def test_dashboard_rejects_oversized_input_before_parsing(self):
        path = self.directory / "huge.json"
        path.write_bytes(b" " * 2_000_001)
        with self.assertRaisesRegex(ValueError, "2 MB"):
            customize.validate_dashboard(path)

    def test_dashboard_install_is_private_and_requires_explicit_replacement(self):
        source = self.write_dashboard(dashboard())
        args = argparse.Namespace(command="install-dashboard", path=str(source), flavor="beta", replace=False, dry_run=False)
        with patch.object(customize.Path, "home", return_value=self.directory), redirect_stdout(io.StringIO()):
            customize.dashboard_command(args)
            target = self.directory / "Library/Application Support/com.rootwise.sidekey.beta/Monitor/dashboards/example.json"
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(ValueError, "already exists"):
                customize.dashboard_command(args)
            changed = dashboard(); changed["title"] = "Changed"; self.write_dashboard(changed)
            self.assertEqual(json.loads(target.read_text())["title"], "Example")
            args.replace = True
            customize.dashboard_command(args)
            self.assertEqual(json.loads(target.read_text())["title"], "Changed")
            self.assertEqual(list(target.parent.glob(".dashboard-*")), [])

    def test_install_dry_run_has_no_filesystem_side_effects(self):
        source = self.write_dashboard(dashboard())
        with patch.object(customize.Path, "home", return_value=self.directory), redirect_stdout(io.StringIO()):
            customize.dashboard_command(argparse.Namespace(command="install-dashboard", path=str(source), flavor="prod", replace=False, dry_run=True))
        self.assertFalse((self.directory / "Library").exists())

    def test_guidance_regeneration_only_uses_canonical_file_and_rejects_symlinks(self):
        root = self.directory
        (root / ".project-docs").mkdir()
        (root / ".project-docs/agent-context.md").write_text("Canonical guidance\n")
        (root / "AGENTS.md").write_text("Old generated text\n")
        (root / "CLAUDE.md").write_text("Old generated text\n")
        with patch.object(customize, "ROOT", root):
            self.assertFalse(customize.guidance_status()["synchronized"])
            with redirect_stdout(io.StringIO()):
                customize.sync_guidance(argparse.Namespace(write=True, json=True))
            self.assertEqual((root / "AGENTS.md").read_bytes(), (root / ".project-docs/agent-context.md").read_bytes())
            (root / "CLAUDE.md").unlink()
            (root / "CLAUDE.md").symlink_to(root / "AGENTS.md")
            with self.assertRaises(ValueError):
                customize.guidance_status()


if __name__ == "__main__":
    unittest.main()
