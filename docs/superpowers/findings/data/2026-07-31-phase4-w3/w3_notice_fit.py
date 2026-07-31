#!/usr/bin/env python3
"""Reproduce every derived number in docs/superpowers/findings/2026-07-31-phase4-w3.md.

Reads the thirteen 2026-07-31 MFSEAM logs and re-derives: the per-arm heavy-band
and exact-anchor tables, the piecewise knee fit, the bootstrap CI and
P(K >= 0.35) (window-noise-only and with the measured run-to-run sd folded in),
the pub linearity self-check, the chord-vs-post-knee-slope decomposition, and the
term-identity residuals.

Stdlib only, no numpy. Deterministic: seed 20260731.

    python3 w3_notice_fit.py [--logs /path/to/bench-results]

Log path defaults to ../../../../bench-results relative to the repo root, i.e.
the mister-gmloader checkout's bench-results/ directory. The logs are not
committed (they are large and live in the parent repo); pass --logs if yours are
elsewhere.
"""

import argparse
import os
import random
import re
import statistics
import sys

SUFFIX = "---preset_fabric--scene_ingame-stage1.log"

# arm label -> log timestamp prefix
LOGS = {
    "D0":    "20260731-093529",
    "D100":  "20260731-093711",
    "D200":  "20260731-093830",
    "D300":  "20260731-093949",
    "D400":  "20260731-094125",
    "D600":  "20260731-094245",
    "D900":  "20260731-094405",
    "P0":    "20260731-094548",
    "P50":   "20260731-094708",
    "P250":  "20260731-094827",
    "P1000": "20260731-095423",
    "STEP1": "20260731-093246",
    "LAST":  "20260731-100257",
}
SWEEP = ["D0", "D100", "D200", "D300", "D400", "D600", "D900"]
REQ_D = {"D0": 0, "D100": 100, "D200": 200, "D300": 300,
         "D400": 400, "D600": 600, "D900": 900}
POLL = ["P0", "P50", "P250", "P1000"]
# the three like-for-like unmodified replicates (run 13 / LAST is duration-anomalous)
REPLICATES = ["STEP1", "D0", "P0"]

HEAVY_COV = 205000
ANCHOR_COV = 213358
SEED = 20260731


# ---------------------------------------------------------------- parsing

def parse_log(path):
    """One dict per MFSEAM window, merged with the MFSUBMIT line that precedes it."""
    windows, pending = [], None
    with open(path, errors="replace") as fh:
        for line in fh:
            if line.startswith("MFSUBMIT"):
                d = {"n": int(re.search(r"MFSUBMIT n=(\d+)", line).group(1))}
                m = re.search(r"fabric_ms\[frame=([\d.]+) tri=([\d.]+) "
                              r"texwait=([\d.]+) dpath=([\d.]+) ovhd=([\d.]+)\]", line)
                d["frame"], d["tri"] = float(m.group(1)), float(m.group(2))
                d["dpath"], d["ovhd"] = float(m.group(4)), float(m.group(5))
                d["cov_px"] = int(re.search(r"cov_px=(\d+)", line).group(1))
                d["spin_avg"] = int(re.search(r"spin_avg=(\d+)", line).group(1))
                pending = d
            elif line.startswith("MFSEAM"):
                d = dict(pending) if pending else {}
                for k in ("period", "host", "block", "pub", "notice"):
                    d[k] = float(re.search(k + r"=(-?[\d.]+)", line).group(1))
                d["blocked"] = int(re.search(r"blocked=(\d+)%", line).group(1))
                windows.append(d)
                pending = None
    return windows


def load(logdir):
    data = {}
    for arm, stamp in LOGS.items():
        p = os.path.join(logdir, stamp + SUFFIX)
        if not os.path.exists(p):
            sys.exit("missing log: " + p)
        data[arm] = parse_log(p)
    return data


# ------------------------------------------------------------- pooling

