#!/usr/bin/env python3
"""Sparkle update feeds (appcasts) of the macOS app.

The app finds its updates with Sparkle (the framework desktop-apps bundles,
2.0.0): once a day it reads the feed named by SUFeedURL in its Info.plist,
takes the newest item whose sparkle:version is above its own CFBundleVersion,
downloads the DMG the item names and installs it only if the item's EdDSA
signature verifies with the SUPublicEDKey of the running app. See "Automatic
updates (Sparkle)" in build/macos/README.md.

Subcommands:

  bundle-version TAG
      Prints the CFBundleVersion of a CE release tag (see bundle_version).

  check-key --public-key FILE
      Checks the private key in $SPARKLE_ED_PRIVATE_KEY (or --private-key-file)
      against the committed public key: Sparkle's format, and that its public
      half is FILE. Prints nothing secret.

  generate --private-out FILE --public-out FILE
      Makes the release key pair in the format of Sparkle 2.0.0's
      generate_keys -x, without a keychain. Refuses to overwrite either
      file and to write the private key into a git work tree.

  test-key --private-out FILE --public-out FILE
      Makes a throwaway key pair the same way, for local tests.

  verify --public-key FILE --signature SIG FILE
      Checks Sparkle's EdDSA signature of FILE (RFC 8032 Ed25519 over the
      file's bytes), independently of Sparkle's tools.

  item --tag TAG --repo OWNER/NAME --asset NAME --dmg FILE --info-plist FILE
       --signature SIG --length N --public-key FILE --out JSON
      Describes a signed, notarized DMG as one update (JSON), after checking
      the signature, the length and the app's update settings.

  publish [--update JSON --dmg FILE --tag TAG --channel stable|prerelease
           [--notes HTML]] --state DIR --out DIR --base-url URL
           [--public-key FILE] [--keep N] [--now UNIXTIME]
      Adds an update to the per-release fragments in --state (one JSON per
      tag, like the package repository's .state/) and writes from them
      --out/appcast.xml (stable releases) and --out/appcast-testing.xml
      (stable and prerelease), the newest --keep items each. Without
      --update it only writes the feeds again.

Only the Python standard library is used.
"""

import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import sys
import time
from xml.sax.saxutils import escape, quoteattr

FEEDS = {"stable": "appcast.xml", "testing": "appcast-testing.xml"}
FEED_TITLES = {
    "stable": "Euro-Office Community Edition (UnityStack GmbH)",
    "testing": "Euro-Office Community Edition testing (UnityStack GmbH)",
}
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FORMAT = 1


def die(msg):
    if os.environ.get("GITHUB_ACTIONS"):
        print("::error::appcast.py: %s" % msg, file=sys.stderr)
    else:
        print("appcast.py: error: %s" % msg, file=sys.stderr)
    sys.exit(1)


# ── Versions ─────────────────────────────────────────────────────

# The CE tag formats of the version job of build.yml. Its upstream formats
# (vX.Y.Z, vX.Y.Z-N, vX.Y.Z-rc.N) are left out: they would get the
# CFBundleVersion of a CE tag (v9.3.6 and v9.3.6-ce, v9.3.6-1 and
# v9.3.6-ce.1), and the feeds refuse a second tag with the same one.
TAG_RE = re.compile(
    r"^v(\d+)\.(\d+)\.(\d+)-ce"
    r"(?:\.(?P<cebuild>[1-9]\d*)"
    r"|\.(?P<stage>rc|beta|alpha)\.(?P<pre>[1-9]\d*))?$"
)
STAGES = {"alpha": 1, "beta": 2, "rc": 3}
FINAL = 5


