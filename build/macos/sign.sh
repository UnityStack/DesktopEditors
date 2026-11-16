#!/usr/bin/env bash
# Signs a built Euro-Office DMG for distribution outside the App Store:
# every Mach-O in the app gets a Developer ID signature with the hardened
# runtime and a secure timestamp (inside-out, entitlements from
# build/macos/entitlements/), the app is notarized and stapled, and the DMG
# is rebuilt from the signed app with the original layout, signed,
# notarized and stapled. The result is checked the way Gatekeeper checks
# it. Used by the sign-macos job in .github/workflows/build.yml; see
# "Signing and notarization" in build/macos/README.md for the setup and for
# running it locally.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS_DIR="${SCRIPT_DIR}/entitlements"
# Developer ID Certification Authority (G2), the intermediate that issues
# Developer ID certificates. A .p12 exported from Keychain Access holds only
# the leaf certificate, and codesign needs the chain to Apple's root.
INTERMEDIATE_CA="${SCRIPT_DIR}/DeveloperIDG2CA.pem"
INTERMEDIATE_CA_SHA256="F1:6C:D3:C5:4C:7F:83:CE:A4:BF:1A:3E:6A:08:19:C8:AA:A8:E4:A1:52:8F:D1:44:71:5F:35:06:43:D2:DF:3A"

usage() {
    cat <<EOF
Usage: $(basename "$0") --input <dmg-or-app> --output <path-to-.dmg> [options]

Required:
  --input <path>         The unsigned DMG from build-macos (or a built .app).
  --output <path>        Where to write the signed DMG.

Optional:
  --identity <id>        Sign with this identity (SHA-1 hash or name) from the
                         keychain search list instead of importing
                         APPLE_DEVELOPER_ID_P12. "-" signs ad hoc: local tests
                         only, needs --no-notarize. Required outside GitHub
                         Actions.
  --work-dir <path>      Working directory (must not exist; removed at the end).
                         Holds the unpacked app and the decoded API key.
                         Default: a new directory under \${TMPDIR}.
  --entitlements-dir <path>
                         Default: ${ENTITLEMENTS_DIR}
  --no-notarize          Skip notarization and stapling (local tests).
  --smoke-test           After signing, convert a document with the signed x2t,
                         start the app with a document for --smoke-seconds and
                         fail if it exits, if a process crashes, or if any file
                         in the bundle changes.
  --smoke-seconds <n>    Default: 20.

Automatic updates (all three or none; required when APPLE_DEVELOPER_ID_P12 is
imported, i.e. in CI), written into the app's Info.plist before signing by
sparkle-configure.sh:
  --update-feed <url>    SUFeedURL, the appcast the app reads.
  --update-key <file>    SUPublicEDKey, Sparkle's public EdDSA key
                         (build/macos/sparkle-ed25519.pub).
  --bundle-version <n>   CFBundleVersion the appcast compares
                         (appcast.py bundle-version <tag>).

Environment (CI, from the GitHub environment "signing"):
  APPLE_DEVELOPER_ID_P12           base64 of the .p12 with the Developer ID
                                   Application certificate and its private key
                                   (not needed with --identity). Imported into
                                   a temporary keychain under \${RUNNER_TEMP},
                                   only when GITHUB_ACTIONS=true.
  APPLE_DEVELOPER_ID_P12_PASSWORD  its export password
  APPLE_TEAM_ID                    the team the certificate must belong to
  APPLE_API_KEY_ID                 App Store Connect API key for notarytool
  APPLE_API_ISSUER_ID              its issuer ID
  APPLE_API_KEY_P8                 contents of its AuthKey_<id>.p8
EOF
}

INPUT=""
OUTPUT=""
IDENTITY=""
WORK_DIR=""
NOTARIZE=true
SMOKE_TEST=false
SMOKE_SECONDS=20
UPDATE_FEED=""
UPDATE_KEY=""
BUNDLE_VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --input) INPUT="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --identity) IDENTITY="$2"; shift 2 ;;
        --work-dir) WORK_DIR="$2"; shift 2 ;;
        --entitlements-dir) ENTITLEMENTS_DIR="$2"; shift 2 ;;
        --no-notarize) NOTARIZE=false; shift ;;
        --smoke-test) SMOKE_TEST=true; shift ;;
        --smoke-seconds) SMOKE_SECONDS="$2"; shift 2 ;;
        --update-feed) UPDATE_FEED="$2"; shift 2 ;;
        --update-key) UPDATE_KEY="$2"; shift 2 ;;
        --bundle-version) BUNDLE_VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" 1>&2; usage 1>&2; exit 1 ;;
    esac
done

log() { echo "==> $*"; }

fail() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::error::$*"
    else
        echo "error: $*" 1>&2
    fi
    exit 1
}

if [ -z "${INPUT}" ] || [ -z "${OUTPUT}" ]; then
    echo "error: --input and --output are required." 1>&2
    usage 1>&2
    exit 1
fi
case "${OUTPUT}" in
    *.dmg) ;;
    *) fail "--output must end in .dmg: ${OUTPUT}" ;;
esac
if [ ! -e "${INPUT}" ]; then
    fail "${INPUT} not found."
