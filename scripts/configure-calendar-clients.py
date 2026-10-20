#!/usr/bin/env python3
"""Put registered public native OAuth clients into an unsigned app's Info.plist.

The local config lives outside Git; no account tokens or web-app secrets are
accepted. Output names providers only, never client configuration values.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def validated_clients(value):
    if not isinstance(value, dict) or not value or set(value) - {"google", "microsoft", "zoom"}:
        raise ValueError("Expected registered Google, Microsoft or Zoom native clients.")
    result = {}
    for provider, client in value.items():
        allowed = {"clientID", "clientSecret"} if provider == "google" else {"clientID"}
        if not isinstance(client, dict) or set(client) - allowed:
            raise ValueError("Only public native-client configuration is accepted.")
        identifier = client.get("clientID")
        if not isinstance(identifier, str) or not identifier or len(identifier.encode()) > 8192 or any(c.isspace() or c == "\0" for c in identifier):
            raise ValueError("A native OAuth client ID is missing or invalid.")
        secret = client.get("clientSecret")
        if secret is not None and (not isinstance(secret, str) or not secret or len(secret.encode()) > 8192 or "\0" in secret):
            raise ValueError("Invalid Google desktop client configuration.")
        result[provider] = dict(client)
    return result


def configure(info_path, config_path, require_all=False):
    if config_path is None or not config_path.exists():
        if require_all:
            raise ValueError("Register Google, Microsoft and Zoom native OAuth clients before packaging this candidate.")
        print("Calendar sign-in: no shared client configuration; custom client setup remains available.")
        return
    if config_path.is_symlink() or not config_path.is_file() or config_path.stat().st_size > 65536:
        raise ValueError("Calendar client configuration must be a small regular plist file.")
    with config_path.open("rb") as stream:
        clients = validated_clients(plistlib.load(stream))
    if require_all and set(clients) != {"google", "microsoft", "zoom"}:
        raise ValueError("All three native OAuth clients are required for this candidate.")
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    info["WhytapCalendarOAuthClients"] = clients
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream)
    print("Calendar sign-in configured: " + ", ".join(sorted(clients)))


def client_config_path(explicit=None):
    if explicit is not None:
        return explicit
    if configured := os.environ.get("WHYTAP_CALENDAR_CLIENTS_PLIST"):
        return Path(configured)
    try:
        common = subprocess.check_output(
            ["git", "-C", str(Path(__file__).resolve().parent.parent), "rev-parse",
             "--path-format=absolute", "--git-common-dir"], text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        # A source ZIP has no shared registration. Custom client setup still works.
        return None
    return Path(common) / "whytap-calendar-clients.plist"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("info_plist", type=Path)
    parser.add_argument("--clients", type=Path)
    parser.add_argument("--require-all", action="store_true")
    args = parser.parse_args()
    try:
        config = client_config_path(args.clients)
        configure(args.info_plist, config, args.require_all)
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError):
        print("Calendar client configuration could not be validated; the app was not signed. Check the local native-client plist.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
