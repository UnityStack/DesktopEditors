#!/usr/bin/env bash
# Offline checks of render-manifests.sh with a made-up release: the manifests
# of a final tag, and the refusals (prereleases, rebuilds, drafts, a missing
# installer or digest, a SHA256SUMS line that does not match). Needs bash,
# jq and sed, no network:
#   render.sh <build/windows/winget>
# With SCHEMA_DIR set to a directory holding manifest.{version,installer,
# defaultLocale}.1.28.0.json (microsoft/winget-cli, schemas/JSON/manifests/
# v1.28.0) and check-jsonschema on PATH, it also validates the manifests.
set -euo pipefail
dir=$(cd "$1" && pwd)
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

# The rc.1 installers' hashes.
x64=abeff83d17f13be606f9c3f1bdd464409a8de3f255f25bb5d776267013fd076c
arm=6b6739cbf521de61b5bcf3ae504382e771c0c2702921b2019f57a1855125db8e

# release <tag> <draft> <prerelease> [jq filter applied to the release]
release() {
  jq -n --arg tag "$1" --argjson draft "$2" --argjson pre "$3" --arg x "$x64" --arg a "$arm" '{
    tagName: $tag, isDraft: $draft, isPrerelease: $pre, publishedAt: "2026-12-01T10:00:00Z",
    assets: [
      {name: "Euro-Office-DesktopEditors-9.3.6-0-ce-windows-x64.exe", digest: ("sha256:" + $x)},
      {name: "Euro-Office-DesktopEditors-9.3.6-0-ce-windows-x64.zip", digest: ("sha256:" + ("2" * 64))},
      {name: "Euro-Office-DesktopEditors-9.3.6-0-ce-windows-arm64.exe", digest: ("sha256:" + $a)},
      {name: "euro-office-euro-office_9.3.6-0.ce_amd64.deb", digest: ("sha256:" + ("3" * 64))}
    ]}' | jq "${4:-.}" > "$w/release.json"
}
sums() {   # <arm64 hash>; CRLF like the files sign-windows writes
  mkdir -p "$w/sums"
  printf '%s  %s\r\n' "$x64" Euro-Office-DesktopEditors-9.3.6-0-ce-windows-x64.exe \
    "$(printf '2%.0s' {1..64})" Euro-Office-DesktopEditors-9.3.6-0-ce-windows-x64.zip \
    > "$w/sums/SHA256SUMS-windows-amd64.txt"
  printf '%s  %s\r\n' "$1" Euro-Office-DesktopEditors-9.3.6-0-ce-windows-arm64.exe \
    > "$w/sums/SHA256SUMS-windows-arm64.txt"
}
render() {   # <tag> [extra args]; output in $w/log
  local tag=$1; shift
  rm -rf "$w/out"
  "$dir/render-manifests.sh" --tag "$tag" --out "$w/out" --release-json "$w/release.json" \
    --sums-dir "$w/sums" "$@" > "$w/log" 2>&1
}
refused() {   # <what> <expected message> <tag> [extra args]
  local what=$1 msg=$2; shift 2
  if render "$@"; then fail "$what was accepted"; fi
  grep -q -- "$msg" "$w/log" || { cat "$w/log" >&2; fail "$what: expected '$msg'"; }
  [ ! -e "$w/out" ] || [ -z "$(find "$w/out" -name '*.yaml')" ] || fail "$what left manifests behind"
  ok "refused: $what"
}

# ── A final release ──────────────────────────────────────────────
release v9.3.6-ce false false
sums "$arm"
render v9.3.6-ce || { cat "$w/log" >&2; fail "final release refused"; }
m=$w/out/manifests/u/UnityStack/EuroOfficeCommunityEdition/9.3.6.0
[ "$(tail -n 1 "$w/log")" = "$m" ] || fail "printed $(tail -n 1 "$w/log"), expected $m"
[ "$(find "$w/out" -type f | wc -l)" -eq 3 ] || fail "expected 3 manifests"
i=$m/UnityStack.EuroOfficeCommunityEdition.installer.yaml
l=$m/UnityStack.EuroOfficeCommunityEdition.locale.en-US.yaml
v=$m/UnityStack.EuroOfficeCommunityEdition.yaml
for f in "$i" "$l" "$v"; do
  grep -qx 'PackageIdentifier: UnityStack.EuroOfficeCommunityEdition' "$f" || fail "$f: identifier"
  grep -qx 'PackageVersion: 9.3.6.0' "$f" || fail "$f: version"
  ! grep -q '@[A-Z0-9_]*@' "$f" || fail "$f: placeholder left"
