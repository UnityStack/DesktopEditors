#!/usr/bin/env bash
# Runs inside an openSUSE container:
#   client-zypper.sh <base url> <key url> <channel> <key fingerprint> <full|download> [extra key file] [test rpm] [its signing subkey]
# zypper checks repomd.xml.asc against the keys in the rpm database and
# refuses unsigned or badly signed metadata (no --gpg-auto-import-keys,
# no --no-gpg-checks). The key is imported the way the README tells users
# to: rpm --import of its published URL, after checking its fingerprint.
set -euo pipefail
base=$1 key_url=$2 channel=$3 fpr=$4 mode=$5 extra=${6:-} test_rpm=${7:-} sub_fpr=${8:-}
. /etc/os-release; echo "== $PRETTY_NAME, $(rpm --version), $(zypper --version)"
zypper -n -q install -y gpg2 curl >/dev/null

curl -fsS -o /tmp/unitystack.asc "$key_url"
got=$(gpg --batch --with-colons --show-keys /tmp/unitystack.asc | awk -F: '$1=="fpr"{print $10; exit}')
[ "$got" = "$fpr" ] || { echo "FAIL: key fingerprint $got, expected $fpr"; exit 1; }
echo "ok   key fingerprint $got"
rpm --import "$key_url"
rpm -q gpg-pubkey --qf '%{VERSION}-%{RELEASE} %{SUMMARY}\n' | grep -i "${fpr: -8}" \
  || { echo "FAIL: rpm --import $key_url added no key ${fpr: -8}"; exit 1; }
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
curl -fsS -o /tmp/repo "$base/rpm/$repo"
grep -qx "gpgkey=$key_url" /tmp/repo || { echo "FAIL: the .repo's gpgkey= is not $key_url"; exit 1; }
zypper -n addrepo "$base/rpm/$repo"
id=$(sed -n 's/^\[\(.*\)\]$/\1/p' /tmp/repo)
zypper -n refresh -r "$id" 2>&1 | tee /tmp/refresh.log
grep -q "Repository '.*' is up to date\|All repositories have been refreshed\|Retrieving repository" /tmp/refresh.log
if grep -iE 'unsigned|signature verification failed|not trusted|error' /tmp/refresh.log; then echo "FAIL: refresh"; exit 1; fi
echo "ok   repomd.xml signature verified"

# "(rp)": repomd.xml AND package signatures are checked. Without
# pkg_gpgcheck=1 zypper shows "(r )" and installs a package whose key it
# does not know, with only a warning.
zypper lr -d "$id" | grep -E '^GPG Check +: \(rp\) Yes' || { zypper lr -d "$id"; echo "FAIL: package signature check off"; exit 1; }
zypper -n search -s -r "$id" euro-office-euro-office
if [ "$mode" = full ] && [ "${SHIM_MISSING:-}" = 1 ]; then
  # Only for releases whose RPM still requires Fedora package names
  # (v9.3.6-ce.rc.1; package.patch fixes the Requires for later builds):
  # a test-only, unsigned noarch package provides exactly the requirements
  # nothing in this distribution provides, so the real package can still
  # go through the signed repository and zypper's package signature check.
  missing=()
  while IFS= read -r r; do
    case "$r" in rpmlib\(*|/*|'') continue ;; esac
    zypper -n -q --no-refresh search --match-exact --provides "${r%% *}" >/dev/null 2>&1 || missing+=("$r")
  done < <(zypper -n -q --no-refresh info --requires -r "$id" euro-office-euro-office \
             | sed -n '/^Requires *:/,/^[A-Za-z]/{/^ /s/^ *//p}')
  if [ ${#missing[@]} -gt 0 ]; then
    echo "WORKAROUND (test only): the package requires ${#missing[@]} names openSUSE does not have: ${missing[*]}"
    zypper -n -q install -y rpm-build >/dev/null
    mkdir -p /tmp/shim/SPECS
    { printf 'Name: eo-test-requires-shim\nVersion: 1\nRelease: 1\nSummary: test only\nLicense: CC0-1.0\nBuildArch: noarch\n'
      for r in "${missing[@]}"; do
        case "$r" in *' >= '*) printf 'Provides: %s = %s\n' "${r%% *}" "${r##* }" ;; *) printf 'Provides: %s\n' "$r" ;; esac
      done
      printf '%%description\ntest only\n%%files\n'; } > /tmp/shim/SPECS/shim.spec
    rpmbuild -bb --quiet --define '_topdir /tmp/shim' /tmp/shim/SPECS/shim.spec
    rpm -i /tmp/shim/RPMS/noarch/eo-test-requires-shim-1-1.noarch.rpm
  fi
fi
if [ "$mode" = full ]; then
  # The dependencies come from the distribution's repositories. pkg_gpgcheck
  # (from gpgcheck=1) makes zypper check the package signature before it
  # installs; an unknown key would be a prompt, which -n answers with no.
  zypper -n install euro-office-euro-office > /tmp/install.log 2>&1 || { tail -40 /tmp/install.log; exit 1; }
  grep -E "Retrieving: euro-office-euro-office-|euro-office-euro-office-[^ ]*\.rpm" /tmp/install.log | head -n 3
  grep -iE 'unsigned|signature verification failed|not trusted|NOKEY|ignore' /tmp/install.log && { echo "FAIL: signature"; exit 1; }
  grep -E "Checking for file conflicts|\(1/|done\]" /tmp/install.log | tail -n 3
  rpm -q euro-office-euro-office
  rpm -q --qf '%{SIGPGP:pgpsig}%{RSAHEADER:pgpsig}\n' euro-office-euro-office
  echo "ok   installed $(rpm -q euro-office-euro-office) from $id with pkg_gpgcheck"
else
  zypper -n download euro-office-euro-office 2>&1 | tail -n 4
  rpmf=$(find /var/cache/zypp/packages -name 'euro-office-euro-office-*.rpm' | head -n1)
  [ -n "$rpmf" ] || { echo "FAIL: nothing downloaded"; exit 1; }
  rpm -K "$rpmf"
  rpm -K "$rpmf" | grep -qi 'pgp.*OK\|signatures OK' || { echo "FAIL: package signature"; exit 1; }
  echo "ok   downloaded $(basename "$rpmf") through the repository, rpm -K OK"
fi
