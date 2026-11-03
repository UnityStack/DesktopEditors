#!/usr/bin/env bash
# The emergency of build/linux/README.md ("If the CI secret leaks") on real
# clients, in Docker, with a throwaway key:
#
#   build/linux/repo/test/revocation.sh
#
# The key has the real layout: subkey A (CI's) bound with an expiry, a
# package signed by it, A re-bound without expiry, a spare S without
# expiry. The published key (before.asc) is merged from the first and the
# re-bound export with build/linux/merge-public-key.py, as the README does.
# Then A is revoked; the README's merge of the published key and the
# owner's new export (revoked.asc) has both of A's bindings and then the
# revocation. Each rpm client (fedora:43, Rocky Linux 9, AlmaLinux 10,
# openSUSE Leap 15.6 and Tumbleweed) must import revoked.asc on a fresh
# system and verify the spare's package, and an updated system (the old key
# imported first) must keep verifying it. The remedy the README's advisory
# gives rpm users (remove the key, import it without the revoked subkey,
# written by merge-public-key.py --drop-revoked-subkeys) must make every
# client reject A's package and keep accepting S's. The script also prints
# how each treats A's package otherwise (rpm 6 and 4.20 reject it, older
# rpm 4 ignore the revocation) and how each takes a revocation in front of
# the bindings: the owner's plain gpg export (only the new binding), and the
# same order with both bindings. The apt verifiers (gpgv on ubuntu:24.04,
# sqv on debian:13) must reject A's signature and accept S's with
# revoked.asc. Every container is removed (docker run --rm). Needs docker.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src_root=$(cd "$here/../../../.." && pwd)
w=$(mktemp -d "${TMPDIR:-/tmp}/eo-revocation.XXXXXX")
trap 'rm -rf "$w"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

cat > "$w/make-keys.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
export GNUPGHOME=$(mktemp -d)
merge=/src/build/linux/merge-public-key.py
ago() { date -u -d "-$1 days" +%Y%m%dT%H%M%S!; }
g() { gpg --batch --quiet --passphrase "" --pinentry-mode loopback "$@"; }
g --faked-system-time "$(ago 800)" --quick-generate-key "Revocation test (throwaway) <rev@invalid>" rsa3072 cert never
P=$(gpg --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')
g --faked-system-time "$(ago 800)" --quick-add-key "$P" rsa3072 sign "$(date -u -d "400 days" +%F)"
A=$(gpg --batch --with-colons --list-keys "$P" | awk -F: '$1=="sub"{s=1;next} s&&$1=="fpr"{print $10; exit}')
gpg --batch --armor --export "$P" > /w/first.asc
SIGN_FPR=$A FAKED_TIME=$(ago 500) bash /src/build/linux/repo/test/sign-test-rpm.sh /w/a.rpm >/dev/null
g --faked-system-time "$(ago 300)" --quick-set-expire "$P" never "$A"
g --faked-system-time "$(ago 300)" --quick-add-key "$P" rsa3072 sign never
S=$(gpg --batch --with-colons --list-keys "$P" | awk -F: '$1=="sub"{n++} n==2&&$1=="fpr"{print $10; exit}')
SIGN_FPR=$S bash /src/build/linux/repo/test/sign-test-rpm.sh /w/s.rpm >/dev/null
echo a > /w/a.txt; echo s > /w/s.txt
g --local-user "$A!" --clearsign -o /w/a.txt.asc /w/a.txt; g --local-user "$S!" --clearsign -o /w/s.txt.asc /w/s.txt
gpg --batch --armor --export "$P" > /w/rebound.asc
python3 "$merge" --output /w/before.asc /w/first.asc /w/rebound.asc 2>/dev/null
printf 'key 1\nrevkey\ny\n1\n\ny\nsave\n' | gpg --batch --command-fd 0 --pinentry-mode loopback --passphrase "" --edit-key "$P" >/dev/null 2>&1
gpg --batch --armor --export "$P" > /w/revoked-only.asc
# The README: the published key first, then the owner's new export.
python3 "$merge" --output /w/revoked.asc /w/before.asc /w/revoked-only.asc
python3 "$merge" --drop-revoked-subkeys --output /w/without-revoked.asc /w/revoked.asc
# The revocation in front of both bindings.
python3 - "$merge" /w/revoked.asc /w/revfirst.asc <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('m', sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
key = m.Key('k', m.dearmor('k', open(sys.argv[2], 'rb').read()))
for c in key.subkeys():
    c[2] = [s for s in c[2] if m.sigtype(s[1]) == 0x28] + [s for s in c[2] if m.sigtype(s[1]) != 0x28]
open(sys.argv[3], 'w').write(m.armor(key.bytes()))
PY
for f in before revoked-only revoked revfirst without-revoked; do
  echo "$f.asc: $(gpg --batch --list-packets /w/$f.asc | grep -o 'sigclass 0x[0-9a-f]*' | sed 's/sigclass //' | paste -sd ' ' -)"
done
echo "$A" > /w/A; echo "$S" > /w/S
EOF
docker build -q -t eo-repo-builder:test -f "$here/builder.Dockerfile" "$here" >/dev/null
docker run --rm -v "$src_root:/src:ro" -v "$w:/w" eo-repo-builder:test bash /w/make-keys.sh

cat > "$w/rpm-client.sh" <<'EOF'
#!/bin/bash
# fresh:    import revoked.asc (the README's merge) on a fresh system
# gpg:      import revoked-only.asc on a fresh system: the owner's plain gpg
#           export after the revocation (revocation first, new binding only)
# revfirst: the revocation in front of both bindings
# update:   before.asc imported, then revoked.asc
# remedy:   before.asc imported, then the advisory for rpm: the key removed
#           and imported without the revoked subkey (rpm 6 warns that
#           erasing gpg-pubkey is deprecated, and does it)
. /etc/os-release
rpm -qa >/dev/null 2>&1
k() { r=$(rpm --dbpath "$1" -K "$2" 2>&1); if [[ $r == *"signatures OK"* ]]; then echo accepted; else echo rejected; fi; }
for mode in fresh gpg revfirst update remedy; do
  db=/tmp/db-$mode; mkdir -p $db; rpm --dbpath $db --initdb
  case $mode in
    fresh) imp=$(rpm --dbpath $db --import /w/revoked.asc 2>&1); rc=$? ;;
    gpg) imp=$(rpm --dbpath $db --import /w/revoked-only.asc 2>&1); rc=$? ;;
    revfirst) imp=$(rpm --dbpath $db --import /w/revfirst.asc 2>&1); rc=$? ;;
    update) rpm --dbpath $db --import /w/before.asc; imp=$(rpm --dbpath $db --import /w/revoked.asc 2>&1); rc=$? ;;
    remedy) rpm --dbpath $db --import /w/before.asc
            imp=$(rpm --dbpath $db -e $(rpm --dbpath $db -q gpg-pubkey) 2>&1 &&
                  rpm --dbpath $db --import /w/without-revoked.asc 2>&1); rc=$? ;;
  esac
  imp=$(grep -vE "Rebuilding outdated index databases|Generating [0-9]+ missing index" <<<"$imp")
  echo "$ID $VERSION_ID $(rpm --version | sed 's/RPM version //') $mode: import rc=$rc$( [ -z "$imp" ] || printf ' (%s)' "$(tr '\n' ' ' <<<"$imp" | sed 's/ *$//')"), keys $(rpm --dbpath $db -q gpg-pubkey 2>/dev/null | grep -c '^gpg-pubkey'), A's package $(k $db /w/a.rpm), S's package $(k $db /w/s.rpm)"
