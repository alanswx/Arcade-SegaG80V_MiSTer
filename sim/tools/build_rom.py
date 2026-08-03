#!/usr/bin/env python3
"""Build a flat ROM image per romset, in the layout the core expects.

    0x0000 - 0xBFFF   maincpu   (program ROM, CPU board U25 + EPROM board)
    0xC000 - 0xC3FF   s-c.xyt-u39 sin/cos PROM

Parses the ROM_START blocks straight out of MAME's segag80v.cpp so the load
offsets cannot drift from the driver.

    build_rom.py <segag80v.cpp> <romdir> <outdir> [set ...]
"""

import re
import sys
import os
import zipfile

def parse_sets(src_path):
    src = open(src_path).read()
    sets = {}
    for m in re.finditer(r'ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END', src, re.S):
        name, body = m.groups()
        regions = {}
        cur = None
        for line in body.splitlines():
            r = re.search(r'ROM_REGION\(\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"', line)
            if r:
                cur = r.group(2)
                regions.setdefault(cur, [])
                continue
            l = re.search(r'ROM_LOAD\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,'
                          r'\s*(0x[0-9a-fA-F]+)', line)
            if l and cur:
                regions[cur].append((l.group(1), int(l.group(2), 16),
                                     int(l.group(3), 16)))
        sets[name] = regions
    return sets


def build(setname, regions, romdir, outdir):
    zpath = os.path.join(romdir, setname + '.zip')
    if not os.path.exists(zpath):
        return None, f'{setname}.zip not found'
    zf = zipfile.ZipFile(zpath)
    names = set(zf.namelist())

    # MAME zero-fills a ROM_REGION, and the games do read past the end of
    # their populated ROM (elim2 fetches from $8FF8 during boot), so the fill
    # value is not cosmetic — it changes what the CPU executes.
    img = bytearray(0xC400)

    for fn, off, size in regions.get('maincpu', []):
        if fn not in names:
            return None, f'missing {fn}'
        d = zf.read(fn)
        if len(d) != size:
            return None, f'{fn} is {len(d)} bytes, expected {size}'
        img[off:off + size] = d

    sine = None
    for fn, off, size in regions.get('proms', []):
        if 'xyt-u39' in fn:
            sine = zf.read(fn)
    if sine is None or len(sine) != 0x400:
        return None, 'sine PROM missing or wrong size'
    img[0xC000:0xC400] = sine

    out = os.path.join(outdir, setname + '.rom')
    open(out, 'wb').write(bytes(img))
    return out, None


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    src, romdir, outdir = sys.argv[1:4]
    wanted = sys.argv[4:]
    os.makedirs(outdir, exist_ok=True)

    sets = parse_sets(src)
    targets = wanted or sorted(sets)
    for name in targets:
        if name not in sets:
            print(f'{name:12s} unknown set')
            continue
        out, err = build(name, sets[name], romdir, outdir)
        if err:
            print(f'{name:12s} SKIP  {err}')
        else:
            print(f'{name:12s} -> {out} ({os.path.getsize(out)} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
