#!/usr/bin/env python3
"""mftrace_analyze.py — offline decomposition analyzer for MFTRACE captures.

Consumes the MFTRACE text format emitted by the gmloader mfgpu backend
(GMLOADER_MFGPU_TRACE, Task 2): one `MFTRACE G ...` header line per draw
group, followed by nt*3 `MFTRACE V x y u v rgba` vertex lines (x,y,u,v are
raw 12.4 fixed-point ints; screen is 288x216).

Per frame, and as medians across frames, reports:
  covered_px  - total covered-pixel *instances* (write-count sum; counts overdraw)
  bbox_px     - sum of each triangle's own screen-clamped bbox rect area
  bbox_tax    = bbox_px - covered_px
  unique_px   - distinct pixels touched at least once
  overdraw    = covered_px / unique_px
  blend split - covered_px broken out by blend mode {COPY, CONST_ALPHA,
                COLORKEY, ADD, MULTIPLY}
  cullable_px - covered px of draws fully occluded by later COPY-mode
                geometry (the opaque-cull ceiling; see cullable_px_for_frame)

Device-truth gate (Task 4 brief): on the quiet capture, median covered_px
should land within ~2% of 182,661 (overdraw approx 2.94) -- this is the
Task 4 anchor value for the quiet capture. The gate is opt-in: pass
--expect-covered N (and optionally --tol PCT, default 2.0) to have this
script actually enforce it. When given, covered_px MEDIAN is compared
against N and the script exits 1 with a clear message if it falls outside
the tolerance, rather than fudging the tolerance. Without --expect-covered
no gate runs.
"""
import sys
import statistics
from collections import namedtuple

FB_WIDTH = 288
FB_HEIGHT = 216

# --- BLT_BLEND_* -------------------------------------------------------
# Numeric values transcribed from the wire-protocol codec header
# 3rdparty/mfgpu/host/blt_wire.h (`#include "blitter_ref.h"` at the top of
# that file pulls in the enum; blt_wire.h's own doc comment restates the
# same symbol names at the BLT_OP_TRILIST header-field mapping). The actual
# integer values are the enum in refmodel/blitter_ref.h, which blt_wire.h
# treats as its single source of truth for the wire's blend_mode byte:
#   BLT_BLEND_COPY        = 0  opaque copy (fast path)
#   BLT_BLEND_COLORKEY    = 1  skip src pixels == cmd.colorkey (fast path)
#   BLT_BLEND_CONST_ALPHA = 2  dst = src*a + dst*(1-a), a=cmd.alpha/255
#   BLT_BLEND_PALPHA      = 3  per-pixel source-over (not used by TRILIST)
#   BLT_BLEND_ADD         = 4  per-channel saturating add
#   BLT_BLEND_MULTIPLY    = 5  per-channel modulate
BLT_BLEND_COPY = 0
BLT_BLEND_COLORKEY = 1
BLT_BLEND_CONST_ALPHA = 2
BLT_BLEND_PALPHA = 3
BLT_BLEND_ADD = 4
BLT_BLEND_MULTIPLY = 5

BLEND_NAMES = {
    BLT_BLEND_COPY: "COPY",
    BLT_BLEND_CONST_ALPHA: "CONST_ALPHA",
    BLT_BLEND_COLORKEY: "COLORKEY",
    BLT_BLEND_ADD: "ADD",
    BLT_BLEND_MULTIPLY: "MULTIPLY",
}
# Report these five in this order (PALPHA is not emitted by the mfgpu
# TRILIST backend and is intentionally excluded per the task brief).
REPORT_BLEND_ORDER = [
    BLT_BLEND_COPY,
    BLT_BLEND_CONST_ALPHA,
    BLT_BLEND_COLORKEY,
    BLT_BLEND_ADD,
    BLT_BLEND_MULTIPLY,
]

SUB = 4
ONE = 1 << SUB
HALF = ONE >> 1


# --- Coverage rule, transcribed from blt_raster_tri() -------------------
# fpga/sim/blt_tri.c (vendored refmodel copy, wt-maldita-60fps-p3), the
# golden spec the RTL blt_tri module must match bit-for-bit. This analyzer
# only needs coverage *counts* (Task 5's sim replay is the bit-exact
# oracle), so it drops texturing/blending and keeps just the rasterization
# rule from blt_raster_tri:
#   - edge functions in 12.4 fixed-point (signed area x2, `edge()`)
#   - CCW-normalize by swapping b,c when the signed area is negative
#   - pixel-center sampling at ((px<<4)|8, (py<<4)|8)
#   - top-left fill rule via a -1 bias on non-top-left edges (`top_left()`)
#   - screen-clamped integer bbox from the fixed-point vertex extents
def _edge(ax, ay, bx, by, cx, cy):
    """Signed area x2 of triangle (a,b,c); >0 for CCW in a Y-down screen.
    Transcribed from blt_tri.c:edge()."""
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)


