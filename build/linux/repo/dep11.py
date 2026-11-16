#!/usr/bin/env python3
"""Turn an AppStream metainfo file into one DEP-11 component document.

publish-repo.sh calls this once per release and keeps the result in
.state/apt/<tag>/component.yml; every suite then concatenates a DEP-11 header
and the component of its newest release into main/dep11/Components-<arch>.yml.

DEP-11 is the YAML form of an AppStream catalog that apt downloads next to the
Packages files (see /etc/apt/apt.conf.d/50appstream). Software centres (Ubuntu
App Center, GNOME Software, Discover) read the developer, licence, icon and
description from it. The metainfo file inside the package is not enough: it
only becomes visible after the package is installed.

Spec: https://www.freedesktop.org/software/appstream/docs/sect-AppStream-YAML.html

Usage:
  dep11.py --metainfo FILE --package NAME [--cached-icon NAME:WxH ...]
           [--remote-icon URL:WxH] [--release VERSION:TYPE:UNIXTIME]

Only the Python standard library is used (the CI runner and the test
containers have no PyYAML). The output uses block style and double-quoted
JSON strings, which are valid YAML scalars.
"""

import argparse
import datetime
import json
import sys
import xml.etree.ElementTree as ET

XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"


def lang_of(el):
    return el.get(XML_LANG) or "C"


def text_of(el):
    return " ".join("".join(el.itertext()).split())


def localized(root, tag):
    """{lang: text} for every <tag> directly below the component."""
    out = {}
    for el in root.findall(tag):
        out.setdefault(lang_of(el), text_of(el))
    return out


def markup(el):
    """Re-serialise a <p>, <ul> or <ol> element as AppStream description markup."""
    if el.tag == "p":
        return "<p>%s</p>" % escape(text_of(el))
    items = "".join("<li>%s</li>" % escape(text_of(li)) for li in el.findall("li"))
    return "<%s>%s</%s>" % (el.tag, items, el.tag)


def escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def description(root):
    """{lang: markup}. Translations sit either on <description xml:lang> or on
    the single <p>/<li> elements (the form translation tools produce)."""
    out = {}
    for desc in root.findall("description"):
        dlang = lang_of(desc)
        for child in desc:
            if child.tag not in ("p", "ul", "ol"):
                continue
            if child.tag == "p":
                lang = child.get(XML_LANG) or dlang
                out.setdefault(lang, []).append(markup(child))
            else:
                # Split a list by the language of its items.
                langs = {}
                for li in child.findall("li"):
                    langs.setdefault(li.get(XML_LANG) or dlang, []).append(li)
                for lang, lis in langs.items():
                    items = "".join("<li>%s</li>" % escape(text_of(li)) for li in lis)
                    out.setdefault(lang, []).append(
                        "<%s>%s</%s>" % (child.tag, items, child.tag))
    return {k: "".join(v) for k, v in out.items()}


def to_timestamp(date):
    """AppStream dates are ISO 8601 (YYYY-MM-DD, optionally with a time);
    DEP-11 wants seconds since the epoch."""
    d = datetime.datetime.fromisoformat(date.replace("Z", "+00:00"))
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp())


def q(s):
    return json.dumps(s, ensure_ascii=False)


