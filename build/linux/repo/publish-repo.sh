#!/usr/bin/env bash
# Adds one release to the signed apt and rpm repositories served at
# https://packages.unitystack.eu/euro-office/ and rebuilds every index of the
# site.
#
#   publish-repo.sh --tag v9.3.6-ce --channel stable|prerelease \
#                   --packages <dir> --site <dir> \
#                   [--asset-map <file>] [--repo owner/name] \
#                   [--base-url https://packages.unitystack.eu/euro-office] \
#                   [--key-url https://packages.unitystack.eu/keys/unitystack.asc] \
#                   [--date YYYY-MM-DD]
#
# --base-url is where the site is served, --key-url where the signing key is:
# UnityStack's key, the same for its other products' repositories, so it is
# served next to them rather than below this one (nginx serves it from this
# site's keys/unitystack.asc). The .sources, .repo and README.txt files carry
# both. Every directory gets a listing (index.html) in the form of nginx's
# autoindex, written by autoindex.py.
#
# The site (the `packages` branch, served by GitHub Pages behind nginx) holds
# only metadata. Package files stay on GitHub Releases: the indexes point at
#   apt/pool/<tag>/<asset>                    (apt, Filename:)
#   rpm/<channel>/packages/<tag>/<asset>      (rpm, location href)
# and nginx answers those paths with a 302 to
#   https://github.com/<repo>/releases/download/<tag>/<asset>.
# <asset> is the name GitHub gave the uploaded file, which is not always the
# local file name (GitHub turns the `~` of 9.3.6-0~ce.rc.1 into `.`), so local
# files are matched to release assets by SHA-256.
#
# Nothing here needs the package files of older releases. Each release leaves
# its own index fragments in <site>/.state/ (apt Packages stanzas, an AppStream
# component, icons, rpm repodata), and every run rebuilds all suites from those
# fragments. Re-running a tag replaces that tag's fragments, so the script is
# idempotent. Channels:
#   stable   = releases published with --channel stable
#   testing  = stable + prerelease
# Each keeps its newest $KEEP releases (by package version) in the indexes.
#
# The new site is built in a temporary directory, checked (gpgv), and only
# then copied over <site> (everything except .git), so an aborted run leaves
# <site> as it was and no index refers to a file that is not there.
#
# Refused: v9.3.6-ce.rc.1 and anything else built as 0~ce.rc.N (the version
# scheme before ~rc, which sorts above every later build of that version),
# a second tag with the package version of a published one, and a site whose
# .state/format is newer than this script's (a re-run of an older tag after
# the tooling changed).
#
# Environment:
#   SIGN_FPR             fingerprint of the signing (sub)key; required
#   GNUPGHOME            keyring holding its secret key
#   GPG_PASSPHRASE_FILE  optional, as set by the sign-linux import step
#   KEY_FILE             public key to publish (default: ../unitystack-package-signing.asc)
#   ICON_256             remote AppStream icon (default: desktop-apps icons-eo/256x256.png)
#   GH_TOKEN             for `gh api` when --asset-map is not given
#   ALLOW_OLD_SCHEME=1   accept a 0~ce.rc.N version (tests on throwaway sites)
#
# Tools: apt-ftparchive (apt-utils), dpkg-deb, rpm, createrepo_c, mergerepo_c
# (createrepo-c), gpg, gpgv, jq, python3, gzip, xz. All of them are apt
# packages on ubuntu-24.04. See build/linux/README.md, "Package repositories".
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src_root=$(cd "$here/../../.." && pwd)

KEEP=${KEEP:-10}
PKG_NAME=euro-office-euro-office
APPSTREAM_ID=org.euro_office.desktopeditors
ARCHES=(amd64 arm64)
KEY_FILE=${KEY_FILE:-$here/../unitystack-package-signing.asc}
ICON_256=${ICON_256:-$src_root/desktop-apps/package/common/linux/icons-eo/256x256.png}
METAINFO_M4=${METAINFO_M4:-$here/../package/common/linux/metainfo.xml.m4}
# Layout of .state/ and of the files generated from it. Bump it when a change
# of the fragments, templates or generated files must not be undone by a
# re-run of an older tag (whose checkout has the older script).
STATE_FORMAT=1

tag='' channel='' packages='' site='' asset_map='' repo=UnityStack/DesktopEditors
base_url=https://packages.unitystack.eu/euro-office
key_url=https://packages.unitystack.eu/keys/unitystack.asc date=$(date -u +%F)

