#!/usr/bin/env bash
# Table test of build/linux/select-signing-subkey.sh with throwaway keys:
#
#   build/linux/repo/test/select-subkey.sh
#
# The keys are made with gpg --faked-system-time, so their subkeys have the
# creation, binding and expiry times of the real layout's history, and
# every case sets TEST_NOW. The main key K is the real key's story: signing
# subkey A bound with an expiry (2013-02-01), used to sign a release
# (2010-06-01), re-bound without expiry (2011-01-01), and a spare S without
# expiry (2011-01-02). All dates lie in the past (2010 to 2019): gpg
# distrusts keys created in the future, and the script decides by TEST_NOW,
# not by gpg's notion of "expired". The published key comes from
# TEST_KEY_URL: a file:// URL, or a local python3 http.server for the HTTP
# cases (skipped without python3; the keys are merged with python3 and
# build/linux/merge-public-key.py, as the README does). Ed25519 keeps key generation fast; the script
# does not look at the algorithm. Needs bash 4, GnuPG 2.2+, curl and python3
# (run.sh runs it in the builder image).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
linux=$(cd "$here/../.." && pwd)
select=$linux/select-signing-subkey.sh
w=$(mktemp -d)
# A keyring of its own for the commands without --homedir (the caller's
# GNUPGHOME may not exist, as in run.sh).
export GNUPGHOME=$w/default
mkdir -m 700 "$GNUPGHOME"
http_pid=
trap '[ -z "$http_pid" ] || kill "$http_pid" 2>/dev/null; for h in "$w"/*/; do gpgconf --homedir "$h" --kill all 2>/dev/null || true; done; rm -rf "$w"' EXIT