def _top_left(ax, ay, bx, by):
    """Top-left rule: edge a->b is "inside" on E==0 iff top or left edge.
    Transcribed from blt_tri.c:top_left()."""
    return (ay == by and bx < ax) or (by > ay)


def _tri_screen_bbox(tri):
    """Screen-clamped integer pixel bbox [minx,maxx] x [miny,maxy] for a
    triangle's raw 12.4 fixed vertices. Transcribed from the bbox
    computation in blt_tri.c:blt_raster_tri()."""
    (x0, y0), (x1, y1), (x2, y2) = tri
    lx = min(x0, x1, x2)
    hx = max(x0, x1, x2)
    ly = min(y0, y1, y2)
    hy = max(y0, y1, y2)
    minx = lx >> SUB
    maxx = (hx + ONE - 1) >> SUB
    miny = ly >> SUB
    maxy = (hy + ONE - 1) >> SUB
    if minx < 0:
        minx = 0
    if miny < 0:
        miny = 0
    if maxx >= FB_WIDTH:
        maxx = FB_WIDTH - 1
    if maxy >= FB_HEIGHT:
        maxy = FB_HEIGHT - 1
    return minx, maxx, miny, maxy


def bbox_px(tri):
    """Screen-clamped bbox rect area for a single triangle's raw 12.4 fixed
    vertices, per blt_tri.c:blt_raster_tri()'s bbox computation. A
    degenerate/off-screen bbox (max < min after clamping) contributes 0."""
    minx, maxx, miny, maxy = _tri_screen_bbox(tri)
    if maxx < minx or maxy < miny:
        return 0
    return (maxx - minx + 1) * (maxy - miny + 1)


def coverage_pixels(tri):
    """Yield (px, py) pixel coordinates covered by triangle `tri`, per the
    same rasterization rule as blt_tri.c:blt_raster_tri() (CCW-normalize,
    pixel-center sample, top-left fill rule). `tri` is a 3-sequence of raw
    12.4 fixed (x, y) pairs."""
    (x0, y0), (x1, y1), (x2, y2) = tri
    area = _edge(x0, y0, x1, y1, x2, y2)
    if area == 0:
        return
    if area < 0:
        (x1, y1), (x2, y2) = (x2, y2), (x1, y1)
        area = -area
    minx, maxx, miny, maxy = _tri_screen_bbox(((x0, y0), (x1, y1), (x2, y2)))
    bias0 = 0 if _top_left(x1, y1, x2, y2) else -1  # edge opposite a (b->c)
    bias1 = 0 if _top_left(x2, y2, x0, y0) else -1  # edge opposite b (c->a)
    bias2 = 0 if _top_left(x0, y0, x1, y1) else -1  # edge opposite c (a->b)
    for py in range(miny, maxy + 1):
        sy = (py << SUB) | HALF
        for px in range(minx, maxx + 1):
            sx = (px << SUB) | HALF
            w0 = _edge(x1, y1, x2, y2, sx, sy) + bias0
            if w0 < 0:
                continue
            w1 = _edge(x2, y2, x0, y0, sx, sy) + bias1
            if w1 < 0:
                continue
            w2 = _edge(x0, y0, x1, y1, sx, sy) + bias2
            if w2 < 0:
                continue
            yield (px, py)


def coverage_px(tri):
    """Count of pixels covered by a single triangle (raw 12.4 fixed (x,y)
    triple), per coverage_pixels()."""
    n = 0
    for _ in coverage_pixels(tri):
        n += 1
    return n


# --- Frame / group model -------------------------------------------------
Group = namedtuple("Group", ["blend", "tris"])


def group(tris, blend):
    """Build a draw group: `tris` is a list of triangles, each a 3-sequence
    of (x, y) raw 12.4 fixed pairs (u,v,rgba are irrelevant to coverage
    counting and are dropped by the parser before this point)."""
    return Group(blend=blend, tris=list(tris))


def make_frame(groups):
    """A frame is just its ordered list of draw groups (submission order,
    needed by the cullable_px occlusion pass)."""
    return {"groups": list(groups)}


FrameStats = namedtuple(
    "FrameStats",
    ["covered_px", "bbox_px", "bbox_tax", "unique_px", "overdraw",
     "blend_split", "cullable_px"],
)


