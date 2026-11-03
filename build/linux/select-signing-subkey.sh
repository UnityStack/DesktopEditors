#!/usr/bin/env bash
# Checks the Linux package-signing key (build/linux/README.md, "Signing
# key") and, in signing mode, prints the subkey CI signs with.
#
#   select-signing-subkey.sh [--after-build] [--released DIR]       signing mode
#   select-signing-subkey.sh --public [--require-published] [--check-signatures] [--live] [--released DIR]
#
# The layout it expects: a primary key that only certifies, a signing
# subkey whose secret CI holds (LINUX_GPG_PRIVATE_KEY), and at least one
# spare signing subkey whose secret stays offline. The spare is in the key
# from the first release on, so installed systems already trust it when
# the CI subkey has to be revoked. Subkeys that never expire are the normal,
# healthy case; a subkey that has an expiry is checked against FAIL_DAYS
# and WARN_DAYS.
#
# Every mode refuses a PUBLIC_KEY_FILE that is not exactly one public key
# the way rpm reads it: secret key material (gpg would import it as if it
# were public, and the packages and the site would ship it), or more than
# one armored block (gpg merges them, rpm 4 imports only the first). The
# subkey CI holds is designated by CI_SUBKEY_FILE, committed next to the
# key, and/or LINUX_GPG_SIGN_SUBKEY.
#
# Every mode reads the key KEY_URL serves, the one installed systems got.
# Once it is served:
# - PUBLIC_KEY_FILE (the committed key) must contain every signature packet
#   of it: no binding, revocation or self-signature that clients have may go
#   missing. gpg keeps only the newest binding of a subkey on import, and
#   export-minimal or export-clean drop the others; rpm 6 (Fedora) then
#   rejects everything that subkey signed before its newest binding.
# - Where it states an earlier expiry for a subkey than PUBLIC_KEY_FILE, the
#   earlier one counts: installed systems reject that subkey's signatures
#   from then on.
# - PUBLIC_KEY_FILE should list the published key's subkeys first and in
#   the same order (a warning otherwise): dnf 4.14 (RHEL 9) shows the first
#   signing subkey's fingerprint when it imports the key.
# --released DIR checks the signatures already published: every *.asc under
# DIR (the releases' SHA256SUMS-linux-<arch>.txt.asc) must verify with
# PUBLIC_KEY_FILE, which must also hold a binding of the signing subkey and
# a self-signature of the primary key made no later than the signature
# (rpm 6 and sqv check the key as it was at signature time). A signature of
# a subkey PUBLIC_KEY_FILE revokes is only a notice. A non-empty
# DIR/.fetch-errors (build/linux/fetch-released-signatures.sh could not
# download everything) is an error in signing mode and a warning in public
# mode. PUBLIC_KEY_FILE must also list a subkey's bindings before its
# revocation: rpm 4.14 and 4.16 (openSUSE Leap 15.6, RHEL 9) refuse to
# import a key with a subkey revocation in front of the binding, which is
# the order gpg exports (build/linux/merge-public-key.py writes it right).
#
# Signing mode runs after LINUX_GPG_PRIVATE_KEY was imported into
# $GNUPGHOME (build/linux/import-signing-key.sh: the signing-preflight,
# sign-linux and publish-repo jobs of .github/workflows/build.yml). The
# secret must hold exactly one signing subkey (the spare's secret stays
# offline), and that one must be valid now (created, not expired, not
# revoked), in PUBLIC_KEY_FILE with the same binding, and in the published
# key once it is served (not revoked or expired there either). It must be
# the designated subkey (CI_SUBKEY_FILE, LINUX_GPG_SIGN_SUBKEY), if one is.
# Prints its fingerprint. If it has an expiry: fails under FAIL_DAYS (signing-preflight,
# before anything is built), with --after-build (sign-linux and publish-repo,
# which can be re-run up to RERUN_DAYS after a preflight passed) only under
# FAIL_DAYS minus RERUN_DAYS, and warns under WARN_DAYS. Warns when the key
# has no spare. While KEY_URL does not answer or answers 404, the published
# key is only a notice.
#
# Public mode needs no secret (the signing-key job of build.yml on every
# run, and signing-key-check.yml every month). It prints a Markdown report
# of every signing subkey of PUBLIC_KEY_FILE to stdout. Which one CI holds
# it cannot see; it names it from, in this order, the designation
# (CI_SUBKEY_FILE, LINUX_GPG_SIGN_SUBKEY), the newest valid signature it
# checked (the site's index files with --check-signatures, the releases
# with --released), or the only valid signing subkey; the others are
# spares. It fails when no signing subkey is valid or the designated one is
# not, and warns when the newest valid signature is by another subkey than
# the designated one, when there is no spare (fewer than two valid signing
# subkeys: CI holds exactly one, signing mode makes sure of that), when a
# valid subkey has an expiry within WARN_DAYS (fails within FAIL_DAYS for
# the one CI holds), when one is not in the published key, and when the
# primary key expires. It compares the key KEY_URL serves with
# PUBLIC_KEY_FILE, key material and signature packets both ways: a
# difference is a warning, or with --require-published an error.
# --check-signatures also verifies the InRelease and
# repomd.xml.asc files the site serves next to the key and fails when their
# subkey is revoked, expired or has fewer than FAIL_DAYS left (warns under
# WARN_DAYS): the repository is only re-signed when a tag is published.
# --live says the repository is live (signing-key-check.yml: the packages
# branch exists): a key or index files the site does not serve are then
# errors, not notices.
#
# Environment:
#   PUBLIC_KEY_FILE         the committed public key (required)
#   GNUPGHOME               signing mode: the keyring with the imported secret
#   CI_SUBKEY_FILE          the committed designation of the subkey CI holds:
#                           its 40-digit fingerprint, "#" comments allowed.
#                           Default: PUBLIC_KEY_FILE with .ci-subkey in place
#                           of .asc, if that file exists (empty: none).
#                           Signing mode fails if the secret holds another
#                           subkey; public mode names it in the report
#   LINUX_GPG_SIGN_SUBKEY   the same as a repository variable (40-digit
#                           fingerprint, optional); must agree with
#                           CI_SUBKEY_FILE where both are set
#   LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY
#                           signing mode: this subkey (40-digit fingerprint)
#                           may sign although KEY_URL serves a key without it
#                           (or with another expiry), with a warning; only
#                           when no published subkey is left (README, "If the
#                           CI secret leaks")
#   FAIL_DAYS, WARN_DAYS    for subkeys with an expiry: remaining validity
#                           under which CI fails (default 90) or warns (180)
#   RERUN_DAYS              --after-build: how much of FAIL_DAYS a re-run may
#                           use up (default 30, how long GitHub re-runs a run)
#   TEST_NOW, TEST_KEY_URL  tests only, refused under GitHub Actions: the
#                           time to check for (epoch seconds) and the URL to
#                           read the published key from (file:// works)
#
# Annotations (::error:: etc.) go to stderr; in public mode errors that stop
# the check early are also written to stdout, so the report says why.
# Exits 1 on an error, 2 on a usage error; in public mode 3 when there were
# warnings but no error. Needs bash 4, GnuPG 2.2 or newer (gpg, gpgv) and
# curl.
set -euo pipefail