q() { gpg --batch --quiet --passphrase '' --pinentry-mode loopback "$@" 2>/dev/null; }
at() { q --homedir "$1" --faked-system-time "${2//-/}T120000!" "${@:3}"; }
subs() { gpg --homedir "$1" --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="sub"{s=1;next} s&&$1=="fpr"{print $10;s=0}'; }
primary() { gpg --homedir "$1" --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'; }
home() { mkdir -m 700 "$w/$1"; echo "$w/$1"; }
export_pub() { gpg --homedir "$1" --batch --armor --export "$(primary "$1")" > "$w/$2"; }
# secret <home> <name> <subkey fpr>...: a CI keyring holding only the
# secrets of the given subkeys, as exported for LINUX_GPG_PRIVATE_KEY.
secret() {
  local h args=() f
  h=$(home "$2")
  for f in "${@:3}"; do args+=("$f!"); done
  gpg --homedir "$1" --batch --armor --export-secret-subkeys "${args[@]}" | gpg --homedir "$h" --batch --quiet --import 2>/dev/null
}
# mergetool <out> <file>...: merged as the README does (merge-public-key.py).
mergetool() {
  local args=() f
  for f in "${@:2}"; do args+=("$w/$f"); done
  python3 "$linux/merge-public-key.py" --output "$w/$1" "${args[@]}" 2>/dev/null
}
# merge <out> <file>...: the files imported oldest first into an empty
# keyring, then exported (what gpg makes of them). gpg keeps an older
# binding only when it is already in the keyring as the newer one arrives.
merge() {
  local h f
  h=$(home "merge-$1")
  for f in "${@:2}"; do gpg --homedir "$h" --batch --quiet --import "$w/$f" 2>/dev/null; done
  export_pub "$h" "$1"
}
bindings() { gpg --batch --list-packets "$w/$1" 2>/dev/null | grep -c 'sigclass 0x18'; }
exp_of() { gpg --batch --with-colons --with-subkey-fingerprint --show-keys "$1" 2>/dev/null | awk -F: -v f="$2" '$1=="sub"{e=$7} $1=="fpr"&&$10==f{print e; exit}'; }
day=86400

# ── Keys ─────────────────────────────────────────────────────────
K=$(home K)
at "$K" 2010-01-01 --quick-generate-key "Select test (throwaway) <test@invalid>" ed25519 cert never
P=$(primary "$K")
at "$K" 2010-02-01 --quick-add-key "$P" ed25519 sign 2013-02-01
A=$(subs "$K" | head -n 1)
export_pub "$K" pub-first.asc            # the first release's key: A with its expiry, no spare
EA=$(exp_of "$w/pub-first.asc" "$A")
secret "$K" a-first "$A"                 # A's secret as exported before the re-binding
mkdir -p "$w/released/v1"
printf 'aaaa  euro-office_1_amd64.deb\n' > "$w/released/v1/SHA256SUMS-linux-amd64.txt"
at "$K" 2010-06-01 --yes --clearsign --local-user "$A!" -o "$w/released/v1/SHA256SUMS-linux-amd64.txt.asc" "$w/released/v1/SHA256SUMS-linux-amd64.txt"
rm "$w/released/v1/SHA256SUMS-linux-amd64.txt"
# The re-binding: A never expires from now on. The keyring keeps only this
# newest binding, so a plain export of it lacks the one the release was
# signed under.
at "$K" 2011-01-01 --quick-set-expire "$P" never "$A"
at "$K" 2011-01-02 --quick-add-key "$P" ed25519 sign never
at "$K" 2011-01-02 --quick-add-key "$P" cv25519 encr never
mapfile -t S_ < <(subs "$K")
S=${S_[1]} ENC=${S_[2]}
export_pub "$K" pub-rebound-only.asc     # what the owner's keyring exports: H2
q --homedir "$K" --armor --export-options export-minimal --export "$P" > "$w/pub-minimal.asc"
mergetool pub.asc pub-first.asc pub-rebound-only.asc   # the healthy key: both bindings of A
# Bindings: A twice (or once), S, ENC.
[ "$(bindings pub.asc)" = 4 ] && [ "$(bindings pub-rebound-only.asc)" = 3 ] \
  || { echo "setup: unexpected bindings (pub.asc $(bindings pub.asc), rebound-only $(bindings pub-rebound-only.asc))"; exit 1; }
merge pub-reimported.asc pub.asc         # a fresh import of the healthy key drops the old binding again
secret "$K" a "$A"
secret "$K" s "$S"
secret "$K" as "$A" "$S"
secret "$K" enc "$ENC"                   # signing subkeys only as stubs
home empty >/dev/null

# The emergency: A revoked with the primary key (2012-01-01). gpg exports the
# revocation before A's binding; merge-public-key.py puts it behind.
cp -a "$K" "$w/K-rev"
printf 'key 1\nrevkey\ny\n1\n\ny\nsave\n' | gpg --homedir "$w/K-rev" --batch --command-fd 0 --pinentry-mode loopback \
  --passphrase '' --faked-system-time 20120101T120000! --edit-key "$P" >/dev/null 2>&1
export_pub "$w/K-rev" pub-rev-only.asc
merge pub-rev-gpg-order.asc pub-first.asc pub-rev-only.asc
mergetool pub-rev.asc pub.asc pub-rev-only.asc
secret "$w/K-rev" a-revoked "$A"
# A without the spare: what the site serves before the spare was shipped.
merge pub-no-spare.asc pub-first.asc
# A spare with an expiry (SP), O: another key, Q: a primary key that
# expires (2014) before its subkey (2019).
SPH=$(home SP)
at "$SPH" 2010-01-01 --quick-generate-key "Spare expiry (throwaway) <sp@invalid>" ed25519 cert never
at "$SPH" 2010-02-01 --quick-add-key "$(primary "$SPH")" ed25519 sign never
at "$SPH" 2010-02-01 --quick-add-key "$(primary "$SPH")" ed25519 sign 2013-02-01
export_pub "$SPH" pub-spare-expiry.asc
mapfile -t SP_ < <(subs "$SPH")
O=$(home O)
at "$O" 2010-01-01 --quick-generate-key "Other (throwaway) <other@invalid>" ed25519 cert never
at "$O" 2010-02-01 --quick-add-key "$(primary "$O")" ed25519 sign never
OS=$(subs "$O" | head -n 1)
secret "$O" other "$OS"
Q=$(home Q)
at "$Q" 2010-01-01 --quick-generate-key "Short primary (throwaway) <short@invalid>" ed25519 cert 2014-02-01
at "$Q" 2010-02-01 --quick-add-key "$(primary "$Q")" ed25519 sign 2019-02-01
export_pub "$Q" pub-short-primary.asc
printf 'this is not a key\n' > "$w/garbage.asc"
# Key files that gpg takes but must never ship: the secret key (all of it),
# the public key with it, and two armored blocks (rpm 4 reads the first).
q --homedir "$K" --armor --export-secret-keys "$P" > "$w/secret.asc"
cat "$w/pub.asc" "$w/secret.asc" > "$w/pub-plus-secret.asc"
cat "$w/pub-first.asc" "$w/pub-rebound-only.asc" > "$w/pub-cat.asc"
# The subkey order changed (S before A), as sq keyring merge may write it.
python3 - "$linux/merge-public-key.py" "$w/pub.asc" "$w/pub-reordered.asc" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('m', sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
key = m.Key('pub', m.dearmor('pub', open(sys.argv[2], 'rb').read()))
uids = [c for c in key.components if m.tag_of(c[0]) != m.SUBKEY]; subs = key.subkeys()
key.components = uids + [subs[1], subs[0]] + subs[2:]
open(sys.argv[3], 'w').write(m.armor(key.bytes()))
PY
# Designations of the subkey CI holds: next to a copy of the key (the
# default CI_SUBKEY_FILE), and files for CI_SUBKEY_FILE.
cp "$w/pub.asc" "$w/pub-designated.asc"
printf '# CI holds:\n%s\n' "$A" > "$w/pub-designated.ci-subkey"
echo "$S" > "$w/des-s"; echo "$A" > "$w/des-a"; echo "${A: -16}" > "$w/des-bad"

# Sites for --check-signatures, signed at the time of the last publish
# (2011-06-01): site: stable and testing InRelease and rpm stable by A, no
# rpm testing; site-bad: repomd.xml changed after signing, InRelease of
# another key.
sign() {   # sign <keyring> <subkey> <date> <file> [--detach]
  local mode=--clearsign out=$4.signed
  if [ "${5:-}" = --detach ]; then mode=--detach-sign out=$4.asc; fi
  at "$1" "$3" --yes --armor --local-user "$2!" "$mode" -o "$out" "$4"
}
for site in site site-bad; do
  mkdir -p "$w/$site/keys" "$w/$site/apt/dists/stable" "$w/$site/apt/dists/testing" "$w/$site/rpm/stable/repodata"
  cp "$w/pub.asc" "$w/$site/keys/euro-office.asc"
  for s in stable testing; do printf 'Suite: %s\n' "$s" > "$w/$site/apt/dists/$s/Release"; done
  printf '<repomd/>\n' > "$w/$site/rpm/stable/repodata/repomd.xml"
done
sign "$w/a" "$A" 2011-06-01 "$w/site/apt/dists/stable/Release"
sign "$w/a" "$A" 2011-06-01 "$w/site/apt/dists/testing/Release"
sign "$w/a" "$A" 2011-06-01 "$w/site/rpm/stable/repodata/repomd.xml" --detach
sign "$w/other" "$OS" 2011-06-01 "$w/site-bad/apt/dists/stable/Release"
cp "$w/site/apt/dists/testing/Release.signed" "$w/site-bad/apt/dists/testing/Release.signed"
cp "$w/site/rpm/stable/repodata/repomd.xml.asc" "$w/site-bad/rpm/stable/repodata/"
printf '<repomd>changed</repomd>\n' > "$w/site-bad/rpm/stable/repodata/repomd.xml"
for site in site site-bad; do
  for s in stable testing; do mv "$w/$site/apt/dists/$s/Release.signed" "$w/$site/apt/dists/$s/InRelease"; done
done
mkdir -p "$w/site-keyonly/keys"; cp "$w/pub.asc" "$w/site-keyonly/keys/euro-office.asc"
# Released signatures by S (after the emergency), and an empty directory.
mkdir -p "$w/released-s/v2" "$w/released-none"
cp -a "$w/released/v1" "$w/released-s/"
printf 'bbbb  euro-office_2_amd64.deb\n' > "$w/released-s/v2/SHA256SUMS-linux-amd64.txt"
at "$w/s" 2012-02-01 --yes --clearsign --local-user "$S!" -o "$w/released-s/v2/SHA256SUMS-linux-amd64.txt.asc" "$w/released-s/v2/SHA256SUMS-linux-amd64.txt"
rm "$w/released-s/v2/SHA256SUMS-linux-amd64.txt"
# What fetch-released-signatures.sh leaves when the API failed for a release.
cp -a "$w/released" "$w/released-incomplete"
echo "v2: cannot download SHA256SUMS-linux-amd64.txt.asc: HTTP 503" > "$w/released-incomplete/.fetch-errors"

# A web server for the HTTP status cases.
http=
if command -v python3 >/dev/null; then
  mkdir "$w/www"; cp "$w/pub.asc" "$w/www/key.asc"; cp "$w/garbage.asc" "$w/www/garbage.asc"
  port=$((20000 + $$ % 20000))
  python3 -m http.server --bind 127.0.0.1 --directory "$w/www" "$port" >/dev/null 2>&1 &
  http_pid=$!
  for _ in $(seq 50); do curl -fsS -o /dev/null "http://127.0.0.1:$port/key.asc" 2>/dev/null && { http=http://127.0.0.1:$port; break; }; sleep 0.1; done
fi

# ── Cases ────────────────────────────────────────────────────────
name_of() {
  case $1 in
    "$A") echo A ;; "$S") echo S ;; *) echo "${1:-none}" ;;
  esac
}
epoch() { case $1 in @*) echo "${1#@}" ;; *) date -u -d "$1" +%s ;; esac; }
fails=0 n=0
# t <description> <keyring|-> <public key> <YYYY-MM-DD|@epoch> <expected> [<regex>...]
#   keyring "-": public mode. expected: A or S (signing mode: exit 0 and
#   that fingerprint on stdout), OK (public mode: exit 0), WARN (public
#   mode: warnings only, exit 3) or ERROR (exit 1). Each regex must match
#   stdout+stderr; "!regex" must not.
# Extra environment and options: the array EXTRA (VAR=value ... --option
# [value] ...; a value after --released is taken as its argument); the
# published key is URL (default: a file that does not exist, "not live
# yet").
EXTRA=() URL=
t() {
  local desc=$1 h=$2 pub=$3 when=$4 want=$5 out=$w/stdout errf=$w/stderr rc=0 got p ok=1 args=() next=
  shift 5
  [ "$h" != - ] || args=(--public)
  cp /dev/null "$out"
  local envs=(PUBLIC_KEY_FILE="$w/$pub" TEST_NOW="$(epoch "$when")" TEST_KEY_URL="${URL:-file://$w/not-published.asc}")
  [ "$h" = - ] || envs+=(GNUPGHOME="$h")
  for p in "${EXTRA[@]}"; do
    if [ -n "$next" ]; then args+=("$p"); next=
    elif [[ $p == --* ]]; then args+=("$p"); [ "$p" != --released ] || next=1
    else envs+=("$p"); fi
  done
  env -u GITHUB_ACTIONS -u GNUPGHOME "${envs[@]}" "$select" "${args[@]}" >"$out" 2>"$errf" || rc=$?
  case $want in
    ERROR) [ $rc -eq 1 ] || ok=0; got="exit $rc" ;;
    OK) [ $rc -eq 0 ] || ok=0; got="exit $rc" ;;
    WARN) [ $rc -eq 3 ] || ok=0; got="exit $rc" ;;
    *) [ $rc -eq 0 ] && [ "$(cat "$out")" = "${!want}" ] || ok=0
       got=$(name_of "$(cat "$out")"); [ $rc -eq 0 ] || got+=" (exit $rc)" ;;
  esac
  cat "$out" >> "$errf"
  for p in "$@"; do
    case $p in
      !*) ! grep -Eq -- "${p#!}" "$errf" || { ok=0; got+=" (unexpected /${p#!}/)"; } ;;
      *) grep -Eq -- "$p" "$errf" || { ok=0; got+=" (no /$p/)"; } ;;
    esac
  done
  n=$((n + 1))
  [[ $when != @* ]] || when=$(date -u -d "$when" +%FT%T 2>/dev/null || echo "$when")
  if [ $ok = 1 ]; then
    printf 'ok   %-70s %s -> %s\n' "$desc" "$when" "$got"
  else
    printf 'FAIL %-70s %s -> %s, expected %s\n' "$desc" "$when" "$got" "$want"
    sed 's/^/       | /' "$errf"
    fails=$((fails + 1))
  fi
}

