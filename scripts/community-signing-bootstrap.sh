#!/usr/bin/env bash
#
# community-signing-bootstrap.sh — One-shot code-signing identity for
# community builds.
#
# Creates a self-signed code-signing certificate, stores its private key in
# Doppler (or a private file for a fork) and writes the public certificate to
# Resources/community-signing-certificate.pem for commit. With that file
# committed, build-dmg.sh signs every community build with this identity.
#
# Run it once. The designated requirement of each build pins the certificate's
# SHA-1 and macOS privacy grants (Microphone, System Audio) follow that
# requirement. A new certificate is a new identity: every install has to grant
# its permissions again, once. Rotate only for a reason such as a leaked key,
# because code signed with the key inherits those grants.
# WHY: .project-docs/decisions/2026-10-19-community-signing-identity.md
#
# Usage:
#   ./scripts/community-signing-bootstrap.sh                  # Doppler sidekey/dev
#   ./scripts/community-signing-bootstrap.sh --project P --config C
#   ./scripts/community-signing-bootstrap.sh --key-file PATH  # without Doppler
#
# The private key is never printed or passed on a command line.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERTIFICATE_FILE="${PROJECT_DIR}/Resources/community-signing-certificate.pem"
SECRET_NAME="EXODIA_COMMUNITY_SIGNING_KEY"
DOPPLER_PROJECT_NAME="sidekey"
DOPPLER_CONFIG_NAME="dev"
KEY_FILE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --project) DOPPLER_PROJECT_NAME="${2:?--project needs a value}"; shift ;;
        --config) DOPPLER_CONFIG_NAME="${2:?--config needs a value}"; shift ;;
        --key-file) KEY_FILE="${2:?--key-file needs a path}"; shift ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -s "${CERTIFICATE_FILE}" ]; then
    echo "ERROR: ${CERTIFICATE_FILE#"${PROJECT_DIR}"/} already exists." >&2
    echo "Refusing to replace the community signing identity: every install would" >&2
    echo "have to grant its macOS permissions again. Read the header before rotating." >&2
    exit 1
fi
if [ -n "${KEY_FILE}" ]; then
    if [ -e "${KEY_FILE}" ]; then
        echo "ERROR: ${KEY_FILE} already exists; refusing to overwrite a private key." >&2
        exit 1
    fi
else
    command -v doppler >/dev/null 2>&1 || { echo "ERROR: doppler CLI is required (or use --key-file)." >&2; exit 1; }
    if doppler secrets get "${SECRET_NAME}" --project "${DOPPLER_PROJECT_NAME}" \
            --config "${DOPPLER_CONFIG_NAME}" --plain >/dev/null 2>&1; then
        echo "ERROR: ${SECRET_NAME} already exists in Doppler ${DOPPLER_PROJECT_NAME}/${DOPPLER_CONFIG_NAME}." >&2
        echo "Refusing to replace it; restore its certificate from git history instead." >&2
        exit 1
    fi
fi

umask 077
WORK_DIR="$(mktemp -d -t exodia-community-signing)"
cleanup() {
    local size
    if [ -f "${WORK_DIR}/key.pem" ]; then
        size="$(wc -c < "${WORK_DIR}/key.pem" | tr -d ' ')"
        dd if=/dev/zero of="${WORK_DIR}/key.pem" bs=1 count="${size}" conv=notrunc >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# CN only: without an organization the default designated requirement is
# identifier + certificate leaf hash. 30 years, so expiry never forces a rotation.
echo "▶ Generating an RSA-3072 self-signed code-signing certificate..."
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 10950 -nodes \
    -keyout "${WORK_DIR}/key.pem" -out "${WORK_DIR}/certificate.pem" \
    -subj "/CN=Exodia Community Code Signing" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
CERTIFICATE_PUBLIC_KEY="$(/usr/bin/openssl x509 -in "${WORK_DIR}/certificate.pem" -noout -pubkey)"

if [ -n "${KEY_FILE}" ]; then
    cp "${WORK_DIR}/key.pem" "${KEY_FILE}"
    STORED_PUBLIC_KEY="$(/usr/bin/openssl pkey -in "${KEY_FILE}" -pubout)"
    STORED_IN="${KEY_FILE} (mode 0600)"
else
    echo "▶ Storing ${SECRET_NAME} in Doppler ${DOPPLER_PROJECT_NAME}/${DOPPLER_CONFIG_NAME}..."
    doppler secrets set "${SECRET_NAME}" --project "${DOPPLER_PROJECT_NAME}" \
        --config "${DOPPLER_CONFIG_NAME}" --silent < "${WORK_DIR}/key.pem" >/dev/null
    STORED_PUBLIC_KEY="$(doppler secrets get "${SECRET_NAME}" --project "${DOPPLER_PROJECT_NAME}" \
        --config "${DOPPLER_CONFIG_NAME}" --plain | /usr/bin/openssl pkey -pubout)"
    STORED_IN="Doppler ${DOPPLER_PROJECT_NAME}/${DOPPLER_CONFIG_NAME} as ${SECRET_NAME}"
fi
if [ "${STORED_PUBLIC_KEY}" != "${CERTIFICATE_PUBLIC_KEY}" ]; then
    echo "ERROR: the stored private key does not match the new certificate." >&2
    exit 1
fi

# Write the public certificate only after the key is safely stored.
cp "${WORK_DIR}/certificate.pem" "${CERTIFICATE_FILE}"
chmod 0644 "${CERTIFICATE_FILE}"
SHA1="$(/usr/bin/openssl x509 -in "${CERTIFICATE_FILE}" -noout -fingerprint -sha1 \
    | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')"

echo "✓ Private key stored in ${STORED_IN}"
echo "✓ Certificate saved to Resources/community-signing-certificate.pem"
echo "  SHA-1: ${SHA1}"
echo "  prod requirement: identifier \"com.rootwise.sidekey\" and certificate leaf = H\"${SHA1}\""
echo "  beta requirement: identifier \"com.rootwise.sidekey.beta\" and certificate leaf = H\"${SHA1}\""
echo ""
echo "Next: commit the certificate (public, not secret) and build with the key, e.g."
echo "  doppler run --project ${DOPPLER_PROJECT_NAME} --config ${DOPPLER_CONFIG_NAME} -- \\"
echo "    env FLAVOR=prod ./scripts/user-release.sh --build-only"
