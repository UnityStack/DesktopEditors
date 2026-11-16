#!/usr/bin/env python3
"""Write a directory listing, index.html, into every directory of the site.

GitHub Pages lists no directories, so publish-repo.sh calls this last and
every directory below packages.unitystack.eu/euro-office/ answers like a
directory that nginx's autoindex module lists: "Index of <path>", then one
line per entry with its date (UTC) and size, directories first, in the same
HTML down to the CRLF line ends. Hidden entries (.state/, .nojekyll) are not
listed, and neither is the index.html a listing is written to.

apt/pool/ and rpm/<channel>/packages/ hold no files on the site: nginx
redirects their paths to the GitHub release assets. Their listings name what
the indices name, the Filename: of every apt Packages file and the location
of every package in the rpm primary metadata, with the size the index gives.

Dates: an entry keeps the date of the previous run while its content stays
the same (for a directory: the names in it), else it gets --now. Every
entry's checksum and date are kept in .state/listing.tsv, so a tree that did
not change gives the same listings again.

Usage:
  autoindex.py --site DIR --base-url URL --now UNIXTIME

Only the Python standard library is used.
"""

import argparse
import bz2
import gzip
import hashlib
import html
import lzma
import os
import sys
import time
import urllib.parse
import xml.etree.ElementTree as ET

STATE = ".state/listing.tsv"
INDEX = "index.html"
# nginx: NGX_HTTP_AUTOINDEX_NAME_LEN, the width of the name column.
NAME_LEN = 50
MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
REPO_NS = "{http://linux.duke.edu/metadata/repo}"
COMMON_NS = "{http://linux.duke.edu/metadata/common}"


class Entry:
    def __init__(self, size=None, ident=None):
        self.children = {} if size is None else None
        self.size = size
        self.ident = ident
        self.mtime = None

    @property
    def is_dir(self):
        return self.children is not None


def add(root, path, size=None, ident=None):
    """Adds a file, or a directory when size is None."""
    parts = path.split("/")
    node = root
    for p in parts[:-1]:
        node = node.children.setdefault(p, Entry())
        if not node.is_dir:
            sys.exit("autoindex: %s is a file and a directory" % path)
    if size is None:
        node.children.setdefault(parts[-1], Entry())
    else:
        node.children[parts[-1]] = Entry(size, ident)


def check_name(path):
    # ASCII only: nginx pads names with other characters differently.
    if not all(" " <= c <= "~" for c in path):
        sys.exit("autoindex: refusing a name with a character outside printable ASCII: %r" % path)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return "sha256:" + h.hexdigest()


def site_files(site, root):
    for top, dirs, files in os.walk(site):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        rel = os.path.relpath(top, site)
        for d in dirs:
            path = d if rel == "." else rel + "/" + d
            check_name(path)
            add(root, path)
        for f in files:
            if f.startswith(".") or f == INDEX:
                continue
            path = f if rel == "." else rel + "/" + f
            check_name(path)
            add(root, path, os.path.getsize(os.path.join(top, f)), sha256(os.path.join(top, f)))


def apt_packages(site, root):
    dists = os.path.join(site, "apt", "dists")
    if not os.path.isdir(dists):
        return
    for top, dirs, files in os.walk(dists):
        dirs[:] = [d for d in dirs if d != "by-hash"]
        if "Packages" not in files:
            continue
        with open(os.path.join(top, "Packages"), encoding="utf-8") as f:
            for stanza in f.read().split("\n\n"):
                fields = {}
                for line in stanza.splitlines():
                    if line and not line[0].isspace() and ":" in line:
                        k, v = line.split(":", 1)
                        fields[k] = v.strip()
                if "Filename" in fields:
                    path = "apt/" + fields["Filename"]
                    check_name(path)
                    add(root, path, int(fields["Size"]), "sha256:" + fields["SHA256"])


def open_compressed(path):
    if path.endswith(".gz"):
        return gzip.open(path)
    if path.endswith(".xz"):
        return lzma.open(path)
    if path.endswith(".bz2"):
        return bz2.open(path)
    if path.endswith(".zst"):
        sys.exit("autoindex: %s: zstd is not supported" % path)
    return open(path, "rb")


