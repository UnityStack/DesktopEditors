#!/usr/bin/env python3
"""Merges OpenPGP public keys without losing a signature or changing their order.

    merge-public-key.py --output <out.asc> <published.asc> <key.asc>...
    merge-public-key.py --drop-revoked-subkeys --output <out.asc> <key.asc>

The first file sets the order (the key installed systems have); every later
file adds the signatures and subkeys the first lacks. See
build/linux/README.md, "Changing the public key". What it does, and why:

- Keeps every signature packet of every file. gpg cannot do this: its
  keyring holds only a subkey's newest binding, so an export drops the
  older ones, and rpm 6 (Fedora) and sqv then reject what the subkey signed
  before its newest binding.
- Keeps the subkeys in the first file's order and appends new ones.
  dnf 4.14 (RHEL 9) shows the first signing subkey's fingerprint when it
  imports the key; sq keyring merge may reorder the subkeys.
- Puts a subkey's revocation behind its bindings. gpg and sq write it in
  front, and rpm 4.14 and 4.16 (openSUSE Leap 15.6, RHEL 9) then refuse the
  whole key ("key 1 import failed", measured Nov 2026).
- Refuses secret key material, more than one key, more than one armored
  block or text after it (rpm 4 imports only the first block), and armor
  with a bad checksum.

Packets are copied byte for byte; two signatures are the same when they
agree in everything but their unhashed subpackets, and the first file's
copy is kept. --drop-revoked-subkeys writes the key without its revoked
subkeys: for rpm 4.14, 4.16 and 4.19, which ignore a subkey revocation
(README, "If the CI secret leaks").
"""
import argparse
import base64
import sys

BEGIN = '-----BEGIN PGP PUBLIC KEY BLOCK-----'
END = '-----END PGP PUBLIC KEY BLOCK-----'
SIG, PRIMARY, SUBKEY, UID, UAT, TRUST = 2, 6, 14, 13, 17, 12
SECRET = {5: 'secret key', 7: 'secret subkey'}


def fail(msg):
    sys.exit(f'merge-public-key.py: {msg}')


def crc24(data):
    crc = 0xB704CE
    for byte in data:
        crc ^= byte << 16
        for _ in range(8):
            crc <<= 1
            if crc & 0x1000000:
                crc ^= 0x1864CFB
    return crc & 0xFFFFFF


def dearmor(name, raw):
    if raw[:1] and raw[0] & 0x80:
        return raw                       # binary
    text = raw.decode('ascii', 'replace')
    lines = [line.rstrip() for line in text.splitlines()]
    if any('PRIVATE KEY BLOCK' in line for line in lines):
        fail(f'{name} contains a secret key (PRIVATE KEY BLOCK)')
    begins = [i for i, line in enumerate(lines) if line.startswith('-----BEGIN PGP')]
    if len(begins) != 1 or lines[begins[0]] != BEGIN:
        fail(f'{name} must hold exactly one armored public key block, not {len(begins)} armored block(s): '
             'rpm 4 imports only the first one')
    start = begins[0] + 1
    if END not in lines[start:]:
        fail(f'{name}: no {END} line')
    end = lines.index(END, start)
    if any(line.strip() for line in lines[:begins[0]] + lines[end + 1:]):
        fail(f'{name} has text outside its armored block')
    pos = start
    while pos < end and lines[pos].strip():   # armor headers, up to the blank line
        if ':' not in lines[pos]:
            break                        # no headers and no blank line
        pos += 1
    if pos < end and not lines[pos].strip():
        pos += 1
    body, crc = [], None
    for line in lines[pos:end]:
        if line.startswith('='):
            crc = line[1:]
            break
        body.append(line.strip())
    data = base64.b64decode(''.join(body), validate=True)
    if crc is not None and base64.b64decode(crc) != crc24(data).to_bytes(3, 'big'):
        fail(f'{name}: armor checksum mismatch')
    return data


def armor(data):
    b64 = base64.b64encode(data).decode()
    crc = base64.b64encode(crc24(data).to_bytes(3, 'big')).decode()
    return '\n'.join([BEGIN, ''] + [b64[i:i + 64] for i in range(0, len(b64), 64)] + ['=' + crc, END]) + '\n'


def packets(name, data):
    """Yields (tag, packet bytes, body bytes)."""
    pos = 0
    while pos < len(data):
        ctb = data[pos]
        if not ctb & 0x80:
            fail(f'{name}: not an OpenPGP packet at offset {pos}')
        if ctb & 0x40:                   # new format
            tag, first = ctb & 0x3F, data[pos + 1]
            if first < 192:
                hlen, length = 2, first
            elif first < 224:
                hlen, length = 3, ((first - 192) << 8) + data[pos + 2] + 192
            elif first == 255:
                hlen, length = 6, int.from_bytes(data[pos + 2:pos + 6], 'big')
            else:
                fail(f'{name}: partial body lengths do not occur in keys')
        else:                            # old format
            tag, ltype = (ctb >> 2) & 0x0F, ctb & 3
            if ltype == 3:
                fail(f'{name}: indeterminate lengths do not occur in keys')
            n = 1 << ltype
            hlen, length = 1 + n, int.from_bytes(data[pos + 1:pos + 1 + n], 'big')
        if pos + hlen + length > len(data):
            fail(f'{name}: truncated packet at offset {pos}')
        yield tag, data[pos:pos + hlen + length], data[pos + hlen:pos + hlen + length]
        pos += hlen + length


