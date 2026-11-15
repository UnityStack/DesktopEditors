#!/usr/bin/env bash
# Writes the winget manifests of UnityStack.EuroOfficeCommunityEdition for one
# GitHub release of UnityStack/DesktopEditors, in the layout of
# microsoft/winget-pkgs:
#
#   render-manifests.sh --tag v9.3.6-ce --out <dir> \
#                       [--release-json <file>] [--sums-dir <dir>] [--allow-prerelease]
#
# writes <dir>/manifests/u/UnityStack/EuroOfficeCommunityEdition/<version>/
# (version, installer and en-US locale manifest) and prints that directory.
# `komac submit <that directory>` opens the pull request.
#
# Only final Community Edition tags are accepted: vX.Y.Z-ce becomes package
# version X.Y.Z.0, the DisplayVersion the Inno installer writes (its AppVersion,
# from build.ps1's $VersionFull). Release candidates (-ce.rc.N, -ce.beta.N,
# -ce.alpha.N) and rebuilds (-ce.N) write the same DisplayVersion X.Y.Z.0, so
# winget could not tell them from the final release: they are refused. The
# release must not be a draft or a prerelease.
#
# The installer URLs and SHA-256 come from the release: the digest GitHub
# computed for each Windows .exe, which must match the line for it in the
# release's SHA256SUMS-windows-<arch>.txt.
#
# --release-json  output of `gh release view <tag> --json
#                 tagName,isDraft,isPrerelease,publishedAt,assets` (default:
#                 fetched with gh)
# --sums-dir      directory holding the SHA256SUMS-windows-*.txt files of the
#                 release (default: downloaded with gh)
# --allow-prerelease  also accept -ce.rc.N/-ce.beta.N/-ce.alpha.N tags and
#                 prerelease releases; for tests only, never submit the result
#
# Environment: GH_TOKEN for gh when --release-json or --sums-dir is not given.
# Tools: jq, sed, and gh unless both files are given. See
# build/windows/README.md, "Updates via winget".
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
REPO=UnityStack/DesktopEditors
ID=UnityStack.EuroOfficeCommunityEdition

tag='' out='' release_json='' sums_dir='' allow_prerelease=0

die() { echo "render-manifests: error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) tag=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --release-json) release_json=$2; shift 2 ;;
    --sums-dir) sums_dir=$2; shift 2 ;;
    --allow-prerelease) allow_prerelease=1; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$tag" ] && [ -n "$out" ] || die "--tag and --out are required (see --help)"
for t in jq sed; do command -v "$t" >/dev/null || die "$t is not installed"; done

if [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-ce$ ]]; then
  short_version=${BASH_REMATCH[1]}
elif [ "$allow_prerelease" = 1 ] && [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-ce\.(rc|beta|alpha)\.[1-9][0-9]*$ ]]; then
  short_version=${BASH_REMATCH[1]}
else
  die "$tag is not a final Community Edition tag (vX.Y.Z-ce)"
fi
version=$short_version.0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -z "$release_json" ]; then
  release_json=$work/release.json
  gh release view "$tag" -R "$REPO" --json tagName,isDraft,isPrerelease,publishedAt,assets > "$release_json"
fi
jq -e --arg t "$tag" '.tagName == $t' "$release_json" >/dev/null || die "release JSON is not for $tag"
jq -e '.isDraft == false' "$release_json" >/dev/null || die "release $tag is a draft"
if [ "$allow_prerelease" = 0 ]; then
  jq -e '.isPrerelease == false' "$release_json" >/dev/null || die "release $tag is a prerelease"
fi
release_date=$(jq -r '.publishedAt[0:10]' "$release_json")
[[ $release_date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "release $tag has no publish date"

if [ -z "$sums_dir" ]; then
  sums_dir=$work/sums
  gh release download "$tag" -R "$REPO" -D "$sums_dir" -p 'SHA256SUMS-windows-*.txt'
fi

# installer <x64|arm64>: sets name and sha (upper case, as winget-pkgs writes it).
installer() {
  local arch=$1 sums_arch=$1 names digest listed
  [ "$arch" = x64 ] && sums_arch=amd64
  mapfile -t names < <(jq -r --arg a "$arch" \
    '.assets[].name | select(test("^Euro-Office-DesktopEditors-.*-windows-" + $a + "\\.exe$"))' "$release_json")
  [ "${#names[@]}" = 1 ] || die "release $tag has ${#names[@]} Windows $arch installers, expected 1"
  name=${names[0]}
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "asset name $name has characters outside [A-Za-z0-9._-]"
  digest=$(jq -r --arg n "$name" '.assets[] | select(.name == $n) | .digest // ""' "$release_json")
  [[ $digest =~ ^sha256:([0-9a-f]{64})$ ]] || die "asset $name has no SHA-256 digest"
  sha=${BASH_REMATCH[1]}
  [ -f "$sums_dir/SHA256SUMS-windows-$sums_arch.txt" ] || die "SHA256SUMS-windows-$sums_arch.txt is missing"
  # sign-windows writes these files on Windows, with CRLF line ends.
  listed=$(awk -v n="$name" '{ sub(/\r$/, ""); f = $2; sub(/^\*/, "", f) } f == n { print tolower($1) }' \
    "$sums_dir/SHA256SUMS-windows-$sums_arch.txt")
  [ "$listed" = "$sha" ] || die "$name: SHA256SUMS-windows-$sums_arch.txt says '${listed:-nothing}', GitHub says $sha"
  sha=$(tr '[:lower:]' '[:upper:]' <<<"$sha")
}
installer x64;   x64_name=$name   x64_sha=$sha
installer arm64; arm64_name=$name arm64_sha=$sha

dir=$out/manifests/u/${ID%%.*}/${ID#*.}/$version
mkdir -p "$dir"
base=https://github.com/$REPO/releases/download/$tag
for f in "$ID.yaml" "$ID.installer.yaml" "$ID.locale.en-US.yaml"; do
  sed -e "s|@VERSION@|$version|g" -e "s|@SHORT_VERSION@|$short_version|g" -e "s|@TAG@|$tag|g" \
      -e "s|@RELEASE_DATE@|$release_date|g" \
      -e "s|@X64_URL@|$base/$x64_name|g" -e "s|@X64_SHA256@|$x64_sha|g" \
      -e "s|@ARM64_URL@|$base/$arm64_name|g" -e "s|@ARM64_SHA256@|$arm64_sha|g" \
      "$here/templates/$f.in" > "$dir/$f"
  ! grep -n '@[A-Z0-9_]*@' "$dir/$f" || die "$f: unreplaced placeholder"
done
echo "$dir"