def _analyze_frame(frame):
    plane = [0] * (FB_WIDTH * FB_HEIGHT)
    # last_writer[idx] = submission-order group index of the last group
    # (so far) whose triangle covered pixel idx.
    last_writer = [-1] * (FB_WIDTH * FB_HEIGHT)
    # Per-triangle covered pixel index lists, cached so we rasterize each
    # triangle exactly once even though it feeds four different tallies.
    tri_records = []  # (group_index, blend, [pixel_idx, ...])
    total_bbox = 0
    blend_split = {b: 0 for b in REPORT_BLEND_ORDER}

    for gi, grp in enumerate(frame["groups"]):
        for tri in grp.tris:
            total_bbox += bbox_px(tri)
            idxs = [py * FB_WIDTH + px for (px, py) in coverage_pixels(tri)]
            tri_records.append((gi, grp.blend, idxs))
            for idx in idxs:
                plane[idx] += 1
                last_writer[idx] = gi
            blend_split[grp.blend] = blend_split.get(grp.blend, 0) + len(idxs)

    covered = sum(plane)
    unique = sum(1 for v in plane if v)
    overdraw = (covered / unique) if unique else 0.0

    cullable = 0
    for gi, blend, idxs in tri_records:
        for idx in idxs:
            writer = last_writer[idx]
            if writer != gi and frame["groups"][writer].blend == BLT_BLEND_COPY:
                cullable += 1

    return FrameStats(
        covered_px=covered,
        bbox_px=total_bbox,
        bbox_tax=total_bbox - covered,
        unique_px=unique,
        overdraw=overdraw,
        blend_split=blend_split,
        cullable_px=cullable,
    )


class AnalysisResult:
    """Holds per-frame stats plus medians across frames. The scalar
    attributes (.covered, .unique, .overdraw, .cullable) are the *median*
    of the corresponding per-frame metric; for a single-frame input (as in
    selftest()) the median of one value is that value, so the same object
    serves both the selftest's direct-value checks and the multi-frame
    report's median table."""

    def __init__(self, per_frame):
        self.per_frame = per_frame
        self.covered = _median(f.covered_px for f in per_frame)
        self.bbox = _median(f.bbox_px for f in per_frame)
        self.bbox_tax = _median(f.bbox_tax for f in per_frame)
        self.unique = _median(f.unique_px for f in per_frame)
        self.overdraw = _median(f.overdraw for f in per_frame)
        self.cullable = _median(f.cullable_px for f in per_frame)
        self.blend_split = {
            b: _median(f.blend_split.get(b, 0) for f in per_frame)
            for b in REPORT_BLEND_ORDER
        }


def _median(values):
    values = list(values)
    if not values:
        return 0
    return statistics.median(values)


def analyze(frames):
    per_frame = [_analyze_frame(f) for f in frames]
    return AnalysisResult(per_frame)


# --- MFTRACE parser --------------------------------------------------------
def parse_mftrace(path):
    """Parse an MFTRACE text capture into a list of frames (grouped by the
    `f=` field), each a make_frame()-built list of groups in file order
    (== submission order)."""
    frames_by_id = {}
    order = []
    with open(path, "r") as fh:
        lines = fh.read().splitlines()

    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if not line.startswith("MFTRACE G "):
            i += 1
            continue
        fields = dict(tok.split("=", 1) for tok in line[len("MFTRACE G "):].split())
        frame_id = fields["f"]
        blend = int(fields["blend"])
        nt = int(fields["nt"])
        i += 1
        verts = []
        for _ in range(nt * 3):
            vline = lines[i]
            i += 1
            assert vline.startswith("MFTRACE V "), f"expected V line, got: {vline!r}"
            parts = vline.split()
            x, y = int(parts[2]), int(parts[3])
            verts.append((x, y))
        tris = [verts[k:k + 3] for k in range(0, len(verts), 3)]
        if frame_id not in frames_by_id:
            frames_by_id[frame_id] = []
            order.append(frame_id)
        frames_by_id[frame_id].append(group(tris, blend))

    return [make_frame(frames_by_id[fid]) for fid in order]


# --- Report emission --------------------------------------------------------
def _fmt_num(v):
    if isinstance(v, float):
        return f"{v:.3f}"
    return str(v)


def format_report(path, result):
    lines = []
    lines.append(f"# MFTRACE decomposition analysis: `{path}`\n")
    lines.append(f"Frames analyzed: {len(result.per_frame)}\n")
    lines.append("## Medians across frames\n")
    lines.append("| metric | value |")
    lines.append("|---|---|")
    lines.append(f"| covered_px | {_fmt_num(result.covered)} |")
    lines.append(f"| bbox_px | {_fmt_num(result.bbox)} |")
    lines.append(f"| bbox_tax | {_fmt_num(result.bbox_tax)} |")
    lines.append(f"| unique_px | {_fmt_num(result.unique)} |")
    lines.append(f"| overdraw | {_fmt_num(result.overdraw)} |")
    lines.append(f"| cullable_px | {_fmt_num(result.cullable)} |")
    lines.append("")
    lines.append("## Covered px by blend mode (median)\n")
    lines.append("| blend | covered_px |")
    lines.append("|---|---|")
    for b in REPORT_BLEND_ORDER:
        lines.append(f"| {BLEND_NAMES[b]} | {_fmt_num(result.blend_split[b])} |")
    lines.append("")
    return "\n".join(lines) + "\n"