echo "--- signing mode: the final layout (A in CI, spare S, neither expires)"
t "A's secret: signs, the spare is named, nothing to warn about" "$w/a" pub.asc 2012-06-01 A \
  "::notice::Signing with subkey $A \(created 2010-02-01, expires never\)" "::notice::Spare signing subkey\(s\), secret offline: $S" \
  '!::warning' '!::error'
t "... years later: still healthy" "$w/a" pub.asc 2019-06-01 A '!::warning' '!::error'
t "A and S in the secret: fails, the spare must stay offline" "$w/as" pub.asc 2012-06-01 ERROR \
  "::error::LINUX_GPG_PRIVATE_KEY holds the secrets of 2 signing subkeys \($A $S\). CI must hold exactly one: the spare's secret stays offline"
t "only stubs of the signing subkeys" "$w/enc" pub.asc 2012-06-01 ERROR \
  "::error::LINUX_GPG_PRIVATE_KEY holds the secret of no signing subkey. Export the one CI signs with as in build/linux/README.md, \"Exporting the CI subkey\""
t "no secret key at all" "$w/empty" pub.asc 2012-06-01 ERROR "::error::GNUPGHOME holds 0 secret keys"
t "secret of another key" "$w/other" pub.asc 2012-06-01 ERROR "::error::The secret key belongs to "
t "A's secret exported before the re-binding: binding differs" "$w/a-first" pub.asc 2012-06-01 ERROR \
  "::error::Signing subkey $A has another binding in LINUX_GPG_PRIVATE_KEY \(expires 2013-02-01\) than in .* \(expires never\)"
