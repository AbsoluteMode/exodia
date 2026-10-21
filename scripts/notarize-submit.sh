#!/bin/bash
#
# notarize-submit.sh - submit one signed archive to Apple's notary service and
# wait for its verdict. build-dmg.sh calls it for the zipped app and the DMG.
#
# The App Store Connect team API key comes only from the environment:
#   ASC_API_KEY_ID         key ID
#   ASC_API_KEY_ISSUER_ID  issuer ID
#   ASC_API_KEY_P8         contents of the AuthKey_<key ID>.p8 file
# Team builds run this script through Whytap Case
# (`whytap case run -p whytap --only ...`), so the key reaches only this
# process. The private key is written to a 0600 file in a private temporary
# directory and wiped on exit; it never appears in arguments or output.
# notarytool accepts the key ID and issuer ID only as arguments.
#
# Usage: notarize-submit.sh <archive.zip|archive.dmg> <log directory>
# Exits 0 only when Apple accepts the archive. For any other verdict the
# submission's log is saved as <log directory>/notarization-<id>.json.
#
# WHY: docs/decisions/2026-10-21-notarized-releases.md

set -euo pipefail
# Tracing (bash -x, or xtrace inherited through SHELLOPTS) would print the key.
set +x

if [ "$#" -ne 2 ]; then
    echo "usage: notarize-submit.sh <archive.zip|archive.dmg> <log directory>" >&2
    exit 64
fi
ARCHIVE="$1"
LOG_DIR="$2"
ARCHIVE_NAME="${ARCHIVE##*/}"
if [ ! -f "${ARCHIVE}" ]; then
    echo "ERROR: archive to notarize not found: ${ARCHIVE_NAME}" >&2
    exit 1
fi
if [ ! -d "${LOG_DIR}" ]; then
    echo "ERROR: notarization log directory not found: ${LOG_DIR}" >&2
    exit 1
fi

missing=()
for var in ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID ASC_API_KEY_P8; do
    [ -n "${!var:-}" ] || missing+=("$var")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: notarization needs ${missing[*]} in its environment (Whytap Case project whytap)." >&2
    exit 1
fi

KEY_DIR=""
NOTARYTOOL_PID=""
wipe_file() {
    local size
    if [ -f "$1" ]; then
        size="$(wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0)"
        if [ "${size:-0}" -gt 0 ]; then
            dd if=/dev/zero of="$1" bs=1 count="${size}" conv=notrunc >/dev/null 2>&1 || true
        fi
        rm -f "$1"
    fi
}
cleanup() {
    if [ -n "${NOTARYTOOL_PID}" ]; then
        kill "${NOTARYTOOL_PID}" 2>/dev/null || true
        wait "${NOTARYTOOL_PID}" 2>/dev/null || true
    fi
    if [ -n "${KEY_DIR}" ] && [ -d "${KEY_DIR}" ]; then
        wipe_file "${KEY_DIR}/AuthKey.p8"
        rm -rf "${KEY_DIR}"
    fi
}
trap cleanup EXIT
# Leave through the EXIT trap on interruption too, so the key file is removed.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

umask 077
KEY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whytap-notary.XXXXXX")"
KEY_FILE="${KEY_DIR}/AuthKey.p8"
RESULT_FILE="${KEY_DIR}/submission.json"

# Case stores a value from a single-line field, so a pasted .p8 can lose its
# line breaks. Accept the file's PEM with or without them, with literal \n, or
# base64 of the whole file, and write the canonical PEM. The value is read from
# the environment and never printed.
/usr/bin/python3 -I - "${KEY_FILE}" <<'PYKEY'
import base64
import binascii
import os
import re
import sys
import textwrap

MARKER = re.compile(r"-----(BEGIN|END) PRIVATE KEY-----")


def decode(text):
    try:
        return base64.b64decode(re.sub(r"\s+", "", MARKER.sub("", text)), validate=True)
    except (binascii.Error, ValueError):
        return b""


der = decode(os.environ["ASC_API_KEY_P8"].replace("\\n", "\n"))
if der.startswith(b"-----BEGIN PRIVATE KEY-----"):
    der = decode(der.decode("ascii", "replace"))