def print_stdout_table(path, result):
    print(f"=== {path} ===")
    print(f"frames: {len(result.per_frame)}")
    print(f"covered_px (median): {_fmt_num(result.covered)}")
    print(f"bbox_px (median):    {_fmt_num(result.bbox)}")
    print(f"bbox_tax (median):   {_fmt_num(result.bbox_tax)}")
    print(f"unique_px (median):  {_fmt_num(result.unique)}")
    print(f"overdraw (median):   {_fmt_num(result.overdraw)}")
    print(f"cullable_px (median):{_fmt_num(result.cullable)}")
    for b in REPORT_BLEND_ORDER:
        print(f"  blend {BLEND_NAMES[b]:12s}: {_fmt_num(result.blend_split[b])}")


# --- Device-truth gate -------------------------------------------------------
def check_covered_gate(median_covered, expect_covered, tol_pct):
    """Compare a covered_px median against an expected value within tol_pct
    percent. Returns (ok, diff_pct, message). Pure function so both main()
    and selftest() can exercise the same gate logic."""
    diff_pct = abs(median_covered - expect_covered) / expect_covered * 100.0
    ok = diff_pct <= tol_pct
    verdict = "OK" if ok else "FAIL"
    message = (
        f"GATE {verdict}: covered_px median {median_covered} is "
        f"{diff_pct:.2f}% away from expected {expect_covered} (tol {tol_pct}%)"
    )
    return ok, diff_pct, message


# --- selftest ---------------------------------------------------------------
def selftest():
    # Two right triangles forming a 16x16 axis-aligned quad at (0,0), 12.4 fixed.
    def fx(v): return v << 4
    quad = [ (fx(0),fx(0)), (fx(16),fx(0)), (fx(0),fx(16)),
             (fx(16),fx(0)), (fx(16),fx(16)), (fx(0),fx(16)) ]
    tris = [quad[0:3], quad[3:6]]
    cov  = sum(coverage_px(t) for t in tris)
    bbox = sum(bbox_px(t) for t in tris)
    assert cov == 256, f"quad coverage {cov} != 256 (fill rule must not double-count the diagonal)"
    assert bbox == 2 * 289 or bbox == 2 * 256, f"bbox {bbox}"  # pin to the actual rule, see step 3
    # Overdraw: same quad drawn twice = covered 512, unique 256, overdraw 2.0
    frames = [make_frame([group(tris, blend=BLT_BLEND_COPY)] * 2)]
    st = analyze(frames)
    assert st.covered == 512 and st.unique == 256 and abs(st.overdraw - 2.0) < 1e-9
    # Cull ceiling: an ALPHA draw fully under a later COPY quad is 100% cullable
    frames = [make_frame([group(tris, blend=BLT_BLEND_CONST_ALPHA),
                          group(tris, blend=BLT_BLEND_COPY)])]
    st = analyze(frames)
    assert st.cullable == 256
    # Device-truth gate: trips (not ok) on a wrong expectation, passes (ok)
    # when the expectation matches the actual median.
    ok, _, _ = check_covered_gate(st.covered, 999999, 2.0)
    assert not ok, "gate must trip when covered median is far from expectation"
    ok, _, _ = check_covered_gate(st.covered, st.covered, 2.0)
    assert ok, "gate must pass when covered median matches expectation"
    print("selftest OK")


def main(argv):
    args = argv[1:]
    if "--selftest" in args:
        selftest()
        return 0

    expect_covered = None
    tol_pct = 2.0
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--expect-covered":
            i += 1
            expect_covered = float(args[i])
        elif a == "--tol":
            i += 1
            tol_pct = float(args[i])
        else:
            positional.append(a)
        i += 1

    if not positional:
        print(
            "usage: mftrace_analyze.py [--selftest] "
            "[--expect-covered N] [--tol PCT] <mftrace.txt>",
            file=sys.stderr,
        )
        return 2
    path = positional[0]
    frames = parse_mftrace(path)
    if not frames:
        print(f"no MFTRACE frames parsed from {path}", file=sys.stderr)
        return 1
    result = analyze(frames)
    print_stdout_table(path, result)
    out_path = path + ".analysis.md"
    with open(out_path, "w") as fh:
        fh.write(format_report(path, result))
    print(f"wrote {out_path}")

    if expect_covered is not None:
        ok, _, message = check_covered_gate(result.covered, expect_covered, tol_pct)
        if not ok:
            print(message, file=sys.stderr)
            return 1
        print(message)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
