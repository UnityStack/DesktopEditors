#!/usr/bin/env bash
# Creates a throwaway signing key with the real key's layout and history
# (build/linux/README.md, "Signing key") and writes its public part to $1:
#
#   make-key.sh <public key> [<old rpm>]
#
#   primary key   certify only, no expiry
#   subkey 1      created 800 days ago and bound with an expiry (in 400
#                 days); it signs <old rpm> 500 days ago; 300 days ago it is
#                 re-bound without expiry (gpg --quick-set-expire ... never).
#                 CI holds its secret and signs with it.
#   subkey 2      the spare: created 300 days ago, no expiry, secret offline
#
# The keyring then holds only subkey 1's newest binding, and so does a plain
# export of it (written to <public key>.rebound-only, the H2 breakage: rpm 6
# rejects <old rpm> with it). <public key> is merged the way the README says
# (build/linux/merge-public-key.py, the first export first) and carries both
# bindings. The dates come from gpg --faked-system-time. $GNUPGHOME receives
# only subkey 1's secret, exported the way LINUX_GPG_PRIVATE_KEY is (the
# primary key as a stub), and build/linux/select-signing-subkey.sh checks it
# as in CI. Prints subkey 1's fingerprint. RSA-3072 keeps key generation
# fast; the clients treat it like RSA-4096. Runs in the builder image (GNU
# date, rpm for <old rpm>).
set -euo pipefail
pub=$1 old_rpm=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
full=$(mktemp -d) merged=$(mktemp -d)
cleanup() {
  local h
  for h in "$full" "$merged"; do gpgconf --homedir "$h" --kill all 2>/dev/null || true; done
  rm -rf "$full" "$merged" "$pub.first"
}
trap cleanup EXIT
ago() { date -u -d "-$1 days" +%Y%m%dT%H%M%S!; }
in_days() { date -u -d "$1 days" +%F; }
g() { gpg --homedir "$full" --batch --quiet --passphrase '' --pinentry-mode loopback --cert-digest-algo SHA256 "$@"; }
fprs() { gpg --homedir "$full" --batch --with-colons --list-keys "$primary" | awk -F: '$1=="sub"{s=1;next} s&&$1=="fpr"{print $10;s=0}'; }

g --faked-system-time "$(ago 800)" \
  --quick-generate-key "Euro-Office repo test key (throwaway) <test@invalid>" rsa3072 cert never
primary=$(gpg --homedir "$full" --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}')
g --faked-system-time "$(ago 800)" --quick-add-key "$primary" rsa3072 sign "$(in_days 400)"
sub1=$(fprs | head -n 1)
gpg --homedir "$full" --batch --armor --export "$primary" > "$pub.first"
if [ -n "$old_rpm" ]; then
  GNUPGHOME=$full SIGN_FPR=$sub1 FAKED_TIME=$(ago 500) bash "$here/sign-test-rpm.sh" "$old_rpm" >&2
fi
g --faked-system-time "$(ago 300)" --quick-set-expire "$primary" never "$sub1"
g --faked-system-time "$(ago 300)" --quick-add-key "$primary" rsa3072 sign never
gpg --homedir "$full" --batch --armor --export "$primary" > "$pub.rebound-only"
python3 "$here/../../merge-public-key.py" --output "$pub" "$pub.first" "$pub.rebound-only"
n=$(gpg --homedir "$merged" --batch --list-packets "$pub" | grep -c 'sigclass 0x18')
[ "$n" = 3 ] || { echo "make-key.sh: $pub has $n subkey bindings, not 3 (subkey 1 twice, the spare)" >&2; exit 1; }

mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --homedir "$full" --batch --armor --export-secret-subkeys "$sub1!" | gpg --batch --quiet --import
# Not live: the real https://packages.unitystack.eu key must not be asked.
sign_fpr=$(PUBLIC_KEY_FILE=$pub TEST_KEY_URL=file:///nonexistent/unitystack.asc \
           bash "$here/../../select-signing-subkey.sh")
[ "$sign_fpr" = "$sub1" ] || { echo "select-signing-subkey.sh picked $sign_fpr, not subkey 1 ($sub1)" >&2; exit 1; }
echo "$sign_fpr"