def bundle_version(tag):
    """CFBundleVersion of a CE tag: one integer, higher for every later release.

    Sparkle offers an item only if its sparkle:version is above the running
    app's CFBundleVersion, and upstream's Info.plist has a fixed build number
    (544 in v9.3.6-ce.rc.1). The digits are X YY ZZ S NNN for vX.Y.Z, stage S
    (1 alpha, 2 beta, 3 rc, 5 final) and number NNN (the N of rc.N, or of a
    rebuild -ce.N; 0 for the final itself):

      v9.3.6-ce.rc.2  -> 903063002
      v9.3.6-ce       -> 903065000
      v9.3.6-ce.1     -> 903065001
      v9.3.7-ce.rc.1  -> 903073001

    Within the CE tags that sorts like the package versions
    (0~ce~rc.2 < 0~ce < 0~ce.1) and stays below 2^31 for X <= 20. Only CE
    tags have macOS updates; any other tag is refused (see TAG_RE). Apple asks for at most three
    period-separated integers here; one integer is the simplest that
    compares the same everywhere.
    """
    m = TAG_RE.match(tag)
    if not m:
        raise ValueError("macOS updates are built only for CE tags (vX.Y.Z-ce, vX.Y.Z-ce.N, "
                         "vX.Y.Z-ce.rc.N; beta/alpha like rc), not for %s" % tag)
    x, y, z = (int(m.group(i)) for i in (1, 2, 3))
    if m.group("stage"):
        stage, n = STAGES[m.group("stage")], int(m.group("pre"))
    else:
        stage, n = FINAL, int(m.group("cebuild") or 0)
    if x > 20 or y > 99 or z > 99 or n > 999:
        raise ValueError("%s is outside the CFBundleVersion scheme (X <= 20, Y and Z <= 99, "
                         "N <= 999); see bundle_version in build/macos/appcast.py" % tag)
    return str(((x * 100 + y) * 100 + z) * 10000 + stage * 1000 + n)


# ── Ed25519 (RFC 8032, section 6), verification and key checks ───
# Sparkle signs with orlp/ed25519. Its private key is the 64-byte expanded
# secret (the clamped scalar, then the nonce prefix), and generate_keys of
# Sparkle 2.0.0 stores it base64-encoded together with the public key:
# 64 + 32 bytes, 128 characters.

P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _inv(x):
    return pow(x, P - 2, P)


def _add(p1, p2):
    a = (p1[1] - p1[0]) * (p2[1] - p2[0]) % P
    b = (p1[1] + p1[0]) * (p2[1] + p2[0]) % P
    c = 2 * p1[3] * p2[3] * D % P
    d = 2 * p1[2] * p2[2] % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(s, pt):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, pt)
        pt = _add(pt, pt)
        s >>= 1
    return q


def _equal(p1, p2):
    return ((p1[0] * p2[2] - p2[0] * p1[2]) % P == 0
            and (p1[1] * p2[2] - p2[1] * p1[2]) % P == 0)


def _recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * _inv(D * y * y + 1) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


_GY = 4 * _inv(5) % P
_GX = _recover_x(_GY, 0)
G = (_GX, _GY, 1, _GX * _GY % P)


def _compress(pt):
    zi = _inv(pt[2])
    x, y = pt[0] * zi % P, pt[1] * zi % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decompress(b):
    if len(b) != 32:
        return None
    y = int.from_bytes(b, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % P)


def _clamp(b):
    b = bytearray(b[:32])
    b[0] &= 248
    b[31] &= 63
    b[31] |= 64
    return bytes(b)


def verify_file(public, signature, path):
    """Ed25519 verification of a file's bytes, hashed in chunks."""
    if len(signature) != 64:
        return False
    a = _decompress(public)
    r = _decompress(signature[:32])
    s = int.from_bytes(signature[32:], "little")
    if a is None or r is None or s >= L:
        return False
    h = hashlib.sha512(signature[:32] + public)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    k = int.from_bytes(h.digest(), "little") % L
    return _equal(_mul(s, G), _add(r, _mul(k, a)))


def read_public_key(path):
    """The committed public key: one line, base64 of 32 bytes (SUPublicEDKey)."""
    try:
        with open(path, encoding="ascii") as f:
            text = f.read().strip()
    except OSError as e:
        die("cannot read the Sparkle public key %s: %s. The owner creates it once, see "
            "\"Automatic updates (Sparkle)\" in build/macos/README.md." % (path, e.strerror))
    try:
        raw = base64.b64decode(text, validate=True)
    except ValueError:
        raw = b""
    if len(raw) != 32 or _decompress(raw) is None:
        die("%s is not a Sparkle public key (base64 of 32 bytes, the SUPublicEDKey "
            "appcast.py generate writes)" % path)
    return text, raw


