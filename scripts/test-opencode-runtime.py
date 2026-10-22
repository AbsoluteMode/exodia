#!/usr/bin/env python3
"""Exercise an installed OpenCode CLI against a loopback model; no paid requests.

Use --legacy-binary to check that V2 continues a synthetic V1 conversation.
All conversations, files, config, and keys are disposable fixtures.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import signal
import sys
import subprocess
import tempfile
import threading
import time

SCREEN_IMAGE = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQckkDAAFYAM11wf4aAAAAAElFTkSuQmCC"


def screen_server():
    """Synthetic MCP pixels only; never accesses a real screen or the app."""
    for line in sys.stdin:
        request = json.loads(line)
        if os.environ.get("WHYTAP_FIXTURE_MCP_LOG"):
            with open(os.environ["WHYTAP_FIXTURE_MCP_LOG"], "a") as log:
                log.write(json.dumps({"method": request.get("method"), "params": request.get("params")}) + "\n")
        if "id" not in request:
            continue
        method = request.get("method")
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "screen-fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "whytap_capture_screen", "description": "Return synthetic fixture pixels",
                                "inputSchema": {"type": "object", "properties": {}, "required": [], "additionalProperties": False},
                                "annotations": {"readOnlyHint": True, "destructiveHint": False}}]}
        elif method == "tools/call":
            assert request["params"]["name"] == "whytap_capture_screen"
            result = {"content": [{"type": "image", "mimeType": "image/png", "data": SCREEN_IMAGE}], "isError": False}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--legacy-binary", type=Path)
    parser.add_argument("--screen-fixture", action="store_true", help="Check MCP image delivery using synthetic pixels")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    legacy = args.legacy_binary.resolve(strict=True) if args.legacy_binary else None
    requests = []
    screen_requested = []
    failure = []
    fixture_key = "whytap-disposable-runtime-fixture"
    with tempfile.TemporaryDirectory(prefix="whytap-opencode-fixture-") as temporary:
        root = Path(temporary)
        fixture = root / "fixture.txt"
        fixture.write_text("synthetic-read-fixture\n")

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                try:
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    assert self.path == "/v1/chat/completions"
                    assert body["model"] == "whytap-fixture"
                    assert body.get("provider") == {"order": ["fixture-pin"], "allow_fallbacks": False}, "OpenRouter pin must survive V2 config normalization"
                    assert self.headers.get("Authorization") == "Bearer " + fixture_key
                    requests.append(body)
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    if (args.screen_fixture and not screen_requested) or (not args.screen_fixture and len(requests) == 1):
                        if args.screen_fixture:
                            time.sleep(0.4)  # Model latency lets V2 finish its asynchronous MCP registration.
                        names = {t["function"]["name"] for t in body.get("tools", [])}
                        # V2 admits its first prompt before MCP registration.
                        # A tool boundary carries the catalog update into the
                        # next request; real models discover the same update.
                        discovered = "tools.screen.whytap_capture_screen" in json.dumps(body["messages"])
                        use_screen = args.screen_fixture and (discovered or "screen_whytap_capture_screen" in names)
                        assert len(requests) <= 3, "screen catalog did not become available"
                        tool_name = ("screen_whytap_capture_screen" if "screen_whytap_capture_screen" in names else "execute") if use_screen else "read"
                        assert tool_name in names, (tool_name, sorted(names))
                        tool = next(t["function"] for t in body["tools"] if t["function"]["name"] == tool_name)
                        fields = tool["parameters"].get("properties", {})
                        path_key = "filePath" if "filePath" in fields else "path"
                        delta = {"role": "assistant", "tool_calls": [{"index": 0,
                            "id": f"call_fixture_{len(requests)}", "type": "function", "function": {
                                "name": tool_name, "arguments": json.dumps(
                                    {"code": "console.log(await tools.screen.whytap_capture_screen({}));"}
                                    if use_screen and tool_name == "execute" else
                                    {} if use_screen else {path_key: str(fixture.resolve())})}}]}
                        if use_screen:
                            screen_requested.append(True)
                        finish = "tool_calls"
                    else:
                        delta = {"role": "assistant", "content": "fixture answer"}
                        finish = "stop"
                    for value, reason in [(delta, None), ({}, finish)]:
                        event = {"id": "chatcmpl-fixture", "object": "chat.completion.chunk",
                            "created": int(time.time()), "model": "whytap-fixture",
                            "choices": [{"index": 0, "delta": value, "finish_reason": reason}]}
                        self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                except Exception as error:
                    failure.append(type(error).__name__ + ": " + str(error))

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            # Preserve HOME for normal CLI behavior; all OpenCode stores are
            # redirected, and no inherited provider/config variable is copied.
            env = {k: os.environ[k] for k in ("HOME", "PATH", "TMPDIR") if k in os.environ}
            for key, name in [("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"),
                              ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")]:
                env[key] = str(root / name)
            env.update(OPENROUTER_API_KEY=fixture_key, OPENCODE_DISABLE_AUTOUPDATE="true",
                OPENCODE_DISABLE_DEFAULT_PLUGINS="true", OPENCODE_DISABLE_CLAUDE_CODE="true")
            # The supported V1 configuration is deliberately retained in the
            # app; this checks its V2 compatibility, not a substitute config.
            config = {"model": "openrouter/whytap-fixture", "enabled_providers": ["openrouter"],
                "share": "disabled", "autoupdate": False,
                "permission": {"*": "deny", "read": "allow"},
                "provider": {"openrouter": {"options": {"apiKey": "{env:OPENROUTER_API_KEY}",
                    "baseURL": f"http://127.0.0.1:{server.server_port}/v1"},
                    "models": {"whytap-fixture": {"tool_call": True,
                        "limit": {"context": 128000, "output": 4096},
                        "options": {"provider": {"order": ["fixture-pin"], "allow_fallbacks": False}}}}}}}
            env["OPENCODE_CONFIG_CONTENT"] = json.dumps(config)
            if args.screen_fixture:
                env["WHYTAP_FIXTURE_MCP_LOG"] = str(root / "screen-calls.jsonl")
                config["mcp"] = {"screen": {"type": "local", "command": [sys.executable, str(Path(__file__).resolve()), "--mcp-screen-server"], "enabled": True}}
                config["permission"]["screen_*"] = "allow"
                config["permission"]["execute"] = "allow"
                env["OPENCODE_CONFIG_CONTENT"] = json.dumps(config)

            def run(executable, prompt, session=None):
                version = subprocess.run([str(executable), "--version"], cwd=root, env=env,
                    text=True, capture_output=True, timeout=15, check=True).stdout.strip()
                command = [str(executable), "run"]
                if version.startswith("opencode v2."):
                    command.append("--standalone")
                command += ["--format", "json", "--model", "openrouter/whytap-fixture", "--title", "Whytap fixture"]
                if session:
                    command += ["--session", session]
                process = subprocess.Popen(command, cwd=root, env=env, text=True,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                try:
                    stdout, stderr = process.communicate(prompt, timeout=45)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.communicate()
                    raise AssertionError("OpenCode fixture timed out")
                assert process.returncode == 0, f"OpenCode exited {process.returncode}: {stderr[:1000]}"
                events = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
                assert any(e.get("type") == "text" and e.get("part", {}).get("text") == "fixture answer" for e in events)
                assert not any(e.get("type") == "error" for e in events)
                return version, events

            first_version, first = run(legacy or binary, "First synthetic fixture")
            assert not failure, failure
            completed_count = len(requests)
            assert (2 <= completed_count <= 4) if args.screen_fixture else completed_count == 2, "tool call(s) followed by the answer"
            expected_tool = "screen_whytap_capture_screen" if args.screen_fixture else "read"
            # V2's JSON run stream omits MCP tool_use events. The final model
            # request must still contain the actual MCP image, not a text label.
            if not args.screen_fixture:
                assert any(e.get("type") == "tool_use" and e.get("part", {}).get("tool") == expected_tool for e in first)
            if args.screen_fixture:
                calls = (root / "screen-calls.jsonl").read_text()
                assert '"tools/call"' in calls, "screen MCP tool was not invoked"
                assert SCREEN_IMAGE in json.dumps(requests[-1]["messages"]), "MCP image must reach the selected model as media"
                assert '"image_url"' in json.dumps(requests[-1]["messages"])
            else:
                assert "synthetic-read-fixture" in json.dumps(requests[1]["messages"])
            session = next(e["sessionID"] for e in first if e.get("sessionID"))
            second_version, second = run(binary, "Second synthetic fixture", session)
            assert len(requests) == completed_count + 1
            history = json.dumps(requests[-1]["messages"])
            assert "First synthetic fixture" in history and "Second synthetic fixture" in history
            assert all(e.get("sessionID", session) == session for e in second)
            assert not failure, failure
            for path in root.rglob("*"):
                if path.is_file():
                    assert fixture_key.encode() not in path.read_bytes(), "provider key persisted in runtime fixture"
            print(json.dumps({"status": "passed", "first_version": first_version,
                "second_version": second_version, "local_model_requests": len(requests),
                "read_tool": not args.screen_fixture, "screen_image": args.screen_fixture,
                "resumed_history": True, "persisted_key": False}))
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    if sys.argv[1:] == ["--mcp-screen-server"]:
        screen_server()
    else:
        main()
