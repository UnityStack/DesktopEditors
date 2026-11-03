#!/usr/bin/env bash
# Structural checks of a site written by publish-repo.sh, without a client:
#   check-site.sh <site dir> <armored public key>
# Runs in the builder image (test/builder.Dockerfile). Prints one "ok" line
# per check and exits non-zero on the first failure.
set -euo pipefail
site=$1 key=$2
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

kr=$(mktemp)
trap 'rm -f "$kr"' EXIT
gpg --batch --dearmor < "$key" > "$kr"
cmp -s "$key" "$site/keys/euro-office.asc" || fail "keys/euro-office.asc is not the signing key"
cmp -s "$kr" "$site/keys/euro-office.gpg" || fail "keys/euro-office.gpg is not the dearmored key"
ok "keys/euro-office.{asc,gpg} match the signing key"

for f in .nojekyll index.html apt/euro-office.sources apt/euro-office-testing.sources \
         rpm/euro-office.repo rpm/euro-office-testing.repo; do
  [ -f "$site/$f" ] || fail "$f missing"
done
grep -q 'not affiliated with the Euro-Office project' "$site/index.html" || fail "index.html lacks the disclaimer"
ok "top-level files present"

for suite in stable testing; do
  d=$site/apt/dists/$suite
  gpgv --quiet --keyring "$kr" "$d/InRelease" 2>/dev/null || fail "$suite/InRelease does not verify"
  gpgv --quiet --keyring "$kr" "$d/Release.gpg" "$d/Release" 2>/dev/null || fail "$suite/Release.gpg does not verify"
  # InRelease must carry exactly the Release text.
  gpg --batch --quiet --decrypt "$d/InRelease" 2>/dev/null | cmp -s - "$d/Release" \
    || fail "$suite/InRelease and Release differ"
  ok "apt $suite: InRelease and Release.gpg verify with gpgv"

  for field in "Origin: euro-office.org" "Label: Euro-Office Community Edition" "Suite: $suite" \
               "Codename: $suite" "Components: main" "Architectures: amd64 arm64" "Acquire-By-Hash: yes"; do
    grep -qx "$field" "$d/Release" || fail "$suite/Release lacks '$field'"
  done
  ! grep -q '^Valid-Until:' "$d/Release" || fail "$suite/Release has Valid-Until"
  ! grep -q '^MD5Sum:' "$d/Release" || fail "$suite/Release still lists MD5"
  ok "apt $suite: Release fields"

  # Every index listed in Release exists, matches, and has its by-hash copy
  # for each hash type (apt fetches by the strongest one).
  n=0
  for algo in SHA256 SHA512; do
    sum=$(echo "$algo" | tr A-Z a-z)sum
    while read -r hash size path; do
      [ -f "$d/$path" ] || fail "$suite: $path listed but missing"
      [ "$(stat -c %s "$d/$path")" = "$size" ] || fail "$suite: $path size"
      [ "$($sum "$d/$path" | cut -d' ' -f1)" = "$hash" ] || fail "$suite: $path $algo"
      bh=$d/$(dirname "$path")/by-hash/$algo/$hash
      [ -f "$bh" ] && cmp -s "$bh" "$d/$path" || fail "$suite: by-hash/$algo for $path missing"
      n=$((n + 1))
    done < <(awk -v a="$algo:" '$0 == a { on = 1; next } /^[^ ]/ { on = 0 } on' "$d/Release")
  done
  [ "$n" -ge 20 ] || fail "$suite: only $n Release entries"
  ok "apt $suite: $n Release entries match their files and by-hash copies"

  for arch in amd64 arm64; do
    p=$d/main/binary-$arch/Packages
    zcat "$p.gz" | cmp -s - "$p" || fail "$suite $arch: Packages.gz differs"
    xzcat "$p.xz" | cmp -s - "$p" || fail "$suite $arch: Packages.xz differs"
    if grep '^Filename:' "$p" | grep -vqE '^Filename: pool/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
      fail "$suite $arch: a Filename nginx would not redirect"
    fi
    if grep '^Architecture:' "$p" | grep -vqE "^Architecture: ($arch|all)$"; then
      fail "$suite $arch: foreign architecture in Packages"
    fi
    zcat "$d/main/dep11/Components-$arch.yml.gz" > /tmp/c.yml
    appstreamcli convert --format=xml /tmp/c.yml /tmp/c.xml >/dev/null || fail "$suite $arch: DEP-11 does not parse"
  done
  ok "apt $suite: Packages{,.gz,.xz} consistent, pool paths valid, DEP-11 parses"
done

for ch in stable testing; do
  r=$site/rpm/$ch/repodata
  gpgv --quiet --keyring "$kr" "$r/repomd.xml.asc" "$r/repomd.xml" 2>/dev/null \
    || fail "rpm $ch: repomd.xml.asc does not verify"
  cmp -s "$r/repomd.xml.key" "$key" || fail "rpm $ch: repomd.xml.key is not the key"
  for href in $(grep -o 'href="[^"]*"' "$r/repomd.xml" | sed 's/^href="//; s/"$//'); do
    [ -f "$site/rpm/$ch/$href" ] || fail "rpm $ch: $href missing"
  done
  primary=$site/rpm/$ch/$(grep -o 'href="repodata/[^"]*primary.xml.gz"' "$r/repomd.xml" | sed 's/^href="//; s/"$//')
  ! zcat "$primary" | grep -q 'xml:base' || fail "rpm $ch: xml:base in primary"
  if zcat "$primary" | grep -o '<location href="[^"]*"' | grep -vqE '"packages/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.rpm"$'; then
    fail "rpm $ch: a location href nginx would not redirect"
  fi
  ok "rpm $ch: repomd.xml.asc verifies, data files present, hrefs packages/<tag>/<asset>"
done