def public_of_private(raw):
    """The public key that belongs to a private key in one of Sparkle's formats:
    96 bytes (expanded secret + public, Sparkle 2.0.0's generate_keys) or a
    32-byte seed (later Sparkle versions)."""
    if len(raw) == 96:
        derived = _compress(_mul(int.from_bytes(raw[:32], "little"), G))
        if raw[:32] != _clamp(raw[:32]) or derived != raw[64:]:
            raise ValueError("the private key and the public key in it do not belong together")
        return derived, "expanded"
    if len(raw) == 32:
        a = _clamp(hashlib.sha512(raw).digest())
        return _compress(_mul(int.from_bytes(a, "little"), G)), "seed"
    raise ValueError("%d bytes, expected 96 (appcast.py generate, or generate_keys -x of Sparkle 2.0.0)" % len(raw))


def cmd_check_key(args):
    text, public = read_public_key(args.public_key)
    if args.private_key_file:
        with open(args.private_key_file, encoding="ascii") as f:
            secret = f.read()
    else:
        secret = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "")
    secret = secret.strip()
    if not secret:
        die("SPARKLE_ED_PRIVATE_KEY is empty. Set it in the GitHub environment 'signing' "
            "(see \"Automatic updates (Sparkle)\" in build/macos/README.md).")
    try:
        raw = base64.b64decode(secret, validate=True)
        derived, kind = public_of_private(raw)
    except ValueError as e:
        die("SPARKLE_ED_PRIVATE_KEY is not a Sparkle private key: %s" % e)
    if kind == "seed":
        die("SPARKLE_ED_PRIVATE_KEY is a 32-byte seed, which the sign_update of the bundled "
            "Sparkle 2.0.0 does not read. Use the 96-byte format of appcast.py generate "
            "(the same as generate_keys -x of Sparkle 2.0.0).")
    if derived != public:
        die("SPARKLE_ED_PRIVATE_KEY belongs to the public key %s, not to %s (%s). Every "
            "installed app checks updates with the committed key." % (
                base64.b64encode(derived).decode(), text, args.public_key))
    print("SPARKLE_ED_PRIVATE_KEY matches %s (%s)." % (args.public_key, text))


def new_key_pair(private_out, public_out, public_mode):
    """A key pair as Sparkle 2.0.0's generate_keys makes it (ed25519_create_keypair
    of orlp/ed25519 from 32 random bytes): the private key file holds
    base64(expanded secret + public key), the 96 bytes generate_keys -x
    exports and sign_update -f reads; the public key file the SUPublicEDKey.
    The private key file is created with mode 600 and never overwritten."""
    seed = os.urandom(32)
    h = hashlib.sha512(seed).digest()
    a = _clamp(h)
    public = _compress(_mul(int.from_bytes(a, "little"), G))
    old = os.umask(0o077)
    try:
        with open(private_out, "x", encoding="ascii") as f:
            f.write(base64.b64encode(a + h[32:] + public).decode() + "\n")
    finally:
        os.umask(old)
    with open(public_out, public_mode, encoding="ascii") as f:
        f.write(base64.b64encode(public).decode() + "\n")
    return base64.b64encode(public).decode()


def git_work_tree_of(path):
    """The git work tree that contains path, or None."""
    d = os.path.dirname(os.path.abspath(path))
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def cmd_generate(args):
    tree = git_work_tree_of(os.path.realpath(args.private_out))
    if tree:
        die("%s is inside the git work tree %s; write the private key outside any "
            "repository" % (args.private_out, tree))
    for path in (args.private_out, args.public_out):
        if os.path.lexists(path):
            die("%s already exists; appcast.py generate does not overwrite a key" % path)
    try:
        text = new_key_pair(args.private_out, args.public_out, "x")
    except OSError as e:
        die("cannot write the key pair: %s" % e)
    print("Private key (mode 600, keep it secret): %s" % args.private_out)
    print("Public key (SUPublicEDKey): %s, in %s" % (text, args.public_out))