def rpm_packages(site, root):
    rpm = os.path.join(site, "rpm")
    if not os.path.isdir(rpm):
        return
    for ch in sorted(os.listdir(rpm)):
        repomd = os.path.join(rpm, ch, "repodata", "repomd.xml")
        if not os.path.isfile(repomd):
            continue
        for data in ET.parse(repomd).getroot().findall(REPO_NS + "data"):
            if data.get("type") != "primary":
                continue
            href = data.find(REPO_NS + "location").get("href")
            with open_compressed(os.path.join(rpm, ch, href)) as f:
                for p in ET.parse(f).getroot().findall(COMMON_NS + "package"):
                    path = "rpm/%s/%s" % (ch, p.find(COMMON_NS + "location").get("href"))
                    check_name(path)
                    c = p.find(COMMON_NS + "checksum")
                    add(root, path, int(p.find(COMMON_NS + "size").get("package")),
                        "%s:%s" % (c.get("type"), c.text.strip()))


def date_entries(node, path, old, new, now):
    """Sets mtime on every entry below node; directories after their content."""
    for name, child in node.children.items():
        p = path + name
        if child.is_dir:
            date_entries(child, p + "/", old, new, now)
            names = sorted(n + "/" if c.is_dir else n for n, c in child.children.items())
            child.ident = "names:" + hashlib.sha256("\n".join(names).encode()).hexdigest()
            p += "/"
        ident, mtime = old.get(p, (None, None))
        child.mtime = mtime if ident == child.ident else now
        new[p] = (child.ident, child.mtime)


def listing(url_path, node):
    esc = lambda s: html.escape(s, quote=True).replace("&#x27;", "'")
    lines = ["<html>",
             "<head><title>Index of %s</title></head>" % esc(url_path),
             "<body>",
             '<h1>Index of %s</h1><hr><pre><a href="../">../</a>' % esc(url_path)]
    for name, e in sorted(node.children.items(), key=lambda i: (not i[1].is_dir, i[0])):
        href = urllib.parse.quote(name, safe="!$()*+,-.:;=@_~") + ("/" if e.is_dir else "")
        n = len(name)
        if n > NAME_LEN:
            shown, pad = esc(name[:NAME_LEN - 3]) + "..&gt;", 0
        else:
            shown = esc(name)
            if e.is_dir and n < NAME_LEN:
                shown, n = shown + "/", n + 1
            pad = NAME_LEN - n
        t = time.gmtime(e.mtime)
        date = "%02d-%s-%d %02d:%02d" % (t.tm_mday, MONTHS[t.tm_mon - 1], t.tm_year, t.tm_hour, t.tm_min)
        size = "%19s" % ("-" if e.is_dir else e.size)
        lines.append('<a href="%s">%s</a>%s %s %s' % (href, shown, " " * pad, date, size))
    lines += ["</pre><hr></body>", "</html>", ""]
    return "\r\n".join(lines)


def write_listings(site, node, rel, url_path):
    d = os.path.join(site, rel)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, INDEX), "w", encoding="utf-8", newline="") as f:
        f.write(listing(url_path, node))
    for name, child in node.children.items():
        if child.is_dir:
            write_listings(site, child, os.path.join(rel, name), url_path + name + "/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site", required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--now", required=True, type=int)
    a = ap.parse_args()

    root = Entry()
    site_files(a.site, root)
    apt_packages(a.site, root)
    rpm_packages(a.site, root)

    old = {}
    state = os.path.join(a.site, STATE)
    if os.path.isfile(state):
        with open(state, encoding="utf-8") as f:
            for line in f:
                p, ident, mtime = line.rstrip("\n").split("\t")
                old[p] = (ident, int(mtime))
    new = {}
    date_entries(root, "", old, new, a.now)
    os.makedirs(os.path.dirname(state), exist_ok=True)
    with open(state, "w", encoding="utf-8") as f:
        for p in sorted(new):
            f.write("%s\t%s\t%d\n" % (p, new[p][0], new[p][1]))

    base = urllib.parse.urlsplit(a.base_url).path.rstrip("/") + "/"
    write_listings(a.site, root, "", base)


if __name__ == "__main__":
    main()
