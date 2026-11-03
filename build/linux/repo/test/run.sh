#!/usr/bin/env bash
# End-to-end test of the package repositories, in Docker:
#
#   build/linux/repo/test/run.sh [client ...]
#
# 0. runs select-subkey.sh, the table test of the signing key checks,
# 1. builds a site with publish-repo.sh from the REAL assets of a GitHub
#    release ($TAG, default v9.3.6-ce.rc.1; only the packages for the host's
#    architecture and the help .deb are downloaded, into $CACHE) and a
#    throwaway signing key, twice, and checks that the second run changes
#    no index (idempotency). The key has the real key's layout and history
#    (make-key.sh): signing subkey 1 bound with an expiry, a small RPM
#    signed with it, then subkey 1 re-bound without expiry, a spare without
#    expiry; CI holds and signs with subkey 1. The key carries both of
#    subkey 1's bindings, merged with build/linux/merge-public-key.py as
#    the README does,
# 2. runs check-site.sh (gpgv, by-hash, hrefs) and channels.sh (channels,
#    version window, retention, failure paths, with fake packages),
# 3. serves the site with the REAL nginx config of packages.euro-office.org
#    ($NGINX_CONF, from fluxcd-org-apps). Only its Pages upstream is swapped
#    for a local static-file container; the 302 to GitHub Releases is real,
# 4. points real clients at it, each with signature checks on:
#      ubuntu:24.04 (also AppStream), ubuntu:22.04, debian:12, debian:13,
#      fedora:43 (dnf5), rockylinux:9 (dnf4), opensuse/leap:15.6 (zypper)
#    and checks in the nginx log that the packages came through the 302.
#    The rpm clients also run rpm -K on that small RPM, signed before the
#    re-binding: the regression test for a key that lost the old binding
#    (rpm 6 on Fedora rejects such signatures; a fedora:43 control checks
#    that it does with the key that has only the new binding). The rc.1
#    RPMs carry the real key's subkey E94F... signature from before its
#    re-binding, so installing them on fedora:43 checks the committed key.
#
# Clients to run can be named on the command line (e.g. `run.sh ubuntu:24.04`);
# `run.sh none` stops after step 3's smoke test. Every container, network and
# volume it creates is removed on exit. Needs docker and an authenticated gh.
#
# Environment:
#   TAG         release to build the site from (default v9.3.6-ce.rc.1)
#   CACHE       download cache (default $TMPDIR/eo-assets); files land in
#               $CACHE/<tag>/ and are written via a temporary name
#   NGINX_CONF  the nginx config to test (default: the fluxcd-org-apps checkout
#               next to this one, see below)
#   WORK        working directory, kept for inspection (default: mktemp)
#   PACKAGE_KEY the key the release's RPMs are signed with, which the rpm
#               clients import besides the test key (default: the committed
#               build/linux/unitystack-package-signing.asc)
#   INSTALL     full (default): install the package with its dependencies
#               from the distribution; download: only fetch it (faster)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$here/.." && pwd)                    # build/linux/repo
src_root=$(cd "$here/../../../.." && pwd)           # DesktopEditors checkout
TAG=${TAG:-v9.3.6-ce.rc.1}
GH_REPO=${GH_REPO:-UnityStack/DesktopEditors}
CACHE=${CACHE:-${TMPDIR:-/tmp}/eo-assets}
NGINX_CONF=${NGINX_CONF:-$HOME/DevOps/unitystack-customer/customer-fluxcd/fluxcd-org-apps/websites/euro-office/files/downloads-nginx.conf}
# The image downloads.yaml deploys.
NGINX_IMAGE=${NGINX_IMAGE:-nginxinc/nginx-unprivileged:1.30.6-alpine@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03}
INSTALL=${INSTALL:-full}
case "$INSTALL" in full|download) ;; *) echo "INSTALL must be full or download" >&2; exit 1 ;; esac
HOST=packages.euro-office.org
BASE=http://$HOST:8080       # the nginx container, under the real host name
ALL_CLIENTS=(ubuntu:24.04 ubuntu:22.04 debian:12 debian:13 fedora:43 rockylinux:9 opensuse/leap:15.6)
clients=("$@")
[ ${#clients[@]} -gt 0 ] || clients=("${ALL_CLIENTS[@]}")

[ -f "$NGINX_CONF" ] || { echo "nginx config $NGINX_CONF not found; set NGINX_CONF" >&2; exit 1; }
grep -q 'proxy_pass https://unitystack.github.io;' "$NGINX_CONF" \
  || { echo "$NGINX_CONF has no 'proxy_pass https://unitystack.github.io;' line to swap" >&2; exit 1; }

id=eo-repo-test-$$
WORK=${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/eo-repo-test.XXXXXX")}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
cleanup() {
  docker rm -f "$id-pages" "$id-nginx" >/dev/null 2>&1 || true
  docker network rm "$id" >/dev/null 2>&1 || true
  docker volume rm "$id-gnupg" >/dev/null 2>&1 || true
}
trap cleanup EXIT
step() { printf '\n### %s\n' "$*"; }

case "$(uname -m)" in
  arm64|aarch64) deb_arch=arm64 rpm_arch=aarch64 ;;
  *) deb_arch=amd64 rpm_arch=x86_64 ;;
esac

step "builder image"
docker build -q -t eo-repo-builder:test -f "$here/builder.Dockerfile" "$here" >/dev/null
# ALLOW_OLD_SCHEME: the site is a throwaway one, and rc.1 (0~ce.rc.1, which
# publish-repo.sh refuses otherwise) is the only release with real assets.
builder() {
  docker run --rm -v "$src_root:/src:ro" -v "$WORK:/w" -v "$id-gnupg:/g" \
    -e GNUPGHOME=/g/home -e KEY_FILE=/w/key.asc -e ALLOW_OLD_SCHEME=1 "$@"
}

step "select-subkey.sh (signing key checks)"
builder eo-repo-builder:test /src/build/linux/repo/test/select-subkey.sh | tail -n 1

step "release assets of $TAG ($deb_arch/$rpm_arch + help)"
gh api "repos/$GH_REPO/releases/tags/$TAG" \
  --jq '.assets[] | [.name, (.digest // ""), .size] | @tsv' > "$WORK/assets.tsv"
mkdir -p "$CACHE/$TAG" "$WORK/pkgs"
while IFS=$'\t' read -r name digest size; do
  case "$name" in
    *_"$deb_arch".deb|*-help_*_all.deb|*."$rpm_arch".rpm) ;;
    *) continue ;;
  esac
  f=$CACHE/$TAG/$name
  if [ ! -s "$f" ] || [ "sha256:$(shasum -a 256 "$f" | cut -d' ' -f1)" != "$digest" ]; then
    echo "downloading $name ($size bytes)"
    tmp=$(mktemp -d "$CACHE/$TAG/.dl.XXXXXX")
    gh release download "$TAG" -R "$GH_REPO" -p "$name" -D "$tmp"
    mv "$tmp/$name" "$f"
    rmdir "$tmp"
  fi
  ln -f "$f" "$WORK/pkgs/$name" 2>/dev/null || cp "$f" "$WORK/pkgs/$name"