done
grep -qx '  InstallerUrl: https://github.com/UnityStack/DesktopEditors/releases/download/v9.3.6-ce/Euro-Office-DesktopEditors-9.3.6-0-ce-windows-x64.exe' "$i" \
  || fail "x64 URL"
grep -qx "  InstallerSha256: ${x64^^}" "$i" || fail "x64 sha"
grep -qx "  InstallerSha256: ${arm^^}" "$i" || fail "arm64 sha"
grep -qx '  - DisplayName: Euro-Office (Standalone) 9.3.6 (arm64)' "$i" || fail "arm64 DisplayName"
[ "$(grep -c '^    DisplayVersion: 9.3.6.0$' "$i")" = 2 ] || fail "DisplayVersion"
grep -qx 'ReleaseDate: 2026-12-01' "$i" || fail "ReleaseDate"
grep -qx 'ReleaseNotesUrl: https://github.com/UnityStack/DesktopEditors/releases/tag/v9.3.6-ce' "$l" || fail "ReleaseNotesUrl"
grep -q 'not affiliated with the Euro-Office project' "$l" || fail "affiliation note"
# euro-office.org does not resolve yet (build/windows/README.md, "One-time setup").
grep -qx 'PackageUrl: https://github.com/UnityStack/DesktopEditors' "$l" || fail "PackageUrl"
grep -qx 'PublisherSupportUrl: https://github.com/UnityStack/DesktopEditors/issues' "$l" || fail "PublisherSupportUrl"
ok "final release v9.3.6-ce -> 9.3.6.0"

if [ -n "${SCHEMA_DIR:-}" ]; then
  check-jsonschema --schemafile "$SCHEMA_DIR/manifest.version.1.28.0.json" "$v"
  check-jsonschema --schemafile "$SCHEMA_DIR/manifest.installer.1.28.0.json" "$i"
  check-jsonschema --schemafile "$SCHEMA_DIR/manifest.defaultLocale.1.28.0.json" "$l"
  ok "schema 1.28.0"
fi

# ── Refusals ─────────────────────────────────────────────────────
release v9.3.6-ce.rc.2 false true
refused "release candidate" "not a final Community Edition tag" v9.3.6-ce.rc.2
release v9.3.6-ce.1 false false
refused "rebuild" "not a final Community Edition tag" v9.3.6-ce.1
release v9.3.6 false false
refused "upstream tag" "not a final Community Edition tag" v9.3.6
release v9.3.6-ce false true
refused "prerelease release" "is a prerelease" v9.3.6-ce
release v9.3.6-ce true false
refused "draft" "is a draft" v9.3.6-ce
release v9.3.7-ce false false
refused "JSON of another release" "release JSON is not for v9.3.6-ce" v9.3.6-ce
release v9.3.6-ce false false '.assets |= map(select(.name | endswith("arm64.exe") | not))'
refused "missing arm64 installer" "0 Windows arm64 installers" v9.3.6-ce
release v9.3.6-ce false false '.assets[0] |= del(.digest)'
refused "asset without digest" "has no SHA-256 digest" v9.3.6-ce
release v9.3.6-ce false false
sums "$x64"
refused "SHA256SUMS mismatch" "SHA256SUMS-windows-arm64.txt says" v9.3.6-ce

# --allow-prerelease (tests only) renders a release candidate.
sums "$arm"
release v9.3.6-ce.rc.2 false true
render v9.3.6-ce.rc.2 --allow-prerelease || { cat "$w/log" >&2; fail "--allow-prerelease"; }
ok "--allow-prerelease renders v9.3.6-ce.rc.2"
echo "all checks passed"
