#!/usr/bin/env python3
"""Local, content-free inventory logger for the open Computer Use input bug.

This tool never receives keyboard events, reads clipboard contents, automates UI,
contacts the network, or stops other applications. `install` explicitly enables
a per-user background logger. `disable` stops only this logger and preserves logs.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import uuid

LABEL = "local.computer-use-input-routing"
TOOLS = Path.home() / ".codex/diagnostics/tools/input-routing"
DATA = Path.home() / ".codex/diagnostics/input-routing"
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
HELPER = str(Path.home() / ".codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
APP_PATHS = {
    "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT": "Codex",
    "/Applications/Codex.app/Contents/MacOS/Codex": "Codex",
    "/Applications/Whytap.app/Contents/MacOS/Sidekey": "Whytap",
    "/Applications/Exodia.app/Contents/MacOS/Sidekey": "Exodia",
    "/Applications/Dia.app/Contents/MacOS/Dia": "Dia",
}
MAX_LOG_BYTES = 2 * 1024 * 1024
MAX_INCIDENTS = 5
REASONS = ("duplicated_typing", "stray_paste", "history_paste_failed", "recovered", "diagnostic_check")


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def atomic_json(path, value):
    temp = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    try:
        temp.write_text(json.dumps(value, sort_keys=True) + "\n")
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def processes():
    output = subprocess.run(
        ["/bin/ps", "-axo", "uid=,pid=,ppid=,lstart=,comm="],
        capture_output=True, text=True, check=True, timeout=3,
    ).stdout
    result = {}
    for line in output.splitlines():
        row = line.strip().split(None, 8)
        if len(row) != 9:
            continue
        result[int(row[1])] = {
            "pid": int(row[1]), "ppid": int(row[2]), "uid": int(row[0]),
            "started": " ".join(row[3:8]), "executable": row[8],
        }
    return result


def snapshot():
    output = subprocess.run(
        [str(TOOLS / "event-tap-inventory")], capture_output=True,
        text=True, check=True, timeout=3,
    ).stdout
    taps = json.loads(output)
    procs = processes()
    helpers = [p for p in procs.values() if p["executable"] == HELPER and p["uid"] == os.getuid()]
    helper_pids = {p["pid"] for p in helpers}
    app_processes = []
    disk_versions = {}
    for proc in procs.values():
        name = "Computer Use" if proc["executable"] == HELPER else APP_PATHS.get(proc["executable"])
        if name and proc["uid"] == os.getuid():
            try:
                info = plistlib.loads((Path(proc["executable"]).parent.parent / "Info.plist").read_bytes())
                disk_versions[name] = {k: info.get(k) for k in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion")}
            except (OSError, plistlib.InvalidFileException):
                disk_versions[name] = None
        if proc["executable"] in APP_PATHS and proc["uid"] == os.getuid():
            app_processes.append({
                "name": APP_PATHS[proc["executable"]],
                "pid": proc["pid"], "started": proc["started"],
            })
    inventory = []
    for tap in taps:
        # Select the schema explicitly; no arbitrary tool output enters the log.
        record = {key: tap[key] for key in (
            "id", "owner_pid", "target_pid", "location", "options", "enabled", "mask"
        )}
        for field, name in (("owner_pid", "owner"), ("target_pid", "target")):
            record[name] = Path(procs.get(record[field], {}).get("executable", "unknown")).name
        record["computer_use"] = record["owner_pid"] in helper_pids
        inventory.append(record)
    inventory.sort(key=lambda item: item["id"])
    keyboard_mask = (1 << 10) | (1 << 11) | (1 << 12)
    active = [t for t in inventory if t["computer_use"] and t["enabled"] and not (t["options"] & 1)]
    return {
        "helper_processes": sorted(
            [{k: p[k] for k in ("pid", "ppid", "started")} for p in helpers], key=lambda p: p["pid"]
        ),
        "app_processes": sorted(app_processes, key=lambda p: p["pid"]),
        "on_disk_versions": disk_versions,
        "taps": inventory,
        "counts": {
            "all_taps": len(inventory),
            "computer_use_taps": sum(t["computer_use"] for t in inventory),
            "computer_use_active_per_app_keyboard_filters": sum(
                t["target_pid"] > 0 and bool(t["mask"] & keyboard_mask) for t in active
            ),
        },
    }


def logger_run(interval):
    DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (DATA / "logger.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        logger = logging.getLogger("input-routing")
        logger.setLevel(logging.INFO)
        logger.propagate = False
        handler = RotatingFileHandler(DATA / "routing.jsonl", maxBytes=MAX_LOG_BYTES, backupCount=7)
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger.addHandler(handler)
        previous = None
        last_written = 0.0
        sequence = 0
        session = uuid.uuid4().hex
        started = utc_now()
        while True:
            collected = utc_now()
            sequence += 1
            try:
                current = snapshot()
                kind = "startup" if previous is None else "change" if current != previous else "heartbeat"
                if current != previous or time.monotonic() - last_written >= 60:
                    logger.info(json.dumps({
                        "schema": 1, "time": collected, "kind": kind,
                        "session": session, "sequence": sequence, "snapshot": current,
                    }, sort_keys=True))
                    last_written = time.monotonic()
                previous = current
                state = {
                    "schema": 1, "logger_pid": os.getpid(), "started": started,
                    "sampled_at": collected, "sequence": sequence,
                    "interval_seconds": interval, "counts": current["counts"], "last_error": None,
                }
            except Exception as error:
                # Exception messages can contain subprocess output; store only the class.
                state = {
                    "schema": 1, "logger_pid": os.getpid(), "started": started,
                    "sampled_at": collected, "sequence": sequence,
                    "interval_seconds": interval, "last_error": type(error).__name__,
                }
                if time.monotonic() - last_written >= 60 or previous is not None:
                    logger.info(json.dumps({"schema": 1, "time": collected, "kind": "error", "error": type(error).__name__}))
                    last_written = time.monotonic()
                previous = None
            atomic_json(DATA / "state.json", state)
            time.sleep(interval)


def status():
    try:
        state = json.loads((DATA / "state.json").read_text())
        age = (datetime.now(timezone.utc) - datetime.fromisoformat(state["sampled_at"])).total_seconds()
        try:
            os.kill(state["logger_pid"], 0)
            alive = True
        except ProcessLookupError:
            alive = False
        return {
            "installed": PLIST.exists(), "healthy": alive and age < 20 and state["last_error"] is None,
            "sample_age_seconds": round(age, 1), "state": state,
        }
    except FileNotFoundError:
        return {"installed": PLIST.exists(), "healthy": False, "state": None}


def capture(reason):
    # Read-only capture before recovery; no app restart or clipboard access.
    incidents = DATA / "incidents"
    incidents.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = incidents / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f") + "-" + uuid.uuid4().hex[:8])
    target.mkdir(mode=0o700)
    try:
        atomic_json(target / "snapshot.json", {
            "schema": 1, "time": utc_now(), "reason": reason,
            "logger": status(), "snapshot": snapshot(),
        })
    except Exception:
        shutil.rmtree(target)
        raise
    try:
        with (DATA / "routing.jsonl").open("rb") as source:
            source.seek(0, os.SEEK_END)
            offset = max(0, source.tell() - MAX_LOG_BYTES)
            source.seek(offset)
            if offset:
                source.readline()
            (target / "preceding-routing.jsonl").write_bytes(source.read(MAX_LOG_BYTES))
    except FileNotFoundError:
        pass
    # Prune only this tool's own captures after a successful capture.
    own = sorted(p for p in incidents.iterdir() if p.is_dir() and (p / "snapshot.json").is_file())
    for old in own[:-MAX_INCIDENTS]:
        shutil.rmtree(old)
    return {"capture": str(target), "reason": reason}


def install():
    TOOLS.mkdir(parents=True, exist_ok=True, mode=0o700)
    DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    source = Path(__file__).resolve()
    native_source = source.with_name("event_tap_inventory.swift")
    if not native_source.is_file():
        raise RuntimeError("Install from the repository source directory")
    candidate = TOOLS / "event-tap-inventory.new"
    subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", str(native_source), "-o", str(candidate)], check=True)
    installed_script = TOOLS / source.name
    # Only this named logger service is stopped during an explicit reinstall.
    if PLIST.exists():
        subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}", str(PLIST)], capture_output=True)
    os.replace(candidate, TOOLS / "event-tap-inventory")
    if source != installed_script.resolve():
        shutil.copyfile(source, installed_script)
        shutil.copyfile(native_source, TOOLS / native_source.name)
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    PLIST.write_bytes(plistlib.dumps({
        "Label": LABEL,
        "ProgramArguments": [sys.executable, str(installed_script), "run"],
        "RunAtLoad": True, "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 30, "ProcessType": "Background", "Nice": 10,
        "LowPriorityIO": True, "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
    }))
    subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(PLIST)], check=True)
    return {"installed": True, "label": LABEL, "logs": str(DATA)}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "run", "status", "capture", "disable"))
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--reason", choices=REASONS, default="diagnostic_check")
    args = parser.parse_args()
    if args.interval < 1:
        parser.error("interval must be at least one second")
    if args.action == "run":
        logger_run(args.interval)
        return
    if args.action == "install":
        result = install()
    elif args.action == "status":
        result = status()
    elif args.action == "capture":
        result = capture(args.reason)
    else:
        subprocess.run(["/bin/launchctl", "bootout", f"gui/{os.getuid()}", str(PLIST)], check=False, capture_output=True)
        PLIST.unlink(missing_ok=True)
        result = {"disabled": True, "logs_preserved": str(DATA)}
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