t "the spare's secret only, nothing designated: S signs" "$w/s" pub.asc 2012-06-01 S "Spare signing subkey\(s\), secret offline: $A" '!::warning'
t "the committed key is another key" "$w/a" pub-spare-expiry.asc 2012-06-01 ERROR "::error::The secret key belongs to "
t "S not in the committed key" "$w/s" pub-first.asc 2010-06-01 ERROR "::error::Signing subkey $S of LINUX_GPG_PRIVATE_KEY is not in .*pub-first.asc"
t "the primary key expired" "$w/a" pub-short-primary.asc 2015-01-01 ERROR "::error::The primary key .* expired on 2014-02-01"
EXTRA=(TEST_NOW=1 GITHUB_ACTIONS=true)
t "TEST_NOW under GitHub Actions" "$w/a" pub.asc 2012-06-01 ERROR "::error::TEST_NOW and TEST_KEY_URL are for the tests only"
EXTRA=(FAIL_DAYS=ninety)
t "FAIL_DAYS not a number" "$w/a" pub.asc 2012-06-01 ERROR "FAIL_DAYS must be a whole number"
EXTRA=()

echo "--- signing mode: the emergency (A revoked, CI moves to S)"
t "A's secret, A revoked in the committed key: fails, points to the spare" "$w/a" pub-rev.asc 2012-02-01 ERROR \
  "::error::Signing subkey $A is revoked in .*pub-rev.asc. Move CI to the spare as in build/linux/README.md, \"If the CI secret leaks\""
t "A revoked in the secret too" "$w/a-revoked" pub-rev.asc 2012-02-01 ERROR "::error::Signing subkey $A is revoked in LINUX_GPG_PRIVATE_KEY"
URL=file://$w/pub.asc
t "S's secret, revoked key committed, site still serves the old key: S signs" "$w/s" pub-rev.asc 2012-02-01 S \
  "::warning::.*pub-rev.asc has no spare signing subkey besides $S" '!::error'
URL=file://$w/pub-no-spare.asc
t "... but the site's key lacks S (spare never shipped): fails" "$w/s" pub-rev.asc 2012-02-01 ERROR \
  "::error::The published key .*pub-no-spare.asc does not contain signing subkey $S, so installed systems would reject"
EXTRA=(LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY="$S")
t "... allowed by LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY" "$w/s" pub-rev.asc 2012-02-01 S \
  "::warning::The published key .* does not contain signing subkey $S, but LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY allows it" '!::error'
EXTRA=()
URL=file://$w/pub-rev.asc
t "the site serves the revocation, CI still holds A" "$w/a" pub.asc 2012-02-01 ERROR \
  "::error::.*pub.asc lacks 1 signature\(s\) that the published key .* has: the revocation of subkey ${A: -16} made 2012-01-01"
URL=
t "revocation in gpg's order (before the binding): fails" "$w/s" pub-rev-gpg-order.asc 2012-02-01 ERROR \
  "::error::.* has the revocation of subkey ${A: -16} before a binding of it, the order gpg exports: rpm 4.14 and 4.16 .*merge-public-key.py"

echo "--- signing mode: LINUX_GPG_SIGN_SUBKEY must name the subkey CI holds"
EXTRA=(LINUX_GPG_SIGN_SUBKEY="$A")
t "pin A, secret A" "$w/a" pub.asc 2012-06-01 A '!::warning' '!::error'
EXTRA=(LINUX_GPG_SIGN_SUBKEY="$(tr A-F a-f <<<"$A")")
t "pin A in lower case" "$w/a" pub.asc 2012-06-01 A
EXTRA=(LINUX_GPG_SIGN_SUBKEY="$S")
t "pin S, secret A: fails" "$w/a" pub.asc 2012-06-01 ERROR "::error::LINUX_GPG_SIGN_SUBKEY designates $S as the subkey CI holds, but LINUX_GPG_PRIVATE_KEY holds the secret of $A"
EXTRA=(LINUX_GPG_SIGN_SUBKEY="${A: -16}")
t "pin a short key ID" "$w/a" pub.asc 2012-06-01 ERROR "must be a 40-digit subkey fingerprint"
EXTRA=()

echo "--- signing mode: the committed designation (CI_SUBKEY_FILE, next to the key)"
t "designated A, secret A" "$w/a" pub-designated.asc 2012-06-01 A '!::warning' '!::error'
t "designated A, the spare's secret in CI: fails" "$w/s" pub-designated.asc 2012-06-01 ERROR \
  "::error::.*pub-designated.ci-subkey designates $A as the subkey CI holds, but LINUX_GPG_PRIVATE_KEY holds the secret of $S. If the wrong subkey was exported"
EXTRA=(LINUX_GPG_SIGN_SUBKEY="$A")
t "designated A and LINUX_GPG_SIGN_SUBKEY=A: agree" "$w/a" pub-designated.asc 2012-06-01 A '!::error'
EXTRA=(CI_SUBKEY_FILE="$w/des-s" LINUX_GPG_SIGN_SUBKEY="$A")
t "CI_SUBKEY_FILE says S, LINUX_GPG_SIGN_SUBKEY A: fails" "$w/a" pub.asc 2012-06-01 ERROR \
  "::error::LINUX_GPG_SIGN_SUBKEY is $A, but .*des-s designates $S"
EXTRA=(CI_SUBKEY_FILE="$w/des-s")
t "after the emergency: designated S, S's secret" "$w/s" pub-rev.asc 2012-02-01 S '!::error'
t "designated S, A's secret: fails" "$w/a" pub.asc 2012-06-01 ERROR "designates $S as the subkey CI holds, but LINUX_GPG_PRIVATE_KEY holds the secret of $A"
EXTRA=(CI_SUBKEY_FILE="$w/des-bad")
t "a designation that is not a fingerprint" "$w/a" pub.asc 2012-06-01 ERROR "::error::.*des-bad must hold the 40-digit fingerprint"
EXTRA=(CI_SUBKEY_FILE="$w/des-missing")
t "CI_SUBKEY_FILE that does not exist" "$w/a" pub.asc 2012-06-01 ERROR "::error::CI_SUBKEY_FILE .*des-missing' not found"
EXTRA=(CI_SUBKEY_FILE=)
t "CI_SUBKEY_FILE empty: no designation" "$w/s" pub-designated.asc 2012-06-01 S '!::error'
EXTRA=()

