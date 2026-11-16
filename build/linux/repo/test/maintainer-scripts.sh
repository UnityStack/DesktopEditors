#!/usr/bin/env bash
# Runs the package scripts that register the package repository, built the
# way build/.docker/packages.bake.Dockerfile builds them (desktop-apps/package,
# the build/linux/package/ overlay, package.patch with --fuzz=0) and with the
# defaults of fork.mk, in a throwaway container:
#   maintainer-scripts.sh deb <DesktopEditors checkout>   (debian:13)
#   maintainer-scripts.sh rpm <DesktopEditors checkout>   (fedora:43)
# deb: postinst writes the .sources file and UnityStack's keyring; a purge
# removes the keyring only when no apt source names it any more, also when
# a second UnityStack product shares it. rpm: %post writes the .repo file
# with the channel's URL and the unitystack key, erase removes it and keeps
# the imported key (gpg-pubkey).
# The E2E clients install a release that predates these scripts, so this is
# their only test. Prints one "ok" line per check and exits non-zero on the
# first failure.
set -euo pipefail
kind=$1 src=$2
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

case "$kind" in
  deb) export DEBIAN_FRONTEND=noninteractive
       { apt-get -qq update && apt-get -qq install -y m4 patch; } >/dev/null 2>&1 || fail "apt-get install m4 patch" ;;
  rpm) dnf -y -q install rpm-build patch >/dev/null 2>&1 || fail "dnf install rpm-build patch" ;;
  *) fail "unknown kind '$kind' (deb or rpm)" ;;
esac

pkg=/tmp/package
cp -R "$src/desktop-apps/package" "$pkg"
cp -R "$src/build/linux/package/." "$pkg/"
cp "$src/build/linux/unitystack-package-signing.asc" "$pkg/common/linux/unitystack.asc"
(cd "$pkg" && patch -s -p1 --forward --fuzz=0 < "$src/build/linux/package.patch")
default() { sed -n "s/^$1 ?= //p" "$pkg/fork.mk"; }
repo_url=$(default REPO_URL) repo_name=$(default REPO_NAME)
key_url=$(default REPO_KEY_URL) key_name=$(default REPO_KEY_NAME)
[ "$repo_url $repo_name $key_url $key_name" = \
  "https://packages.unitystack.eu/euro-office euro-office https://packages.unitystack.eu/keys/unitystack.asc unitystack" ] \
  || fail "fork.mk defaults: $repo_url $repo_name $key_url $key_name"
key=$pkg/common/linux/$key_name.asc
a=euro-office-euro-office

if [ "$kind" = deb ]; then
  kr=/usr/share/keyrings/$key_name.asc
  sources=/etc/apt/sources.list.d/$repo_name.sources
  # build_deb <package> <repository name> <repository URL>: only the
  # scripts, rendered with the macros fork.mk adds.
  build_deb() {
    local d=/tmp/deb/$1 s
    mkdir -p "$d/DEBIAN"
    for s in postinst postrm; do
      m4 -D M4_PACKAGE_NAME="$1" -D M4_PACKAGE_VERSION=9.3.7-0~ce -D M4_COMPANY_NAME_LOW="$1" \
         -D M4_DESKTOPEDITORS_PREFIX="$1/desktopeditors" -D M4_REPO_URL="$3" -D M4_REPO_NAME="$2" \
         -D M4_REPO_KEY="$key" -D M4_REPO_KEY_NAME="$key_name" "$pkg/deb/template/$s.m4" > "$d/DEBIAN/$s"
      chmod 755 "$d/DEBIAN/$s"
    done
    printf 'Package: %s\nVersion: 9.3.7-0~ce\nArchitecture: all\nMaintainer: test <t@invalid>\nDescription: test\n test\n' \
      "$1" > "$d/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$d" "/tmp/deb/$1.deb" >/dev/null
  }
  # A second UnityStack product with its own repository and the same key.
  b=unitystack-other
  build_deb "$a" "$repo_name" "$repo_url"
  build_deb "$b" other https://packages.unitystack.eu/other

  dpkg -i "/tmp/deb/$a.deb" >/dev/null
  grep -qx "URIs: $repo_url/apt" "$sources" && grep -qx 'Suites: stable' "$sources" &&
    grep -qx "Signed-By: $kr" "$sources" || fail "$sources: $(cat "$sources")"
  cmp -s "$kr" "$key" || fail "$kr is not the committed key"
  ok "install: $sources (URIs $repo_url/apt, stable, Signed-By $kr) and the keyring"

  dpkg -i "/tmp/deb/$b.deb" >/dev/null
  dpkg -P "$a" >/dev/null
  [ ! -e "$sources" ] && [ ! -e "/etc/default/$repo_name" ] || fail "purge left $sources or /etc/default/$repo_name"
  [ -e "$kr" ] || fail "purge removed the keyring that other.sources names"
  dpkg -P "$b" >/dev/null
  [ ! -e "$kr" ] || fail "the purge of its last user kept the keyring"
  ok "purge: the keyring stays while another product's source names it and goes with the last one"

  dpkg -i "/tmp/deb/$a.deb" "/tmp/deb/$b.deb" >/dev/null
  dpkg -r "$a" >/dev/null
  [ -e "$sources" ] && [ -e "$kr" ] || fail "remove deleted $sources or the keyring"
  dpkg -P "$b" >/dev/null
  [ -e "$kr" ] || fail "keyring removed while the removed (not purged) $a's source names it"
  dpkg -P "$a" >/dev/null
  [ ! -e "$sources" ] && [ ! -e "$kr" ] || fail "the last purge left $sources or the keyring"
  ok "remove keeps source and keyring, a purge in the other order keeps the keyring until the last"

  dpkg -i "/tmp/deb/$a.deb" >/dev/null
  echo "deb [signed-by=$kr] https://example.invalid/apt stable main" > /etc/apt/sources.list.d/own.list
  dpkg -P "$a" >/dev/null
  [ -e "$kr" ] || fail "purge removed the keyring an admin's own.list names"
  rm /etc/apt/sources.list.d/own.list "$kr"
  ok "purge keeps the keyring that an admin's own .list names"

  : > "/etc/default/$repo_name"
  dpkg -i "/tmp/deb/$a.deb" >/dev/null
  [ ! -e "$sources" ] && [ ! -e "$kr" ] || fail "opted out, yet $sources or the keyring was written"
  echo stale > "$kr"
  dpkg -i "/tmp/deb/$a.deb" >/dev/null
  cmp -s "$kr" "$key" || fail "opted out: an existing keyring was not rewritten"
  dpkg -P "$a" >/dev/null
  [ -e "/etc/default/$repo_name" ] && [ ! -s "/etc/default/$repo_name" ] && [ ! -e "$kr" ] \
    || fail "purge after an opt-out: the opt-out must stay, the unused keyring go"
  ok "opted out: no source, an existing keyring is rewritten; purge keeps the opt-out"