def bframes(w):
    """Blocked frames in a 30-frame window. This is the pooling weight."""
    return round(w["blocked"] / 100 * 30)


def band(windows, blocked_min, cov_min=HEAVY_COV):
    return [w for w in windows if w["cov_px"] >= cov_min and w["blocked"] >= blocked_min]


def anchor(windows):
    return [w for w in windows if w["cov_px"] == ANCHOR_COV]


def wmean(ws, key):
    tot = sum(bframes(w) for w in ws)
    return sum(w[key] * bframes(w) for w in ws) / tot


# ------------------------------------------------------------- models

def fit_piecewise(pts, step=0.0005, kmax=1.2):
    """notice(pub) = floor + max(0, K - pub). Grid on K, floor in closed form."""
    best = None
    k = 0.0
    while k <= kmax + 1e-9:
        ramp = [max(0.0, k - p) for p, _ in pts]
        floor = sum(y - r for (_, y), r in zip(pts, ramp)) / len(pts)
        sse = sum((y - (floor + r)) ** 2 for (_, y), r in zip(pts, ramp))
        if best is None or sse < best[2] - 1e-15:
            best = (k, floor, sse)
        k += step
    return best


def ols(pts, weights=None):
    if weights is None:
        weights = [1.0] * len(pts)
    tot = sum(weights)
    mx = sum(w * p[0] for w, p in zip(weights, pts)) / tot
    my = sum(w * p[1] for w, p in zip(weights, pts)) / tot
    sxy = sum(w * (p[0] - mx) * (p[1] - my) for w, p in zip(weights, pts))
    sxx = sum(w * (p[0] - mx) ** 2 for w, p in zip(weights, pts))
    slope = sxy / sxx
    return my - slope * mx, slope


def r_squared(pts, intercept, slope):
    my = sum(y for _, y in pts) / len(pts)
    ssr = sum((y - (intercept + slope * x)) ** 2 for x, y in pts)
    sst = sum((y - my) ** 2 for _, y in pts)
    return 1 - ssr / sst


# ------------------------------------------------------------- bootstrap

def bootstrap(data, blocked_min, n=2000, seed=SEED, run_sd=0.0):
    """Resample windows within each arm. run_sd > 0 adds an independent
    N(0, run_sd) offset per arm, modelling run-to-run variation the window
    resample cannot see (each arm is one device run)."""
    rng = random.Random(seed)
    arms = [band(data[a], blocked_min) for a in SWEEP]
    ks, floors = [], []
    for _ in range(n):
        pts = []
        for ws in arms:
            rs = [rng.choice(ws) for _ in ws]
            off = rng.gauss(0.0, run_sd) if run_sd else 0.0
            pts.append((wmean(rs, "pub"), wmean(rs, "notice") + off))
        k, fl, _ = fit_piecewise(pts, step=0.005)
        ks.append(k)
        floors.append(fl)
    ks.sort()
    floors.sort()
    q = lambda v, p: v[int(p * (len(v) - 1))]
    return {
        "medK": statistics.median(ks), "ciK": (q(ks, 0.05), q(ks, 0.95)),
        "medFloor": statistics.median(floors),
        "ciFloor": (q(floors, 0.05), q(floors, 0.95)),
        "P_ge_035": sum(1 for k in ks if k >= 0.35) / len(ks),
    }


