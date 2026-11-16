#!/usr/bin/env bash
# Turns on Sparkle's automatic updates in a built Euro-Office.app: writes the
# feed (SUFeedURL), the public EdDSA key the updates are checked with
# (SUPublicEDKey), SUEnableAutomaticChecks=true and the CFBundleVersion the
# feed compares into its Info.plist. The committed Info.plist in
# desktop-apps (a submodule, not patched) has SUEnableAutomaticChecks=false
# and neither key. sign.sh runs this before it signs, so the signature
# covers the result. See "Automatic updates (Sparkle)" in
# build/macos/README.md.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") --app <path-to-.app> --feed-url <https URL> \\
         --public-key <file> --bundle-version <integer>

  --app <path>             The unsigned app (its Info.plist is changed in place).
  --feed-url <url>         The appcast the app reads (https).
  --public-key <file>      Sparkle's public EdDSA key, base64 of 32 bytes
                           (build/macos/sparkle-ed25519.pub).
  --bundle-version <n>     CFBundleVersion, from appcast.py bundle-version <tag>.
EOF
}

APP="" FEED_URL="" PUBLIC_KEY="" BUNDLE_VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --feed-url) FEED_URL="$2"; shift 2 ;;
        --public-key) PUBLIC_KEY="$2"; shift 2 ;;
        --bundle-version) BUNDLE_VERSION="$2"; shift 2 ;;
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

if [ -z "${APP}" ] || [ -z "${FEED_URL}" ] || [ -z "${PUBLIC_KEY}" ] || [ -z "${BUNDLE_VERSION}" ]; then
    echo "error: --app, --feed-url, --public-key and --bundle-version are required." 1>&2
    usage 1>&2
    exit 1
fi
PLIST="${APP}/Contents/Info.plist"
[ -f "${PLIST}" ] || fail "${PLIST} not found."
# No spaces or quotes, so the URL reaches Sparkle as written.
[[ "${FEED_URL}" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$ ]] ||
    fail "--feed-url must be an https URL: ${FEED_URL}"
[[ "${BUNDLE_VERSION}" =~ ^[1-9][0-9]{0,9}$ ]] ||
    fail "--bundle-version must be a positive integer: ${BUNDLE_VERSION}"
[ -f "${PUBLIC_KEY}" ] ||
    fail "${PUBLIC_KEY} not found: the Sparkle public key is created once by the owner (\"Automatic updates (Sparkle)\" in build/macos/README.md)."
KEY="$(tr -d '[:space:]' < "${PUBLIC_KEY}")"
if ! [[ "${KEY}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || [ "$(printf '%s' "${KEY}" | base64 -D | wc -c | tr -d ' ')" != 32 ]; then
    fail "${PUBLIC_KEY} is not a Sparkle public key (base64 of 32 bytes)."
fi

plutil -replace SUFeedURL -string "${FEED_URL}" "${PLIST}"
plutil -replace SUPublicEDKey -string "${KEY}" "${PLIST}"
plutil -replace SUEnableAutomaticChecks -bool YES "${PLIST}"
plutil -replace CFBundleVersion -string "${BUNDLE_VERSION}" "${PLIST}"
plutil -lint "${PLIST}" >/dev/null

# Read back what Sparkle will read.
[ "$(plutil -extract SUFeedURL raw -o - "${PLIST}")" = "${FEED_URL}" ] || fail "SUFeedURL did not stick."
[ "$(plutil -extract SUPublicEDKey raw -o - "${PLIST}")" = "${KEY}" ] || fail "SUPublicEDKey did not stick."
[ "$(plutil -extract SUEnableAutomaticChecks raw -o - "${PLIST}")" = true ] || fail "SUEnableAutomaticChecks did not stick."
[ "$(plutil -extract CFBundleVersion raw -o - "${PLIST}")" = "${BUNDLE_VERSION}" ] || fail "CFBundleVersion did not stick."
echo "Updates: SUFeedURL ${FEED_URL}, SUPublicEDKey ${KEY}, SUEnableAutomaticChecks true, CFBundleVersion ${BUNDLE_VERSION} (CFBundleShortVersionString $(plutil -extract CFBundleShortVersionString raw -o - "${PLIST}"))."