echo "--- every mode: the key file must be one public key, as rpm reads it"
t "the secret key as the public key: fails" "$w/a" secret.asc 2012-06-01 ERROR "::error::.*secret.asc contains secret key material: the packages and the site would publish it"
t "public key plus secret key: fails" "$w/a" pub-plus-secret.asc 2012-06-01 ERROR "::error::.*pub-plus-secret.asc contains secret key material"
t "... public mode: fails" - pub-plus-secret.asc 2012-06-01 ERROR "contains secret key material" "\*\*Error:\*\* .*contains secret key material"
t "two armored blocks (first export, then the re-bound one): fails" "$w/a" pub-cat.asc 2012-06-01 ERROR \
  "::error::.*pub-cat.asc has 2 armored blocks, and rpm 4 imports only the first one.*merge-public-key.py"
EXTRA=(--released "$w/released")
t "... public mode, although gpg verifies the release with it: fails" - pub-cat.asc 2012-06-01 ERROR "has 2 armored blocks"
EXTRA=()
URL=file://$w/pub-plus-secret.asc
t "the site serves secret key material: fails" "$w/a" pub.asc 2012-06-01 ERROR "::error::The published key .* contains secret key material. Take it off the site"
t "... public mode: fails" - pub.asc 2012-06-01 ERROR "::error::The published key .* contains secret key material"
URL=file://$w/pub-cat.asc
t "the site serves two armored blocks: warning" - pub.asc 2012-06-01 WARN "::warning::.*pub-cat.asc has 2 armored blocks"
URL=

echo "--- the released signatures could not all be downloaded"
EXTRA=(--released "$w/released-incomplete")
t "signing mode: fails" "$w/a" pub.asc 2012-06-01 ERROR \
  "::error::The released signatures could not all be downloaded \(v2: cannot download SHA256SUMS-linux-amd64.txt.asc: HTTP 503\).* Re-run the job"
t "public mode: warning" - pub.asc 2012-06-01 WARN "::warning::The released signatures could not all be downloaded"
EXTRA=()

echo "--- signing mode: the H2 class (a binding dropped by the re-binding's export)"
EXTRA=(--released "$w/released")
t "merged key, released signature of 2010: verifies as rpm 6 does" "$w/a" pub.asc 2012-06-01 A \
  "::notice::Released signatures that .* verifies as rpm 6 does: 1 of 1" '!::error'
t "the owner's keyring export (newest binding only): fails" "$w/a" pub-rebound-only.asc 2012-06-01 ERROR \
  "::error::v1/SHA256SUMS-linux-amd64.txt.asc was signed by $A on 2010-06-01, but .*pub-rebound-only.asc has no binding of that subkey .* made by then \(its bindings: 2011-01-01\): rpm 6 \(Fedora\) and sqv reject"
t "export-minimal: fails" "$w/a" pub-minimal.asc 2012-06-01 ERROR "was signed by $A on 2010-06-01, but .*pub-minimal.asc has no binding"
t "merged key re-imported into a fresh keyring and exported: fails" "$w/a" pub-reimported.asc 2012-06-01 ERROR \
  "was signed by $A on 2010-06-01, but .*pub-reimported.asc has no binding"
t "the first release's key itself" "$w/a-first" pub-first.asc 2010-07-01 A '!::error'
EXTRA=(--released "$w/released-none")
t "no released signatures: notice" "$w/a" pub.asc 2012-06-01 A "::notice::No released signatures to check under "
EXTRA=()
URL=file://$w/pub.asc
t "committed key lacks a binding the published key has: fails" "$w/a" pub-rebound-only.asc 2012-06-01 ERROR \
  "::error::.*pub-rebound-only.asc lacks 1 signature\(s\) that the published key .*pub.asc has: the binding of subkey ${A: -16} made 2010-02-01.*merge the published key into the new one"
t "the merged key against itself: passes" "$w/a" pub.asc 2012-06-01 A '!::error' '!lacks'
URL=file://$w/pub-first.asc
t "the published key is the first release's (no spare yet): passes" "$w/a" pub.asc 2012-06-01 A '!::error'
URL=

echo "--- signing mode: FAIL_DAYS (90) and WARN_DAYS (180) for a subkey with an expiry (A before the re-binding)"
t "A, 180 days left: no expiry warning" "$w/a-first" pub-first.asc "@$((EA - 180 * day))" A '!::warning::Signing subkey'
t "A, 180 days minus a second: warning" "$w/a-first" pub-first.asc "@$((EA - 180 * day + 1))" A \
  "::warning::Signing subkey $A expires on 2013-02-01 \(179 days left\); from 2012-11-0[23] on \(FAIL_DAYS=90\) tag builds fail. Before then, extend it with the primary key"
t "A, 90 days left: warning only" "$w/a-first" pub-first.asc "@$((EA - 90 * day))" A "::warning::Signing subkey $A" '!::error'
t "A, 90 days minus a second: fails" "$w/a-first" pub-first.asc "@$((EA - 90 * day + 1))" ERROR \
  "::error::Signing subkey $A expires on 2013-02-01 \(89 days left, FAIL_DAYS=90\): CI does not build or sign with it any more"
t "A expired" "$w/a-first" pub-first.asc 2013-02-02 ERROR "::error::Signing subkey $A expired on 2013-02-01. Move CI to the spare"
t "no spare in that key: a warning" "$w/a-first" pub-first.asc 2010-06-01 A "::warning::.*pub-first.asc has no spare signing subkey besides $A"
EXTRA=(--after-build)
t "--after-build: 89 days left signs, with a warning" "$w/a-first" pub-first.asc "@$((EA - 89 * day))" A \
  "::warning::Signing subkey $A expires on 2013-02-01 \(89 days left\): signing-preflight refuses it for new tag builds since 2012-11-0[23] \(FAIL_DAYS=90\). This job signs anyway" '!::error'
t "--after-build: 60 days left signs" "$w/a-first" pub-first.asc "@$((EA - 60 * day))" A "::warning::Signing subkey $A"
t "--after-build: 60 days minus a second fails" "$w/a-first" pub-first.asc "@$((EA - 60 * day + 1))" ERROR \
  "::error::Signing subkey $A expires on 2013-02-01 \(59 days left, FAIL_DAYS=90 minus RERUN_DAYS=30\)"