die() { echo "publish-repo: error: $*" >&2; exit 1; }
log() { echo "publish-repo: $*" >&2; }
warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::publish-repo: $*" >&2
  else echo "publish-repo: warning: $*" >&2; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) tag=$2; shift 2 ;;
    --channel) channel=$2; shift 2 ;;
    --packages) packages=$2; shift 2 ;;
    --site) site=$2; shift 2 ;;
    --asset-map) asset_map=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --base-url) base_url=${2%/}; shift 2 ;;
    --key-url) key_url=$2; shift 2 ;;
    --date) date=$2; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$tag" ] && [ -n "$channel" ] && [ -n "$packages" ] && [ -n "$site" ] \
  || die "--tag, --channel, --packages and --site are required (see --help)"
# nginx only redirects names made of these characters (and so does GitHub).
[[ $tag =~ ^[A-Za-z0-9._-]+$ ]] || die "tag '$tag' has characters outside [A-Za-z0-9._-]"
case "$channel" in stable|prerelease) ;; *) die "--channel must be stable or prerelease" ;; esac
[[ $date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date must be YYYY-MM-DD"
[ -d "$packages" ] || die "--packages $packages is not a directory"
[ -f "$KEY_FILE" ] || die "public key $KEY_FILE not found"
[[ ${SIGN_FPR:-} =~ ^[0-9A-Fa-f]{40}$ ]] || die "SIGN_FPR must be the 40-digit fingerprint of the signing key"
for t in apt-ftparchive dpkg-deb dpkg rpm createrepo_c mergerepo_c gpg gpgv jq python3 gzip xz sha256sum sha512sum; do
  command -v "$t" >/dev/null || die "$t is not installed"
done
mkdir -p "$site"
site=$(cd "$site" && pwd)
if [ -f "$site/.state/format" ]; then
  site_format=$(cat "$site/.state/format")
  [[ $site_format =~ ^[0-9]+$ ]] || die "$site/.state/format is not a number"
  [ "$site_format" -le "$STATE_FORMAT" ] \
    || die "site was written by a newer publish-repo.sh (format $site_format, this is $STATE_FORMAT); re-run from a newer tag"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
new=$work/site        # the complete new site
mkdir -p "$new"

gpg_sign=(gpg --batch --yes --local-user "${SIGN_FPR}!" --digest-algo SHA512)
if [ -n "${GPG_PASSPHRASE_FILE:-}" ]; then
  gpg_sign+=(--pinentry-mode loopback --passphrase-file "$GPG_PASSPHRASE_FILE")
fi

# ── Keys ─────────────────────────────────────────────────────────
# keys/unitystack.gpg is the binary form for gpgv and for users who want
# a .gpg keyring. Everything this run signs is checked against it, so a
# signing key that is not the published one fails here and not on clients.
# The site serves this file as it is, so it must be one public key: gpg
# would accept a secret key here too, and rpm 4 imports only the first of
# several armored blocks (build/linux/select-signing-subkey.sh checks the
# same before anything is signed).
key_packets=$(gpg --batch --list-packets "$KEY_FILE" 2>/dev/null || true)
if grep -q 'PRIVATE KEY BLOCK' "$KEY_FILE" || grep -Eq '^:secret (sub)?key packet:' <<<"$key_packets"; then
  die "$KEY_FILE contains secret key material; refusing to publish it"
fi
[ "$(grep -c -- '^-----BEGIN PGP' "$KEY_FILE" || true)" -le 1 ] \
  || die "$KEY_FILE has more than one armored block (rpm 4 imports only the first)"
[ "$(grep -c '^:public key packet:' <<<"$key_packets" || true)" = 1 ] \
  || die "$KEY_FILE is not exactly one OpenPGP public key"
mkdir -p "$new/keys"
cp "$KEY_FILE" "$new/keys/unitystack.asc"
gpg --batch --dearmor < "$KEY_FILE" > "$new/keys/unitystack.gpg"
key_fpr=$(gpg --batch --with-colons --show-keys "$KEY_FILE" | awk -F: '$1=="fpr"{print $10; exit}')
key_fpr_spaced=$(sed -E 's/(.{4})/\1 /g; s/^(.{24})/\1 /; s/ +$//' <<<"$key_fpr")
gpg --batch --with-colons --show-keys "$KEY_FILE" | awk -F: '$1=="fpr"{print $10}' \
  | grep -qix "$SIGN_FPR" || die "SIGN_FPR $SIGN_FPR is not a key in $KEY_FILE"
verify() { gpgv --quiet --keyring "$new/keys/unitystack.gpg" "$@" 2>/dev/null \
             || die "signature check failed: $*"; }

# ── Release assets ───────────────────────────────────────────────
# One line per asset: name <TAB> digest ("sha256:<hex>", or empty for
# assets uploaded before GitHub recorded digests) <TAB> size.
if [ -n "$asset_map" ]; then
  cp "$asset_map" "$work/assets.tsv"
else
  command -v gh >/dev/null || die "gh is not installed; pass --asset-map"
  gh api "repos/$repo/releases/tags/$tag" \
    --jq '.assets[] | [.name, (.digest // ""), .size] | @tsv' > "$work/assets.tsv"
fi
[ -s "$work/assets.tsv" ] || die "release $tag of $repo has no assets"

# GitHub replaces every character outside [A-Za-z0-9._-] in an uploaded file
# name with "." (and "~" too). Only used when an asset has no digest.
gh_name() { sed -E 's/[^A-Za-z0-9._-]/./g' <<<"$1"; }

# Prints the asset name for a local file, or nothing when the release has no
# asset with the same content.
asset_for() {
  local file=$1 sha size name
  sha=$(sha256sum "$file" | cut -d' ' -f1)
  size=$(stat -c %s "$file")
  name=$(awk -F'\t' -v d="sha256:$sha" '$2 == d { print $1; exit }' "$work/assets.tsv")
  if [ -z "$name" ]; then
    name=$(gh_name "$(basename "$file")")
    awk -F'\t' -v n="$name" -v s="$size" '$1 == n && $2 == "" && $3 == s { f = 1 } END { exit !f }' \
      "$work/assets.tsv" || name=
  fi
  printf '%s' "$name"
}

# Both architecture builds produce the arch-independent packages (the _all
# help .deb). CI publishes only the amd64 build's (sign-linux), but a local
# directory may hold both, so a file without a matching asset is fine when
# another local file of the same name matched.
declare -A asset_of=() matched_name=()
mapfile -t local_files < <(find "$packages" -type f \( -name '*.deb' -o -name '*.rpm' \) | sort)
[ ${#local_files[@]} -gt 0 ] || die "no .deb or .rpm files in $packages"
unmatched=()
for f in "${local_files[@]}"; do
  a=$(asset_for "$f")
  if [ -z "$a" ]; then unmatched+=("$f"); continue; fi
  [[ $a =~ ^[A-Za-z0-9._-]+$ ]] || die "asset name '$a' has characters nginx does not redirect"
  [ -n "${matched_name[$(basename "$f")]:-}" ] && continue   # same file twice
  matched_name[$(basename "$f")]=$a
  asset_of[$f]=$a
done
for f in "${unmatched[@]}"; do
  if [ -n "${matched_name[$(basename "$f")]:-}" ]; then
    log "skipping $f: a file with the same name matched asset ${matched_name[$(basename "$f")]}"
  else
    die "$f is not an asset of release $tag (no asset with its SHA-256)"
  fi
done

debs=() rpms=()
for f in "${!asset_of[@]}"; do
  case "$f" in *.deb) debs+=("$f") ;; *.rpm) rpms+=("$f") ;; esac
done
log "$tag: ${#debs[@]} .deb, ${#rpms[@]} .rpm"

# The indexes vouch for these bytes, so every file must read completely:
# apt-ftparchive and createrepo_c look at the headers only, and a damaged
# payload would only fail on the clients.
for f in "${debs[@]}"; do
  { dpkg-deb --ctrl-tarfile "$f" | tar -t > /dev/null && dpkg-deb --fsys-tarfile "$f" | tar -t > /dev/null; } 2>/dev/null \
    || die "${asset_of[$f]} is damaged: dpkg-deb cannot read it completely"
done
for f in "${rpms[@]}"; do
  rpm -K --nosignature "$f" > /dev/null 2>&1 || die "${asset_of[$f]} is damaged: rpm -K --nosignature fails"
done

# ── Previous state ───────────────────────────────────────────────
if [ -d "$site/.state" ]; then
  cp -a "$site/.state" "$new/.state"
fi
mkdir -p "$new/.state"
[ -f "$new/.state/releases.json" ] || echo '{"releases":[]}' > "$new/.state/releases.json"
rm -rf "$new/.state/apt/$tag" "$new/.state/rpm/$tag"

# Links the release files into <dir>/<prefix>/<asset> so the index tools
# write the published path.
stage() {
  local dir=$1 prefix=$2; shift 2
  mkdir -p "$dir/$prefix"
  for f in "$@"; do
    ln "$f" "$dir/$prefix/${asset_of[$f]}" 2>/dev/null \
      || ln -s "$(realpath "$f")" "$dir/$prefix/${asset_of[$f]}"
  done
}

# ── This release: apt fragments ──────────────────────────────────
deb_version='' rpm_version='' deb_arches=()
if [ ${#debs[@]} -gt 0 ]; then
  st=$new/.state/apt/$tag
  mkdir -p "$st"
  stage "$work/apt" "pool/$tag" "${debs[@]}"
  (cd "$work/apt" && apt-ftparchive \
      -o APT::FTPArchive::Packages::MD5=false -o APT::FTPArchive::Packages::SHA1=false \
      packages "pool/$tag") > "$st/Packages" 2> "$work/ftparchive.err" || true
  # apt-ftparchive skips a .deb it cannot parse and only says so on stderr.
  # The v9.3.6-ce.rc.1 help .deb is such a file: 144 bytes of the other
  # arch's build trail its last ar member (both arch artifacts carried a help
  # .deb of the same name and one overwrote the other in publish-release,
  # fixed since). dpkg ignores them and the members read completely (checked
  # above), so the package still installs; write its stanza from dpkg-deb
  # instead. Only rc.1 gets this; for any other tag it is an error.
  cat "$work/ftparchive.err" >&2
  for f in "${debs[@]}"; do
    a=${asset_of[$f]}
    grep -q "^Filename: pool/$tag/$a\$" "$st/Packages" && continue
    [ "$tag" = v9.3.6-ce.rc.1 ] || die "apt-ftparchive could not parse $a"
    warn "apt-ftparchive could not parse $a; writing its Packages entry from dpkg-deb"
    {
      dpkg-deb -f "$f" | sed '/^Description:/,$d'
      echo "Filename: pool/$tag/$a"
      echo "Size: $(stat -c %s "$f")"
      echo "SHA256: $(sha256sum "$f" | cut -d' ' -f1)"
      echo "SHA512: $(sha512sum "$f" | cut -d' ' -f1)"
      dpkg-deb -f "$f" | sed -n '/^Description:/,$p'
      echo
    } >> "$st/Packages"
  done

  # The newest version of the main package names the release; the
  # AppStream data comes from its .deb.
  main_deb=
  for f in "${debs[@]}"; do
    [ "$(dpkg-deb -f "$f" Package)" = "$PKG_NAME" ] || continue
    v=$(dpkg-deb -f "$f" Version)
    deb_arches+=("$(dpkg-deb -f "$f" Architecture)")
    if [ -z "$deb_version" ] || dpkg --compare-versions "$v" gt "$deb_version"; then
      deb_version=$v
    fi
    main_deb=$f
  done
  printf '%s\n' "${deb_arches[@]}" | sort -u > "$st/arches"

  if [ -n "$main_deb" ]; then
    x=$work/deb-x
    mkdir -p "$x"
    dpkg-deb --fsys-tarfile "$main_deb" | tar -x -C "$x" --wildcards \
      "./usr/share/metainfo/*" "./usr/share/icons/hicolor/64x64/apps/$PKG_NAME.png" \
      "./usr/share/icons/hicolor/128x128/apps/$PKG_NAME.png" \
      "./usr/share/icons/hicolor/256x256/apps/$PKG_NAME.png" 2>/dev/null || true
    meta=$x/usr/share/metainfo/$APPSTREAM_ID.metainfo.xml
    rtype=stable; [ "$channel" = prerelease ] && rtype=development
    if [ ! -f "$meta" ]; then
      # Releases built before the packages shipped metainfo (rc.1 and
      # older): render the same template, or the fallback here.
      meta=$work/$APPSTREAM_ID.metainfo.xml
      if [ -f "$METAINFO_M4" ] && command -v m4 >/dev/null; then
        log "no metainfo in $(basename "$main_deb"), rendering $METAINFO_M4"
        # The same macros as desktop-apps/package/Makefile and fork.mk.
        m4 -D M4_COMPANY_NAME=Euro-Office -D M4_PUBLISHER_NAME="UnityStack GmbH" \
           -D M4_PUBLISHER_URL=https://euro-office.org -D M4_SUPPORT_MAIL=packages@unitystack.eu \
           -D M4_DESKTOPEDITORS_EXEC="$PKG_NAME" -D M4_APPSTREAM_ID="$APPSTREAM_ID" \
           -D M4_APPSTREAM_DEVELOPER_ID=eu.unitystack \
           -D M4_VCS_URL="https://github.com/$repo" -D M4_BUGTRACKER_URL="https://github.com/$repo/issues" \
           -D M4_RELEASE_VERSION="${deb_version%%-*}" -D M4_RELEASE_DATE="$date" \
           -D M4_RELEASE_TYPE="$rtype" \
           "$METAINFO_M4" > "$meta"
      else
        log "no metainfo in $(basename "$main_deb"), using templates/metainfo.xml.in"
        sed -e "s|@VERSION@|${deb_version%%-*}|g" -e "s|@RELEASE_TYPE@|$rtype|g" -e "s|@DATE@|$date|g" \
          "$here/templates/metainfo.xml.in" > "$meta"
      fi
    fi
    # Warnings and infos are printed but do not stop a release; errors do.
    if command -v appstreamcli >/dev/null; then
      out=$(appstreamcli validate --no-net "$meta" 2>&1 || true)
      printf '%s\n' "$out" >&2
      ! grep -q '^E:' <<<"$out" || die "$meta is not valid AppStream"
    fi
    cp "$meta" "$st/metainfo.xml"

    # DEP-11 icons: cached icons go into icons-<size>.tar.gz as
    # <package>_<icon name>.png; the 256px one is linked from the site.
    icon_name=${PKG_NAME}_${PKG_NAME}.png
    cached=()
    for s in 64x64 128x128; do
      png=$x/usr/share/icons/hicolor/$s/apps/$PKG_NAME.png
      [ -f "$png" ] || png=$src_root/desktop-apps/package/common/linux/icons-eo/$s.png
      if [ -f "$png" ]; then
        mkdir -p "$st/icons/$s"
        cp "$png" "$st/icons/$s/$icon_name"
        cached+=(--cached-icon "$icon_name:$s")
      fi
    done
    png=$ICON_256
    [ -f "$png" ] || png=$x/usr/share/icons/hicolor/256x256/apps/$PKG_NAME.png
    remote=()
    if [ -f "$png" ]; then
      cp "$png" "$st/icon-256.png"
      remote=(--remote-icon "$base_url/apt/icons/euro-office-256.png:256x256")
    fi
    python3 -I "$here/dep11.py" --metainfo "$meta" --package "$PKG_NAME" \
      "${cached[@]}" "${remote[@]}" > "$st/component.yml"
    rm -rf "$x"
  fi
fi

# ── This release: rpm fragments ──────────────────────────────────
# createrepo_c over packages/<tag>/<asset> gives the location href the
# channel repos need. mergerepo_c later combines the per-release repodata
# without the RPM files.
if [ ${#rpms[@]} -gt 0 ]; then
  stage "$work/rpm" "packages/$tag" "${rpms[@]}"
  mkdir -p "$new/.state/rpm/$tag"
  createrepo_c --quiet --no-database --simple-md-filenames \
    --outputdir "$new/.state/rpm/$tag" "$work/rpm" >&2
  rpm_version=$(python3 -I - "$new/.state/rpm/$tag/repodata/primary.xml.gz" "$PKG_NAME" <<'EOF'
import gzip, sys, xml.etree.ElementTree as ET
ns = {"c": "http://linux.duke.edu/metadata/common"}
for p in ET.parse(gzip.open(sys.argv[1])).getroot().findall("c:package", ns):
    if p.findtext("c:name", namespaces=ns) == sys.argv[2]:
        v = p.find("c:version", ns)
        print("%s-%s" % (v.get("ver"), v.get("rel")))
        break
EOF
)
fi
rm -rf "$work/apt" "$work/rpm"

# ── releases.json ────────────────────────────────────────────────
# Sorted by package version, newest first. The version decides which
# releases stay in a channel and whose AppStream data a suite shows.
version=${deb_version:-$rpm_version}
[ -n "$version" ] || die "no $PKG_NAME package among the release files"
# v9.3.6-ce.rc.1 was built as 0~ce.rc.1, before CE prereleases became
# 0~ce~rc.N: it sorts above 0~ce~rc.N, 0~ce and (dpkg) 0~ce.N, so in a
# channel it would be offered as an upgrade to all of them.
case "$version" in
  *~ce.rc.*|*~ce.alpha.*|*~ce.beta.*)
    [ "${ALLOW_OLD_SCHEME:-}" = 1 ] \
      || die "$tag ($version) was built before the ~rc version scheme; it would sort above every later build of the same version and must not be published" ;;
esac
# Two tags for one version (v9.3.7-ce.rc.1 and v9.3.7-ce-rc.1 both build
# 0~ce~rc.1) would put two different files under one version.
dup=$(jq -r --arg tag "$tag" --arg v "$version" \
  '.releases[] | select(.tag != $tag and .version == $v) | .tag' "$new/.state/releases.json")
[ -z "$dup" ] || die "$tag has package version $version, already published by $dup"
jq --arg tag "$tag" --arg channel "$channel" --arg version "$version" --arg date "$date" \
   --argjson apt "$([ -n "$deb_version" ] && echo true || echo false)" \
   --argjson rpm "$([ -n "$rpm_version" ] && echo true || echo false)" '
  (.releases | map(select(.tag == $tag)) | first) as $old
  | .releases = [.releases[] | select(.tag != $tag)]
      + [{tag: $tag, channel: $channel, version: $version,
          date: ($old.date // $date), apt: $apt, rpm: $rpm}]' \
  "$new/.state/releases.json" > "$work/releases.json"

# Insertion sort with dpkg's version order (a few dozen entries at most).
sorted=()
while IFS= read -r t; do
  v=$(jq -r --arg t "$t" '.releases[] | select(.tag == $t) | .version' "$work/releases.json")
  i=${#sorted[@]}
  while [ "$i" -gt 0 ]; do
    pv=$(jq -r --arg t "${sorted[$((i-1))]}" '.releases[] | select(.tag == $t) | .version' "$work/releases.json")
    dpkg --compare-versions "$v" gt "$pv" || break
    sorted[$i]=${sorted[$((i-1))]}
    i=$((i-1))
  done
  sorted[$i]=$t
done < <(jq -r '.releases[].tag' "$work/releases.json")
printf '%s\n' "${sorted[@]}" | jq -R . | jq -s . > "$work/order.json"
jq --slurpfile order "$work/order.json" '
  .releases as $r | .releases = [$order[0][] as $t | $r[] | select(.tag == $t)]' \
  "$work/releases.json" > "$new/.state/releases.json"

# suite_tags <suite> <apt|rpm>: the newest $KEEP tags of a channel.
suite_tags() {
  jq -r --arg suite "$1" --arg kind "$2" --argjson keep "$KEEP" '
    [.releases[] | select(.[$kind]) | select($suite == "testing" or .channel == "stable")]
    | .[:$keep][] | .tag' "$new/.state/releases.json"
}

# Keeps the files of older index generations that a client or cache may
# still ask for: a client that read the previous InRelease or repomd.xml
# fetches the files it names a moment later.
keep_files_of() {   # <old dir> <new dir> <relative paths...>
  local from=$1 to=$2; shift 2
  for p in "$@"; do
    [ -f "$from/$p" ] && [ ! -e "$to/$p" ] && mkdir -p "$(dirname "$to/$p")" && cp -a "$from/$p" "$to/$p"
  done
  return 0
}

repodata_hrefs() { grep -o 'href="repodata/[^"]*"' "$1" | sed 's/^href="//; s/"$//' | sort; }

# ── apt suites ───────────────────────────────────────────────────
for suite in stable testing; do
  d=$new/apt/dists/$suite
  mkdir -p "$d"
  mapfile -t tags < <(suite_tags "$suite" apt)

  # by-hash files from earlier runs, without their listings. apt-ftparchive
  # adds the current ones; anything not named by the last three Release
  # files is dropped below.
  if [ -d "$site/apt/dists/$suite" ]; then
    (cd "$site/apt/dists/$suite" && find . -path '*/by-hash/*' -type f ! -name index.html -print0) \
      | (cd "$site/apt/dists/$suite" && xargs -0 -r cp -a --parents -t "$d")
  fi

  for arch in "${ARCHES[@]}"; do
    b=$d/main/binary-$arch
    mkdir -p "$b"
    : > "$b/Packages"
    for t in "${tags[@]}"; do
      awk -v RS= -v ORS='\n\n' -v a="$arch" \
        '$0 ~ ("(^|\n)Architecture: (" a "|all)(\n|$)")' "$new/.state/apt/$t/Packages" >> "$b/Packages"
    done
    gzip -9nc "$b/Packages" > "$b/Packages.gz"
    xz -9c "$b/Packages" > "$b/Packages.xz"

    # DEP-11: the AppStream component of the newest release built for arch.
    dep=$d/main/dep11
    mkdir -p "$dep"
    comp_tag=
    for t in "${tags[@]}"; do
      if [ -f "$new/.state/apt/$t/component.yml" ] && grep -qx "$arch" "$new/.state/apt/$t/arches"; then
        comp_tag=$t; break
      fi
    done
    {
      printf -- '---\nFile: DEP-11\nVersion: "0.16"\nOrigin: "euro-office-%s-main"\n' "$suite"
      if [ -n "$comp_tag" ]; then cat "$new/.state/apt/$comp_tag/component.yml"; fi
    } > "$dep/Components-$arch.yml"
    gzip -9nc "$dep/Components-$arch.yml" > "$dep/Components-$arch.yml.gz"
  done

  # Icons of the newest release that has any (the component above).
  icon_tag=
  for t in "${tags[@]}"; do
    [ -d "$new/.state/apt/$t/icons" ] && { icon_tag=$t; break; }
  done
  for s in 64x64 128x128; do
    src=$work/empty
    [ -n "$icon_tag" ] && [ -d "$new/.state/apt/$icon_tag/icons/$s" ] && src=$new/.state/apt/$icon_tag/icons/$s
    mkdir -p "$src"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -C "$src" -cf "$d/main/dep11/icons-$s.tar" .
    gzip -9nc "$d/main/dep11/icons-$s.tar" > "$d/main/dep11/icons-$s.tar.gz"
  done
  # apt only fetches an index whose uncompressed name is in Release (it then
  # downloads a compressed variant), so the plain files are published too,
  # as the Debian and Ubuntu archives do for Packages and DEP-11.
  if [ "$suite" = stable ] || [ ! -f "$new/apt/icons/euro-office-256.png" ]; then
    if [ -n "$icon_tag" ] && [ -f "$new/.state/apt/$icon_tag/icon-256.png" ]; then
      mkdir -p "$new/apt/icons"
      cp "$new/.state/apt/$icon_tag/icon-256.png" "$new/apt/icons/euro-office-256.png"
    fi
  fi

  (cd "$d" && apt-ftparchive \
      -o APT::FTPArchive::DoByHash=true \
      -o APT::FTPArchive::Release::MD5=false -o APT::FTPArchive::Release::SHA1=false \
      -o APT::FTPArchive::Release::Origin=euro-office.org \
      -o "APT::FTPArchive::Release::Label=Euro-Office Community Edition" \
      -o APT::FTPArchive::Release::Suite="$suite" \
      -o APT::FTPArchive::Release::Codename="$suite" \
      -o APT::FTPArchive::Release::Components=main \
      -o "APT::FTPArchive::Release::Architectures=${ARCHES[*]}" \
      -o "APT::FTPArchive::Release::Description=Euro-Office Community Edition, $suite channel (unofficial build by UnityStack GmbH)" \
      release .) > "$work/Release"
  mv "$work/Release" "$d/Release"
  "${gpg_sign[@]}" --clearsign -o "$d/InRelease" "$d/Release"
  "${gpg_sign[@]}" --armor --detach-sign -o "$d/Release.gpg" "$d/Release"
  verify "$d/InRelease"
  verify "$d/Release.gpg" "$d/Release"

  # Rotate the Release history and drop by-hash files no generation names.
  # Only a run that changed the suite starts a generation: a re-run or a
  # publish to the other channel differs in Date only, and rotating then
  # would push out a generation that cached clients may still read.
  h=$new/.state/apt/history/$suite
  mkdir -p "$h"
  if ! { [ -f "$h/Release.0" ] && cmp -s <(grep -v '^Date:' "$h/Release.0") <(grep -v '^Date:' "$d/Release"); }; then
    [ -f "$h/Release.1" ] && mv "$h/Release.1" "$h/Release.2"
    [ -f "$h/Release.0" ] && mv "$h/Release.0" "$h/Release.1"
  fi
  cp "$d/Release" "$h/Release.0"
  cat "$h"/Release.* | awk '/^ [0-9a-f]+ +[0-9]+ /{print $1}' | sort -u > "$work/hashes"
  find "$d" -path '*/by-hash/*' -type f | while read -r f; do
    grep -qx "$(basename "$f")" "$work/hashes" || rm -f "$f"
  done
done

# ── rpm channels ─────────────────────────────────────────────────
for ch in stable testing; do
  out=$new/rpm/$ch
  mkdir -p "$out"
  mapfile -t tags < <(suite_tags "$ch" rpm)
  if [ ${#tags[@]} -gt 0 ]; then
    margs=()
    for t in "${tags[@]}"; do margs+=(--repo "file://$new/.state/rpm/$t/"); done
    # --omit-baseurl: hrefs stay relative (packages/<tag>/<asset>); zypper
    # ignores xml:base. --all: keep every version, not only the newest.
    mergerepo_c --all --omit-baseurl --no-database \
      -o "$work/merge-$ch" "${margs[@]}" >&2
    mv "$work/merge-$ch/repodata" "$out/repodata"
  else
    # An empty but valid repository, so dnf and zypper do not fail.
    mkdir -p "$work/empty-rpm"
    mkdir -p "$work/empty-$ch"
    createrepo_c --quiet --no-database --outputdir "$work/empty-$ch" "$work/empty-rpm" >&2
    mv "$work/empty-$ch/repodata" "$out/repodata"
  fi
  r=$out/repodata
  "${gpg_sign[@]}" --armor --detach-sign -o "$r/repomd.xml.asc" "$r/repomd.xml"
  verify "$r/repomd.xml.asc" "$r/repomd.xml"
  cp "$new/keys/unitystack.asc" "$r/repomd.xml.key"

  # Keep the data files of the last three repomd.xml generations (see
  # keep_files_of), counted like the apt Release history: repomd.xml.0 is
  # this run's, and only a run that changed the data files rotates. The
  # hrefs are compared, not the bytes: repomd.xml carries a timestamp.
  h=$new/.state/rpm/history/$ch
  mkdir -p "$h"
  if ! { [ -f "$h/repomd.xml.0" ] && cmp -s <(repodata_hrefs "$h/repomd.xml.0") <(repodata_hrefs "$r/repomd.xml"); }; then
    [ -f "$h/repomd.xml.1" ] && mv "$h/repomd.xml.1" "$h/repomd.xml.2"
    [ -f "$h/repomd.xml.0" ] && mv "$h/repomd.xml.0" "$h/repomd.xml.1"
  fi
  cp "$r/repomd.xml" "$h/repomd.xml.0"
  for g in "$h/repomd.xml.1" "$h/repomd.xml.2"; do
    [ -f "$g" ] || continue
    mapfile -t old < <(repodata_hrefs "$g")
    keep_files_of "$site/rpm/$ch" "$out" "${old[@]}"
  done
done

# ── Repository files, README.txt and the listings ────────────────
render() {   # <template> <output> [KEY=VALUE...]
  local tpl=$1 out=$2; shift 2
  local args=(-e "s|@BASE_URL@|$base_url|g" -e "s|@KEY_URL@|$key_url|g" -e "s|@KEY_FPR@|$key_fpr|g"
              -e "s|@KEY_FPR_SPACED@|$key_fpr_spaced|g")
  for kv in "$@"; do args+=(-e "s|@${kv%%=*}@|${kv#*=}|g"); done
  mkdir -p "$(dirname "$out")"
  sed "${args[@]}" "$tpl" > "$out"
}
render "$here/templates/euro-office.sources.in" "$new/apt/euro-office.sources" SUITE=stable
render "$here/templates/euro-office.sources.in" "$new/apt/euro-office-testing.sources" SUITE=testing
render "$here/templates/euro-office.repo.in" "$new/rpm/euro-office.repo" CHANNEL=stable \
  REPO_ID=euro-office "REPO_NAME=Euro-Office Community Edition (UnityStack GmbH)"
render "$here/templates/euro-office.repo.in" "$new/rpm/euro-office-testing.repo" CHANNEL=testing \
  REPO_ID=euro-office-testing "REPO_NAME=Euro-Office Community Edition testing (UnityStack GmbH)"
render "$here/templates/README.txt.in" "$new/README.txt"
touch "$new/.nojekyll"
echo "$STATE_FORMAT" > "$new/.state/format"
# Last, so the listings name every file above. Entries keep their date while
# their content stays the same (.state/listing.tsv).
python3 -I "$here/autoindex.py" --site "$new" --base-url "$base_url" --now "$(date -u +%s)"

# ── Swap in ──────────────────────────────────────────────────────
find "$site" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -a "$new/." "$site/"
log "published $tag ($channel, $version) to $site"
for ch in stable testing; do
  log "  $ch: $(suite_tags "$ch" apt | tr '\n' ' ')"
done