fi

if [ "$kind" = rpm ]; then
  top=/tmp/rpmbuild
  mkdir -p "$top/SPECS"
  {
    cat <<'EOF'
Name: %{_package_name}
Version: 9.3.7
Release: 0~ce
Summary: maintainer script test
License: CC0-1.0
BuildArch: noarch
%description
maintainer script test
%install
install -m 644 -D %{_key_file} %{buildroot}%{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-%{_repo_key_name}
%files
EOF
    grep -x '%attr(644, root, root) %{_sysconfdir}/pki/rpm-gpg/RPM-GPG-KEY-%{_repo_key_name}' "$pkg/rpm/common.spec" \
      || fail "common.spec does not ship RPM-GPG-KEY-%{_repo_key_name}"
    echo
    sed -n '/^%post$/,/^%changelog$/p' "$pkg/rpm/common.spec"
    printf '* Tue Nov 03 2026 test <t@invalid> - 9.3.7-0~ce\n- test\n'
  } > "$top/SPECS/test.spec"
  grep -q '^%postun$' "$top/SPECS/test.spec" || fail "no %post/%postun in common.spec"
  rpmbuild -bb --quiet --define "_topdir $top" --define "_key_file $key" \
    --define "_package_name $a" --define '_company_name Euro-Office' \
    --define '_publisher_name UnityStack GmbH' --define "_repo_url $repo_url" \
    --define "_repo_name $repo_name" --define "_repo_key_url $key_url" \
    --define "_repo_key_name $key_name" "$top/SPECS/test.spec" >/dev/null
  rpm --import "$key"
  keys=$(rpm -q gpg-pubkey | sort)
  rpm -i "$top"/RPMS/noarch/*.rpm
  repo=/etc/yum.repos.d/$repo_name.repo
  grep -qx "baseurl=$repo_url/rpm/stable/" "$repo" &&
    grep -qx "gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-$key_name $key_url" "$repo" || fail "$repo: $(cat "$repo")"
  cmp -s "/etc/pki/rpm-gpg/RPM-GPG-KEY-$key_name" "$key" || fail "RPM-GPG-KEY-$key_name is not the committed key"
  ok "install: $repo (baseurl $repo_url/rpm/stable/, gpgkey= RPM-GPG-KEY-$key_name and $key_url)"
  rpm -e "$a"
  [ ! -e "$repo" ] && [ ! -e "/etc/default/$repo_name" ] || fail "erase left $repo or /etc/default/$repo_name"
  [ "$(rpm -q gpg-pubkey | sort)" = "$keys" ] || fail "erase removed the imported key"
  ok "erase: .repo and defaults removed, the imported key (gpg-pubkey) kept"
fi
