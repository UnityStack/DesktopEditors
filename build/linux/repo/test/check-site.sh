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
cmp -s "$key" "$site/keys/unitystack.asc" || fail "keys/unitystack.asc is not the signing key"
cmp -s "$kr" "$site/keys/unitystack.gpg" || fail "keys/unitystack.gpg is not the dearmored key"
ok "keys/unitystack.{asc,gpg} match the signing key"

for f in .nojekyll README.txt apt/euro-office.sources apt/euro-office-testing.sources \
         rpm/euro-office.repo rpm/euro-office-testing.repo; do
  [ -f "$site/$f" ] || fail "$f missing"
done
grep -qx '# Unofficial community build by UnityStack GmbH, not affiliated with the Euro-Office project.' \
  "$site/README.txt" || fail "README.txt lacks the disclaimer"
fpr=$(gpg --batch --with-colons --show-keys "$key" | awk -F: '$1=="fpr"{print $10; exit}')
grep -qF "$(sed -E 's/(.{4})/\1 /g; s/^(.{24})/\1 /; s/ +$//' <<<"$fpr")" "$site/README.txt" \
  || fail "README.txt lacks the key fingerprint"
# Its apt snippet writes the stable .sources file without its comments.
sed -n '\#^sudo tee /etc/apt/sources.list.d/euro-office.sources #,/^END$/p' "$site/README.txt" | sed '1d;$d' \
  | cmp -s - <(grep -v '^#' "$site/apt/euro-office.sources") || fail "README.txt: the apt snippet is not apt/euro-office.sources"
ok "top-level files present, README.txt with the disclaimer, the fingerprint and the apt source"
for f in README.txt apt/euro-office.sources apt/euro-office-testing.sources rpm/euro-office.repo rpm/euro-office-testing.repo; do
  ! grep -q '@[A-Z_]*@' "$site/$f" || fail "$f has a placeholder left: $(grep -o '@[A-Z_]*@' "$site/$f" | head -n1)"
done
for f in apt/euro-office.sources apt/euro-office-testing.sources; do
  grep -qx 'Signed-By: /usr/share/keyrings/unitystack.asc' "$site/$f" || fail "$f: Signed-By is not /usr/share/keyrings/unitystack.asc"
done
for f in rpm/euro-office.repo rpm/euro-office-testing.repo; do
  grep -qE '^gpgkey=[^ ]+/keys/unitystack\.asc$' "$site/$f" || fail "$f: gpgkey= is not a .../keys/unitystack.asc URL"
done
ok "repository files filled in, key named unitystack"

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

# Listings: every directory has an index.html in the form of nginx's
# autoindex that names exactly what is in it, directories first. Below
# apt/pool/ and rpm/<channel>/packages/ that is what the indices name, with
# the size they give.
python3 -I - "$site" <<'EOF' || fail "listings"
import gzip, os, re, sys, urllib.parse
site = sys.argv[1]
# Expected entries per directory: {dir: {name: size}}, "name/" and "-" for a
# directory.
tree = {"": {}}
def add(path, size):
    parts = path.split("/")
    for i in range(1, len(parts)):
        tree.setdefault("/".join(parts[:i]), {})
        tree["/".join(parts[:i - 1])][parts[i - 1] + "/"] = "-"
    if parts[-1]:
        tree["/".join(parts[:-1])][parts[-1]] = str(size)
for top, dirs, files in os.walk(site):
    dirs[:] = [d for d in dirs if not d.startswith(".")]
    rel = os.path.relpath(top, site)
    rel = "" if rel == "." else rel + "/"
    for d in dirs:
        add(rel + d + "/", None)
    for f in files:
        if not f.startswith(".") and f != "index.html":
            add(rel + f, os.path.getsize(os.path.join(top, f)))
for top, dirs, files in os.walk(os.path.join(site, "apt", "dists")):
    dirs[:] = [d for d in dirs if d != "by-hash"]
    if "Packages" in files:
        for st in open(os.path.join(top, "Packages")).read().split("\n\n"):
            m = dict(re.findall(r"^(Filename|Size): (.*)$", st, re.M))
            if m:
                add("apt/" + m["Filename"], m["Size"])
for ch in ("stable", "testing"):
    r = os.path.join(site, "rpm", ch)
    href = re.search(r'href="(repodata/[^"]*primary\.xml\.gz)"', open(os.path.join(r, "repodata", "repomd.xml")).read()).group(1)
    for pkg in gzip.open(os.path.join(r, href)).read().decode().split("<package ")[1:]:
        add("rpm/%s/%s" % (ch, re.search(r'<location href="([^"]*)"', pkg).group(1)),
            re.search(r'<size package="(\d+)"', pkg).group(1))

row_re = re.compile(r'<a href="([^"]+)">[^<]*</a> +\d\d-[A-Z][a-z]{2}-\d{4} \d\d:\d\d +(-|\d+)$')
for d, entries in sorted(tree.items()):
    f = os.path.join(site, d, "index.html")
    if not os.path.isfile(f):
        sys.exit("FAIL: %s/ has no index.html" % d)
    body = open(f, newline="").read()
    head = "<html>\r\n<head><title>Index of "
    if not body.startswith(head) or not body.endswith("</pre><hr></body>\r\n</html>\r\n"):
        sys.exit("FAIL: %s/index.html is not an autoindex page" % d)
    title = body[len(head):body.index("</title>")]
    if not title.endswith("/" + d + ("/" if d else "")):
        sys.exit("FAIL: %s/index.html has the title 'Index of %s'" % (d, title))
    got = []
    for row in body.split('<a href="../">../</a>\r\n', 1)[1].split("</pre>")[0].split("\r\n")[:-1]:
        m = row_re.match(row)
        if not m:
            sys.exit("FAIL: %s/index.html: not an autoindex line: %r" % (d, row))
        got.append((urllib.parse.unquote(m.group(1)), m.group(2)))
    # nginx compares the names without the slash of a directory.
    want = sorted(entries.items(), key=lambda e: (not e[0].endswith("/"), e[0].rstrip("/")))
    if got != want:
        sys.exit("FAIL: %s/index.html lists %s, expected %s" % (d, got, want))
pkg_dirs = [d for d in tree if re.fullmatch(r"apt/pool/[^/]+|rpm/(stable|testing)/packages/[^/]+", d)]
if not pkg_dirs:
    sys.exit("FAIL: no package directory listed")
print("ok   %d listings name exactly their directory's entries, %d of them package directories from the indices"
      % (len(tree), len(pkg_dirs)))
EOF
