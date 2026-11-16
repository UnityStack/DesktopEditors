#!/usr/bin/env bash
# Imports LINUX_GPG_PRIVATE_KEY (the secret of the one signing subkey CI
# holds, from the GitHub environment "signing") into $RUNNER_TEMP/gnupg and
# checks it with build/linux/select-signing-subkey.sh. The "Import the
# signing key" steps of signing-preflight, sign-linux and publish-repo in
# .github/workflows/build.yml run it from the repository root, with the
# options they pass on to that script (--after-build in sign-linux and
# publish-repo, --released <dir> in signing-preflight). Later steps get,
# through $GITHUB_ENV:
#
#   GNUPGHOME            the keyring
#   PRIMARY_FPR          the primary key (its secret is only a stub)
#   SIGN_FPR             the signing subkey; pass it to gpg as "$SIGN_FPR!"
#   VERIFY_KEY           the public key to verify against (PUBLIC_KEY_FILE)
#   GPG_PASSPHRASE_FILE  only with LINUX_GPG_PASSPHRASE: for --passphrase-file
#
# Environment: LINUX_GPG_PRIVATE_KEY, LINUX_GPG_PASSPHRASE (optional),
# PUBLIC_KEY_FILE, RUNNER_TEMP, GITHUB_ENV, and what
# select-signing-subkey.sh reads (LINUX_GPG_SIGN_SUBKEY, ...). The designation
# of CI's subkey, build/linux/unitystack-package-signing.ci-subkey, is found
# next to PUBLIC_KEY_FILE.
set -euo pipefail
umask 077
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "${LINUX_GPG_PRIVATE_KEY:-}" ]; then
  echo "::error::Secret LINUX_GPG_PRIVATE_KEY is empty or missing in the 'signing' environment (see build/linux/README.md)."
  exit 1
fi
case "$LINUX_GPG_PRIVATE_KEY" in
  *'-----BEGIN PGP PRIVATE KEY BLOCK-----'*) ;;
  *) echo "::error::LINUX_GPG_PRIVATE_KEY is not an ASCII-armored secret key (gpg --export-secret-subkeys --armor)."
     exit 1 ;;
esac

export GNUPGHOME="$RUNNER_TEMP/gnupg"
mkdir -p "$GNUPGHOME"
echo allow-loopback-pinentry > "$GNUPGHOME/gpg-agent.conf"
pass_args=()
if [ -n "${LINUX_GPG_PASSPHRASE:-}" ]; then
  printf '%s' "$LINUX_GPG_PASSPHRASE" > "$GNUPGHOME/passphrase"
  pass_args=(--pinentry-mode loopback --passphrase-file "$GNUPGHOME/passphrase")
  echo "GPG_PASSPHRASE_FILE=$GNUPGHOME/passphrase" >> "$GITHUB_ENV"
fi
gpg --batch --quiet "${pass_args[@]}" --import <<<"$LINUX_GPG_PRIVATE_KEY"

# Exactly one primary key, without its secret: CI only holds a signing
# subkey. The primary key's secret stays offline; with it, a leak of the CI
# secrets could not be repaired by revoking a subkey.
colons=$(gpg --batch --with-colons --list-secret-keys)
if [ "$(grep -c '^sec:' <<<"$colons")" -ne 1 ]; then
  echo "::error::LINUX_GPG_PRIVATE_KEY must contain exactly one key."
  exit 1
fi
read -r primary_fpr primary_stub < <(awk -F: '
  $1 == "sec" { stub = ($15 == "#"); rec = 1; next }
  $1 == "fpr" && rec { print $10, stub; exit }' <<<"$colons")
if [ "$primary_stub" != 1 ]; then
  echo "::error::LINUX_GPG_PRIVATE_KEY contains the secret of the primary key. It must hold only the signing subkey CI uses: export it as in build/linux/README.md, \"Exporting the CI subkey\", and replace the secret."
  exit 1
fi
echo "Primary key: $primary_fpr"

# Checks run against the published public key when it is committed, so a
# secret that does not match it fails here, not for users.
gpg --batch --armor --export "$primary_fpr" > "$RUNNER_TEMP/signing-key.asc"
key=$PUBLIC_KEY_FILE
if [ ! -f "$key" ]; then
  echo "::warning::$PUBLIC_KEY_FILE is not committed yet; verifying against the imported key."
  key=$RUNNER_TEMP/signing-key.asc
fi
cp "$key" "$RUNNER_TEMP/verify-key.asc"

# The signing subkey, checked against the committed and the published key
# (see "Signing key" in build/linux/README.md). --after-build lowers the
# validity a subkey with an expiry needs by RERUN_DAYS, so that a re-run of
# sign-linux or publish-repo does not fail on a subkey the preflight of the
# same run accepted. "<fpr>!" makes gpg use that exact subkey.
sign_fpr=$(PUBLIC_KEY_FILE=$key bash "$here/select-signing-subkey.sh" "$@")
echo "Signing subkey: $sign_fpr"

{
  echo "GNUPGHOME=$GNUPGHOME"
  echo "PRIMARY_FPR=$primary_fpr"
  echo "SIGN_FPR=$sign_fpr"
  echo "VERIFY_KEY=$RUNNER_TEMP/verify-key.asc"
} >> "$GITHUB_ENV"
