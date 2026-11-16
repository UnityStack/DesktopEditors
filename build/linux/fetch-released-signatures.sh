#!/usr/bin/env bash
# Downloads the SHA256SUMS-linux-<arch>.txt.asc of the newest releases into
# <dir>/<tag>/, for build/linux/select-signing-subkey.sh --released <dir>:
#
#   fetch-released-signatures.sh <dir> [<count>]       (default: 10 releases)
#
# sign-linux clearsigns them with the same subkey and in the same run as the
# RPMs, so they show whether the committed key still verifies what was
# released the way rpm 6 (Fedora) does. 10 is the number of releases a
# repository channel lists. Drafts are skipped, and so are releases without
# such an asset (older ones). The script itself never fails: when it cannot
# list the releases, read a release's assets or download one of those
# files, it writes the reason to <dir>/.fetch-errors, which
# select-signing-subkey.sh turns into an error in signing mode (the
# signing-preflight job, which then signs nothing) and a warning in public
# mode. So an API outage cannot make the check pass with fewer files.
# Environment: GH_TOKEN, GITHUB_REPOSITORY.
set -uo pipefail
dir=$1 count=${2:-10}
mkdir -p "$dir"
errors=$dir/.fetch-errors
: > "$errors"
problem() { echo "::warning::$*"; echo "$*" >> "$errors"; }
pattern='^SHA256SUMS-linux-.*\.txt\.asc$'
if ! tags=$(gh release list -R "$GITHUB_REPOSITORY" --exclude-drafts --limit "$count" \
              --json tagName --jq '.[].tagName' 2>&1); then
  problem "Cannot list the releases of $GITHUB_REPOSITORY: $(head -n 1 <<<"$tags")"
  exit 0
fi
for tag in $tags; do
  if ! names=$(gh release view "$tag" -R "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' 2>&1); then
    problem "$tag: cannot read the release's assets: $(head -n 1 <<<"$names")"
    continue
  fi
  want=$(grep -E "$pattern" <<<"$names" || true)
  if [ -z "$want" ]; then
    echo "$tag: no SHA256SUMS-linux-*.txt.asc asset (released before Linux signing)"
    continue
  fi
  args=()
  while IFS= read -r name; do args+=(-p "$name"); done <<<"$want"
  if ! out=$(gh release download "$tag" -R "$GITHUB_REPOSITORY" -D "$dir/$tag" --clobber "${args[@]}" 2>&1); then
    problem "$tag: cannot download $(paste -sd ' ' - <<<"$want"): $(head -n 1 <<<"$out")"
    continue
  fi
  while IFS= read -r name; do
    [ -s "$dir/$tag/$name" ] || problem "$tag: $name is missing or empty after the download"
  done <<<"$want"
done
find "$dir" -type f -name '*.asc' | sort
exit 0