def cmd_test_key(args):
    new_key_pair(args.private_out, args.public_out, "w")
    print("Throwaway key pair for tests: %s (private), %s (public)." % (
        args.private_out, args.public_out))


def decode_signature(sig):
    try:
        raw = base64.b64decode(sig, validate=True)
    except ValueError:
        raw = b""
    if len(raw) != 64:
        die("%r is not an EdDSA signature (base64 of 64 bytes)" % sig)
    return raw


def cmd_verify(args):
    _, public = read_public_key(args.public_key)
    if not verify_file(public, decode_signature(args.signature), args.file):
        die("the EdDSA signature does not verify %s with %s" % (args.file, args.public_key))
    print("EdDSA signature OK: %s, %s." % (args.file, args.public_key))


# ── One update ───────────────────────────────────────────────────

def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


ASSET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.dmg$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def cmd_item(args):
    text, public = read_public_key(args.public_key)
    if not ASSET_RE.match(args.asset):
        die("asset name %r is not GitHub's name of a .dmg asset" % args.asset)
    if not REPO_RE.match(args.repo):
        die("--repo must be owner/name")
    try:
        version = bundle_version(args.tag)
    except ValueError as e:
        die(str(e))
    with open(args.info_plist, "rb") as f:
        info = plistlib.load(f)

    problems = []
    if str(info.get("CFBundleVersion")) != version:
        problems.append("CFBundleVersion is %r, the tag needs %s" % (info.get("CFBundleVersion"), version))
    if info.get("SUPublicEDKey") != text:
        problems.append("SUPublicEDKey is %r, not the committed %s" % (info.get("SUPublicEDKey"), text))
    feed = info.get("SUFeedURL")
    if not isinstance(feed, str) or not feed.startswith("https://"):
        problems.append("SUFeedURL is %r, not an https URL" % feed)
    if info.get("SUEnableAutomaticChecks") is not True:
        problems.append("SUEnableAutomaticChecks is %r, not true" % info.get("SUEnableAutomaticChecks"))
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "LSMinimumSystemVersion"):
        if not isinstance(info.get(key), str) or not info.get(key):
            problems.append("%s is missing" % key)
    if problems:
        die("the app in %s is not set up for updates: %s" % (args.dmg, "; ".join(problems)))

    size = os.path.getsize(args.dmg)
    if size != args.length:
        die("sign_update reports length %d, %s has %d bytes" % (args.length, args.dmg, size))
    signature = decode_signature(args.signature)
    if not verify_file(public, signature, args.dmg):
        die("the EdDSA signature of %s does not verify with %s" % (args.dmg, args.public_key))

    item = {
        "format": FORMAT,
        "tag": args.tag,
        "asset": args.asset,
        "url": "https://github.com/%s/releases/download/%s/%s" % (args.repo, args.tag, args.asset),
        "release_url": "https://github.com/%s/releases/tag/%s" % (args.repo, args.tag),
        "length": size,
        "sha256": sha256_of(args.dmg),
        "ed_signature": args.signature,
        "public_key": text,
        "bundle_id": info["CFBundleIdentifier"],
        "version": version,
        "short_version": info["CFBundleShortVersionString"],
        "minimum_system_version": info["LSMinimumSystemVersion"],
        "feed_url": feed,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(item, f, indent=2, sort_keys=True)
        f.write("\n")
    print("Update %s: sparkle:version %s (%s), %d bytes, EdDSA signature verified with %s; feed %s."
          % (args.tag, version, item["short_version"], size, args.public_key, feed))


# ── Feeds ────────────────────────────────────────────────────────

def feed_url(base_url, feed):
    return "%s/macos/%s" % (base_url.rstrip("/"), FEEDS[feed])


def load_state(state):
    items = []
    if not os.path.isdir(state):
        return items
    for name in sorted(os.listdir(state)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(state, name), encoding="utf-8") as f:
            items.append(json.load(f))
    return items


def rfc822(ts):
    # English names whatever the locale, the form of Sparkle's sample appcast.
    t = time.gmtime(ts)
    return "%s, %02d %s %d %02d:%02d:%02d +0000" % (
        "Mon Tue Wed Thu Fri Sat Sun".split()[t.tm_wday], t.tm_mday,
        "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()[t.tm_mon - 1],
        t.tm_year, t.tm_hour, t.tm_min, t.tm_sec)


def cdata(text):
    return "<![CDATA[%s]]>" % text.replace("]]>", "]]]]><![CDATA[>")


def render(items, feed, base_url):
    url = feed_url(base_url, feed)
    out = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<rss version="2.0" xmlns:sparkle="%s">' % SPARKLE_NS,
        "  <channel>",
        "    <title>%s</title>" % escape(FEED_TITLES[feed]),
        "    <link>%s</link>" % escape(url),
        "    <description>Updates of Euro-Office Community Edition for macOS, built and "
        "signed by UnityStack GmbH.</description>",
        "    <language>en</language>",
    ]
    for it in items:
        out += [
            "    <item>",
            "      <title>%s</title>" % escape("Euro-Office %s" % it["tag"][1:]),
            "      <link>%s</link>" % escape(it["release_url"]),
            "      <sparkle:version>%s</sparkle:version>" % escape(it["version"]),
            "      <sparkle:shortVersionString>%s</sparkle:shortVersionString>" % escape(it["short_version"]),
            "      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>"
            % escape(it["minimum_system_version"]),
            "      <pubDate>%s</pubDate>" % rfc822(it["published"]),
        ]
        if it.get("notes_html"):
            out.append("      <description>%s</description>" % cdata(it["notes_html"]))
        out += [
            "      <enclosure url=%s length=\"%d\" type=\"application/octet-stream\" "
            "sparkle:edSignature=%s/>" % (quoteattr(it["url"]), it["length"], quoteattr(it["ed_signature"])),
            "    </item>",
        ]
    out += ["  </channel>", "</rss>", ""]
    return "\n".join(out)