EXTRA=(--after-build RERUN_DAYS=100)
t "--after-build, RERUN_DAYS over FAIL_DAYS: floor 0" "$w/a-first" pub-first.asc "@$((EA - 1 * day))" A "::warning::Signing subkey $A"
EXTRA=(FAIL_DAYS=30 WARN_DAYS=60)
t "FAIL_DAYS=30 WARN_DAYS=60: 89 days left passes" "$w/a-first" pub-first.asc "@$((EA - 89 * day))" A '!::warning::Signing subkey'
EXTRA=()
URL=file://$w/pub-first.asc
t "the published key's earlier expiry counts (A re-bound, site still old)" "$w/a" pub.asc 2012-12-15 ERROR \
  "::error::Signing subkey $A expires on 2013-02-01 \(as the published key states; .*pub.asc says never\) \(48 days left, FAIL_DAYS=90\)"
EXTRA=(LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY="$A")
t "... LINUX_GPG_ALLOW_UNPUBLISHED_SUBKEY: the committed expiry" "$w/a" pub.asc 2012-12-15 A \
  "::warning::The published key .* states another expiry for $A \(2013-02-01\) than .* \(never\)" '!::error'
EXTRA=()
URL=

echo "--- signing mode: the published key (TEST_KEY_URL)"
URL=file://$w/garbage.asc
t "published file is not a key: warning" "$w/a" pub.asc 2012-06-01 A "::warning::.* is not exactly one OpenPGP public key"
URL=file://$w/nothing-here.asc
t "published key not reachable: notice" "$w/a" pub.asc 2012-06-01 A "::notice::.* is not reachable .*not live yet" '!::warning'
URL=
if [ -n "$http" ]; then
  URL=$http/key.asc
  t "HTTP 200 with the key" "$w/a" pub.asc 2012-06-01 A '!::warning' '!not live'
  URL=$http/missing.asc
  t "HTTP 404: notice" "$w/a" pub.asc 2012-06-01 A "::notice::.* answers HTTP 404; the repository is not live yet"
  URL=$http/garbage.asc
  t "HTTP 200, not a key: warning" "$w/a" pub.asc 2012-06-01 A "::warning::.* is not exactly one OpenPGP public key"
  URL=http://127.0.0.1:9/key.asc
  t "connection refused: notice" "$w/a" pub.asc 2012-06-01 A "::notice::.* is not reachable \(curl exit 7"
  URL=
else
  echo "skip HTTP cases (no python3)"
fi

echo "--- public mode: the final layout"
t "A and S, no evidence: both valid, healthy" - pub.asc 2012-06-01 OK \
  "\| \`$A\` \| 2010-02-01 \| never \| valid \(CI holds one of these, the others are spares\) \|" \
  "\| \`$S\` \| 2011-01-02 \| never \| valid" "not live yet" '!::warning' '!::error' "!$ENC"
t "... in 2019: still healthy" - pub.asc 2019-06-01 OK '!::warning' '!::error'
EXTRA=(--released "$w/released")
t "--released: A signed the newest release, S is the spare" - pub.asc 2012-06-01 OK \
  "\| \`$A\` \| .* \| CI signs with it \(signed the newest release, 2010-06-01\) \|" "\| \`$S\` \| .* \| spare \(secret offline\) \|" '!::warning'
EXTRA=(LINUX_GPG_SIGN_SUBKEY="$S")
t "LINUX_GPG_SIGN_SUBKEY=S: S is CI's, A the spare" - pub.asc 2012-06-01 OK \
  "\| \`$S\` \| .* \| CI signs with it \(LINUX_GPG_SIGN_SUBKEY\) \|" "\| \`$A\` \| .* \| spare \(secret offline\) \|"
EXTRA=()
t "designated A (next to the key): named from it" - pub-designated.asc 2012-06-01 OK \
  "\| \`$A\` \| .* \| CI signs with it \(.*pub-designated.ci-subkey\) \|" "\| \`$S\` \| .* \| spare \(secret offline\) \|" '!::warning'
EXTRA=(--released "$w/released-s")
t "designated A, but the newest release is S's: warning" - pub-designated.asc 2012-03-01 WARN \
  "::warning::The newest signature checked \(the newest release, 2012-02-01\) is by $S, but .*pub-designated.ci-subkey designates $A"
EXTRA=(CI_SUBKEY_FILE="$w/des-a")
t "designated A, which the committed key revokes: error" - pub-rev.asc 2012-02-01 ERROR "::error::.*des-a designates $A, which is revoked"
EXTRA=(LINUX_GPG_SIGN_SUBKEY="$OS")
t "LINUX_GPG_SIGN_SUBKEY not in the key: error" - pub.asc 2012-06-01 ERROR "::error::LINUX_GPG_SIGN_SUBKEY designates $OS, which is not a signing subkey of"
EXTRA=()
t "one signing subkey only (the first release's key): no spare, warning" - pub-first.asc 2010-06-01 WARN \
  "::warning::.*pub-first.asc has only one valid signing subkey, $A, and no spare" \
  "\| \`$A\` \| 2010-02-01 \| 2013-02-01 \([0-9]+ days\) \| CI signs with it \(the only valid signing subkey\) \|"
t "... A within WARN_DAYS: it is CI's" - pub-first.asc 2012-10-01 WARN \
  "::warning::Signing subkey $A, the one CI holds \(the only valid signing subkey\), expires on 2013-02-01 \(123 days\); tag builds fail from 2012-11-0[23] on"
t "... A within FAIL_DAYS: error" - pub-first.asc 2012-12-01 ERROR "::error::Signing subkey $A, the one CI holds .* \(62 days, FAIL_DAYS=90\): tag builds fail"
t "... everything expired" - pub-first.asc 2013-03-01 ERROR "::error::.* has no valid signing subkey: CI cannot sign" "\| expired \|"
EXTRA=(LINUX_GPG_SIGN_SUBKEY="${SP_[0]}")
t "a spare with an expiry, within WARN_DAYS" - pub-spare-expiry.asc 2012-10-01 WARN \
  "::warning::The spare signing subkey ${SP_[1]} expires on 2013-02-01 \(123 days\)" '!::error'
EXTRA=()
t "the same, CI unknown: if CI holds it" - pub-spare-expiry.asc 2012-10-01 WARN \
  "::warning::Signing subkey ${SP_[1]} expires on 2013-02-01 \(123 days\); if CI holds it, tag builds fail"
t "a primary key that expires: warning" - pub-short-primary.asc 2010-06-01 WARN "::warning::The primary key .* expires on 2014-02-01"
t "subkey capped by the primary key's expiry" - pub-short-primary.asc 2013-06-01 WARN "\| 2014-02-01 \(245 days\) \|"
t "the primary key expired" - pub-short-primary.asc 2015-01-01 ERROR "::error::The primary key .* expired on 2014-02-01"

