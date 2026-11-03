#!/usr/bin/env bash
# Runs inside a Debian/Ubuntu container: sets the repository up the way the
# README tells users to, then installs from it.
#   client-apt.sh <base url> <suite> <key fingerprint> <full|download> [appstream]
# Fails on any apt warning about the repository; never uses trusted=yes or
# --allow-unauthenticated, so the package can only come from a verified index.
set -euo pipefail
base=$1 suite=$2 fpr=$3 mode=$4 appstream=${5:-}
export DEBIAN_FRONTEND=noninteractive
pkgs=(ca-certificates curl gpg)
[ -n "$appstream" ] && pkgs+=(appstream)
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >/dev/null
. /etc/os-release; echo "== $PRETTY_NAME, $(apt-get --version | head -n1)"

curl -fsS -o /usr/share/keyrings/euro-office.asc "$base/keys/euro-office.asc"
got=$(gpg --batch --with-colons --show-keys /usr/share/keyrings/euro-office.asc | awk -F: '$1=="fpr"{print $10; exit}')
[ "$got" = "$fpr" ] || { echo "FAIL: key fingerprint $got, expected $fpr"; exit 1; }
echo "ok   key fingerprint $got"

# Software centres (GNOME Software, App Center) switch the DEP-11 icon
# downloads on; a bare container has them off.
if [ -n "$appstream" ]; then
  echo 'Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled "true";
Acquire::IndexTargets::deb::DEP-11-icons-large::DefaultEnabled "true";' > /etc/apt/apt.conf.d/99euro-office-test-icons
fi

src=euro-office.sources; [ "$suite" = testing ] && src=euro-office-testing.sources
curl -fsS -o /etc/apt/sources.list.d/euro-office.sources "$base/apt/$src"
grep -q '^Signed-By: /usr/share/keyrings/euro-office.asc$' /etc/apt/sources.list.d/euro-office.sources
apt-get update 2>&1 | tee /tmp/update.log | grep -i 'euro-office' || true
if grep -E '^(W|E|Err):' /tmp/update.log; then echo "FAIL: apt update reported problems"; exit 1; fi
grep -q "InRelease" /tmp/update.log
echo "ok   apt update verified InRelease ($suite)"

cand=$(apt-cache policy euro-office-euro-office | awk '/Candidate:/{print $2}')
[ -n "$cand" ] && [ "$cand" != "(none)" ] || { echo "FAIL: no candidate"; exit 1; }
echo "ok   candidate $cand"

if [ "$mode" = full ]; then
  apt-get install -y -q euro-office-euro-office > /tmp/install.log 2>&1 || { tail -30 /tmp/install.log; exit 1; }
  dpkg -s euro-office-euro-office | grep -q '^Status: install ok installed'
  echo "ok   installed $(dpkg-query -W -f '${Version}' euro-office-euro-office)"
else
  apt-get install -y -q --download-only euro-office-euro-office > /tmp/install.log 2>&1 || { tail -30 /tmp/install.log; exit 1; }
  deb=$(ls /var/cache/apt/archives/euro-office-euro-office_*.deb)
  echo "ok   downloaded $(basename "$deb") ($(stat -c %s "$deb") bytes)"
fi
grep -E "^Get:.*euro-office-euro-office " /tmp/install.log

if [ -n "$appstream" ]; then
  appstreamcli refresh-cache --force >/dev/null 2>&1 || true
  appstreamcli get --details org.euro_office.desktopeditors | tee /tmp/as.txt
  grep -q 'UnityStack GmbH' /tmp/as.txt || { echo "FAIL: no developer in AppStream"; exit 1; }
  grep -q 'AGPL-3.0-only' /tmp/as.txt || { echo "FAIL: no license in AppStream"; exit 1; }
  for s in 64x64 128x128; do
    f=$(ls /var/lib/swcatalog/icons/euro-office-*-main/$s/euro-office-euro-office_euro-office-euro-office.png)
    echo "ok   cached icon $f"
  done
  echo "ok   AppStream: developer and license from the repository's DEP-11 data"
fi
