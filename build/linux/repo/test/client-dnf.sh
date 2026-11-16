#!/usr/bin/env bash
# Runs inside a Fedora/RHEL-family container (dnf5 or dnf4):
#   client-dnf.sh <base url> <key url> <channel> <key fingerprint> <full|download> [extra key file] [test rpm] [its signing subkey]
# The .repo has gpgcheck=1 and repo_gpgcheck=1, so dnf only reads verified
# metadata and installs only signed packages. The extra key is the real
# package-signing key: the rc.1 RPMs are signed with it, the test repository
# with a throwaway key.
set -euo pipefail
base=$1 key_url=$2 channel=$3 fpr=$4 mode=$5 extra=${6:-} test_rpm=${7:-} sub_fpr=${8:-}
. /etc/os-release; echo "== $PRETTY_NAME, $(rpm --version), dnf $(dnf --version 2>/dev/null | head -n1)"
command -v gpg >/dev/null || dnf -y -q install gnupg2 >/dev/null

curl -fsS -o /tmp/unitystack.asc "$key_url"
got=$(gpg --batch --with-colons --show-keys /tmp/unitystack.asc | awk -F: '$1=="fpr"{print $10; exit}')
[ "$got" = "$fpr" ] || { echo "FAIL: key fingerprint $got, expected $fpr"; exit 1; }
echo "ok   key fingerprint $got"
rpm --import /tmp/unitystack.asc
[ -n "$extra" ] && rpm --import "$extra"

# A package signature of the throwaway key's subkey 1 (CI's), made before
# the subkey was re-bound, checked against the key imported once above:
# rpm -K needs "signatures OK" (rpm 6 checks the binding valid at signature
# time, so the key must still carry the old one), and the signature's
# issuer must be that subkey (rpm 6's -Kv names the primary key, rpm 4's
# the subkey, so ask the header).
if [ -n "$test_rpm" ]; then
  k=$(rpm -K "$test_rpm" 2>&1) || true
  issuer=$(rpm -qp --qf '%{RSAHEADER:pgpsig}' "$test_rpm" 2>/dev/null) || true
  echo "$k ($issuer)"
  [[ $k == *"signatures OK"* ]] && grep -qi "Key ID ${sub_fpr: -16}\$" <<<"$issuer" \
    || { echo "FAIL: rpm -K of the test RPM signed by subkey $sub_fpr: $k ($issuer)"; exit 1; }
  echo "ok   rpm -K: package signature of signing subkey ${sub_fpr: -16}, made before its re-binding, verified"
fi

repo=euro-office.repo; [ "$channel" = testing ] && repo=euro-office-testing.repo
curl -fsS -o "/etc/yum.repos.d/$repo" "$base/rpm/$repo"
grep -qx 'repo_gpgcheck=1' "/etc/yum.repos.d/$repo"
grep -qx "gpgkey=$key_url" "/etc/yum.repos.d/$repo" || { echo "FAIL: the .repo's gpgkey= is not $key_url"; exit 1; }
id=$(sed -n 's/^\[\(.*\)\]$/\1/p' "/etc/yum.repos.d/$repo")
# dnf keeps the keys for repo_gpgcheck in a keyring of its own (not the rpm
# database), so the first run reports the key missing, imports it from the
# gpgkey= URL (-y) and verifies again. That key must be ours, and a second
# run must verify without any import or error.
dnf -y --disablerepo='*' --enablerepo="$id" makecache 2>&1 | tee /tmp/makecache.log
if grep -q 'Fingerprint' /tmp/makecache.log; then
  imported=$(awk '/Fingerprint/{gsub(/ /,"",$0); sub(/.*:/,""); print; exit}' /tmp/makecache.log)
  # dnf5 and dnf 4.20 print the primary key's fingerprint, dnf 4.14 (EL9)
  # the first signing subkey's, even when that one has expired (the README
  # lists both).
  first=$(gpg --batch --with-colons --show-keys /tmp/unitystack.asc \
          | awk -F: '$1=="sub" && $12 ~ /s/ {s=1; next} s && $1=="fpr" {print $10; exit}')
  [ "$imported" = "$fpr" ] || [ "$imported" = "$first" ] \
    || { echo "FAIL: dnf showed key $imported, neither the primary key $fpr nor the first signing subkey $first"; exit 1; }
  echo "ok   dnf imported the repository key $imported from gpgkey="
fi
dnf -y --disablerepo='*' --enablerepo="$id" makecache --refresh 2>&1 | tee /tmp/makecache2.log
if grep -iE 'error|fail|not found|importing' /tmp/makecache2.log; then echo "FAIL: makecache"; exit 1; fi
echo "ok   repomd.xml signature verified (repo_gpgcheck=1)"

dnf -y --disablerepo='*' --enablerepo="$id" list --showduplicates euro-office-euro-office
if [ "$mode" = full ]; then
  # All repositories on: the dependencies come from the distribution. The
  # .repo's gpgcheck=1 makes dnf check the package signature against the
  # rpm database before it installs.
  dnf -y install euro-office-euro-office > /tmp/install.log 2>&1 || { tail -40 /tmp/install.log; exit 1; }
  grep -E "^ *euro-office-euro-office +[^ ]+ +[^ ]+ +$id " /tmp/install.log \
    || { grep -n euro-office /tmp/install.log; echo "FAIL: not installed from $id"; exit 1; }
  grep -iE 'nogpgcheck|not signed|signature.*(fail|bad)' /tmp/install.log && { echo "FAIL: signature"; exit 1; }
  rpm -q euro-office-euro-office
  rpm -q --qf '%{SIGPGP:pgpsig}%{RSAHEADER:pgpsig}\n' euro-office-euro-office
  echo "ok   installed $(rpm -q euro-office-euro-office) from $id with gpgcheck=1"
else
  if ! dnf download --help >/dev/null 2>&1; then dnf -y -q install dnf-plugins-core >/dev/null; fi
  cd /tmp
  dnf -y --disablerepo='*' --enablerepo="$id" download euro-office-euro-office 2>&1 | tail -n 3
  rpmf=$(ls /tmp/euro-office-euro-office-*.rpm)
  rpm -K "$rpmf"
  rpm -K "$rpmf" | grep -q 'signatures OK' || { echo "FAIL: package signature"; exit 1; }
  echo "ok   downloaded $(basename "$rpmf") through the repository, rpm -K OK"
fi