echo "--- public mode: the emergency"
t "A revoked: S is the only one, no spare: warning" - pub-rev.asc 2012-02-01 WARN \
  "\| \`$A\` \| 2010-02-01 \| never \| revoked \|" "\| \`$S\` .* CI signs with it \(the only valid signing subkey\)" \
  "::warning::.*has only one valid signing subkey, $S, and no spare"
EXTRA=(--released "$w/released-s")
t "--released after the emergency: A's release is a notice, S signed the newest" - pub-rev.asc 2012-03-01 WARN \
  "::notice::v1/SHA256SUMS-linux-amd64.txt.asc is signed by $A, which .* revokes" "CI signs with it \(signed the newest release, 2012-02-01\)" '!::error'
EXTRA=(LINUX_GPG_SIGN_SUBKEY="$A")
t "LINUX_GPG_SIGN_SUBKEY still names the revoked A: error" - pub-rev.asc 2012-02-01 ERROR "::error::LINUX_GPG_SIGN_SUBKEY designates $A, which is revoked: tag builds fail"
EXTRA=()
t "revocation in gpg's order: error" - pub-rev-gpg-order.asc 2012-02-01 ERROR "::error::.* has the revocation of subkey ${A: -16} before a binding of it"

echo "--- public mode: the published key"
URL=file://$w/pub.asc
t "published key is the committed one" - pub.asc 2012-06-01 OK "::notice::The published key .* is the committed one" '!::warning'
URL=file://$w/pub-no-spare.asc
t "published key without the spare: warnings" - pub.asc 2012-06-01 WARN '!is the committed one' \
  "::warning::The published key .* differs from .*expected until the next release" \
  "::warning::The published key does not contain signing subkey $S: installed systems do not trust it until a release ships the committed key"
EXTRA=(--require-published)
t "... --require-published: error" - pub.asc 2012-06-01 ERROR "::error::The published key .* differs"
EXTRA=()
URL=file://$w/pub-rebound-only.asc
t "published key lacks the old binding (the H2 export on the site): warning" - pub.asc 2012-06-01 WARN \
  "::warning::The published key .*pub-rebound-only.asc differs from .*pub.asc \(it lacks 1 signature\(s\) of the committed key: the binding of subkey ${A: -16} made 2010-02-01\)" \
  '!is the committed one' '!lines of key material'
EXTRA=(--require-published)
t "... --require-published: error" - pub.asc 2012-06-01 ERROR "::error::The published key .*pub-rebound-only.asc differs .*lacks 1 signature"
EXTRA=()
URL=file://$w/pub.asc
t "committed key lists the subkeys in another order: warning" - pub-reordered.asc 2012-06-01 WARN \
  "::warning::.*pub-reordered.asc lists its subkeys in another order \(${S: -16} ${A: -16} .*dnf 4.14 \(RHEL 9\) shows the first signing subkey" '!lacks'
t "... signing mode: warning" "$w/a" pub-reordered.asc 2012-06-01 A "::warning::.*lists its subkeys in another order"
URL=file://$w/pub.asc
t "committed key lacks a binding the published key has: error" - pub-rebound-only.asc 2012-06-01 ERROR \
  "::error::.*pub-rebound-only.asc lacks 1 signature\(s\) that the published key .* has: the binding of subkey ${A: -16} made 2010-02-01" \
  "\*\*Error:\*\* .*lacks 1 signature"
URL=file://$w/pub-rev.asc
t "committed key lacks the published revocation: error" - pub.asc 2012-02-01 ERROR "lacks 1 signature\(s\) .*: the revocation of subkey ${A: -16} made 2012-01-01"
URL=file://$w/garbage.asc
EXTRA=(--require-published)
t "published file is not a key, --require-published" - pub.asc 2012-06-01 ERROR "::error::.* is not exactly one OpenPGP public key"
URL=file://$w/nothing-here.asc
t "not reachable, --require-published: notice only" - pub.asc 2012-06-01 OK "::notice::.* is not reachable"
EXTRA=() URL=
EXTRA=(--released "$w/released")
t "--released, the owner's keyring export: error" - pub-rebound-only.asc 2012-06-01 ERROR \
  "::error::v1/SHA256SUMS-linux-amd64.txt.asc was signed by $A on 2010-06-01, but .* has no binding" "\*\*Error:\*\* v1/SHA256SUMS"
EXTRA=()

echo "--- public mode: --live (the packages branch exists)"
EXTRA=(--live)
URL=file://$w/nothing-here.asc
t "live, key not reachable: error" - pub.asc 2012-06-01 ERROR "::error::.* is not reachable .*but the repository is live"
EXTRA=(--live --check-signatures)
t "live, key not reachable, --check-signatures: error" - pub.asc 2012-06-01 ERROR "but the repository is live" '!no repository signatures'
URL=file://$w/site/keys/euro-office.asc
t "live, site complete" - pub.asc 2012-06-01 OK '!::error' '!::warning'
URL=file://$w/site-keyonly/keys/euro-office.asc
t "live, key but no index files: error" - pub.asc 2012-06-01 ERROR "::error::.* serves the key but none of the repository's InRelease and repomd.xml.asc files"
EXTRA=(--check-signatures)
t "not live, key but no index files: notices" - pub.asc 2012-06-01 OK '!::error'
EXTRA=() URL=

echo "--- public mode: --check-signatures (the signatures the site serves)"
URL=file://$w/site/keys/euro-office.asc EXTRA=(--check-signatures)
t "signed by A, which never expires: healthy, A is CI's" - pub.asc 2012-06-01 OK \
  "::notice::Signed by a valid subkey with no expiry or 180 days or more left: apt/dists/stable/InRelease apt/dists/testing/InRelease rpm/stable/repodata/repomd.xml.asc" \
  "::notice::.*rpm/testing/repodata/repomd.xml.asc is not reachable .*no signature to check" \
  "CI signs with it \(signed the site's index files, 2011-06-01\)" '!::warning' '!::error'
t "the site signed by A, A revoked in the committed key: error" - pub-rev.asc 2012-02-01 ERROR \
  "::error::.*apt/dists/stable/InRelease is signed by the revoked subkey $A. Publish a release"
