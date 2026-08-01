#!/usr/bin/env python3
"""Measure fabric_probe's known-X geometry in a MiSTer screenshot (issue #32).

fabric_probe emits, into a 288x216 framebuffer:
  * a full-screen clear to RGB565 of (0,0,160)  -> every framebuffer column is blue
  * one magenta triangle, vertices (160,48) (224,176) (96,176)  -> symmetric about x=160

So the scanout is correct iff:
  * screen column 0 is blue (not black)
  * the magenta base row's leftmost/rightmost columns bracket x=160 symmetrically,
    i.e. the emitted x=96..224, not x=97..225.
"""
import sys
from PIL import Image


def classify(p):
    r, g, b = p
    if r > 180 and b > 180 and g < 80:
        return "M"          # magenta triangle
    if r < 60 and g < 60 and 100 < b < 220:
        return "B"          # blue clear
    if (r, g, b) == (0, 0, 0):
        return "K"          # black
    return "?"


for path in sys.argv[1:]:
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    cols = {}
    for x in range(w):
        cnt = {"M": 0, "B": 0, "K": 0, "?": 0}
        for y in range(h):
            cnt[classify(px[x, y])] += 1
        cols[x] = cnt

    blue_cols = [x for x in range(w) if cols[x]["B"] > 0]
    black_only = [x for x in range(w) if cols[x]["K"] == h]
    mag_cols = [x for x in range(w) if cols[x]["M"] > 0]
    # widest magenta scanline = the triangle's base
    best_y, best = None, (None, None)
    for y in range(h):
        xs = [x for x in range(w) if classify(px[x, y]) == "M"]
        if xs and (best[0] is None or (xs[-1] - xs[0]) > (best[1] - best[0])):
            best, best_y = (xs[0], xs[-1]), y
    mid = (best[0] + best[1]) / 2 if best[0] is not None else None
    print(f"{path}  {w}x{h}")
    print(f"  col0 = {px[0,0]} {px[0,108]}   fully-black columns: {black_only}")
    print(f"  blue clear spans x={blue_cols[0]}..{blue_cols[-1]}"
          f"  ({len(blue_cols)} cols)")
    print(f"  magenta spans   x={mag_cols[0]}..{mag_cols[-1]}")
    print(f"  widest magenta scanline y={best_y}: x={best[0]}..{best[1]}"
          f"  midpoint={mid}   (emitted base = 96..224, midpoint 160)")
