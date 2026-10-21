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
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--legacy-binary", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    legacy = args.legacy_binary.resolve(strict=True) if args.legacy_binary else None
    requests = []
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
                    if len(requests) == 1:
                        names = {t["function"]["name"] for t in body.get("tools", [])}
                        assert "read" in names, "read-only policy must expose read"
                        read_tool = next(t["function"] for t in body["tools"] if t["function"]["name"] == "read")
                        fields = read_tool["parameters"].get("properties", {})
                        path_key = "filePath" if "filePath" in fields else "path"
                        delta = {"role": "assistant", "tool_calls": [{"index": 0,
                            "id": "call_fixture", "type": "function", "function": {
                                "name": "read", "arguments": json.dumps({path_key: str(fixture.resolve())})}}]}
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
            assert len(requests) == 2, "one read tool call followed by the answer"
            assert any(e.get("type") == "tool_use" and e.get("part", {}).get("tool") == "read" for e in first)
            assert "synthetic-read-fixture" in json.dumps(requests[1]["messages"]), [(m.get("role"), m.get("content")) for m in requests[1]["messages"] if m.get("role") == "tool"]
            session = next(e["sessionID"] for e in first if e.get("sessionID"))
            second_version, second = run(binary, "Second synthetic fixture", session)
            assert len(requests) == 3
            history = json.dumps(requests[-1]["messages"])
            assert "First synthetic fixture" in history and "Second synthetic fixture" in history
            assert all(e.get("sessionID", session) == session for e in second)
            assert not failure, failure
            for path in root.rglob("*"):
                if path.is_file():
                    assert fixture_key.encode() not in path.read_bytes(), "provider key persisted in runtime fixture"
            print(json.dumps({"status": "passed", "first_version": first_version,
                "second_version": second_version, "local_model_requests": len(requests),
                "read_tool": True, "resumed_history": True, "persisted_key": False}))
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