done
EOF
chmod +x "$w/rpm-client.sh"
echo "### rpm clients"
for img in fedora:43 rockylinux/rockylinux:9 almalinux:10 opensuse/leap:15.6 opensuse/tumbleweed; do
  out=$(docker run --rm --pull missing -v "$w:/w:ro" "$img" /w/rpm-client.sh 2>&1)
  echo "$out"
  grep -q " fresh: import rc=0.*S's package accepted$" <<<"$out" || fail "$img: a fresh system does not import the merged key or verify the spare's package"
  grep -q " update: .*S's package accepted$" <<<"$out" || fail "$img: an updated system does not verify the spare's package"
  grep -q " remedy: import rc=0.*, keys 1, A's package rejected, S's package accepted$" <<<"$out" \
    || fail "$img: the advisory's remedy (the key without the revoked subkey) does not reject A's package or does not accept S's"
  case $img in
    fedora:*|opensuse/tumbleweed) grep -q " fresh: .*A's package rejected" <<<"$out" || fail "$img: accepts A's package although A is revoked" ;;
  esac
done

echo "### apt verifiers"
cat > "$w/apt-client.sh" <<'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
apt-get update -qq >/dev/null
if [ "$ID" = debian ]; then
  apt-get install -y -qq sqv >/dev/null 2>&1
  v() { local e; if e=$(sqv --keyring /w/revoked.asc --cleartext --output "$(mktemp -u)" "$1" 2>&1 >/dev/null); then echo accepted; else echo "rejected ($(tr '\n' ' ' <<<"$e" | sed 's/ *$//'))"; fi; }
  tool="sqv $(sqv --version | awk '{print $2; exit}')"
else
  apt-get install -y -qq gpgv gnupg >/dev/null 2>&1
  gpg --batch --dearmor < /w/revoked.asc > /tmp/k.gpg
  # As apt reads gpgv: only GOODSIG counts; a revoked or expired key gives
  # REVKEYSIG or EXPKEYSIG instead (gpgv still exits 0).
  v() { local st; st=$(gpgv --status-fd 1 --keyring /tmp/k.gpg "$1" 2>/dev/null)
        if grep -q '^\[GNUPG:\] GOODSIG ' <<<"$st"; then echo accepted
        else echo "rejected ($(grep -oE '(REVKEYSIG|EXPKEYSIG|BADSIG|ERRSIG|NO_PUBKEY)' <<<"$st" | sort -u | paste -sd ' ' -))"; fi; }
  tool="gpgv $(gpgv --version | awk 'NR==1{print $3}')"
fi
echo "$ID $VERSION_ID $tool: A's signature $(v /w/a.txt.asc), S's signature $(v /w/s.txt.asc)"
EOF
chmod +x "$w/apt-client.sh"
for img in ubuntu:24.04 debian:13; do
  out=$(docker run --rm --pull missing -v "$w:/w:ro" "$img" /w/apt-client.sh 2>&1)
  echo "$out"
  grep -q "A's signature rejected.*, S's signature accepted$" <<<"$out" || fail "$img: expected A rejected and S accepted"
done

echo
if [ $fails = 0 ]; then echo "### revocation: all passed"; else echo "### revocation: $fails FAILED"; exit 1; fi