def write_if_changed(path, text):
    try:
        with open(path, encoding="utf-8") as f:
            if f.read() == text:
                return
    except FileNotFoundError:
        pass
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


REQUIRED = {"format": int, "tag": str, "asset": str, "url": str, "release_url": str, "length": int,
            "sha256": str, "ed_signature": str, "public_key": str, "bundle_id": str, "version": str,
            "short_version": str, "minimum_system_version": str, "feed_url": str}


def cmd_publish(args):
    new = None
    if args.update:
        for opt in ("dmg", "tag", "channel"):
            if not getattr(args, opt):
                die("--update needs --%s" % opt)
        with open(args.update, encoding="utf-8") as f:
            new = json.load(f)
        for key, typ in REQUIRED.items():
            if not isinstance(new.get(key), typ):
                die("%s: %s is missing or not a %s" % (args.update, key, typ.__name__))
        if new["format"] != FORMAT:
            die("%s has format %r, this script writes %d" % (args.update, new["format"], FORMAT))
        if new["tag"] != args.tag:
            die("%s describes %s, not %s" % (args.update, new["tag"], args.tag))
        try:
            expected_version = bundle_version(args.tag)
        except ValueError as e:
            die(str(e))
        if new["version"] != expected_version:
            die("%s has sparkle:version %s, %s needs %s" % (args.update, new["version"], args.tag,
                                                           expected_version))
        if not new["url"].startswith("https://github.com/") or not new["url"].endswith("/" + new["asset"]):
            die("%s: download URL %s is not a GitHub release asset" % (args.update, new["url"]))
        # The app of a stable release reads the stable feed, a prerelease's
        # the testing feed (sign-macos bakes it into Info.plist).
        want = feed_url(args.base_url, "stable" if args.channel == "stable" else "testing")
        if new["feed_url"] != want:
            die("the %s app of %s reads %s, it should read %s" % (args.channel, args.tag,
                                                                  new["feed_url"], want))
        if not args.public_key:
            die("--update needs --public-key")
        text, public = read_public_key(args.public_key)
        if new["public_key"] != text:
            die("%s was signed for the public key %s, the committed one is %s" % (
                args.update, new["public_key"], text))
        # The bytes clients download: the release asset, not the artifact.
        size = os.path.getsize(args.dmg)
        if size != new["length"] or sha256_of(args.dmg) != new["sha256"]:
            die("%s (%d bytes) is not the DMG %s describes (%d bytes, SHA-256 %s)" % (
                args.dmg, size, args.update, new["length"], new["sha256"]))
        if not verify_file(public, decode_signature(new["ed_signature"]), args.dmg):
            die("the EdDSA signature in %s does not verify %s" % (args.update, args.dmg))
        print("Verified %s: %d bytes, SHA-256 and EdDSA signature (%s) match." % (
            args.dmg, size, args.public_key))

    items = load_state(args.state)
    if new is not None:
        previous = next((it for it in items if it["tag"] == args.tag), None)
        for it in items:
            if it["tag"] != args.tag and it["version"] == new["version"]:
                die("%s has the sparkle:version %s of the published %s" % (args.tag, new["version"], it["tag"]))
        new["channel"] = args.channel
        # A re-run keeps the date while the DMG stays the same.
        if previous and previous.get("sha256") == new["sha256"] and previous.get("published"):
            new["published"] = previous["published"]
        else:
            new["published"] = args.now
        if args.notes:
            with open(args.notes, encoding="utf-8") as f:
                new["notes_html"] = f.read().strip()
        elif previous and previous.get("notes_html"):
            new["notes_html"] = previous["notes_html"]
        os.makedirs(args.state, exist_ok=True)
        write_if_changed(os.path.join(args.state, args.tag + ".json"),
                         json.dumps(new, indent=2, sort_keys=True) + "\n")
        items = load_state(args.state)
    if not items:
        return

    os.makedirs(args.out, exist_ok=True)
    items.sort(key=lambda it: int(it["version"]), reverse=True)
    for feed in ("stable", "testing"):
        chosen = [it for it in items if feed == "testing" or it["channel"] == "stable"][:args.keep]
        write_if_changed(os.path.join(args.out, FEEDS[feed]), render(chosen, feed, args.base_url))
        print("%s: %s" % (feed_url(args.base_url, feed), " ".join(it["tag"] for it in chosen) or "(no items)"))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("bundle-version")
    p.add_argument("tag")

    p = sub.add_parser("check-key")
    p.add_argument("--public-key", required=True)
    p.add_argument("--private-key-file", help="instead of $SPARKLE_ED_PRIVATE_KEY")

    p = sub.add_parser("generate")
    p.add_argument("--private-out", required=True)
    p.add_argument("--public-out", required=True)

    p = sub.add_parser("test-key")
    p.add_argument("--private-out", required=True)
    p.add_argument("--public-out", required=True)

    p = sub.add_parser("verify")
    p.add_argument("--public-key", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("file")

    p = sub.add_parser("item")
    for opt in ("--tag", "--repo", "--asset", "--dmg", "--info-plist", "--signature", "--public-key", "--out"):
        p.add_argument(opt, required=True)
    p.add_argument("--length", type=int, required=True)

    p = sub.add_parser("publish")
    p.add_argument("--update")
    p.add_argument("--dmg")
    p.add_argument("--tag")
    p.add_argument("--channel", choices=("stable", "prerelease"))
    p.add_argument("--notes")
    p.add_argument("--public-key")
    p.add_argument("--state", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--base-url", required=True)
    p.add_argument("--keep", type=int, default=10)
    p.add_argument("--now", type=int, default=int(time.time()))

    args = ap.parse_args()
    if args.cmd == "bundle-version":
        try:
            print(bundle_version(args.tag))
        except ValueError as e:
            die(str(e))
    else:
        {"check-key": cmd_check_key, "generate": cmd_generate, "test-key": cmd_test_key, "verify": cmd_verify,
         "item": cmd_item, "publish": cmd_publish}[args.cmd](args)


if __name__ == "__main__":
    main()