class Writer:
    def __init__(self):
        self.lines = []

    def scalar(self, key, value, indent=0):
        self.lines.append("%s%s: %s" % (" " * indent, key, q(value)))

    def mapping(self, key, d, indent=0):
        if not d:
            return
        self.lines.append("%s%s:" % (" " * indent, key))
        # "C" first, the rest sorted, so the output is stable.
        for k in sorted(d, key=lambda k: (k != "C", k)):
            self.scalar(k, d[k], indent + 2)

    def seq(self, key, values, indent=0):
        if not values:
            return
        self.lines.append("%s%s:" % (" " * indent, key))
        for v in values:
            self.lines.append("%s- %s" % (" " * indent, q(v)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--metainfo", required=True)
    ap.add_argument("--package", required=True)
    ap.add_argument("--cached-icon", action="append", default=[],
                    help="NAME:WxH of an icon inside icons-WxH.tar.gz")
    ap.add_argument("--remote-icon", action="append", default=[], help="URL:WxH")
    ap.add_argument("--release", action="append", default=[],
                    help="VERSION:TYPE:UNIXTIME, added when the metainfo lists no release")
    a = ap.parse_args()

    root = ET.parse(a.metainfo).getroot()
    if root.tag != "component":
        sys.exit("dep11.py: %s: root element is <%s>, not <component>" % (a.metainfo, root.tag))

    cid = (root.findtext("id") or "").strip()
    if not cid:
        sys.exit("dep11.py: %s has no <id>" % a.metainfo)
    ctype = root.get("type") or "generic"

    w = Writer()
    w.lines.append("---")
    w.scalar("Type", ctype)
    w.scalar("ID", cid)
    w.scalar("Package", a.package)
    w.mapping("Name", localized(root, "name"))
    w.mapping("Summary", localized(root, "summary"))
    w.mapping("Description", description(root))

    lic = (root.findtext("project_license") or "").strip()
    if lic:
        w.scalar("ProjectLicense", lic)

    # AppStream 1.0 reads <developer id><name>; AppStream 0.x and the Ubuntu
    # App Center read the older <developer_name>. Emit both.
    dev = root.find("developer")
    dev_names = localized(root, "developer_name")
    if dev is not None:
        names = localized(dev, "name")
        dev_names = dev_names or names
        w.lines.append("Developer:")
        if dev.get("id"):
            w.scalar("id", dev.get("id"), 2)
        w.mapping("name", names, 2)
    w.mapping("DeveloperName", dev_names)

    urls = {}
    for u in root.findall("url"):
        urls.setdefault(u.get("type") or "homepage", (u.text or "").strip())
    if urls:
        w.lines.append("Url:")
        for k in sorted(urls):
            w.scalar(k, urls[k], 2)

    cats = [c.text.strip() for c in root.findall("categories/category") if c.text]
    w.seq("Categories", cats)
    kws = [k.text.strip() for k in root.findall("keywords/keyword")
           if k.text and lang_of(k) == "C"]
    if kws:
        w.lines.append("Keywords:")
        w.seq("C", kws, 2)

    launch = [l.text.strip() for l in root.findall("launchable") if l.text
              and l.get("type") == "desktop-id"]
    if launch:
        w.lines.append("Launchable:")
        w.seq("desktop-id", launch, 2)

    provides = {}
    for p in root.findall("provides/*"):
        if p.text:
            key = {"binary": "binaries", "library": "libraries",
                   "mediatype": "mediatypes", "id": "ids"}.get(p.tag)
            if key:
                provides.setdefault(key, []).append(p.text.strip())
    if provides:
        w.lines.append("Provides:")
        for k in sorted(provides):
            w.seq(k, provides[k], 2)

    stock = [i.text.strip() for i in root.findall("icon") if i.text and i.get("type") == "stock"]
    cached = []
    for spec in a.cached_icon:
        name, size = spec.rsplit(":", 1)
        width, height = size.split("x")
        cached.append((name, int(width), int(height)))
    remote = []
    for spec in a.remote_icon:
        url, size = spec.rsplit(":", 1)
        width, height = size.split("x")
        remote.append((url, int(width), int(height)))
    remote += [(i.text.strip(), int(i.get("width", 0)), int(i.get("height", 0)))
               for i in root.findall("icon") if i.text and i.get("type") == "remote"]
    if stock or cached or remote:
        w.lines.append("Icon:")
        if stock:
            w.scalar("stock", stock[0], 2)
        for kind, entries in (("cached", cached), ("remote", remote)):
            if not entries:
                continue
            w.lines.append("  %s:" % kind)
            for ref, width, height in entries:
                w.lines.append("  - %s: %s" % ("name" if kind == "cached" else "url", q(ref)))
                if width:
                    w.lines.append("    width: %d" % width)
                if height:
                    w.lines.append("    height: %d" % height)

    releases = []
    for r in root.findall("releases/release"):
        rel = {"version": r.get("version"), "type": r.get("type") or "stable"}
        if r.get("timestamp"):
            rel["unix-timestamp"] = int(r.get("timestamp"))
        elif r.get("date"):
            rel["unix-timestamp"] = to_timestamp(r.get("date"))
        releases.append(rel)
    if not releases:
        for spec in a.release:
            version, rtype, ts = spec.rsplit(":", 2)
            releases.append({"version": version, "type": rtype, "unix-timestamp": int(ts)})
    if releases:
        w.lines.append("Releases:")
        for rel in releases:
            w.lines.append("- version: %s" % q(rel["version"]))
            w.lines.append("  type: %s" % q(rel["type"]))
            if "unix-timestamp" in rel:
                w.lines.append("  unix-timestamp: %d" % rel["unix-timestamp"])

    oars = root.find("content_rating")
    if oars is not None:
        attrs = {c.get("id"): (c.text or "").strip() for c in oars.findall("content_attribute")}
        w.lines.append("ContentRating:")
        if attrs:
            w.lines.append("  %s:" % (oars.get("type") or "oars-1.1"))
            for k in sorted(attrs):
                w.scalar(k, attrs[k], 4)
        else:
            w.lines.append("  %s: {}" % (oars.get("type") or "oars-1.1"))

    sys.stdout.write("\n".join(w.lines) + "\n")


if __name__ == "__main__":
    main()