def sigtype(body):
    return body[2] if body[0] == 3 else body[1]


def sigid(body):
    """The signature without its unhashed subpackets (v4: what tools may rewrite)."""
    if body[0] != 4:
        return bytes(body)
    n = int.from_bytes(body[4:6], 'big')
    m = int.from_bytes(body[6 + n:8 + n], 'big')
    return bytes(body[:6 + n] + body[8 + n + m:])


class Key:
    """The primary key with its direct signatures, then its components (user
    IDs, user attributes, subkeys), each with its signatures, in file order."""

    def __init__(self, name, data):
        self.primary, self.components = None, []
        current = None
        for tag, packet, body in packets(name, data):
            if tag in SECRET:
                fail(f'{name} contains a {SECRET[tag]} packet: never put secret key material in the public key')
            if tag == TRUST:
                continue
            if tag == PRIMARY:
                if self.primary is not None:
                    fail(f'{name} holds more than one key')
                self.primary = current = [packet, body, []]
            elif tag in (UID, UAT, SUBKEY):
                if self.primary is None:
                    fail(f'{name}: a {tag} packet before the primary key')
                current = [packet, body, []]
                self.components.append(current)
            elif tag == SIG:
                if current is None:
                    fail(f'{name}: a signature before the primary key')
                current[2].append((packet, body))
            else:
                fail(f'{name}: unexpected packet type {tag}')
        if self.primary is None:
            fail(f'{name} holds no public key')

    def merge(self, other, name):
        if other.primary[1] != self.primary[1]:
            fail(f'{name} is another key than the first file')
        added_sigs = added_subs = 0
        for mine, theirs in [(self.primary, other.primary)] + [(self.find(c), c) for c in other.components]:
            if mine is None:
                self.components.append([theirs[0], theirs[1], list(theirs[2])])
                added_subs += tag_of(theirs[0]) == SUBKEY
                added_sigs += len(theirs[2])
                continue
            have = {sigid(b) for _, b in mine[2]}
            for packet, body in theirs[2]:
                if sigid(body) not in have:
                    mine[2].append((packet, body))
                    have.add(sigid(body))
                    added_sigs += 1
        return added_sigs, added_subs

    def find(self, component):
        for c in self.components:
            if c[1] == component[1] and tag_of(c[0]) == tag_of(component[0]):
                return c
        return None

    def subkeys(self):
        return [c for c in self.components if tag_of(c[0]) == SUBKEY]

    def revocations_last(self):
        moved = 0
        for c in self.subkeys():
            sigs = c[2]
            rest = [s for s in sigs if sigtype(s[1]) != 0x28]
            revs = [s for s in sigs if sigtype(s[1]) == 0x28]
            if rest + revs != sigs:
                moved += sum(1 for i, s in enumerate(sigs) if sigtype(s[1]) == 0x28 and any(sigtype(t[1]) != 0x28 for t in sigs[i + 1:]))
                c[2] = rest + revs
        return moved

    def drop_revoked_subkeys(self):
        keep = [c for c in self.components if not (tag_of(c[0]) == SUBKEY and any(sigtype(b) == 0x28 for _, b in c[2]))]
        dropped = len(self.components) - len(keep)
        self.components = keep
        return dropped

    def bytes(self):
        out = [self.primary[0]] + [p for p, _ in self.primary[2]]
        for c in self.components:
            out += [c[0]] + [p for p, _ in c[2]]
        return b''.join(out)

    def sigids(self):
        return {sigid(b) for c in [self.primary] + self.components for _, b in c[2]}


def tag_of(packet):
    return packet[0] & 0x3F if packet[0] & 0x40 else (packet[0] >> 2) & 0x0F


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--output', required=True)
    ap.add_argument('--drop-revoked-subkeys', action='store_true')
    ap.add_argument('keys', nargs='+')
    args = ap.parse_args()
    if args.drop_revoked_subkeys and len(args.keys) != 1:
        fail('--drop-revoked-subkeys takes one key')
    inputs = []
    for name in args.keys:
        with open(name, 'rb') as f:
            inputs.append((name, Key(name, dearmor(name, f.read()))))
    key = Key(inputs[0][0], inputs[0][1].bytes())
    added_sigs = added_subs = 0
    for name, other in inputs[1:]:
        s, k = key.merge(other, name)
        added_sigs, added_subs = added_sigs + s, added_subs + k
    moved = key.revocations_last()
    dropped = key.drop_revoked_subkeys() if args.drop_revoked_subkeys else 0
    result = key.bytes()
    check = Key(args.output, result)
    if not args.drop_revoked_subkeys:
        missing = set().union(*(k.sigids() for _, k in inputs)) - check.sigids()
        if missing:
            fail(f'internal error: {len(missing)} signature(s) lost')
    with open(args.output, 'w') as f:
        f.write(armor(result))
    nsigs = sum(len(c[2]) for c in [key.primary] + key.components)
    print(f'{args.output}: {len(key.subkeys())} subkey(s) in the order of {inputs[0][0]}, {nsigs} signature(s); '
          f'added {added_sigs} signature(s) and {added_subs} subkey(s) from the later files; '
          f'moved {moved} subkey revocation(s) behind the bindings'
          + (f'; dropped {dropped} revoked subkey(s)' if args.drop_revoked_subkeys else ''), file=sys.stderr)


if __name__ == '__main__':
    main()
