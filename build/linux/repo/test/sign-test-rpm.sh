#!/usr/bin/env bash
# Builds a small noarch RPM and signs it the way sign-linux does (rpmsign
# with %_gpg_name "$SIGN_FPR!"), so the rpm clients of run.sh can check a
# package signature of the throwaway key (make-key.sh):
#
#   sign-test-rpm.sh <output.rpm>
#
# Runs in the builder image; GNUPGHOME and SIGN_FPR as for publish-repo.sh.
# FAKED_TIME (gpg --faked-system-time, e.g. 20240101T120000!) dates the
# signature: make-key.sh signs one before it re-binds the subkey.
set -euo pipefail
out=$1
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
mkdir -p "$w/SPECS"
cat > "$w/SPECS/t.spec" <<'SPEC'
Name: euro-office-subkey-test
Version: 1
Release: 1
Summary: Signed by a signing subkey of a throwaway key (test only)
License: MIT
BuildArch: noarch
%description
Test only: carries a package signature of a throwaway signing subkey.
%files
SPEC
rpmbuild --quiet -bb --define "_topdir $w" --define '_build_id_links none' "$w/SPECS/t.spec" >/dev/null 2>&1
rpm=$(ls "$w"/RPMS/noarch/*.rpm)
{
  echo "%__gpg $(command -v gpg)"
  echo "%_gpg_path $GNUPGHOME"
  echo "%_gpg_name $SIGN_FPR!"
  echo "%_gpg_digest_algo sha256"
  echo "%_gpg_sign_cmd_extra_args --batch${FAKED_TIME:+ --faked-system-time $FAKED_TIME}"
} > "$w/.rpmmacros"
HOME=$w rpmsign --addsign "$rpm" >/dev/null
cp "$rpm" "$out"
echo "signed $(basename "$rpm") with $SIGN_FPR"