KEY_URL=https://packages.euro-office.org/keys/euro-office.asc
README='build/linux/README.md, "Signing key"'
EMERGENCY='build/linux/README.md, "If the CI secret leaks"'
EXPORTDOC='build/linux/README.md, "Changing the public key"'
EXPORTCI='build/linux/README.md, "Exporting the CI subkey"'
MERGE=build/linux/merge-public-key.py

public=0
die() {
  echo "::error::$*" >&2
  [ "$public" = 0 ] || printf -- '- **Error:** %s\n' "$*"
  exit 1
}
failed=0 warned=0 findings=()
err() { echo "::error::$*" >&2; findings+=("**Error:** $*"); failed=1; }
warn() { echo "::warning::$*" >&2; findings+=("**Warning:** $*"); warned=1; }
note() { echo "::notice::$*" >&2; findings+=("$*"); }

usage="usage: $0 [--after-build] [--released DIR] | --public [--require-published] [--check-signatures] [--live] [--released DIR]"
require_published=0 check_signatures=0 live=0 after_build=0 released=
while [ $# -gt 0 ]; do
  case $1 in
    --public) public=1 ;;
    --require-published) require_published=1 ;;
    --check-signatures) check_signatures=1 ;;
    --live) live=1 ;;
    --after-build) after_build=1 ;;
    --released) [ $# -ge 2 ] || { echo "$usage" >&2; exit 2; }; released=$2; shift ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift
done
if { [ $public = 0 ] && [ $((require_published + check_signatures + live)) -gt 0 ]; } ||
   { [ $public = 1 ] && [ $after_build = 1 ]; }; then
  echo "$usage" >&2; exit 2
fi
if [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${TEST_NOW:-}${TEST_KEY_URL:-}" ]; then
  die "TEST_NOW and TEST_KEY_URL are for the tests only."
fi
FAIL_DAYS=${FAIL_DAYS:-90} WARN_DAYS=${WARN_DAYS:-180} RERUN_DAYS=${RERUN_DAYS:-30}
NOW=${TEST_NOW:-$(date +%s)}
for v in FAIL_DAYS WARN_DAYS RERUN_DAYS NOW; do
  [[ ${!v} =~ ^[0-9]+$ ]] || die "$v must be a whole number, not '${!v}'."
done
fpr_var() {   # fpr_var <name>: the variable's value in upper case, checked
  local v
  v=$(tr 'a-f' 'A-F' <<<"${!1:-}")
  if [ -n "$v" ] && [[ ! $v =~ ^[0-9A-F]{40}$ ]]; then
    die "$1 must be a 40-digit subkey fingerprint, not '${!1}'."
  fi
  echo "$v"
}
url=${TEST_KEY_URL:-$KEY_URL}
pin=$(fpr_var LINUX_GPG_SIGN_SUBKEY)
unpublished_ok=$(fpr_var LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY)
[ $public = 0 ] || unpublished_ok=      # only the jobs that sign use it
[ -f "${PUBLIC_KEY_FILE:-}" ] || die "PUBLIC_KEY_FILE '${PUBLIC_KEY_FILE:-}' not found."
[ -z "$released" ] || [ -d "$released" ] || die "--released: $released is not a directory."
# The designated subkey CI holds: CI_SUBKEY_FILE (committed next to the
# key, changed in the same commit as the key when CI moves to the spare)
# and/or LINUX_GPG_SIGN_SUBKEY. Without either, CI may hold any one.
designated='' designated_by=''
if [ -n "${CI_SUBKEY_FILE+set}" ]; then
  ci_file=$CI_SUBKEY_FILE
  [ -z "$ci_file" ] || [ -f "$ci_file" ] || die "CI_SUBKEY_FILE '$ci_file' not found."
else
  ci_file=${PUBLIC_KEY_FILE%.asc}.ci-subkey
  [ -f "$ci_file" ] || ci_file=
fi
if [ -n "$ci_file" ]; then
  designated=$({ grep -v -E '^[[:space:]]*(#|$)' "$ci_file" || true; } | tr -d ' \t\r' | tr 'a-f' 'A-F' | paste -sd ' ' -)
  [[ $designated =~ ^[0-9A-F]{40}$ ]] \
    || die "$ci_file must hold the 40-digit fingerprint of the signing subkey CI holds (and # comments), not '$designated'."
  designated_by=$ci_file
fi
if [ -n "$pin" ]; then
  [ -z "$designated" ] || [ "$pin" = "$designated" ] \
    || die "LINUX_GPG_SIGN_SUBKEY is $pin, but $ci_file designates $designated as the subkey CI holds. Change the one that is wrong (after a move to the spare, both), or delete the variable."
  designated=$pin designated_by=${designated_by:-LINUX_GPG_SIGN_SUBKEY}
fi

ymd() { date -u -d "@$1" +%F 2>/dev/null || date -u -r "$1" +%F; }
days() { echo $(( ($1 - NOW) / 86400 )); }                 # whole days from NOW
expiry() { if [ "$1" = 0 ]; then echo never; else ymd "$1"; fi; }
# later <a> <b>: true if expiry a is later than b (0 is never).
later() { [ "$2" != 0 ] && { [ "$1" = 0 ] || [ "$1" -gt "$2" ]; }; }
# within <expiry> <days>: true if it expires in fewer than that many days.
within() { [ "$1" != 0 ] && (( $1 - NOW < $2 * 86400 )); }
# cap <expiry> <primary expiry>: a subkey cannot outlive its primary key.
cap() { if later "$1" "$2"; then echo "$2"; else echo "$1"; fi; }

work=$(mktemp -d)
cleanup() {
  local h
  for h in "$work"/*/; do gpgconf --homedir "$h" --kill all 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT

# keys <gpg args>: one line per key, "<P|S> <fpr> <created> <expires>
# <validity> <capabilities> <secret>": P the primary key, S a subkey,
# expires 0 for never, validity gpg's field 2 (r = revoked), secret its
# field 15 (+ present, # stub, > on a card, "-" in a public listing).
keys() {
  gpg --batch --with-colons --with-subkey-fingerprint "$@" 2>/dev/null | awk -F: '
    $1 == "pub" || $1 == "sec" { t = "P" } $1 == "sub" || $1 == "ssb" { t = "S" }
    $1 ~ /^(pub|sec|sub|ssb)$/ { v = $2; c = $6; e = ($7 == "" ? 0 : $7); cap = $12; s = ($15 == "" ? "-" : $15); next }
    $1 == "fpr" && t != "" { print t, toupper($10), c, e, (v == "" ? "-" : v), (cap == "" ? "-" : cap), s; t = "" }'
}
# import <name> <file>: the key in a keyring of its own (a key from the
# secret export must not stand in for the public one).
import() { mkdir -m 700 "$work/$1" && gpg --homedir "$work/$1" --batch --quiet --import "$2" 2>/dev/null; }
# Key material only, for comparing two keys: fingerprints, algorithms,
# creation and expiry, capabilities, revocations and user IDs.
material() {
  gpg --homedir "$work/$1" --batch --with-colons --with-subkey-fingerprint --list-keys 2>/dev/null | awk -F: '
    $1 == "pub" || $1 == "sub" { print $1, ($2 ~ /r/ ? "revoked" : "-"), $4, $6, $7, $12 }
    $1 == "fpr" { print $1, $10 } $1 == "uid" { print $1, $10 }'
}
# sigs <key file>: every signature packet of the file, in file order, read
# from the packets (not from a keyring: gpg's import would drop older
# bindings). One line each: "<on>\t<class>\t<created>\t<issuer keyid>\t<body>"
# where <on> is "key:<keyid>" (the primary key or subkey before it) or
# "uid:<user ID>", and <body> its hashed content (version, creation, class,
# digest prefix, hashed subpackets), which identifies the packet. The
# unhashed subpackets are left out: tools may rewrite them.
sigs() {
  gpg --homedir "$work/pub" --batch --list-packets "$1" 2>/dev/null | awk '
    function flush() { if (insig) printf "%s\t%s\t%s\t%s\t%s\n", on, cls, at, by, body; insig = 0 }
    /^:/ { flush(); keyid = 0 }
    /^:public (sub )?key packet:/ { keyid = 1; next }
    /^:user ID packet: / { on = $0; sub(/^:user ID packet: /, "uid:", on); next }
    /^:user attribute packet:/ { on = "uat"; next }
    /^:signature packet:/ { insig = 1; cls = at = body = ""; by = toupper($NF); next }
    keyid && /^\tkeyid: / { on = "key:" toupper($2); next }
    insig && /^\tversion / {
      for (i = 1; i < NF; i++) { if ($i == "created") at = $(i + 1); if ($i == "sigclass") cls = $(i + 1) }
      sub(/,$/, "", at) }
    insig && /^\t(version |digest algo |(critical )?hashed subpkt )/ {
      line = $0; sub(/^\t/, "", line); body = body (body == "" ? "" : "; ") line }
    END { flush() }'
}
# what <sigs line>: "the binding of subkey <keyid> made 2026-11-02" etc.
what() {
  local on cls at
  IFS=$'\t' read -r on cls at _ <<<"$1"
  case $cls in
    0x18) echo "the binding of subkey ${on#key:} made $(ymd "$at")" ;;
    0x28) echo "the revocation of subkey ${on#key:} made $(ymd "$at")" ;;
    0x1[0-3]) echo "the self-signature of user ID ${on#uid:} made $(ymd "$at")" ;;
    0x1f) echo "the direct-key signature made $(ymd "$at")" ;;
    0x20) echo "the revocation of the primary key made $(ymd "$at")" ;;
    0x30) echo "the revocation of user ID ${on#uid:} made $(ymd "$at")" ;;
    *) echo "a signature of class $cls on ${on} made $(ymd "$at")" ;;
  esac
}

# keyfile_problem <file>: why the file is not exactly one public key the
# way rpm reads it (empty: it is). gpg imports secret keys as well, and
# merges several armored blocks into one key; rpm 4 imports only the first
# block (measured Nov 2026: Rocky 9, AlmaLinux 10, Leap 15.6, Tumbleweed).
keyfile_problem() {
  local n
  [ -d "$work/lp" ] || mkdir -m 700 "$work/lp"
  if grep -q 'PRIVATE KEY BLOCK' "$1" ||
     gpg --homedir "$work/lp" --batch --list-packets "$1" 2>/dev/null | grep -Eq '^:secret (sub)?key packet:'; then
    echo "contains secret key material"; return
  fi
  n=$(grep -c -- '^-----BEGIN PGP' "$1" || true)
  if [ "$n" -gt 1 ]; then
    echo "has $n armored blocks, and rpm 4 imports only the first one (gpg merges them, so gpg-based checks see the whole key)"; return
  fi
  n=$(gpg --homedir "$work/lp" --batch --list-packets "$1" 2>/dev/null | grep -c '^:public key packet:' || true)
  [ "$n" = 1 ] || echo "is not exactly one OpenPGP public key"
}

problem=$(keyfile_problem "$PUBLIC_KEY_FILE")
if [ "$problem" = "contains secret key material" ]; then
  die "$PUBLIC_KEY_FILE contains secret key material: the packages and the site would publish it. Export only the public key (gpg --armor --export) and merge it as in $EXPORTDOC; if this file was ever pushed, treat every secret in it as leaked ($EMERGENCY)."
elif [ -n "$problem" ]; then
  die "$PUBLIC_KEY_FILE $problem. Write it with $MERGE as in $EXPORTDOC."
fi
import pub "$PUBLIC_KEY_FILE" || die "$PUBLIC_KEY_FILE is not an OpenPGP public key."
mapfile -t pub < <(keys --homedir "$work/pub" --list-keys)
mapfile -t primaries < <(printf '%s\n' "${pub[@]}" | awk '$1 == "P"')
[ ${#primaries[@]} -eq 1 ] || die "$PUBLIC_KEY_FILE must contain exactly one key."
read -r _ primary _ primary_exp primary_val _ <<<"${primaries[0]}"
[[ $primary_val != *r* ]] || die "The primary key $primary in $PUBLIC_KEY_FILE is revoked."
if [ "$primary_exp" != 0 ] && [ "$primary_exp" -le "$NOW" ]; then
  die "The primary key $primary in $PUBLIC_KEY_FILE expired on $(ymd "$primary_exp")."
fi
sigs "$PUBLIC_KEY_FILE" > "$work/committed.sigs"
gpg --homedir "$work/pub" --batch --dearmor < "$PUBLIC_KEY_FILE" > "$work/committed.gpg" 2>/dev/null ||
  cp "$PUBLIC_KEY_FILE" "$work/committed.gpg"     # already binary

# fetch <url> <file>: sets got_state to none (not served yet: unreachable
# or 404), error (another HTTP status) or ok, and got_why.
fetch() {
  local code rc=0
  if ! command -v curl >/dev/null; then got_state=error got_why="curl is not installed"; return; fi
  code=$(curl -sS -L --max-time 20 --retry 2 -o "$2" -w '%{http_code}' "$1" 2>"$work/curl.err") || rc=$?
  if [ $rc -ne 0 ]; then
    got_state=none got_why="$1 is not reachable (curl exit $rc: $(head -c 200 "$work/curl.err" | tr '\n' ' ' | sed 's/ *$//'))"
    return
  fi
  case $code in
    200|000) got_state=ok got_why= ;;      # 000: a file:// URL (tests)
    404) got_state=none got_why="$1 answers HTTP 404" ;;
    *) got_state=error got_why="$1 answers HTTP $code" ;;
  esac
}
# The key KEY_URL serves: pub_state as fetch's, or bad (not one OpenPGP
# key); for each of its subkeys PUBC (created), PUBE (expires, capped by its
# primary key), PUBV (validity) and PUBCAP (capabilities).
pub_state='' pub_why=''
declare -A PUBC PUBE PUBV PUBCAP
fetch "$url" "$work/published.asc"
pub_state=$got_state pub_why=$got_why
if [ "$pub_state" = ok ]; then
  problem=$(keyfile_problem "$work/published.asc")
  if [ "$problem" = "contains secret key material" ]; then
    err "The published key $url contains secret key material. Take it off the site (the packages branch) now and treat every secret in it as leaked ($EMERGENCY)."
  fi
  if [ -n "$problem" ]; then
    pub_state=bad pub_why="$url $problem"
  elif ! import published "$work/published.asc" ||
     [ "$(keys --homedir "$work/published" --list-keys | grep -c '^P ')" != 1 ]; then
    pub_state=bad pub_why="$url is not exactly one OpenPGP public key"
  else
    pub_why="$url serves a key"
    mapfile -t got < <(keys --homedir "$work/published" --list-keys)
    read -r _ _ _ ppe _ <<<"$(printf '%s\n' "${got[@]}" | awk '$1 == "P"')"
    while read -r _ f c e v cp _; do
      PUBC[$f]=$c PUBE[$f]=$(cap "$e" "$ppe") PUBV[$f]=$v PUBCAP[$f]=$cp
    done < <(printf '%s\n' "${got[@]}" | awk '$1 == "S"')
  fi
fi

# Every signing subkey of the public key, by creation: F fingerprint,
# C created, E expires (0 never), B the expiry its binding states, SRC where
# E comes from (committed: B, capped by the primary key's expiry; published:
# the earlier expiry the published key states), ST status (empty: valid
# now).
F=() C=() E=() B=() SRC=() ST=()
while read -r _ f c b v cp _; do
  [[ $cp == *s* ]] || continue
  e=$(cap "$b" "$primary_exp") src=committed
  if [ -n "${PUBE[$f]+set}" ] && [ "${PUBC[$f]}" = "$c" ] && [ "$f" != "$unpublished_ok" ] &&
     later "$e" "${PUBE[$f]}"; then
    e=${PUBE[$f]} src=published
  fi
  st=
  if [[ $v == *r* ]]; then st=revoked
  elif [ "$c" -gt "$NOW" ]; then st="not valid yet"
  elif [ "$e" != 0 ] && [ "$e" -le "$NOW" ]; then st=expired
  fi
  F+=("$f") C+=("$c") E+=("$e") B+=("$b") SRC+=("$src") ST+=("$st")
done < <(printf '%s\n' "${pub[@]}" | awk '$1 == "S"' | sort -k3,3n -k2,2)
valid=()
for i in "${!F[@]}"; do [ -n "${ST[i]}" ] || valid+=("$i"); done

idx() { local i; for i in "${!F[@]}"; do [ "${F[i]}" = "$1" ] && { echo "$i"; return; }; done; echo -1; }
# expires <i>: "2016-02-01", or with the published key's earlier expiry
# "2016-02-01 (as the published key states; <file> says 2017-02-01)".
expires() {
  if [ "${SRC[$1]}" = published ]; then
    echo "$(expiry "${E[$1]}") (as the published key states; $PUBLIC_KEY_FILE says $(expiry "$(cap "${B[$1]}" "$primary_exp")"))"
  else expiry "${E[$1]}"; fi
}
# pub_problem <i>: why the published key does not cover subkey i (empty: it
# does, or no key is published).
pub_problem() {
  local f=${F[$1]}
  [ "$pub_state" = ok ] || return 0
  if [ -z "${PUBE[$f]+set}" ]; then echo "does not contain signing subkey $f"
  elif [[ ${PUBV[$f]} == *r* ]]; then echo "has signing subkey $f revoked"
  elif [[ ${PUBCAP[$f]} != *s* ]] || [ "${PUBC[$f]}" != "${C[$1]}" ]; then echo "has another binding of signing subkey $f"
  elif [ "${PUBE[$f]}" != 0 ] && [ "${PUBE[$f]}" -le "$NOW" ]; then echo "has signing subkey $f expired"
  fi
}
# spares <i>: the valid signing subkeys other than subkey i.
spares() { local j; for j in "${valid[@]}"; do [ "$j" = "$1" ] || echo "$j"; done; }
EXTEND="extend it with the primary key and change the public key as in $EXPORTDOC, or move CI to the spare as in $EMERGENCY"

# ── Checks of the key file that apply to every mode ───────────────
# whats <sigs lines>: "the binding of ...; the revocation of ..."
whats() { while IFS= read -r l; do what "$l"; done <<<"$1" | paste -sd ';' - | sed 's/;/; /g'; }
# Nothing the published key has may be missing from the committed one
# (missing); what the committed key has beyond it (extra) reaches installed
# systems with the next release.
missing='' extra=''
if [ "$pub_state" = ok ]; then
  sigs "$work/published.asc" | LC_ALL=C sort -u > "$work/published.sigs"
  missing=$(LC_ALL=C comm -23 "$work/published.sigs" <(LC_ALL=C sort -u "$work/committed.sigs"))
  extra=$(LC_ALL=C comm -13 "$work/published.sigs" <(LC_ALL=C sort -u "$work/committed.sigs"))
  if [ -n "$missing" ]; then
    err "$PUBLIC_KEY_FILE lacks $(wc -l <<<"$missing" | tr -d ' ') signature(s) that the published key $url has: $(whats "$missing"). Installed systems keep them, and rpm 6 (Fedora) checks each package against the binding that was valid when it was signed, so dropping one breaks the packages already released. gpg's import keeps only the newest binding of a subkey and export-minimal/export-clean drop the rest: merge the published key into the new one with $MERGE as in $EXPORTDOC."
  fi
  # The subkeys in packet order: the published key's must come first, in
  # their order. dnf 4.14 (RHEL 9) shows the first signing subkey's
  # fingerprint when it imports the key; sq keyring merge may reorder them.
  suborder() { gpg --homedir "$work/pub" --batch --list-packets "$1" 2>/dev/null |
                 awk '/^:public sub key packet:/ { s = 1; next } s && /^\tkeyid: / { print toupper($2); s = 0 }'; }
  suborder "$work/published.asc" > "$work/published.order"
  suborder "$PUBLIC_KEY_FILE" | head -n "$(wc -l < "$work/published.order")" > "$work/committed.order"
  if ! cmp -s "$work/published.order" "$work/committed.order"; then
    warn "$PUBLIC_KEY_FILE lists its subkeys in another order ($(paste -sd ' ' - < "$work/committed.order") ...) than the published key $url ($(paste -sd ' ' - < "$work/published.order")): dnf 4.14 (RHEL 9) shows the first signing subkey's fingerprint when it imports the key, so users would see another one than before and than the README names. Merge with $MERGE, which keeps the published order, as in $EXPORTDOC."
  fi
fi
# A subkey binding after the subkey's revocation: rpm 4.14 and 4.16 refuse
# the whole key when the revocation comes first, the order gpg exports
# (measured, Nov 2026: "key 1 import failed"), and import it when the
# revocation comes after the bindings.
bad_order=$(awk -F'\t' '$1 ~ /^key:/ && $2 == "0x28" { revoked[$1] = 1 }
                        $1 ~ /^key:/ && $2 == "0x18" && ($1 in revoked) { print $1 }' "$work/committed.sigs" |
            sort -u | sed 's/^key://' | paste -sd ' ' -)
if [ -n "$bad_order" ]; then
  err "$PUBLIC_KEY_FILE has the revocation of subkey $bad_order before a binding of it, the order gpg exports: rpm 4.14 and 4.16 (openSUSE Leap 15.6, RHEL 9) then refuse to import the whole key. Write it with $MERGE, which puts revocations last, as in $EXPORTDOC."
fi

# binding_at <signer fpr> <time>: true if the committed key has what rpm 6
# needs to accept a signature made at <time> by <signer>: a self-signature
# of the primary key and, for a subkey, a binding of it, made no later.
binding_at() {
  local k=${1: -16} pk=${primary: -16}
  awk -F'\t' -v k="$k" -v pk="$pk" -v t="$2" '
    $3 <= t && $4 == pk && (($2 ~ /^0x1[0-3]$/ && $1 ~ /^uid:/) || ($2 == "0x1f" && $1 == ("key:" pk))) { self = 1 }
    $3 <= t && $4 == pk && $2 == "0x18" && $1 == ("key:" k) { bound = 1 }
    END { exit !(self && (bound || k == pk)) }' "$work/committed.sigs"
}
bindings_of() {   # bindings_of <fpr>: "2026-11-02, 2026-11-03"
  awk -F'\t' -v k="key:${1: -16}" '$1 == k && $2 == "0x18" { print $3 }' "$work/committed.sigs" |
    while read -r t; do ymd "$t"; done | paste -sd ',' - | sed 's/,/, /g'
}
# The newest valid signature seen (site or releases): who signed, when.
seen_fpr='' seen_at=0 seen_where=''
seen() { if [ "$2" -gt "$seen_at" ]; then seen_fpr=$1 seen_at=$2 seen_where=$3; fi; }
# verify <sig file> [<data file>]: gpgv with the committed key; sets v_fpr,
# v_at (the signature's time) and v_issuer (keyid, also when it fails).
verify() {
  local st
  st=$(gpgv --homedir "$work/pub" --status-fd 1 --keyring "$work/committed.gpg" "$@" 2>/dev/null) || true
  read -r v_fpr v_at < <(awk '$2 == "VALIDSIG" { print $3, $5; exit }' <<<"$st") || v_fpr='' v_at=''
  v_issuer=$(awk '$2 ~ /^(GOODSIG|EXPSIG|EXPKEYSIG|REVKEYSIG|BADSIG|ERRSIG)$/ { print toupper($3); exit }' <<<"$st")
}

# Released signatures (--released): the committed key must still verify
# what was published, the way rpm 6 does.
check_released() {
  local f data i n=0 ok=0 msg
  [ -n "$released" ] || return 0
  # Written by fetch-released-signatures.sh when it could not list the
  # releases or download a signature: fewer files would pass silently.
  if [ -s "$released/.fetch-errors" ]; then
    msg="The released signatures could not all be downloaded ($(head -n 5 "$released/.fetch-errors" | paste -sd ';' - | sed 's/;/; /g' | cut -c 1-600)), so the check that $PUBLIC_KEY_FILE still verifies them is incomplete."
    if [ $public = 0 ]; then err "$msg Re-run the job; it signs nothing until the check is complete."
    else warn "$msg"; fi
  fi
  while IFS= read -r -d '' f; do
    n=$((n + 1)) data=()
    if ! head -n 1 "$f" | grep -q -- '-----BEGIN PGP SIGNED MESSAGE-----'; then
      [ -f "${f%.asc}" ] || { warn "${f#"$released"/}: a detached signature without its file ${f##*/}; not checked."; continue; }
      data=("${f%.asc}")
    fi
    verify "$f" "${data[@]}"
    i=-1; [ -z "$v_issuer" ] || for j in "${!F[@]}"; do [ "${F[j]: -16}" != "$v_issuer" ] || i=$j; done
    if [ "$i" -ge 0 ] && [ "${ST[i]}" = revoked ]; then
      note "${f#"$released"/} is signed by ${F[i]}, which $PUBLIC_KEY_FILE revokes: installed systems reject it once they have the revocation. Expected after a revocation; release again to replace it."
    elif [ -z "$v_fpr" ]; then
      err "${f#"$released"/} (signed by ${v_issuer:-an unknown key}) does not verify with $PUBLIC_KEY_FILE: the key no longer verifies a released file."
    elif ! binding_at "$v_fpr" "$v_at"; then
      err "${f#"$released"/} was signed by $v_fpr on $(ymd "$v_at"), but $PUBLIC_KEY_FILE has no binding of that subkey (or self-signature of the primary key) made by then (its bindings: $(bindings_of "$v_fpr")): rpm 6 (Fedora) and sqv reject what it signed before its newest binding, such as this release's RPMs. Merge the binding back from the published key or the key at the release's commit, as in $EXPORTDOC."
    else
      ok=$((ok + 1)); seen "$v_fpr" "$v_at" "the newest release"
    fi
  done < <(find "$released" -type f -name '*.asc' -print0 | LC_ALL=C sort -z)
  if [ "$n" = 0 ]; then note "No released signatures to check under $released."
  else note "Released signatures that $PUBLIC_KEY_FILE verifies as rpm 6 does: $ok of $n."; fi
}

# ── Signing mode ─────────────────────────────────────────────────
if [ $public = 0 ]; then
  [ -n "${GNUPGHOME:-}" ] || die "GNUPGHOME is not set: import LINUX_GPG_PRIVATE_KEY first (build/linux/import-signing-key.sh)."
  # The validity CI needs: FAIL_DAYS, or after the build (a re-run of a run
  # whose preflight passed up to RERUN_DAYS ago) FAIL_DAYS - RERUN_DAYS.
  floor=$FAIL_DAYS
  [ $after_build = 0 ] || floor=$(( FAIL_DAYS > RERUN_DAYS ? FAIL_DAYS - RERUN_DAYS : 0 ))
  mapfile -t sec < <(keys --list-secret-keys)
  mapfile -t primaries < <(printf '%s\n' "${sec[@]}" | awk '$1 == "P"')
  [ ${#primaries[@]} -eq 1 ] \
    || die "GNUPGHOME holds ${#primaries[@]} secret keys; LINUX_GPG_PRIVATE_KEY must hold one signing subkey of exactly one key."
  read -r _ sec_primary _ <<<"${primaries[0]}"
  [ "$sec_primary" = "$primary" ] || die "The secret key belongs to $sec_primary, $PUBLIC_KEY_FILE is $primary."

  # The signing subkeys whose secret is here, and why the others are not.
  have=() stubs=()
  while read -r _ f c e v cp s; do
    [[ $cp == *s* ]] || continue
    case $s in
      +) have+=("$f $c $e $v") ;;
      '>'*) stubs+=("$f (its secret is on a smartcard)") ;;
      *) stubs+=("$f") ;;
    esac
  done < <(printf '%s\n' "${sec[@]}" | awk '$1 == "S"')
  if [ ${#have[@]} -eq 0 ]; then
    die "LINUX_GPG_PRIVATE_KEY holds the secret of no signing subkey${stubs[0]:+ (only stubs: ${stubs[*]})}. Export the one CI signs with as in $EXPORTCI."
  elif [ ${#have[@]} -gt 1 ]; then
    die "LINUX_GPG_PRIVATE_KEY holds the secrets of ${#have[@]} signing subkeys ($(printf '%s\n' "${have[@]}" | cut -d' ' -f1 | paste -sd ' ' -)). CI must hold exactly one: the spare's secret stays offline, so that a leak of the CI secrets does not take it too. Export only the subkey CI signs with, as in $EXPORTCI."
  fi
  read -r f c e v <<<"${have[0]}"
  sel=$(idx "$f")
  if [ "$sel" -lt 0 ]; then die "Signing subkey $f of LINUX_GPG_PRIVATE_KEY is not in $PUBLIC_KEY_FILE."
  elif [[ $v == *r* ]]; then die "Signing subkey $f is revoked in LINUX_GPG_PRIVATE_KEY. Move CI to the spare as in $EMERGENCY."
  elif [ "${ST[sel]}" = revoked ]; then die "Signing subkey $f is revoked in $PUBLIC_KEY_FILE. Move CI to the spare as in $EMERGENCY."
  elif [ "$c" != "${C[sel]}" ] || [ "$e" != "${B[sel]}" ]; then
    die "Signing subkey $f has another binding in LINUX_GPG_PRIVATE_KEY (expires $(expiry "$e")) than in $PUBLIC_KEY_FILE (expires $(expiry "${B[sel]}")); export both again from the same keyring."
  elif [ "${ST[sel]}" = expired ]; then die "Signing subkey $f expired on $(expires "$sel"). Move CI to the spare as in $EMERGENCY."
  elif [ -n "${ST[sel]}" ]; then die "Signing subkey $f is ${ST[sel]}."
  fi
  if [ -n "$designated" ] && [ "$designated" != "$f" ]; then
    die "$designated_by designates $designated as the subkey CI holds, but LINUX_GPG_PRIVATE_KEY holds the secret of $f. If the wrong subkey was exported (the spare's secret must stay offline), export $designated as in $EXPORTCI; if CI moved to $f on purpose, change $designated_by in the commit that changes the key ($EMERGENCY)."
  fi

  e=${E[sel]} left=
  [ "$e" = 0 ] || left=$(days "$e")
  if within "$e" "$floor"; then
    limits="FAIL_DAYS=$FAIL_DAYS"; [ $after_build = 0 ] || limits+=" minus RERUN_DAYS=$RERUN_DAYS"
    err "Signing subkey $f expires on $(expires "$sel") ($left days left, $limits): CI does not build or sign with it any more. Before it expires, $EXTEND."
  elif within "$e" "$FAIL_DAYS"; then
    warn "Signing subkey $f expires on $(expires "$sel") ($left days left): signing-preflight refuses it for new tag builds since $(ymd $((e - FAIL_DAYS * 86400))) (FAIL_DAYS=$FAIL_DAYS). This job signs anyway, as it runs after a preflight that passed. Now $EXTEND."
  elif within "$e" "$WARN_DAYS"; then
    warn "Signing subkey $f expires on $(expires "$sel") ($left days left); from $(ymd $((e - FAIL_DAYS * 86400))) on (FAIL_DAYS=$FAIL_DAYS) tag builds fail. Before then, $EXTEND."
  fi

  # What installed systems got: the key the repository serves.
  case $pub_state in
    none) note "$pub_why; the repository is not live yet, so the signing subkey is not checked against it." ;;
    error|bad) warn "$pub_why; the signing subkey is not checked against the published key." ;;
    ok)
      problem=$(pub_problem "$sel")
      if [ -n "$problem" ] && [ "$unpublished_ok" = "$f" ]; then
        warn "The published key $url $problem, but LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY allows it: installed systems that do not have it in their key reject these signatures until they get the new key."
      elif [ -n "$problem" ]; then
        err "The published key $url $problem, so installed systems would reject what CI signs. Ship the committed key in a release first, signed with a subkey the published key has; see $EMERGENCY."
      elif [ "${PUBE[$f]}" != "$(cap "${B[sel]}" "$primary_exp")" ]; then
        warn "The published key $url states another expiry for $f ($(expiry "${PUBE[$f]}")) than $PUBLIC_KEY_FILE ($(expiry "${B[sel]}")); installed systems go by theirs until a release ships the committed key, and so do these checks where it is earlier."
      fi ;;
  esac

  mapfile -t sp < <(spares "$sel")
  if [ ${#sp[@]} -eq 0 ]; then
    warn "$PUBLIC_KEY_FILE has no spare signing subkey besides $f: if its secret leaks, installed systems have no other subkey to trust. Add one as in $README."
  else
    note "Spare signing subkey(s), secret offline: $(for i in "${sp[@]}"; do printf '%s ' "${F[i]}"; done | sed 's/ $//')."
  fi

  check_released

  [ $failed = 0 ] || exit 1
  note "Signing with subkey $f (created $(ymd "${C[sel]}"), expires $(expires "$sel")${left:+, $left days left})."
  echo "$f"
  exit 0
fi

# ── Public mode ──────────────────────────────────────────────────
if [ "$primary_exp" != 0 ]; then
  warn "The primary key $primary expires on $(ymd "$primary_exp"), and no subkey is valid after that. The README's layout has a primary key without expiry; see $README."
fi
[ ${#valid[@]} -gt 0 ] || err "$PUBLIC_KEY_FILE has no valid signing subkey: CI cannot sign. See $EMERGENCY."

livemsg="but the repository is live (the packages branch exists): installed systems cannot fetch it, and nothing on the site is checked"
case $pub_state in
  none) if [ $live = 1 ]; then err "$pub_why, $livemsg."
        else note "$pub_why: the repository is not live yet, nothing to compare."; fi ;;
  error) if [ $live = 1 ]; then err "$pub_why, $livemsg."; else warn "$pub_why; the published key is not compared."; fi ;;
  bad) if [ $require_published = 1 ] || [ $live = 1 ]; then err "$pub_why."; else warn "$pub_why."; fi ;;
  ok)
    # Key material through gpg (which keeps only a subkey's newest binding),
    # and the signature packets as they are in the files.
    diff <(material pub) <(material published) > "$work/key.diff" || true
    if [ ! -s "$work/key.diff" ] && [ -z "$extra" ] && [ -z "$missing" ]; then
      note "The published key $url is the committed one."
    elif [ -s "$work/key.diff" ] || [ -n "$extra" ]; then
      diffs=()
      [ ! -s "$work/key.diff" ] || diffs+=("$(grep -c '^[<>]' "$work/key.diff") lines of key material differ")
      [ -z "$extra" ] || diffs+=("it lacks $(wc -l <<<"$extra" | tr -d ' ') signature(s) of the committed key: $(whats "$extra")")
      msg="The published key $url differs from $PUBLIC_KEY_FILE ($(printf '%s; ' "${diffs[@]}" | sed 's/; $//')). Installed systems have the published one. After a change to the committed key that is expected until the next release publishes the repository; otherwise check the packages branch and the host."
      if [ $require_published = 1 ]; then err "$msg"; else warn "$msg"; fi
      [ ! -s "$work/key.diff" ] || sed 's/^/    /' "$work/key.diff" >&2
    fi
    for i in "${valid[@]}"; do
      problem=$(pub_problem "$i")
      [ -z "$problem" ] || warn "The published key $problem: installed systems do not trust it until a release ships the committed key."
    done ;;
esac

# The signatures installed systems check on every update: apt's InRelease
# and dnf's/zypper's repomd.xml.asc. publish-repo re-signs all of them on
# every tag, but between tags they keep the subkey of the last publish, and
# apt and dnf reject the signatures of an expired or revoked subkey.
if [ $check_signatures = 1 ] && [ "$pub_state" = none ]; then
  [ $live = 1 ] || note "The site does not serve the key yet, so there are no repository signatures to check."
elif [ $check_signatures = 1 ]; then
  base=${url%/keys/*} checked=() served=0
  [ "$base" != "$url" ] || base=${url%/*}
  for p in apt/dists/stable/InRelease apt/dists/testing/InRelease \
           rpm/stable/repodata/repomd.xml.asc rpm/testing/repodata/repomd.xml.asc; do
    fetch "$base/$p" "$work/sig"
    if [ "$got_state" = ok ] && [[ $p == *.asc ]]; then fetch "$base/${p%.asc}" "$work/signed"; fi
    case $got_state in
      none) note "$got_why: no signature to check."; continue ;;
      error) warn "$got_why; its signature is not checked."; continue ;;
    esac
    served=$((served + 1))
    signed=(); [[ $p != *.asc ]] || signed=("$work/signed")
    verify "$work/sig" "${signed[@]}"
    i=-1
    for j in "${!F[@]}"; do [ "${F[j]}" != "$v_fpr" ] && [ "${F[j]: -16}" != "$v_issuer" ] || i=$j; done
    resign="Publish a release, or re-run publish-repo of the latest tag, so that the repository is signed with the subkey CI holds now."
    if [ "$i" -ge 0 ] && [ "${ST[i]}" = revoked ]; then err "$base/$p is signed by the revoked subkey ${F[i]}. $resign"
    elif [ -z "$v_fpr" ]; then err "$base/$p does not verify with $PUBLIC_KEY_FILE."
    elif [ "$i" -lt 0 ]; then err "$base/$p is signed by $v_fpr, which is not a signing subkey of $PUBLIC_KEY_FILE."
    elif [ "${ST[i]}" = expired ]; then err "$base/$p is signed by $v_fpr, which expired on $(expires "$i"): apt and dnf reject it. $resign"
    elif ! binding_at "$v_fpr" "$v_at"; then
      err "$base/$p was signed by $v_fpr on $(ymd "$v_at"), before every binding of that subkey in $PUBLIC_KEY_FILE ($(bindings_of "$v_fpr")): rpm 6 rejects it. See $EXPORTDOC."
    elif within "${E[i]}" "$FAIL_DAYS"; then
      err "$base/$p is signed by $v_fpr, which expires on $(expires "$i") ($(days "${E[i]}") days); apt and dnf reject it from then on. $resign"
    elif within "${E[i]}" "$WARN_DAYS"; then
      warn "$base/$p is signed by $v_fpr, which expires on $(expires "$i") ($(days "${E[i]}") days). $resign"
    else
      checked+=("$p"); seen "$v_fpr" "$v_at" "the site's index files"
    fi
  done
  [ ${#checked[@]} -eq 0 ] || note "Signed by a valid subkey with no expiry or $WARN_DAYS days or more left: ${checked[*]}."
  if [ $live = 1 ] && [ $served = 0 ]; then
    err "$base serves the key but none of the repository's InRelease and repomd.xml.asc files, although the repository is live."
  fi
fi

check_released

# The subkey CI holds: the designated one, else the signer of the newest
# valid signature seen, else the only valid one. CI holds exactly one
# (signing mode fails otherwise), so every other valid subkey is a spare.
ci=-1 ci_why=
if [ -n "$designated" ]; then
  ci=$(idx "$designated") ci_why="$designated_by"
  if [ "$ci" -lt 0 ]; then err "$designated_by designates $designated, which is not a signing subkey of $PUBLIC_KEY_FILE: tag builds fail."
  elif [ -n "${ST[ci]}" ]; then err "$designated_by designates $designated, which is ${ST[ci]}: tag builds fail. See $EMERGENCY."; ci=-1
  elif [ -n "$seen_fpr" ] && [ "$seen_fpr" != "$designated" ] && s=$(idx "$seen_fpr") && [ "$s" -ge 0 ] && [ -z "${ST[s]}" ]; then
    warn "The newest signature checked ($seen_where, $(ymd "$seen_at")) is by $seen_fpr, but $designated_by designates $designated as the subkey CI holds. Expected only after CI was moved to another subkey on purpose, until the next release; otherwise the secret in CI may be the spare's (its secret must stay offline): see $EXPORTCI."
  fi
fi
if [ "$ci" -lt 0 ] && [ -n "$seen_fpr" ] && [ -z "$designated" ]; then
  ci=$(idx "$seen_fpr") ci_why="signed $seen_where, $(ymd "$seen_at")"
fi
if [ "$ci" -lt 0 ] && [ ${#valid[@]} -eq 1 ] && [ -z "$designated" ]; then ci=${valid[0]} ci_why="the only valid signing subkey"; fi

if [ ${#valid[@]} -eq 1 ]; then
  warn "$PUBLIC_KEY_FILE has only one valid signing subkey, ${F[valid[0]]}, and no spare: if the CI secret leaks, installed systems have no other subkey to trust, and rpm users then have to import a new key by hand. Add a spare as in $README."
fi
for i in "${valid[@]}"; do
  e=${E[i]}
  [ "$e" != 0 ] || continue
  if [ "$i" = "$ci" ] && within "$e" "$FAIL_DAYS"; then
    err "Signing subkey ${F[i]}, the one CI holds ($ci_why), expires on $(expires "$i") ($(days "$e") days, FAIL_DAYS=$FAIL_DAYS): tag builds fail. Now $EXTEND."
  elif [ "$i" = "$ci" ] && within "$e" "$WARN_DAYS"; then
    warn "Signing subkey ${F[i]}, the one CI holds ($ci_why), expires on $(expires "$i") ($(days "$e") days); tag builds fail from $(ymd $((e - FAIL_DAYS * 86400))) on (FAIL_DAYS=$FAIL_DAYS). Before then, $EXTEND."
  elif [ "$ci" -lt 0 ] && within "$e" "$WARN_DAYS"; then
    warn "Signing subkey ${F[i]} expires on $(expires "$i") ($(days "$e") days); if CI holds it, tag builds fail from $(ymd $((e - FAIL_DAYS * 86400))) on (FAIL_DAYS=$FAIL_DAYS). Before then, $EXTEND."
  elif within "$e" "$WARN_DAYS"; then
    warn "The spare signing subkey ${F[i]} expires on $(expires "$i") ($(days "$e") days). Extend it with the primary key, or add a new spare, as in $README."
  fi
done

echo "Signing subkeys of \`$PUBLIC_KEY_FILE\` (primary key \`$primary\`) on $(ymd "$NOW"):"
echo
echo "| Subkey | Created | Expires | Status |"
echo "|---|---|---|---|"
for i in "${!F[@]}"; do
  st=${ST[i]}
  if [ -n "$st" ]; then :
  elif [ "$i" = "$ci" ]; then st="CI signs with it ($ci_why)"
  elif [ "$ci" -ge 0 ]; then st="spare (secret offline)"
  else st="valid (CI holds one of these, the others are spares)"
  fi
  exp=$(expiry "${E[i]}")
  [ "${E[i]}" = 0 ] || [ -n "${ST[i]}" ] || exp+=" ($(days "${E[i]}") days)"
  [ "${SRC[i]}" != published ] || exp+=" (published key)"
  printf '| `%s` | %s | %s | %s |\n' "${F[i]}" "$(ymd "${C[i]}")" "$exp" "$st"
done
if [ ${#findings[@]} -gt 0 ]; then
  echo
  printf -- '- %s\n' "${findings[@]}"
fi
if [ $failed = 1 ]; then exit 1; elif [ $warned = 1 ]; then exit 3; fi
exit 0