URL=file://$w/site-bad/keys/euro-office.asc
t "changed repomd.xml, InRelease of another key" - pub.asc 2012-06-01 ERROR \
  "::error::.*rpm/stable/repodata/repomd.xml.asc does not verify with" "::error::.*apt/dists/stable/InRelease does not verify with"
URL=file://$w/nothing-here.asc
t "site not live: no signatures to check" - pub.asc 2012-06-01 OK \
  "::notice::The site does not serve the key yet, so there are no repository signatures to check" '!InRelease'
EXTRA=() URL=
t "without --check-signatures: not checked" - pub.asc 2012-06-01 OK '!InRelease'

echo "--- merge-public-key.py"
merge_py=$linux/merge-public-key.py
sigorder() { gpg --batch --list-packets "$1" 2>/dev/null | grep -o 'sigclass 0x[0-9a-f]*' | sed 's/sigclass //' | paste -sd ' ' -; }
suborder() { gpg --batch --list-packets "$1" 2>/dev/null | awk '/^:public sub key packet:/{s=1;next} s&&/keyid:/{print $2;s=0}' | paste -sd ' ' -; }
check() {   # check <description> <condition...>
  n=$((n + 1))
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
check "the revoked key: the same packets as gpg's, A's revocation after its two bindings" \
  bash -c '[ "$(gpg --batch --list-packets "$1" 2>/dev/null | grep -E "^:|sigclass" | sort)" = "$(gpg --batch --list-packets "$2" 2>/dev/null | grep -E "^:|sigclass" | sort)" ] && [ "$3" = "0x13 0x18 0x18 0x28 0x18 0x18" ]' \
  _ "$w/pub-rev.asc" "$w/pub-rev-gpg-order.asc" "$(sigorder "$w/pub-rev.asc")"
check "the subkeys stay in the published key's order" [ "$(suborder "$w/pub-rev.asc")" = "$(suborder "$w/pub.asc")" ]
python3 "$merge_py" --output "$w/m-same.asc" "$w/pub.asc" "$w/pub.asc" 2>/dev/null
check "merging a key with itself changes no byte" cmp -s "$w/m-same.asc" "$w/pub.asc"
python3 "$merge_py" --output "$w/m-order.asc" "$w/pub.asc" "$w/pub-reordered.asc" 2>/dev/null
check "a later file in another order: the first file's order wins" [ "$(suborder "$w/m-order.asc")" = "$(suborder "$w/pub.asc")" ]
python3 "$merge_py" --output "$w/m-gpg.asc" "$w/pub-rev-gpg-order.asc" 2> "$w/m.err"
check "gpg's order: 1 revocation moved" grep -q 'moved 1 subkey revocation(s)' "$w/m.err"
python3 "$merge_py" --output "$w/m-ok.asc" "$w/pub-rev.asc" 2> "$w/m.err"
check "already in order: 0 moved" grep -q 'moved 0 subkey revocation(s)' "$w/m.err"
for bad in secret.asc pub-plus-secret.asc pub-cat.asc garbage.asc; do
  rc=0; python3 "$merge_py" --output "$w/m-bad.asc" "$w/$bad" 2>/dev/null || rc=$?
  check "refuses $bad" [ "$rc" != 0 ]
done
rc=0; python3 "$merge_py" --output "$w/m-bad.asc" "$w/pub.asc" "$w/pub-spare-expiry.asc" 2>/dev/null || rc=$?
check "refuses to merge another key" [ "$rc" != 0 ]
python3 "$merge_py" --drop-revoked-subkeys --output "$w/m-norev.asc" "$w/pub-rev.asc" 2>/dev/null
check "--drop-revoked-subkeys: A gone, S and ENC kept" \
  bash -c '[ "$(gpg --batch --with-colons --with-subkey-fingerprint --show-keys "$1" 2>/dev/null | awk -F: "\$1==\"fpr\"{print \$10}" | tail -n +2 | paste -sd " " -)" = "$2 $3" ]' _ "$w/m-norev.asc" "$S" "$ENC"

echo "--- usage"
for bad in "--check-signatures" "--bogus" "--after-build --public" "--live" "--require-published" "--released"; do
  n=$((n + 1)); rc=0
  # shellcheck disable=SC2086
  PUBLIC_KEY_FILE=$w/pub.asc "$select" $bad >/dev/null 2>&1 || rc=$?
  if [ $rc = 2 ]; then echo "ok   $bad: exit 2"; else echo "FAIL $bad: exit $rc"; fails=$((fails + 1)); fi
done
n=$((n + 1)); rc=0
env -u GITHUB_ACTIONS PUBLIC_KEY_FILE="$w/pub.asc" TEST_KEY_URL="file://$w/not-published.asc" "$select" --public --released "$w/nope" >/dev/null 2>&1 || rc=$?
if [ $rc = 1 ]; then echo "ok   --released without a directory: exit 1"; else echo "FAIL --released without a directory: exit $rc"; fails=$((fails + 1)); fi
# A check that stops early still says why in the report (stdout).
n=$((n + 1))
out=$(env -u GITHUB_ACTIONS PUBLIC_KEY_FILE="$w/pub-short-primary.asc" TEST_NOW="$(epoch 2015-01-01)" \
      TEST_KEY_URL="file://$w/not-published.asc" "$select" --public 2>/dev/null) || true
if grep -q '^- \*\*Error:\*\* The primary key .* expired on 2014-02-01' <<<"$out"; then
  echo "ok   public mode: an early error is in the report too"
else echo "FAIL public mode: early error missing from stdout: $out"; fails=$((fails + 1)); fi
n=$((n + 1))
out=$(env -u GITHUB_ACTIONS PUBLIC_KEY_FILE="$w/pub-short-primary.asc" TEST_NOW="$(epoch 2015-01-01)" GNUPGHOME="$w/a" \
      TEST_KEY_URL="file://$w/not-published.asc" "$select" 2>/dev/null) || true
if [ -z "$out" ]; then echo "ok   signing mode: nothing on stdout on an early error"
else echo "FAIL signing mode printed '$out' on an early error"; fails=$((fails + 1)); fi

echo
if [ $fails -eq 0 ]; then echo "all $n cases passed"; else echo "$fails of $n cases FAILED"; exit 1; fi