done < "$WORK/assets.tsv"
ls -l "$WORK/pkgs"
# The real package-signing key: the release RPMs are signed with it.
cp "${PACKAGE_KEY:-$repo_dir/../unitystack-package-signing.asc}" "$WORK/package-key.asc"

step "throwaway signing key (subkey 1 re-bound without expiry, a spare; CI holds subkey 1)"
docker volume create "$id-gnupg" >/dev/null
# Also writes /w/subkey-test.rpm, signed by subkey 1 before its re-binding
# (the rc.1 RPMs carry the real key's signature).
builder eo-repo-builder:test /src/build/linux/repo/test/make-key.sh /w/key.asc /w/subkey-test.rpm > "$WORK/sign_fpr"
fpr=$(builder eo-repo-builder:test gpg --batch --with-colons --show-keys /w/key.asc | awk -F: '$1=="fpr"{print $10; exit}')
builder eo-repo-builder:test bash -c 'gpg --batch --with-colons --show-keys /w/key.asc |
  awk -F: "\$1==\"sub\" {c=\$6; e=\$7; cap=\$12} \$1==\"fpr\" && c {print \$10, cap, c, e; c=\"\"}" |
  while read -r f cap c e; do echo "  subkey $f ($cap) created $(date -u -d @$c +%F), expires ${e:+$(date -u -d @$e +%F)}${e:-never}"; done
  gpg --batch --list-packets /w/key.asc | grep -c "sigclass 0x18" | sed "s/^/  subkey bindings in the key: /"'
