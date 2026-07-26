"""Minimal PNG reader for MiSTer screenshots — no PIL/Pillow on this host.

MiSTer screenshots (`echo screenshot > /dev/MiSTer_cmd` -> newest PNG in
/media/fat/screenshots/<core>/) are the only reliable observable of what the
fabric actually scanned out, so decoding them is the backbone of fabric
debugging. This implements just enough PNG (all five filter types, colour
types 2/3/6) to get pixels; `to565()` converts back to the RGB565 the fabric
actually wrote, which is what you want to compare against.

Usage:
    import sys; sys.path.insert(0, 'tools')
    from png import readpng, to565
    w, h, rows = readpng('shot.png')
    print('%04X' % to565(rows[150][160]))          # centre pixel as RGB565

Two habits worth keeping (2026-07-26, both learned the hard way):
  - An all-black 1034-byte PNG is the reader's stale-frame watchdog blanking,
    NOT a render result.
  - Never diagnose the texel path with a UNIFORM texture: a correct fetch and a
    broken one both render constant. Use tools/fabric_probe_uv.c in
    gmloader-next (coordinate-encoded: R5 = u>>2, G6 = v>>1) so a wrong texel
    address is visible as a missing ramp.
"""
import zlib, struct


def readpng(p):
    d = open(p, 'rb').read()
    pos = 8
    idat = b''
    w = h = bd = ct = None
    pal = None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if typ == b'IHDR':
            w, h, bd, ct = struct.unpack('>IIBB', data[:10])
        elif typ == b'PLTE':
            pal = data
        elif typ == b'IDAT':
            idat += data
    raw = zlib.decompress(idat)
    nch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    bpp = nch * (bd // 8)
    stride = (w * nch * bd + 7) // 8
    rows = []
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pp = a + b - c
                pa, pb_, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb_ and pa <= pc) else (b if pb_ <= pc else c)
                line[x] = (line[x] + pr) & 255
        prev = line
        px = []
        for x in range(w):
            if ct == 3:
                idx = line[x]; px.append(tuple(pal[idx * 3:idx * 3 + 3]))
            elif ct == 2:
                px.append(tuple(line[x * 3:x * 3 + 3]))
            elif ct == 6:
                px.append(tuple(line[x * 4:x * 4 + 3]))
        rows.append(px)
    return w, h, rows


def to565(c):
    r, g, b = c
    return (round(r * 31 / 255) << 11) | (round(g * 63 / 255) << 5) | round(b * 31 / 255)