# A PKCS#8 private key is a DER SEQUENCE.
if len(der) < 32 or der[0] != 0x30:
    sys.exit("ERROR: ASC_API_KEY_P8 must hold the contents of the AuthKey_<key ID>.p8 file.")
body = "\n".join(textwrap.wrap(base64.b64encode(der).decode("ascii"), 64))
descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w", encoding="ascii") as handle:
    handle.write("-----BEGIN PRIVATE KEY-----\n" + body + "\n-----END PRIVATE KEY-----\n")
PYKEY
chmod 600 "${KEY_FILE}"

# Bash runs a trap only after a foreground child returns, so a stalled
# notarytool would keep the key file on disk past SIGTERM. Run it in the
# background: `wait` returns on a signal, and cleanup() stops notarytool first.
run_notarytool() {
    local status=0
    xcrun notarytool "$@" &
    NOTARYTOOL_PID=$!
    wait "${NOTARYTOOL_PID}" || status=$?
    NOTARYTOOL_PID=""
    return "${status}"
}

# Prints one field of the final notarytool JSON answer, empty when absent.
submission_field() {
    /usr/bin/python3 -I - "${RESULT_FILE}" "$1" <<'PYFIELD'
import json
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
answer = None
for candidate in [text] + text.splitlines()[::-1]:
    try:
        value = json.loads(candidate)
    except ValueError:
        continue
    if isinstance(value, dict):
        answer = value
        break
field = (answer or {}).get(sys.argv[2])
print(field if isinstance(field, str) else "")
PYFIELD
}

echo "▶ Notarizing ${ARCHIVE_NAME} (waiting for Apple, at most 20 minutes)..."
# --timeout 1200 caps the wait: Apple's queue has stalled for many hours
# (May 2026), and the submission continues on Apple's side after a timeout.
submit_status=0
run_notarytool submit "${ARCHIVE}" \
    --key "${KEY_FILE}" \
    --key-id "${ASC_API_KEY_ID}" \
    --issuer "${ASC_API_KEY_ISSUER_ID}" \
    --wait \
    --timeout 1200 \
    --output-format json > "${RESULT_FILE}" || submit_status=$?

submission_id="$(submission_field id)"
submission_status="$(submission_field status)"
if ! [[ "${submission_id}" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    submission_id=""
fi

if [ "${submit_status}" -eq 0 ] && [ "${submission_status}" = "Accepted" ]; then
    echo "  ok: Apple accepted ${ARCHIVE_NAME} (submission ${submission_id:-unknown})"
    exit 0
fi

echo "ERROR: Apple did not accept ${ARCHIVE_NAME}: status ${submission_status:-unknown}, notarytool exit ${submit_status}." >&2
message="$(submission_field message)"
if [ -n "${message}" ]; then
    echo "  notary service: ${message}" >&2
fi
if [ -z "${submission_id}" ]; then
    echo "  No submission was recorded. Check the network and the API key, then rebuild." >&2
    exit 1
fi
if [ -z "${submission_status}" ] || [ "${submission_status}" = "In Progress" ]; then
    echo "  Submission ${submission_id} is still processing on Apple's side; rebuild later." >&2
    exit 1
fi

LOG_FILE="${LOG_DIR}/notarization-${submission_id}.json"
if run_notarytool log "${submission_id}" \
        --key "${KEY_FILE}" \
        --key-id "${ASC_API_KEY_ID}" \
        --issuer "${ASC_API_KEY_ISSUER_ID}" \
        "${LOG_FILE}" >/dev/null; then
    echo "  Log: ${LOG_FILE}" >&2
    /usr/bin/python3 -I - "${LOG_FILE}" <<'PYLOG' >&2 || true
import json
import sys

issues = json.load(open(sys.argv[1], encoding="utf-8")).get("issues") or []
for issue in issues[:20]:
    print("  {}: {} ({})".format(issue.get("severity", "issue"), issue.get("message", ""),
                                 issue.get("path", "")))
if len(issues) > 20:
    print("  ... {} more in the log".format(len(issues) - 20))
PYLOG
else
    echo "  Could not download the log of submission ${submission_id}." >&2
fi
exit 1