echo "primary $fpr, signing subkey $(cat "$WORK/sign_fpr")"

publish() {
  builder -e SIGN_FPR="$(cat "$WORK/sign_fpr")" eo-repo-builder:test \
    /src/build/linux/repo/publish-repo.sh --tag "$TAG" --channel prerelease \
      --packages /w/pkgs --site /w/site --asset-map /w/assets.tsv --base-url "$BASE"
}
# Index content without signatures, dates and checksum-named generations.
snapshot() {
  builder eo-repo-builder:test bash -c 'cd /w/site && find apt .state -type f ! -path "*/by-hash/*" \
      ! -path "*/history/*" ! -name "*Release*" ! -name repomd.xml -print0 | sort -z | xargs -0 sha256sum
    for ch in stable testing; do
      zcat rpm/$ch/$(grep -o "repodata/[^\"]*primary.xml.gz" rpm/$ch/repodata/repomd.xml) \
        | grep -o "<location href=\"[^\"]*\"\|<checksum type=\"sha256\" pkgid=\"YES\">[^<]*"
    done'
}

step "publish $TAG (prerelease) twice"
publish
snapshot > "$WORK/snap1"
publish
snapshot > "$WORK/snap2"
diff "$WORK/snap1" "$WORK/snap2"
echo "ok   second publish of $TAG changed no index ($(wc -l < "$WORK/snap1") files compared)"

step "check-site.sh"
builder eo-repo-builder:test /src/build/linux/repo/test/check-site.sh /w/site /w/key.asc
# Signed by subkey 1, the one CI holds, not by the spare.
got=$(builder eo-repo-builder:test bash -c 'gpg --batch --dearmor < /w/key.asc > /tmp/k.gpg
  gpgv --status-fd 1 --keyring /tmp/k.gpg /w/site/apt/dists/testing/InRelease 2>/dev/null' | awk '$2=="VALIDSIG"{print $3}')
[ "$got" = "$(cat "$WORK/sign_fpr")" ] || { echo "FAIL InRelease signed by '$got', not $(cat "$WORK/sign_fpr")"; exit 1; }
echo "ok   InRelease is signed by signing subkey 1 (CI's) $got"

step "channels.sh (fake packages)"
builder -e SIGN_FPR="$(cat "$WORK/sign_fpr")" eo-repo-builder:test \
  /src/build/linux/repo/test/channels.sh /src/build/linux/repo

step "nginx ($NGINX_CONF) in front of a local Pages stand-in"
sed 's|proxy_pass https://unitystack.github.io;|proxy_pass http://pages;|' "$NGINX_CONF" > "$WORK/nginx.conf"
docker network create "$id" >/dev/null
# GitHub Pages stand-in: the site under /DesktopEditors/, like
# https://unitystack.github.io/DesktopEditors/.
docker run -d --name "$id-pages" --network "$id" --network-alias pages \
  -v "$WORK/site:/usr/share/nginx/html/DesktopEditors:ro" nginx:1.27-alpine >/dev/null
docker run -d --name "$id-nginx" --network "$id" --network-alias "$HOST" \
  -v "$WORK/nginx.conf:/etc/nginx/nginx.conf:ro" --tmpfs /tmp "$NGINX_IMAGE" >/dev/null
sleep 2
docker logs "$id-nginx" 2>&1 | grep -iE 'emerg|error' && { echo "nginx failed to start"; exit 1; }

curl_c() { docker run --rm --network "$id" curlimages/curl:8.11.1 -sS "$@"; }
asset=$(awk -F'\t' -v a="_$deb_arch.deb" 'index($1, a) {print $1; exit}' "$WORK/assets.tsv")
expect() {   # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1: $3"; else echo "FAIL $1: got '$3', expected '$2'"; exit 1; fi
}
expect "GET /apt/dists/testing/InRelease" "200 public, max-age=300, must-revalidate" \
  "$(curl_c -o /dev/null -D - "$BASE/apt/dists/testing/InRelease" | tr -d '\r' \
     | awk 'NR==1{s=$2} tolower($1)=="cache-control:"{sub(/^[^:]*: /,""); c=$0} END{print s, c}')"
expect "GET /apt/pool/$TAG/$asset" "302 https://github.com/$GH_REPO/releases/download/$TAG/$asset" \
  "$(curl_c -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE/apt/pool/$TAG/$asset")"