fi
if ! [[ "${SMOKE_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    fail "--smoke-seconds must be a positive number of seconds."
fi
for tool in codesign security hdiutil ditto plutil file xcrun shasum; do
    command -v "${tool}" >/dev/null 2>&1 || fail "${tool} not found on PATH."
done

# Automatic updates: all three settings or none. A release (the CI path,
# which imports APPLE_DEVELOPER_ID_P12) must not ship without them, nor
# with only some of them.
UPDATES=false
if [ -n "${UPDATE_FEED}${UPDATE_KEY}${BUNDLE_VERSION}" ]; then
    if [ -z "${UPDATE_FEED}" ] || [ -z "${UPDATE_KEY}" ] || [ -z "${BUNDLE_VERSION}" ]; then
        fail "--update-feed, --update-key and --bundle-version go together."
    fi
    [ -f "${UPDATE_KEY}" ] ||
        fail "${UPDATE_KEY} not found: the Sparkle public key is created once by the owner (\"Automatic updates (Sparkle)\" in build/macos/README.md)."
    UPDATES=true
elif [ -z "${IDENTITY}" ]; then
    fail "A release needs --update-feed, --update-key and --bundle-version (automatic updates, see \"Automatic updates (Sparkle)\" in build/macos/README.md)."
fi

AD_HOC=false
if [ "${IDENTITY}" = "-" ]; then
    AD_HOC=true
    if [ "${NOTARIZE}" = true ]; then
        fail "An ad hoc signature cannot be notarized; pass --no-notarize."
    fi
fi

# Importing APPLE_DEVELOPER_ID_P12 means creating a keychain and putting it
# on the user's keychain search list for the run. That is fine on an
# ephemeral GitHub runner and wrong on a developer's Mac, so it only happens
# on GitHub Actions; locally the identity must already be in a keychain.
# Checked before anything is created or read.
if [ -z "${IDENTITY}" ]; then
    if [ "${GITHUB_ACTIONS:-}" != true ]; then
        fail "Outside GitHub Actions sign.sh does not import APPLE_DEVELOPER_ID_P12: that needs a temporary keychain on the keychain search list. Pass --identity with a Developer ID Application identity from your keychain (security find-identity -v -p codesigning), or --identity - --no-notarize for an ad hoc test."
    fi
    if [ -z "${RUNNER_TEMP:-}" ] || [ ! -d "${RUNNER_TEMP}" ]; then
        fail "RUNNER_TEMP is not a directory; the temporary keychain goes there."
    fi
fi

# All missing secrets in one message, not one per run.
missing=()
if [ -z "${IDENTITY}" ]; then
    for v in APPLE_DEVELOPER_ID_P12 APPLE_DEVELOPER_ID_P12_PASSWORD APPLE_TEAM_ID; do
        [ -n "${!v:-}" ] || missing+=("$v")
    done
fi
if [ "${NOTARIZE}" = true ]; then
    for v in APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_P8; do
        [ -n "${!v:-}" ] || missing+=("$v")
    done
fi
if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing secrets: ${missing[*]}. Set them in the GitHub environment 'signing' (see \"Signing and notarization\" in build/macos/README.md)."
fi
if [ -n "${APPLE_TEAM_ID:-}" ] && ! [[ "${APPLE_TEAM_ID}" =~ ^[A-Z0-9]{10}$ ]]; then
    fail "APPLE_TEAM_ID must be the 10-character team ID (Membership details in the Apple Developer account)."
fi

if [ -n "${WORK_DIR}" ]; then
    if [ -e "${WORK_DIR}" ]; then
        fail "--work-dir ${WORK_DIR} already exists."
    fi
    mkdir -p "$(dirname "${WORK_DIR}")"
    mkdir -m 700 "${WORK_DIR}"
else
    WORK_DIR="$(mktemp -d -t eo-sign)"
fi
WORK_DIR="$(cd "${WORK_DIR}" && pwd -P)"

KEYCHAIN=""
KEYCHAIN_DIR=""
OLD_SEARCH_LIST=()
SEARCH_LIST_CHANGED=false
MOUNTS=()
APP=""
EXECUTABLE=""
SMOKE_LAUNCHED=false
PREFS_DOMAIN=""
PREFS_BACKUP=""

# ---- processes of the bundle under test ---------------------------------- #

# Every process whose executable or command line is in the app under test
# (the app, its helpers, x2t). The path goes to awk through the environment:
# in awk's arguments it would match awk itself.
bundle_pids() {
    [ -n "${APP}" ] || return 0
    { ps -axo pid=,comm=; ps -axww -o pid=,command=; } |
        BUNDLE_PREFIX="${APP}/" awk 'index($0, ENVIRON["BUNDLE_PREFIX"]) { print $1 }' | sort -un
}

main_pid() {
    ps -axo pid=,comm= |
        MAIN_EXE="${APP}/Contents/MacOS/${EXECUTABLE}" awk 'substr($0, index($0, "/")) == ENVIRON["MAIN_EXE"] { print $1 }'
}

# Quits the app the way a TERM from the session would, then TERMs and
# finally KILLs whatever of the bundle is left. Helpers that lose the main
# process crash on purpose (SIGTRAP), so crash reports are checked before
# this. Fails if anything survives.
kill_bundle_processes() {
    local main pids i sig
    [ -n "${APP}" ] || return 0
    main="$(main_pid)"
    # shellcheck disable=SC2086 # one PID per word
    [ -z "${main}" ] || kill -TERM ${main} 2>/dev/null || true
    for i in $(seq 10); do
        [ -n "$(bundle_pids)" ] || return 0
        sleep 1
    done
    for sig in TERM KILL; do
        pids="$(bundle_pids)"
        [ -n "${pids}" ] || return 0
        # shellcheck disable=SC2086
        kill -"${sig}" ${pids} 2>/dev/null || true
        for i in $(seq 5); do
            [ -n "$(bundle_pids)" ] || return 0
            sleep 1
        done
    done
    echo "Still running from ${APP}: $(bundle_pids | tr '\n' ' ')" 1>&2
    return 1
}

# The smoke test saves the preferences of the app's bundle ID first; this
# puts them back exactly (delete, then import what was there, if anything).
restore_prefs() {
    [ -n "${PREFS_DOMAIN}" ] || return 0
    defaults delete "${PREFS_DOMAIN}" >/dev/null 2>&1 || true
    if [ -n "${PREFS_BACKUP}" ]; then
        defaults import "${PREFS_DOMAIN}" "${PREFS_BACKUP}" || return 1
    fi
    PREFS_DOMAIN=""
}

cleanup() {
    local rc=$? m
    trap '' HUP INT TERM
    kill_bundle_processes || rc=1
    restore_prefs || rc=1
    if [ "${SMOKE_LAUNCHED}" = true ]; then
        # open registered the copy with Launch Services; forget it again.
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -u "${APP}" >/dev/null 2>&1 || true
    fi
    for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do
        hdiutil detach -quiet -force "$m" 2>/dev/null || true
    done
    if [ "${SEARCH_LIST_CHANGED}" = true ]; then
        security list-keychains -d user -s ${OLD_SEARCH_LIST[@]+"${OLD_SEARCH_LIST[@]}"} || rc=1
    fi
    if [ -n "${KEYCHAIN}" ]; then
        security delete-keychain "${KEYCHAIN}" 2>/dev/null || true
    fi
    [ -z "${KEYCHAIN_DIR}" ] || rm -rf "${KEYCHAIN_DIR}"
    rm -rf "${WORK_DIR}"
    exit "$rc"
}
trap cleanup EXIT
# A cancelled run (runner, Ctrl-C) leaves through cleanup with the usual
# status.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- identity ----------------------------------------------------------- #

KEYCHAIN_ARGS=()
SIGN_ID="${IDENTITY}"
SIGNER_NAME=""

# GitHub Actions only (checked at the top): a new keychain under
# RUNNER_TEMP, on the user search list for this run. cleanup restores the
# previous search list and deletes the keychain on every exit; the
# sign-macos job deletes it again in an always() step after a cancel.
import_identity() {
    log "Importing the Developer ID certificate into a temporary keychain"
    local actual
    actual="$(openssl x509 -in "${INTERMEDIATE_CA}" -noout -fingerprint -sha256 | sed 's/^.*=//')"
    if [ "${actual}" != "${INTERMEDIATE_CA_SHA256}" ]; then
        fail "${INTERMEDIATE_CA} is not the Developer ID G2 intermediate (SHA-256 ${actual})."
    fi

    KEYCHAIN_DIR="$(mktemp -d "${RUNNER_TEMP}/eo-signing-keychain.XXXXXX")"
    chmod 700 "${KEYCHAIN_DIR}"
    local p12="${KEYCHAIN_DIR}/identity.p12" kc_pass
    (umask 077 && printf '%s' "${APPLE_DEVELOPER_ID_P12}" | base64 -D > "${p12}") ||
        fail "APPLE_DEVELOPER_ID_P12 is not base64 (base64 -i DeveloperID.p12 | pbcopy)."
    kc_pass="$(openssl rand -base64 24)"

    # The search list as it was, before create-keychain (which may add the
    # new keychain to it); cleanup puts exactly this back.
    local line
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#\"}"
        line="${line%\"}"
        [ -z "${line}" ] || OLD_SEARCH_LIST+=("${line}")
    done < <(security list-keychains -d user)
    KEYCHAIN="${KEYCHAIN_DIR}/signing.keychain-db"
    SEARCH_LIST_CHANGED=true
    security create-keychain -p "${kc_pass}" "${KEYCHAIN}"
    security set-keychain-settings -lut 21600 "${KEYCHAIN}"
    security unlock-keychain -p "${kc_pass}" "${KEYCHAIN}"
    if ! security import "${p12}" -k "${KEYCHAIN}" -f pkcs12 \
            -P "${APPLE_DEVELOPER_ID_P12_PASSWORD}" -T /usr/bin/codesign >/dev/null; then
        fail "Cannot import APPLE_DEVELOPER_ID_P12: wrong APPLE_DEVELOPER_ID_P12_PASSWORD, or not a .p12."
    fi
    rm -f "${p12}"
    # The trust evaluation needs Apple's intermediate. A .p12 exported with
    # its chain already holds it, and then importing it again fails with
    # errSecDuplicateItem, which only means it is there; any other error stops.
    local out
    if ! out="$(security import "${INTERMEDIATE_CA}" -k "${KEYCHAIN}" 2>&1)"; then
        if ! grep -q 'already exists' <<<"${out}"; then
            fail "Cannot import ${INTERMEDIATE_CA}: ${out}"
        fi
        echo "Apple's Developer ID G2 intermediate is already in the signing keychain."
    fi
    echo "Certificates in the signing keychain:"
    security find-certificate -a "${KEYCHAIN}" | sed -n 's/^ *"labl"<blob>="\(.*\)"$/  \1/p'
    # Lets codesign use the key without a dialog.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${kc_pass}" "${KEYCHAIN}" >/dev/null

    local ids count
    ids="$(security find-identity -p codesigning "${KEYCHAIN}" | grep -Eo '[0-9A-F]{40} "[^"]*"' | sort -u || true)"
    count="$(grep -c . <<<"${ids}" || true)"
    if [ "${count}" != 1 ]; then
        fail "APPLE_DEVELOPER_ID_P12 holds ${count} code signing identities; export only the Developer ID Application certificate with its private key."
    fi
    SIGN_ID="${ids%% *}"
    SIGNER_NAME="$(sed -E 's/^[0-9A-F]{40} "(.*)"$/\1/' <<<"${ids}")"
    if ! [[ "${SIGNER_NAME}" =~ ^Developer\ ID\ Application:\ .*\ \(([A-Z0-9]{10})\)$ ]]; then
        fail "APPLE_DEVELOPER_ID_P12 holds \"${SIGNER_NAME}\", not a Developer ID Application certificate."
    fi
    if [ "${BASH_REMATCH[1]}" != "${APPLE_TEAM_ID}" ]; then
        fail "The certificate \"${SIGNER_NAME}\" belongs to team ${BASH_REMATCH[1]}, APPLE_TEAM_ID is ${APPLE_TEAM_ID}."
    fi

    # codesign (--keychain finds the key) and the trust evaluation (which
    # needs the intermediate) search the keychain search list.
    security list-keychains -d user -s "${KEYCHAIN}" ${OLD_SEARCH_LIST[@]+"${OLD_SEARCH_LIST[@]}"}

    if ! grep -q "${SIGN_ID}" <<<"$(security find-identity -v -p codesigning)"; then
        fail "\"${SIGNER_NAME}\" is not valid for code signing: $(security find-identity -p codesigning "${KEYCHAIN}" | grep -Eo '\(CSSM[^)]*\)' | head -n 1) (expired, revoked, or not issued by Apple)."
    fi
    KEYCHAIN_ARGS=(--keychain "${KEYCHAIN}")
    echo "Signing as \"${SIGNER_NAME}\" (${SIGN_ID})."
}

if [ "${AD_HOC}" = true ]; then
    log "Signing ad hoc (local test; Gatekeeper rejects this)"
elif [ -z "${IDENTITY}" ]; then
    import_identity
else
    # An identity already on the keychain search list (a local run).
    match="$(security find-identity -v -p codesigning | grep -Eo '[0-9A-F]{40} "[^"]*"' | sort -u |
        awk -v id="${IDENTITY}" '$1 == id || substr($0, 42) == "\"" id "\""' || true)"
    if [ "$(grep -c . <<<"${match}" || true)" != 1 ]; then
        fail "--identity ${IDENTITY} matches $(grep -c . <<<"${match}" || true) valid code signing identities (security find-identity -v -p codesigning)."
    fi
    SIGN_ID="${match%% *}"
    SIGNER_NAME="$(sed -E 's/^[0-9A-F]{40} "(.*)"$/\1/' <<<"${match}")"
    echo "Signing as \"${SIGNER_NAME}\" (${SIGN_ID})."
fi

CODESIGN=(codesign --force --sign "${SIGN_ID}" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"})
if [ "${AD_HOC}" = true ]; then
    CODESIGN+=(--timestamp=none)
else
    CODESIGN+=(--timestamp)
fi

# ---- unpack ------------------------------------------------------------- #

# The DMG is rebuilt from this folder: the app plus whatever else the input
# DMG holds (the /Applications link, .background/, the .DS_Store with the
# window layout), so the signed DMG looks like the one make-dmg.sh made.
DMG_ROOT="${WORK_DIR}/dmg-root"
mkdir "${DMG_ROOT}"

attach() {   # attach <image> <mount point>
    mkdir -p "$2"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$2" "$1" >/dev/null
    MOUNTS+=("$2")
}

detach() {   # detach <mount point>
    hdiutil detach -quiet "$1"
    local kept=() m
    for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do
        [ "$m" = "$1" ] || kept+=("$m")
    done
    MOUNTS=(${kept[@]+"${kept[@]}"})
}

case "${INPUT}" in
    *.dmg)
        log "Unpacking ${INPUT}"
        attach "${INPUT}" "${WORK_DIR}/in"
        VOLUME_NAME="$(diskutil info "${WORK_DIR}/in" | sed -n 's/^ *Volume Name: *//p')"
        ditto "${WORK_DIR}/in" "${DMG_ROOT}"
        detach "${WORK_DIR}/in"
        rm -rf "${DMG_ROOT}/.fseventsd" "${DMG_ROOT}/.Trashes" "${DMG_ROOT}/.Spotlight-V100"
        ;;
    *.app|*.app/)
        log "Copying ${INPUT}"
        ditto "${INPUT}" "${DMG_ROOT}/$(basename "${INPUT}")"
        ln -s /Applications "${DMG_ROOT}/Applications"
        VOLUME_NAME="$(basename "${INPUT%/}" .app)"
        ;;
    *) fail "--input must be a .dmg or an .app: ${INPUT}" ;;
esac

apps=()
for a in "${DMG_ROOT}"/*.app; do
    [ -d "$a" ] && apps+=("$a")
done
if [ ${#apps[@]} -ne 1 ]; then
    fail "Expected exactly one .app in ${INPUT}, found ${#apps[@]}."
fi
APP="${apps[0]}"
APP_NAME="$(basename "${APP}")"
EXECUTABLE="$(plutil -extract CFBundleExecutable raw -o - "${APP}/Contents/Info.plist")"
X2T="${APP}/Contents/Resources/converter/x2t"
echo "App: ${APP_NAME} ($(plutil -extract CFBundleIdentifier raw -o - "${APP}/Contents/Info.plist") $(plutil -extract CFBundleShortVersionString raw -o - "${APP}/Contents/Info.plist")), volume \"${VOLUME_NAME}\""

# Quarantine and Finder info attributes make codesign fail ("resource fork,
# Finder information, or similar detritus not allowed").
xattr -cr "${APP}" 2>/dev/null || true

# ---- automatic updates -------------------------------------------------- #

# Before signing, so the signature covers the Info.plist Sparkle reads.
if [ "${UPDATES}" = true ]; then
    log "Setting up automatic updates (sparkle-configure.sh)"
    bash "${SCRIPT_DIR}/sparkle-configure.sh" --app "${APP}" --feed-url "${UPDATE_FEED}" \
        --public-key "${UPDATE_KEY}" --bundle-version "${BUNDLE_VERSION}"
else
    echo "No --update-feed: the app keeps upstream's update settings (no feed, automatic checks off)."
fi

# ---- script caches ------------------------------------------------------ #

# x2t (doctrenderer) compiles editors/sdkjs/<editor>/sdk-all.js on first use
# and writes the V8 code cache next to it as sdk-all.cache, inside the
# bundle. A file written into a signed bundle breaks its seal ("a sealed
# resource is missing or invalid"), so the caches are created here, before
# signing: doctrenderer only reads a cache that exists and never rewrites
# it. x2t -create-js-cache is upstream's own command for this.
# The caches are those CDoctrenderer::CreateCache writes (core
# DesktopEditor/doctrenderer/editors.cpp): word, slide, cell, pdf (built
# from word's sdk-all.js and pdf/src, so pdf/ has no sdk-all.js of its
# own), and visio when visio/sdk-all-min.js exists.
missing_caches() {
    local sdk="${APP}/Contents/Resources/editors/sdkjs" e editors=(word slide cell pdf)
    [ ! -e "${sdk}/visio/sdk-all-min.js" ] || editors+=(visio)
    for e in "${editors[@]}"; do
        [ -s "${sdk}/${e}/sdk-all.cache" ] || echo "${sdk}/${e}/sdk-all.cache"
    done
}
if [ -n "$(missing_caches)" ]; then
    log "Creating the script caches (x2t -create-js-cache)"
    (cd "${WORK_DIR}" && "${X2T}" -create-js-cache)
    if [ -n "$(missing_caches)" ]; then
        fail "x2t -create-js-cache did not create: $(missing_caches | tr '\n' ' ')"
    fi
fi

# ---- sign --------------------------------------------------------------- #

# Every Mach-O file in the bundle (not symlinks), one path per line.
list_macho() {
    find "$1" -type f -print0 |
        xargs -0 file --no-dereference --mime-type -F $'\x1f' |
        awk -F $'\x1f' '$2 ~ /application\/x-mach-binary/ && $1 !~ / \(for architecture [^)]*\)$/ { print $1 }'
}

# Entitlements per executable, by path in the bundle. "-" means none.
# An executable that is not listed fails the run: decide what it needs
# (see "Entitlements" in build/macos/README.md) before it ships.
entitlements_for() {
    case "$1" in
        "Contents/MacOS/${EXECUTABLE}") echo app.entitlements ;;
        "Contents/Frameworks/editors_helper.app/Contents/MacOS/editors_helper") echo helper.entitlements ;;
        "Contents/Frameworks/editors_helper (GPU).app/Contents/MacOS/editors_helper (GPU)") echo helper-gpu.entitlements ;;
        "Contents/Frameworks/editors_helper (Renderer).app/Contents/MacOS/editors_helper (Renderer)") echo helper-renderer.entitlements ;;
        "Contents/Resources/converter/x2t") echo x2t.entitlements ;;
        # Sparkle, signed as its documentation describes (hardened runtime,
        # no entitlements). It installs the updates (--update-feed).
        Contents/Frameworks/Sparkle.framework/Versions/*/Autoupdate|\
        Contents/Frameworks/Sparkle.framework/Versions/*/Updater.app/Contents/MacOS/*|\
        Contents/Frameworks/Sparkle.framework/Versions/*/XPCServices/*.xpc/Contents/MacOS/*) echo - ;;
        *) return 1 ;;
    esac
}

# The main executable of a bundle, which codesign signs with the bundle.
main_executable() {   # main_executable <bundle>
    local plist exe
    case "$1" in
        *.framework)
            plist="$1/Resources/Info.plist"
            exe="$(plutil -extract CFBundleExecutable raw -o - "${plist}" 2>/dev/null)" || return 0
            echo "$1/Versions/$(readlink "$1/Versions/Current")/${exe}"
            ;;
        *)
            plist="$1/Contents/Info.plist"
            exe="$(plutil -extract CFBundleExecutable raw -o - "${plist}" 2>/dev/null)" || return 0
            echo "$1/Contents/MacOS/${exe}"
            ;;
    esac
}

sign() {   # sign <path> <bundle-relative path of its executable>
    local ent args=()
    if ent="$(entitlements_for "$2")"; then
        if [ "${ent}" != - ]; then
            args=(--entitlements "${ENTITLEMENTS_DIR}/${ent}")
        fi
    elif file -b "${APP}/$2" | grep -q executable; then
        fail "No entitlements decided for the executable $2 (see entitlements_for in $(basename "$0"))."
    fi
    "${CODESIGN[@]}" --options runtime ${args[@]+"${args[@]}"} "$1" 2>&1 | grep -v ': replacing existing signature$' || true
    # Not --strict here: the GPU and Renderer helpers link to the base
    # helper's MacOS/system, outside their own bundle, which only the
    # strict check of the whole app below accepts.
    codesign --verify "$1" || fail "Signing $1 failed."
}

by_depth() {   # deepest paths first
    awk '{ print gsub("/", "/"), $0 }' | sort -rn -k1,1 -s | cut -d' ' -f2-
}

log "Listing the code in ${APP_NAME}"
list_macho "${APP}" > "${WORK_DIR}/macho.txt"
find "${APP}/Contents" -type d \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.bundle' \) \
    -print | by_depth > "${WORK_DIR}/bundles.txt"
: > "${WORK_DIR}/main-executables.txt"
while IFS= read -r b; do
    main_executable "$b" >> "${WORK_DIR}/main-executables.txt"
done < "${WORK_DIR}/bundles.txt"
main_executable "${APP}" >> "${WORK_DIR}/main-executables.txt"
grep -vxF -f "${WORK_DIR}/main-executables.txt" "${WORK_DIR}/macho.txt" | by_depth > "${WORK_DIR}/loose.txt" || true
echo "$(wc -l < "${WORK_DIR}/macho.txt" | tr -d ' ') Mach-O files: $(wc -l < "${WORK_DIR}/loose.txt" | tr -d ' ') loose, $(wc -l < "${WORK_DIR}/bundles.txt" | tr -d ' ') nested bundles, the app."

# Inside-out: loose code first (libraries, x2t, Sparkle's Autoupdate), then
# the nested bundles deepest first, then the app, which seals all of it.
log "Signing the loose code"
while IFS= read -r f; do
    rel="${f#"${APP}/"}"
    echo "  ${rel}"
    sign "$f" "${rel}"
done < "${WORK_DIR}/loose.txt"

log "Signing the nested bundles"
while IFS= read -r b; do
    exe="$(main_executable "$b")"
    echo "  ${b#"${APP}/"}"
    sign "$b" "${exe#"${APP}/"}"
done < "${WORK_DIR}/bundles.txt"

log "Signing ${APP_NAME}"
sign "${APP}" "Contents/MacOS/${EXECUTABLE}"

# ---- verify the signatures ---------------------------------------------- #

verify_app() {   # verify_app <app>
    log "Verifying the signatures of $1"
    local out
    if ! out="$(codesign --verify --deep --strict --verbose=2 "$1" 2>&1)"; then
        echo "${out}" 1>&2
        fail "codesign --verify --deep --strict rejects $(basename "$1")."
    fi
    tail -n 2 <<<"${out}"
    local f details ents n=0 bad=()
    while IFS= read -r f; do
        n=$((n + 1))
        details="$(codesign -dvv "$f" 2>&1)" || { bad+=("$f: not signed"); continue; }
        ents="$(codesign -d --entitlements - --xml "$f" 2>/dev/null || true)"
        grep -q '^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime' <<<"${details}" ||
            bad+=("$f: no hardened runtime")
        if [ "${AD_HOC}" = true ]; then
            grep -q '^Signature=adhoc' <<<"${details}" || bad+=("$f: not signed ad hoc")
        else
            grep -qxF "Authority=${SIGNER_NAME}" <<<"${details}" || bad+=("$f: not signed by ${SIGNER_NAME}")
            grep -q '^Timestamp=' <<<"${details}" || bad+=("$f: no secure timestamp")
            if [ -n "${APPLE_TEAM_ID:-}" ]; then
                grep -qxF "TeamIdentifier=${APPLE_TEAM_ID}" <<<"${details}" || bad+=("$f: not team ${APPLE_TEAM_ID}")
            fi
        fi
        if grep -q 'com.apple.security.get-task-allow' <<<"${ents}"; then
            bad+=("$f: has get-task-allow (notarization refuses it)")
        fi
    done < <(list_macho "$1")
    if [ ${#bad[@]} -gt 0 ]; then
        printf '  %s\n' "${bad[@]}" 1>&2
        fail "${#bad[@]} of ${n} Mach-O files in $(basename "$1") are not signed as required."
    fi
    echo "All ${n} Mach-O files are signed with the hardened runtime$([ "${AD_HOC}" = true ] || echo ", a secure timestamp and ${SIGNER_NAME}")."
}

verify_app "${APP}"

# ---- smoke test --------------------------------------------------------- #

SMOKE_DIR="${WORK_DIR}/smoke"
SMOKE_SINCE=""

renderer_running() {   # its path is .../Contents/MacOS/../Frameworks/editors_helper (Renderer).app/...
    ps -axo comm= |
        BUNDLE_PREFIX="${APP}/" awk 'index($0, ENVIRON["BUNDLE_PREFIX"]) == 1 && index($0, "/editors_helper (Renderer).app/") { n++ } END { exit !n }'
}

manifest() {   # every directory, symlink target and file checksum in the bundle
    (
        cd "${APP}"
        find . -type d | sed 's/^/D /'
        find . -type l -exec stat -f 'L %N -> %Y' {} +
        find . -type f -print0 | xargs -0 shasum -a 256 | sed 's/^/F /'
    ) | LC_ALL=C sort
}

# What the unified log knows about a process that ended early: launchd's
# termination record (signal or exit status) as runningboardd logs it.
exit_record() {   # exit_record <pid>
    /usr/bin/log show --start "${SMOKE_SINCE}" --style compact \
        --predicate "process == \"runningboardd\" AND eventMessage CONTAINS \">:$1] termination reported\"" 2>/dev/null |
        grep -F 'termination reported' | tail -n 1 || true
}

# Keychain calls of the test's processes (the SecKeychain* API and the
# SecItem* API, which the Security framework logs as SecItemAdd,
# SecItemUpdate_ios and so on), and requests to create a login keychain on
# their behalf (the "Keychain Not Found" dialog), from the unified log.
# authd names its client by path, quoted: '<app>' for the main app,
# '<app>/Contents/...' for a helper.
keychain_calls() {
    local pids
    pids="$(sort -un "${SMOKE_DIR}/pids.txt" | paste -sd, -)"
    /usr/bin/log show --start "${SMOKE_SINCE}" --style compact --predicate \
        "(processID IN {${pids}} AND (eventMessage BEGINSWITH \"SecKeychain\" OR eventMessage BEGINSWITH \"SecItem\")) OR (process == \"authd\" AND eventMessage CONTAINS \"system.keychain.create.loginkc\" AND (eventMessage CONTAINS \"'${APP}'\" OR eventMessage CONTAINS \"'${APP}/\"))"
}

# The keychain writes among keychain_calls' lines.
KEYCHAIN_WRITES='SecKeychain(Add(Generic|Internet)Password|ItemCreate|ItemModify|ItemDelete|Create|Delete|SetDefault|SetSearchList)|SecItem(Add|Update|Delete)|loginkc'

smoke_test() {
    local dir="${SMOKE_DIR}" home="${SMOKE_DIR}/home" reports marker i n pid="" crashes bundle_id calls writes
    mkdir -p "${home}"
    reports="${HOME}/Library/Logs/DiagnosticReports"
    marker="${dir}/start"
    touch "${marker}"
    : > "${dir}/pids.txt"

    log "Smoke test: manifest of the bundle"
    manifest > "${dir}/before.txt"
    echo "$(wc -l < "${dir}/before.txt" | tr -d ' ') entries."

    # A short document. x2t renders it to PDF through doctrenderer, whose V8
    # needs allow-unsigned-executable-memory under the hardened runtime.
    printf '<html><body><h1>Euro-Office</h1><p>Signing smoke test.</p></body></html>' > "${dir}/smoke.html"
    textutil -convert docx -output "${dir}/smoke.docx" "${dir}/smoke.html"
    log "Smoke test: x2t smoke.docx -> smoke.pdf"
    "${X2T}" "${dir}/smoke.docx" "${dir}/smoke.pdf" || fail "The signed x2t failed to convert a document."
    [ "$(head -c 5 "${dir}/smoke.pdf")" = "%PDF-" ] || fail "The signed x2t wrote no PDF."
    echo "smoke.pdf: $(wc -c < "${dir}/smoke.pdf" | tr -d ' ') bytes."

    # The app runs with its own home: HOME and CFFIXED_USER_HOME point into
    # the work directory, so its data (Application Support/<bundle id>)
    # stays out of the real home (its preferences do not, see below), and
    # the Security framework looks for keychains there, where there are
    # none. That only matters if
    # something writes to a keychain:
    # - Chromium keeps its "Safe Storage" key in the keychain; the app
    #   already passes --use-mock-keychain to CEF (desktop-sdk
    #   cefwrapper/client_app.h), and so does this launch.
    # - desktop-sdk's crypto key (NSAscCrypto::CAscKeychain::Check) is added
    #   to the default keychain whenever <data>/user.data is missing, which
    #   with no keychain asks to create a login keychain ("Keychain Not
    #   Found"). An empty user.data (magic "ENCT", version 1, no key, no
    #   modes) makes the app only look the key up, which writes nothing.
    # keychain_calls checks both afterwards.
    bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "${APP}/Contents/Info.plist")"
    mkdir -p "${home}/Library/Application Support/${bundle_id}/data" "${home}/Library/Caches" "${home}/Library/Preferences"
    printf '\105\116\103\124\001\000\000\000\000\000\000\000\000\000\000\000' \
        > "${home}/Library/Application Support/${bundle_id}/data/user.data"

    # NSUserDefaults do not follow CFFIXED_USER_HOME: the app writes the
    # preferences of its bundle ID (window frame, Sparkle's last check) in
    # the real home, the domain an installed Euro-Office uses too. They are
    # saved here and put back exactly after the test (restore_prefs, also on
    # failure). Sparkle's update check is off for this launch.
    if pgrep -x "${EXECUTABLE}" >/dev/null; then
        fail "Quit ${EXECUTABLE} first (pid $(pgrep -x "${EXECUTABLE}" | tr '\n' ' ')): the smoke test runs the app with the same bundle ID and puts its preferences back afterwards."
    fi
    if defaults read "${bundle_id}" >/dev/null 2>&1; then
        defaults export "${bundle_id}" "${dir}/prefs-before.plist"
        PREFS_BACKUP="${dir}/prefs-before.plist"
    fi
    PREFS_DOMAIN="${bundle_id}"

    # A new instance with the document, in the foreground: the app creates
    # its window, and with it the renderers, only once it is active.
    # Started outside /Applications, the app asks to move itself there
    # (PFMoveApplication) and waits; the argument turns that question off
    # for this launch only.
    SMOKE_SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
    SMOKE_LAUNCHED=true
    log "Smoke test: opening smoke.docx in ${APP_NAME} for ${SMOKE_SECONDS} s"
    open -n -a "${APP}" --env HOME="${home}" --env CFFIXED_USER_HOME="${home}" \
        --stdout "${dir}/app.log" --stderr "${dir}/app.log" "${dir}/smoke.docx" \
        --args -moveToApplicationsFolderAlertSuppress YES -SUEnableAutomaticChecks NO --use-mock-keychain ||
        fail "open -a ${APP_NAME} smoke.docx failed."
    for i in $(seq 10); do
        pid="$(main_pid | head -n 1)"
        [ -z "${pid}" ] || break
        sleep 1
    done
    [ -n "${pid}" ] || fail "${APP_NAME} did not start."
    echo "${pid}" >> "${dir}/pids.txt"
    # Alive for SMOKE_SECONDS, and a renderer (V8 with JIT, the editors'
    # native code) within 90 s: without allow-jit and
    # allow-unsigned-executable-memory in the app, no renderer ever starts.
    # The first start in a new home builds the font cache first (about 45 s
    # in a local test).
    for i in $(seq $((SMOKE_SECONDS + 90))); do
        bundle_pids >> "${dir}/pids.txt"
        if ! kill -0 "${pid}" 2>/dev/null; then
            tail -n 40 "${dir}/app.log" 1>&2
            sleep 2
            echo "launchd: $(exit_record "${pid}")" 1>&2
            find "${reports}" -newer "${marker}" -name "${EXECUTABLE}*" 1>&2 2>/dev/null || true
            fail "${APP_NAME} (pid ${pid}) exited after ${i} s (its last output, launchd's termination record and any crash report above)."
        fi
        if [ "${i}" -gt "${SMOKE_SECONDS}" ] && renderer_running; then
            break
        fi
        sleep 1
    done
    n="$(bundle_pids | wc -l | tr -d ' ')"
    echo "${APP_NAME} (pid ${pid}) is running after ${i} s with ${n} processes from the bundle:"
    ps -axo pid=,comm= | BUNDLE_PREFIX="${APP}/" awk '(i = index($0, ENVIRON["BUNDLE_PREFIX"])) { print "  " substr($0, 1, i - 1) substr($0, i + length(ENVIRON["BUNDLE_PREFIX"])) }'
    renderer_running || fail "No renderer process started."
    crashes="$(find "${reports}" -newer "${marker}" \( -name "${EXECUTABLE}*" -o -name 'editors_helper*' -o -name 'x2t*' \) 2>/dev/null || true)"
    kill_bundle_processes || fail "Processes of ${APP_NAME} are still running after TERM and KILL."
    echo "Stopped; no process from the bundle is left."
    restore_prefs || fail "Cannot put the preferences of ${bundle_id} back (defaults import ${dir}/prefs-before.plist)."
    echo "Preferences of ${bundle_id} put back as they were$([ -n "${PREFS_BACKUP}" ] || echo " (none)")."
    if [ -n "${crashes}" ]; then
        echo "${crashes}" 1>&2
        fail "Processes of ${APP_NAME} crashed during the smoke test (reports above)."
    fi

    log "Smoke test: keychain use (unified log)"
    sleep 2   # the log is written asynchronously
    if ! calls="$(keychain_calls 2>&1)"; then
        echo "Cannot read the unified log, keychain use not checked: $(tail -n 1 <<<"${calls}")"
    else
        calls="$(grep -E 'SecKeychain|SecItem|loginkc' <<<"${calls}" || true)"
        writes="$(grep -E "${KEYCHAIN_WRITES}" <<<"${calls}" || true)"
        if [ -n "${writes}" ]; then
            echo "${writes}" 1>&2
            fail "${APP_NAME} wrote to a keychain or asked for one during the smoke test (log above)."
        fi
        echo "No keychain item written, no keychain requested ($(grep -c . <<<"${calls}" || true) read-only keychain calls)."
    fi

    log "Smoke test: comparing the bundle with the manifest"
    manifest > "${dir}/after.txt"
    if ! diff "${dir}/before.txt" "${dir}/after.txt"; then
        fail "Running ${APP_NAME} changed its bundle (diff above), which breaks the signature."
    fi
    codesign --verify --deep --strict "${APP}" || fail "The signature of ${APP_NAME} is broken after the smoke test."
    echo "No file in the bundle changed; the signature is intact."
}

if [ "${SMOKE_TEST}" = true ]; then
    smoke_test
fi

# ---- notarize ----------------------------------------------------------- #

API_KEY="${WORK_DIR}/AuthKey.p8"
if [ "${NOTARIZE}" = true ]; then
    (umask 077 && printf '%s\n' "${APPLE_API_KEY_P8}" > "${API_KEY}")
    grep -q -- '-----BEGIN PRIVATE KEY-----' "${API_KEY}" ||
        fail "APPLE_API_KEY_P8 is not the contents of an AuthKey_<id>.p8 file."
fi
NOTARY_AUTH=(--key "${API_KEY}" --key-id "${APPLE_API_KEY_ID:-}" --issuer "${APPLE_API_ISSUER_ID:-}")

# notarytool's exit code and the submission's status are checked
# separately: an Invalid submission may come back with either exit code,
# and whenever there is a submission ID, Apple's log says why.
notarize() {   # notarize <file to submit> <what it is>
    local out="${WORK_DIR}/notary-$2.json" status id rc=0
    log "Notarizing the $2 (xcrun notarytool submit --wait)"
    xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --timeout 2h \
        --output-format json > "${out}" || rc=$?
    status="$(plutil -extract status raw -o - "${out}" 2>/dev/null || echo unknown)"
    id="$(plutil -extract id raw -o - "${out}" 2>/dev/null || echo)"
    if [ -z "${id}" ]; then
        { cat "${out}"; echo; } 1>&2 || true
        fail "notarytool submit failed for the $2 with no submission (exit ${rc}; check APPLE_API_KEY_ID, APPLE_API_ISSUER_ID and APPLE_API_KEY_P8)."
    fi
    echo "Submission ${id}: ${status} (notarytool exit ${rc})"
    if xcrun notarytool log "${id}" "${NOTARY_AUTH[@]}" "${WORK_DIR}/notary-$2-log.json" >/dev/null 2>&1; then
        cat "${WORK_DIR}/notary-$2-log.json"
        echo
    else
        echo "notarytool log ${id}: no log (yet)."
    fi
    if [ "${status}" != Accepted ] || [ "${rc}" -ne 0 ]; then
        { cat "${out}"; echo; } 1>&2 || true
        fail "Apple did not notarize the $2 (status ${status}, notarytool exit ${rc}, log above)."
    fi
}

if [ "${NOTARIZE}" = true ]; then
    ditto -c -k --sequesterRsrc --keepParent "${APP}" "${WORK_DIR}/app.zip"
    notarize "${WORK_DIR}/app.zip" app
    rm -f "${WORK_DIR}/app.zip"
    xcrun stapler staple "${APP}"
    xcrun stapler validate "${APP}"
    verify_app "${APP}"
fi

# ---- DMG ---------------------------------------------------------------- #

log "Building the DMG"
DMG="${WORK_DIR}/$(basename "${OUTPUT}")"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${DMG_ROOT}" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "${DMG}" >/dev/null
"${CODESIGN[@]}" "${DMG}"
codesign --verify --strict --verbose=2 "${DMG}"

if [ "${NOTARIZE}" = true ]; then
    notarize "${DMG}" dmg
    xcrun stapler staple "${DMG}"
fi

# ---- check the result like a user's Mac would ---------------------------- #

log "Checking the DMG"
attach "${DMG}" "${WORK_DIR}/out"
verify_app "${WORK_DIR}/out/${APP_NAME}"
if [ "${NOTARIZE}" = true ]; then
    spctl --assess --type execute --verbose=4 "${WORK_DIR}/out/${APP_NAME}"
    xcrun stapler validate "${WORK_DIR}/out/${APP_NAME}"
fi
detach "${WORK_DIR}/out"
codesign --verify --strict --verbose=2 "${DMG}"
if [ "${NOTARIZE}" = true ]; then
    spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG}"
    xcrun stapler validate "${DMG}"
else
    echo "Not notarized (--no-notarize): Gatekeeper would refuse this DMG on another Mac."
fi

mkdir -p "$(dirname "${OUTPUT}")"
mv -f "${DMG}" "${OUTPUT}"
echo ""
echo "Signed DMG: ${OUTPUT}"
shasum -a 256 "${OUTPUT}"
