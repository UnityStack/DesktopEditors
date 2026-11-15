#!/usr/bin/env bash
# Signs the final (signed, notarized, stapled) DMG for Sparkle and describes
# it as one update: Sparkle's sign_update makes the EdDSA signature with the
# private key from SPARKLE_ED_PRIVATE_KEY, appcast.py checks it against the
# committed public key and against the app's Info.plist, and writes the JSON
# that publish-repo adds to the appcasts. Used by the sign-macos job in
# .github/workflows/build.yml; see "Automatic updates (Sparkle)" in
# build/macos/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") --dmg <file> --tag <tag> --sign-update <path> --out <json> [options]

Required:
  --dmg <file>             The DMG as it is attached to the release (stapled;
                           its name is the asset name).
  --tag <tag>              The release tag (v9.3.6-ce, ...).
  --sign-update <path>     Sparkle's sign_update, from the Sparkle the app
                           bundles (desktop-apps/macos/Vendor/Sparkle/bin).
  --out <file>             Where to write the update (JSON).

Optional:
  --repo <owner/name>      Default: \${GITHUB_REPOSITORY:-UnityStack/DesktopEditors}.
  --public-key <file>      Default: ${SCRIPT_DIR}/sparkle-ed25519.pub
  --private-key-file <f>   Read the private key from this file instead of
                           SPARKLE_ED_PRIVATE_KEY (local tests with a
                           throwaway key).

Environment:
  SPARKLE_ED_PRIVATE_KEY   Sparkle's private EdDSA key as appcast.py generate
                           writes it, the format of generate_keys -x of
                           Sparkle 2.0.0 (base64, 128 characters). Written to a
                           mode 600 file under \${RUNNER_TEMP:-\${TMPDIR}} for
                           sign_update and removed on exit.
EOF
}

DMG="" TAG="" SIGN_UPDATE="" OUT="" REPO="${GITHUB_REPOSITORY:-UnityStack/DesktopEditors}"
PUBLIC_KEY="${SCRIPT_DIR}/sparkle-ed25519.pub" PRIVATE_KEY_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dmg) DMG="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --sign-update) SIGN_UPDATE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --public-key) PUBLIC_KEY="$2"; shift 2 ;;
        --private-key-file) PRIVATE_KEY_FILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" 1>&2; usage 1>&2; exit 1 ;;
    esac
done

fail() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::error::$*"
    else
        echo "error: $*" 1>&2
    fi
    exit 1
}

if [ -z "${DMG}" ] || [ -z "${TAG}" ] || [ -z "${SIGN_UPDATE}" ] || [ -z "${OUT}" ]; then
    echo "error: --dmg, --tag, --sign-update and --out are required." 1>&2
    usage 1>&2
    exit 1
fi
[ -f "${DMG}" ] || fail "${DMG} not found."
[ -x "${SIGN_UPDATE}" ] || fail "${SIGN_UPDATE} is not an executable."
APPCAST=(python3 -I "${SCRIPT_DIR}/appcast.py")

# The private key and the public key belong together, before anything is
# signed (prints nothing secret).
check_args=(--public-key "${PUBLIC_KEY}")
[ -z "${PRIVATE_KEY_FILE}" ] || check_args+=(--private-key-file "${PRIVATE_KEY_FILE}")
"${APPCAST[@]}" check-key "${check_args[@]}"

WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sparkle-sign.XXXXXX")"
MOUNT=""
cleanup() {
    local rc=$?
    [ -z "${MOUNT}" ] || hdiutil detach -quiet -force "${MOUNT}" 2>/dev/null || true
    rm -rf "${WORK}"
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
chmod 700 "${WORK}"

# sign_update reads the key from a file (-f) rather than its command line
# (-s), which other processes could see. Without either it would read the
# login keychain.
KEY_FILE="${WORK}/sparkle.key"
if [ -n "${PRIVATE_KEY_FILE}" ]; then
    (umask 077 && tr -d '[:space:]' < "${PRIVATE_KEY_FILE}" > "${KEY_FILE}")
else
    (umask 077 && printf '%s' "${SPARKLE_ED_PRIVATE_KEY:-}" | tr -d '[:space:]' > "${KEY_FILE}")
fi
echo "==> sign_update $(basename "${DMG}")"
out="$("${SIGN_UPDATE}" "${DMG}" -f "${KEY_FILE}")" || fail "sign_update failed: ${out}"
rm -f "${KEY_FILE}"
echo "${out}"
if ! [[ "${out}" =~ sparkle:edSignature=\"([A-Za-z0-9+/=]+)\"\ length=\"([0-9]+)\" ]]; then
    fail "Unexpected sign_update output: ${out}"
fi
SIGNATURE="${BASH_REMATCH[1]}"
LENGTH="${BASH_REMATCH[2]}"

# The app's own update settings, which sign.sh wrote before signing.
echo "==> Reading the app's Info.plist"
MOUNT="${WORK}/mnt"
mkdir "${MOUNT}"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "${MOUNT}" "${DMG}" >/dev/null
apps=("${MOUNT}"/*.app)
[ ${#apps[@]} -eq 1 ] && [ -d "${apps[0]}" ] || fail "Expected exactly one .app in ${DMG}."
cp "${apps[0]}/Contents/Info.plist" "${WORK}/Info.plist"
hdiutil detach -quiet "${MOUNT}"
MOUNT=""

mkdir -p "$(dirname "${OUT}")"
"${APPCAST[@]}" item --tag "${TAG}" --repo "${REPO}" --asset "$(basename "${DMG}")" \
    --dmg "${DMG}" --info-plist "${WORK}/Info.plist" --signature "${SIGNATURE}" \
    --length "${LENGTH}" --public-key "${PUBLIC_KEY}" --out "${OUT}"