# ------------------------------------------------------------- report

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, *[".."] * 5))     # worktree root
    probe = LOGS["D0"] + SUFFIX
    default = os.path.join(root, "bench-results")
    if not os.path.exists(os.path.join(default, probe)):        # sibling checkout
        default = os.path.abspath(os.path.join(root, "..", "mister-gmloader",
                                               "bench-results"))
    ap = argparse.ArgumentParser()
    ap.add_argument("--logs", default=default)
    args = ap.parse_args()
    data = load(args.logs)

    print("=== window counts (findings §1) ===")
    print("  " + "  ".join(f"{a}={len(data[a])}" for a in LOGS))

    print("\n=== §2 self-check 1: pub vs requested D (all windows per arm) ===")
    pts = []
    for a in SWEEP:
        m = sum(w["pub"] for w in data[a]) / len(data[a])
        pts.append((REQ_D[a] / 1000.0, m))
        ratio = f"{m / (REQ_D[a] / 1000.0):.3f}" if REQ_D[a] else "--"
        print(f"  D={REQ_D[a]:4d}  mean pub={m:.4f}  pub/D={ratio}")
    a0, b = ols(pts)
    print(f"  pub = {a0:.4f} + {b:.4f} * D    R2 = {r_squared(pts, a0, b):.5f}")

    for thr in (90, 60):
        tag = "PRIMARY (brief's filter)" if thr == 90 else "sensitivity"
        print(f"\n=== heavy band, cov_px >= {HEAVY_COV}, blocked >= {thr}%  [{tag}] ===")
        print(f"  {'arm':6}{'pub':>8}{'period':>9}{'notice':>8}{'frame':>8}"
              f"{'block':>8}{'spin':>7}{'win':>5}{'bf':>6}{'cov':>9}")
        for a in SWEEP + POLL:
            ws = band(data[a], thr)
            print(f"  {a:6}{wmean(ws,'pub'):8.3f}{wmean(ws,'period'):9.3f}"
                  f"{wmean(ws,'notice'):8.3f}{wmean(ws,'frame'):8.3f}"
                  f"{wmean(ws,'block'):8.3f}{wmean(ws,'spin_avg'):7.0f}"
                  f"{len(ws):5d}{sum(bframes(w) for w in ws):6d}"
                  f"{wmean(ws,'cov_px'):9.0f}")

        arm_pts = [(wmean(band(data[a], thr), "pub"),
                    wmean(band(data[a], thr), "notice")) for a in SWEEP]
        k, fl, sse = fit_piecewise(arm_pts)
        li, ls = ols(arm_pts)
        lsse = sum((y - (li + ls * x)) ** 2 for x, y in arm_pts)
        fm = sum(y for _, y in arm_pts) / len(arm_pts)
        fsse = sum((y - fm) ** 2 for _, y in arm_pts)
        print(f"  piecewise: K={k:.4f} floor={fl:.4f} SSE={sse:.5f} "
              f"RMS={(sse/len(arm_pts))**0.5:.4f} notice(0)={fl+k:.3f}")
        print(f"  linear   : {li:.4f}{ls:+.4f}*pub SSE={lsse:.5f}  ({lsse/sse:.1f}x worse)")
        print(f"  flat null: mean={fm:.4f} SSE={fsse:.5f}  ({fsse/sse:.1f}x worse)")

        reps = [wmean(band(data[r], thr), "notice") for r in REPLICATES]
        sd = statistics.stdev(reps)
        print(f"  unmodified replicates {[round(v,3) for v in reps]} "
              f"mean={sum(reps)/3:.4f} spread={max(reps)-min(reps):.4f} sd={sd:.4f}")

        for run_sd, label in ((0.0, "window noise only"), (sd, "+ run-to-run")):
            b = bootstrap(data, thr, run_sd=run_sd)
            print(f"  bootstrap ({label:17}): K med={b['medK']:.3f} "
                  f"CI=[{b['ciK'][0]:.3f}, {b['ciK'][1]:.3f}]  "
                  f"floor med={b['medFloor']:.3f} "
                  f"CI=[{b['ciFloor'][0]:.3f}, {b['ciFloor'][1]:.3f}]  "
                  f"P(K>=0.35)={b['P_ge_035']:.3f}")

        # chord vs local post-knee slope (findings §3)
        np_pts = [(p, y + p) for p, y in arm_pts]   # notice + pub
        chord = (np_pts[-1][1] - np_pts[0][1]) / (np_pts[-1][0] - np_pts[0][0])
        x_end = np_pts[-1][0]
        print(f"  notice+pub chord over [0,{x_end:.3f}] = {chord:.4f} "
              f"-> implied K = {x_end*(1-chord):.3f}   "
              f"(knee K={k:.3f} predicts chord {(x_end-k)/x_end:.4f})")
        post = [p for p in np_pts if p[0] > 0.30]
        print(f"  post-knee OLS slope (arm means, pub>0.30, n={len(post)}): "
              f"{ols(post)[1]:.4f}   excl D=300: {ols(np_pts[4:])[1]:.4f}")
        pw, wt = [], []
        for a in ["D300", "D400", "D600", "D900"]:
            for w in band(data[a], thr):
                pw.append((w["pub"], w["notice"] + w["pub"]))
                wt.append(bframes(w))
        print(f"  post-knee OLS slope (per-window, blocked-weighted, n={len(pw)}): "
              f"{ols(pw, wt)[1]:.4f}")

    print("\n=== exact anchor cov_px == 213358 (findings Table 1b) ===")
    for a in SWEEP + POLL + ["STEP1", "LAST"]:
        ws = anchor(data[a])
        print(f"  {a:6} win={len(ws)} bf={sum(bframes(w) for w in ws):3d} "
              f"pub={wmean(ws,'pub'):.3f} period={wmean(ws,'period'):.3f} "
              f"frame={wmean(ws,'frame'):.3f} notice={wmean(ws,'notice'):.3f} "
              f"period-frame={wmean(ws,'period')-wmean(ws,'frame'):.3f} "
              f"blocked={[w['blocked'] for w in ws]} n={[w['n'] for w in ws]}")

    print("\n=== §7.6 term identities ===")
    worst_exact, total = 0.0, 0
    for a in LOGS:
        for w in data[a]:
            worst_exact = max(worst_exact,
                              abs(w["period"] - (w["host"] + w["block"] + w["pub"])))
            total += 1
    print(f"  period == host+block+pub : max |resid| = {worst_exact:.4f} ms "
          f"over {total} windows (field width is 0.01)")
    for name, sel in (("exact anchor", anchor),
                      ("heavy band blocked>=90", lambda ws: band(ws, 90)),
                      ("heavy band blocked>=60", lambda ws: band(ws, 60))):
        rs = []
        for a in SWEEP:
            ws = sel(data[a])
            rs.append(wmean(ws, "period") - (wmean(ws, "frame")
                      + wmean(ws, "notice") + wmean(ws, "pub")))
        print(f"  period == frame+notice+pub, arm-pooled, {name:24}: "
              f"{min(rs):+.3f} .. {max(rs):+.3f} ms")
    sing = [(w["period"] - (w["frame"] + w["notice"] + w["pub"]), a, w["n"], w["blocked"])
            for a in LOGS for w in band(data[a], 90)]
    sing.sort(key=lambda t: -abs(t[0]))
    print("  worst single blocked>=90 windows: "
          + ", ".join(f"{r:+.3f} ({a} n={n} {b}%)" for r, a, n, b in sing[:3]))

    print("\n=== §1b heavy-B extent and index drift ===")
    for a in SWEEP:
        seq = [(w["n"], w["cov_px"]) for w in data[a] if 1800 <= w["n"] <= 2100]
        hb = [x for x in seq if x[1] >= HEAVY_COV]
        print(f"  {a:6} cov>=205k at {hb}")
    ref = {w["n"]: w["cov_px"] for w in data["D0"]}
    for a in SWEEP[1:] + POLL:
        common = [w for w in data[a] if w["n"] in ref]
        exact = sum(1 for w in common if ref[w["n"]] == w["cov_px"])
        dev = max((abs(w["cov_px"] - ref[w["n"]]) / ref[w["n"]], w["n"])
                  for w in common if ref[w["n"]] != w["cov_px"])
        print(f"  {a:6} vs D0: {exact}/{len(common)} same-n windows match cov_px "
              f"exactly; worst deviation {100*dev[0]:.0f}% at n={dev[1]}")


if __name__ == "__main__":
    main()