expect "POST /apt/dists/testing/Release" "405" \
  "$(curl_c -o /dev/null -w '%{http_code}' -X POST "$BASE/apt/dists/testing/Release")"
expect "GET /keys/euro-office.asc (sha256)" "$(cat "$WORK/key.asc" | shasum -a 256)" \
  "$(curl_c "$BASE/keys/euro-office.asc" | shasum -a 256)"
expect "GET /apt/pool/x/y/z" "404" "$(curl_c -o /dev/null -w '%{http_code}' "$BASE/apt/pool/x/y/z")"

# The control for the rpm clients' check below: rpm 6 must reject the test
# RPM with the key that lacks subkey 1's old binding, else that check proves
# nothing.
if printf '%s\n' "${clients[@]}" | grep -qx 'fedora:43'; then
  step "control: fedora:43 rejects the old signature with the key that has only the new binding"
  ctl=$(docker run --rm --pull missing --platform "linux/$deb_arch" -v "$WORK:/w:ro" fedora:43 bash -c \
    'rpm --import /w/key.asc.rebound-only && rpm -K /w/subkey-test.rpm 2>&1' || true)
  echo "$ctl"
  if [[ $ctl == *"signatures OK"* ]]; then echo "FAIL fedora:43 accepted the test RPM with the key that lacks the old binding"; exit 1; fi
  echo "ok   fedora:43 rejects it with that key (so the clients' rpm -K below tests the merged key)"
fi

for c in "${clients[@]}"; do
  [ "$c" = none ] && continue
  step "client $c"
  since=$(date -u +%s)
  case "$c" in
    ubuntu:24.04)
      docker run --rm --pull missing --platform "linux/$deb_arch" --network "$id" -v "$here:/t:ro" "$c" /t/client-apt.sh "$BASE" testing "$fpr" "$INSTALL" appstream ;;
    ubuntu:*|debian:*)
      docker run --rm --pull missing --platform "linux/$deb_arch" --network "$id" -v "$here:/t:ro" "$c" /t/client-apt.sh "$BASE" testing "$fpr" "$INSTALL" ;;
    fedora:*|rockylinux:*|almalinux:*)
      docker run --rm --pull missing --platform "linux/$deb_arch" --network "$id" -v "$here:/t:ro" -v "$WORK/package-key.asc:/k.asc:ro" \
        -v "$WORK/subkey-test.rpm:/subkey-test.rpm:ro" "$c" \
        /t/client-dnf.sh "$BASE" testing "$fpr" "$INSTALL" /k.asc /subkey-test.rpm "$(cat "$WORK/sign_fpr")" ;;
    opensuse/*)
      # The RPM of v9.3.6-ce.rc.1 requires Fedora package names, which
      # openSUSE does not have (fixed for later builds in package.patch);
      # client-zypper.sh then installs a test-only shim for exactly those.
      shim=0; [ "$TAG" = v9.3.6-ce.rc.1 ] && shim=1
      docker run --rm --pull missing --platform "linux/$deb_arch" --network "$id" -v "$here:/t:ro" -v "$WORK/package-key.asc:/k.asc:ro" \
        -v "$WORK/subkey-test.rpm:/subkey-test.rpm:ro" -e SHIM_MISSING=$shim "$c" \
        /t/client-zypper.sh "$BASE" testing "$fpr" "$INSTALL" /k.asc /subkey-test.rpm "$(cat "$WORK/sign_fpr")" ;;
    *) echo "unknown client $c"; exit 1 ;;
  esac
  # The package itself came from GitHub through the redirect.
  if docker logs --since "$since" "$id-nginx" 2>/dev/null \
      | grep -E '"GET /(apt/pool|rpm/testing/packages)/[^ ]*euro-office-euro-office[^ ]* HTTP/1.1" 302 ' \
      | grep -v '"curl/' ; then
    echo "ok   $c fetched the package through the 302"
  else
    echo "FAIL $c: no 302 for the package in the nginx log"; exit 1
  fi
done
step "all passed (work dir $WORK)"
