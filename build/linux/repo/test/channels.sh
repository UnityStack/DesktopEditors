#!/usr/bin/env bash
# Offline checks of publish-repo.sh with small fake packages: channels, the
# newest-$KEEP window, version order, idempotency, by-hash and repodata
# retention, asset matching and the failure paths (bad tag, foreign assets
# and key, damaged packages, the old 0~ce.rc.N scheme, duplicate versions,
# a newer .state format). Runs in the builder
# image (test/builder.Dockerfile), needs no network:
#   channels.sh <repo dir (build/linux/repo)>
# GNUPGHOME must hold the throwaway key from make-key.sh; SIGN_FPR and
# KEY_FILE as for publish-repo.sh.
set -euo pipefail
repo=$1
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT
site=$w/site
export KEEP=3
# rc.1 (0~ce.rc.1) stands in for the release with the old version scheme;
# the check that refuses it unsets this.
export ALLOW_OLD_SCHEME=1

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

# make_release <tag> <deb version> [digests: yes|no]
# Writes $w/pkgs/<tag>/ (local file names with "~") and $w/assets/<tag>.tsv
# (GitHub's names with "."), like a real release.
make_release() {
  local tag=$1 v=$2 digests=${3:-yes} d=$w/pkgs/$1 b=$w/build
  mkdir -p "$d" "$w/assets"
  for arch in amd64 arm64; do
    rm -rf "$b"; mkdir -p "$b/DEBIAN" "$b/usr/share/metainfo" \
      "$b/usr/share/icons/hicolor/64x64/apps" "$b/usr/share/icons/hicolor/128x128/apps"
    printf 'Package: euro-office-euro-office\nVersion: %s\nArchitecture: %s\nMaintainer: test <t@invalid>\nDescription: fake\n fake package for channels.sh\n' \
      "$v" "$arch" > "$b/DEBIAN/control"
    # The metainfo carries the full version so the DEP-11 checks can tell
    # releases apart.
    sed -e "s|@VERSION@|$v|" -e "s|@RELEASE_TYPE@|stable|" -e "s|@DATE@|2026-11-03|" \
      "$repo/templates/metainfo.xml.in" > "$b/usr/share/metainfo/org.euro_office.desktopeditors.metainfo.xml"
    printf '\x89PNG fake 64 %s' "$v" > "$b/usr/share/icons/hicolor/64x64/apps/euro-office-euro-office.png"
    printf '\x89PNG fake 128 %s' "$v" > "$b/usr/share/icons/hicolor/128x128/apps/euro-office-euro-office.png"
    dpkg-deb -Zxz --root-owner-group --build "$b" "$d/euro-office-euro-office_${v}_${arch}.deb" >/dev/null
  done
  # The help package, built once per arch like CI does. The two differ, and
  # only the first one is "uploaded" (see below).
  for n in 1 2; do
    rm -rf "$b"; mkdir -p "$b/DEBIAN" "$b/usr/share/doc/h"
    printf 'Package: euro-office-euro-office-help\nVersion: %s\nArchitecture: all\nMaintainer: test <t@invalid>\nDepends: euro-office-euro-office\nDescription: fake help\n fake\n' \
      "$v" > "$b/DEBIAN/control"
    echo "build $n" > "$b/usr/share/doc/h/build"
    mkdir -p "$d/arch$n"
    dpkg-deb -Zxz --root-owner-group --build "$b" "$d/arch$n/euro-office-euro-office-help_${v}_all.deb" >/dev/null
  done
  local rv=${v%%-*} rr=${v#*-}
  for arch in x86_64 aarch64; do
    mkdir -p "$w/rpmbuild/SPECS"
    cat > "$w/rpmbuild/SPECS/f.spec" <<EOF
Name: euro-office-euro-office
Version: $rv
Release: $rr
Summary: fake
License: AGPL-3.0-only
%description
fake
%files
EOF
    rpmbuild --quiet -bb --target "$arch" --define "_topdir $w/rpmbuild" \
      --define '_build_id_links none' "$w/rpmbuild/SPECS/f.spec" >/dev/null 2>&1
    mv "$w/rpmbuild/RPMS/$arch/"*.rpm "$d/"
  done
  : > "$w/assets/$tag.tsv"
  for f in "$d"/*.deb "$d"/*.rpm "$d/arch1/"*.deb; do
    local name digest
    name=$(basename "$f" | sed -E 's/[^A-Za-z0-9._-]/./g')
    digest="sha256:$(sha256sum "$f" | cut -d' ' -f1)"
    [ "$digests" = yes ] || digest=
    printf '%s\t%s\t%s\n' "$name" "$digest" "$(stat -c %s "$f")" >> "$w/assets/$tag.tsv"
  done
}

publish() {   # <tag> <channel>
  "$repo/publish-repo.sh" --tag "$1" --channel "$2" --packages "$w/pkgs/$1" --site "$site" \
    --asset-map "$w/assets/$1.tsv" --base-url http://packages.test --date 2026-11-03 2>"$w/log" \
    || { cat "$w/log" >&2; return 1; }
}
versions() {  # <suite> <arch>: versions of the main package in that index
  awk '/^Package: euro-office-euro-office$/{p=1} /^Package: /&&!/euro-office-euro-office$/{p=0} p&&/^Version:/{print $2}' \
    "$site/apt/dists/$1/main/binary-$2/Packages" | sort -u | tr '\n' ' '
}
rpm_versions() {  # <channel>
  local r=$site/rpm/$1
  zcat "$r/$(grep -o 'repodata/[^"]*primary.xml.gz' "$r/repodata/repomd.xml")" \
    | grep -o 'ver="[^"]*" rel="[^"]*"' | sed -E 's/ver="([^"]*)" rel="([^"]*)"/\1-\2/' | sort -u | tr '\n' ' '
}
dep11_version() {  # <suite>
  zcat "$site/apt/dists/$1/main/dep11/Components-amd64.yml.gz" \
    | awk '/^Releases:/{r=1} r&&/version:/{gsub(/"/,"",$3); print $3; exit}'
}
packages_gz_hash() { sha256sum "$site/apt/dists/testing/main/binary-amd64/Packages.gz" | cut -d' ' -f1; }

make_release v9.3.6-ce.rc.1 9.3.6-0~ce.rc.1
make_release v9.3.6-ce.rc.2 9.3.6-0~ce~rc.2 no   # assets without digest: name + size
make_release v9.3.6-ce      9.3.6-0~ce
make_release v9.3.6-ce.1    9.3.6-0~ce.1
make_release v9.3.7-ce.rc.1 9.3.7-0~ce~rc.1
make_release v9.3.7-ce-rc.1 9.3.7-0~ce~rc.1     # same version, another tag
make_release v9.3.7-ce.rc.2 9.3.7-0~ce~rc.2
make_release v9.3.8-ce.rc.1 9.3.8-0~ce~rc.1
ok "fake releases built"

# ── Failures leave the site alone ──
mkdir -p "$site"
echo keep > "$site/marker"
! "$repo/publish-repo.sh" --tag 'v1/../x' --channel stable --packages "$w/pkgs/v9.3.6-ce" \
    --site "$site" --asset-map "$w/assets/v9.3.6-ce.tsv" 2>/dev/null || fail "bad tag accepted"
! "$repo/publish-repo.sh" --tag v9.3.6-ce --channel stable --packages "$w/pkgs/v9.3.6-ce" \
    --site "$site" --asset-map "$w/assets/v9.3.6-ce.1.tsv" 2>/dev/null || fail "files of another release accepted"
! SIGN_FPR=0000000000000000000000000000000000000000 "$repo/publish-repo.sh" --tag v9.3.6-ce \
    --channel stable --packages "$w/pkgs/v9.3.6-ce" --site "$site" \
    --asset-map "$w/assets/v9.3.6-ce.tsv" 2>/dev/null || fail "foreign SIGN_FPR accepted"
! ALLOW_OLD_SCHEME='' "$repo/publish-repo.sh" --tag v9.3.6-ce.rc.1 --channel prerelease \
    --packages "$w/pkgs/v9.3.6-ce.rc.1" --site "$site" \
    --asset-map "$w/assets/v9.3.6-ce.rc.1.tsv" 2>"$w/log" || fail "0~ce.rc.1 accepted"
grep -q 'before the ~rc version scheme' "$w/log" || fail "0~ce.rc.1: $(cat "$w/log")"
# Damaged packages: a truncated .deb data member and an RPM with trailing
# bytes (as an overwritten upload would have), each with a matching asset.
mkdir -p "$w/pkgs/broken-deb" "$w/pkgs/broken-rpm"
cp "$w/pkgs/v9.3.6-ce/"*_amd64.deb "$w/pkgs/v9.3.6-ce/"*.x86_64.rpm "$w/pkgs/broken-deb/"
cp "$w/pkgs/v9.3.6-ce/"*_amd64.deb "$w/pkgs/v9.3.6-ce/"*.x86_64.rpm "$w/pkgs/broken-rpm/"
f=$(echo "$w/pkgs/broken-deb/"*.deb); truncate -s $(( $(stat -c %s "$f") - 40 )) "$f"
f=$(echo "$w/pkgs/broken-rpm/"*.rpm); head -c 144 "$w/pkgs/v9.3.6-ce/"*.aarch64.rpm >> "$f"
for b in broken-deb broken-rpm; do
  for f in "$w/pkgs/$b/"*; do
    printf '%s\t%s\t%s\n' "$(basename "$f" | sed -E 's/[^A-Za-z0-9._-]/./g')" \
      "sha256:$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c %s "$f")"
  done > "$w/assets/$b.tsv"
  ! "$repo/publish-repo.sh" --tag v9.3.6-ce --channel stable --packages "$w/pkgs/$b" --site "$site" \
      --asset-map "$w/assets/$b.tsv" 2>"$w/log" || fail "$b accepted"
  grep -q 'is damaged' "$w/log" || fail "$b: $(cat "$w/log")"
done
mkdir -p "$site/.state" && echo 2 > "$site/.state/format"
! "$repo/publish-repo.sh" --tag v9.3.6-ce --channel stable --packages "$w/pkgs/v9.3.6-ce" \
    --site "$site" --asset-map "$w/assets/v9.3.6-ce.tsv" 2>"$w/log" || fail "newer .state format accepted"
grep -q 'newer publish-repo.sh' "$w/log" || fail "format: $(cat "$w/log")"
rm -r "$site/.state"
[ "$(ls -A "$site")" = marker ] || fail "a failed run changed the site"
rm "$site/marker"
ok "bad tag, foreign assets and key, damaged packages, 0~ce.rc.N and a newer .state format fail without touching the site"

# ── Channels ──
publish v9.3.6-ce.rc.1 prerelease
h1=$(packages_gz_hash)
grep -q 'skipping .*arch2/euro-office-euro-office-help' "$w/log" || fail "duplicate help .deb not skipped"
grep -q "^Filename: pool/v9.3.6-ce.rc.1/euro-office-euro-office-help_9.3.6-0.ce.rc.1_all.deb$" \
  "$site/apt/dists/testing/main/binary-amd64/Packages" || fail "help .deb missing from amd64 index"
[ "$(versions stable amd64)" = "" ] || fail "prerelease in stable"
[ "$(versions testing arm64)" = "9.3.6-0~ce.rc.1 " ] || fail "testing: $(versions testing arm64)"
ok "prerelease goes to testing only; asset names use '.', the duplicate help .deb is skipped"

publish v9.3.6-ce.rc.2 prerelease
h2=$(packages_gz_hash)
grep -q "^Filename: pool/v9.3.6-ce.rc.2/euro-office-euro-office_9.3.6-0.ce.rc.2_amd64.deb$" \
  "$site/apt/dists/testing/main/binary-amd64/Packages" || fail "digest-less asset not matched by name"
ok "assets without a digest are matched by GitHub's name and size"

publish v9.3.6-ce stable
h3=$(packages_gz_hash)
publish v9.3.6-ce.1 stable
h4=$(packages_gz_hash)
[ "$(versions stable amd64)" = "9.3.6-0~ce 9.3.6-0~ce.1 " ] || fail "stable: $(versions stable amd64)"
[ "$(rpm_versions stable)" = "9.3.6-0~ce 9.3.6-0~ce.1 " ] || fail "rpm stable: $(rpm_versions stable)"
[ "$(dep11_version stable)" = "9.3.6-0~ce.1" ] || fail "stable DEP-11 shows $(dep11_version stable)"
ok "stable channel: stable releases only (apt, rpm), DEP-11 from the newest"

mapfile -t pre_rpm < <(grep -o 'href="repodata/[^"]*"' "$site/rpm/testing/repodata/repomd.xml" | sed 's/^href="//; s/"$//')
publish v9.3.7-ce.rc.1 prerelease
h5=$(packages_gz_hash)
# KEEP=3 by version: 9.3.7-0~ce~rc.1 > 9.3.6-0~ce.rc.1 (old tag scheme) >
# 9.3.6-0~ce.1; 9.3.6-0~ce and 9.3.6-0~ce~rc.2 drop out.
[ "$(versions testing amd64)" = "9.3.6-0~ce.1 9.3.6-0~ce.rc.1 9.3.7-0~ce~rc.1 " ] \
  || fail "testing: $(versions testing amd64)"
[ "$(versions testing arm64)" = "$(versions testing amd64)" ] || fail "arm64 differs from amd64"
[ "$(rpm_versions testing)" = "9.3.6-0~ce.1 9.3.6-0~ce.rc.1 9.3.7-0~ce~rc.1 " ] \
  || fail "rpm testing: $(rpm_versions testing)"
[ "$(versions stable amd64)" = "9.3.6-0~ce 9.3.6-0~ce.1 " ] || fail "stable changed: $(versions stable amd64)"
[ "$(dep11_version testing)" = "9.3.7-0~ce~rc.1" ] || fail "testing DEP-11 shows $(dep11_version testing)"
[ "$(jq -r '[.releases[].tag] | join(" ")' "$site/.state/releases.json")" = \
  "v9.3.7-ce.rc.1 v9.3.6-ce.rc.1 v9.3.6-ce.1 v9.3.6-ce v9.3.6-ce.rc.2" ] || fail "releases.json order"
zcat "$site/rpm/testing/$(grep -o 'repodata/[^"]*primary.xml.gz' "$site/rpm/testing/repodata/repomd.xml")" \
  | grep -c '<package ' | grep -qx 6 || fail "rpm testing should hold 3 releases x 2 arches"
ok "testing channel: newest KEEP=3 by version, both arches, rpm repodata merged without RPM files"

# ── by-hash: the last three generations stay, older ones go ──
bh=$site/apt/dists/testing/main/binary-amd64/by-hash/SHA256
[ -f "$bh/$h5" ] && [ -f "$bh/$h4" ] && [ -f "$bh/$h3" ] || fail "recent by-hash generations missing"
[ ! -f "$bh/$h2" ] && [ ! -f "$bh/$h1" ] || fail "old by-hash generations not pruned"
[ -f "$site/apt/dists/testing/main/binary-amd64/by-hash/SHA512/$(sha512sum \
  "$site/apt/dists/testing/main/binary-amd64/Packages.gz" | cut -d' ' -f1)" ] || fail "by-hash/SHA512 missing"
ok "by-hash keeps three Release generations (SHA256 and SHA512)"

# ── A second tag with a published version ──
! publish v9.3.7-ce-rc.1 prerelease 2>/dev/null || fail "duplicate version accepted"
grep -q 'already published by v9.3.7-ce.rc.1' "$w/log" || fail "duplicate: $(cat "$w/log")"
ok "a second tag for package version 9.3.7-0~ce~rc.1 is refused"

# ── Retention across runs that change nothing ──
# A re-run and a publish to the other channel leave testing as it is; they
# must not use up a generation, so the one before v9.3.7-ce.rc.1 stays.
publish v9.3.7-ce.rc.1 prerelease
publish v9.3.6-ce stable
for p in "${pre_rpm[@]}"; do
  [ -f "$site/rpm/testing/$p" ] || fail "rpm testing: $p of the generation before v9.3.7-ce.rc.1 was dropped"
done
[ -f "$bh/$h4" ] || fail "by-hash of the generation before v9.3.7-ce.rc.1 was dropped"
ok "two runs that change nothing keep the previous apt and rpm generations"
# It is the third newest after one more change and dropped after two.
publish v9.3.7-ce.rc.2 prerelease
for p in "${pre_rpm[@]}"; do
  [ -f "$site/rpm/testing/$p" ] || fail "rpm testing: $p dropped after one change"
done
[ -f "$bh/$h4" ] || fail "by-hash $h4 dropped after one change"
publish v9.3.8-ce.rc.1 prerelease
for p in "${pre_rpm[@]}"; do
  # Files with the same content in every generation (an empty updateinfo)
  # are still the current ones.
  grep -q "href=\"$p\"" "$site/rpm/testing/repodata/repomd.xml" && continue
  [ ! -f "$site/rpm/testing/$p" ] || fail "rpm testing: $p kept after two changes"
done
[ ! -f "$bh/$h4" ] || fail "by-hash $h4 kept after two changes"
"$(dirname "$0")/check-site.sh" "$site" "$KEY_FILE" >/dev/null
ok "three generations stay (apt and rpm), the fourth newest goes"

# ── Idempotency ──
snap() {
  (cd "$site" && find apt rpm .state -type f ! -path '*/history/*' ! -name 'Release*' ! -name InRelease \
     ! -name 'repomd.xml*' ! -path '*/by-hash/*' ! -path 'rpm/*/repodata/*' -print0 | sort -z | xargs -0 sha256sum)
  # repodata names carry checksums of content with timestamps; compare the
  # packages they list instead.
  for ch in stable testing; do echo "$ch $(rpm_versions "$ch")"; done
}
snap > "$w/before"
publish v9.3.6-ce stable
snap > "$w/after"
diff "$w/before" "$w/after" >&2 || fail "re-publishing a tag changed the indexes"
"$(dirname "$0")/check-site.sh" "$site" "$KEY_FILE" >/dev/null
ok "re-publishing v9.3.6-ce changes no index; check-site.sh passes"

# A tag can move between channels.
publish v9.3.6-ce.1 prerelease
[ "$(versions stable amd64)" = "9.3.6-0~ce " ] || fail "stable after moving: $(versions stable amd64)"
ok "re-publishing a tag with another channel moves it"
