#!/usr/bin/env python3
"""Report fully-black columns (and rows) of each PNG given on the command line.

Device check for issue #32: a MiSTer screenshot of the native 288x216 scanout must
have NO fully-black column at x=0 on a frame whose framebuffer column 0 has content.
"""
import sys
from PIL import Image

for path in sys.argv[1:]:
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    black_cols = [x for x in range(w)
                  if all(px[x, y] == (0, 0, 0) for y in range(h))]
    nonblack_col0 = sum(1 for y in range(h) if px[0, y] != (0, 0, 0))
    nonblack_last = sum(1 for y in range(h) if px[w - 1, y] != (0, 0, 0))
    print(f"{path}  {w}x{h}  black_cols({len(black_cols)})={black_cols[:8]}"
          f"  col0_nonblack={nonblack_col0}/{h}  col{w-1}_nonblack={nonblack_last}/{h}")
