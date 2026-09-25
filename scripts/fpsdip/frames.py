#!/usr/bin/env python3
"""fps-dip harness analysis: displayed new frames per 60 scanout frames.

Input: a capture dir holding fps.csv from tools/fps_probe.c
(t_us,scan,fc,sub,done,lat_us,gap). One row per scanout boundary the probe
saw; `fc` is the scanout control word's frame counter, which comp_fb_dma bumps
once per published frame and the reader adopts at a boundary.

Metric (same as the Solarus / Cash Cow DX harnesses): split the run into
consecutive windows of 60 scanout frames (~1.0013 s at 59.9228 Hz) and count
the boundaries that showed a NEW frame. Target: no window < 58, and windows
== 58 at most once per 30 s.

Also reported: repeated scanout frames and where they cluster, engine submit /
completion rate per window (C_SUBMIT / C_DONE deltas), and probe quality.

usage: frames.py <capture-dir> [--windows]
"""
import csv
import sys
from collections import Counter

PERIOD_S = 1 / 59.9228


def load(path):
    with open(path) as f:
        return [{k: int(v) for k, v in r.items()} for r in csv.DictReader(f)]


def main():
    d = sys.argv[1]
    show_windows = "--windows" in sys.argv
    rows = load(f"{d}/fps.csv")
    if len(rows) < 120:
        print(f"{d}: only {len(rows)} boundaries — capture failed?")
        return 1

    # Per boundary: did it show a new frame? A probe gap (missed boundary)
    # spreads the fc delta over the gap; fc can advance at most once per
    # boundary because comp_fb_dma never publishes past an unadopted frame.
    events = rows
    rows = [r for r in events if r["gap"] > 0]
    fresh = []          # (t_us, scan, new(0/1), sub, done)
    prev = rows[0]
    for r in rows[1:]:
        dfc = (r["fc"] - prev["fc"]) & 0x3FFFFFFF
        gap = r["gap"]
        new_total = min(dfc, gap)
        for k in range(gap):
            new = 1 if k < new_total else 0
            fresh.append((r["t_us"], r["scan"] - gap + 1 + k, new, r["sub"], r["done"]))
        prev = r

    wins = []
    for i in range(0, len(fresh) - 59, 60):
        w = fresh[i:i + 60]
        wins.append({
            "t": w[0][0] / 1e6,
            "new": sum(x[2] for x in w),
            "sub": (w[-1][3] - w[0][3]) & 0xFFFFFFFF,
            "done": (w[-1][4] - w[0][4]) & 0xFFFFFFFF,
        })
    dur = len(fresh) * PERIOD_S
    hist = Counter(w["new"] for w in wins)
    below58 = [w for w in wins if w["new"] < 58]
    eq58 = [w for w in wins if w["new"] == 58]
    # A window whose engine completed no frame at all is a load / stall, not a dip.
    stalled = [w for w in wins if w["done"] == 0]
    repeats = [x for x in fresh if x[2] == 0]

    # Sliding worst window (any 60 consecutive boundaries).
    run = sum(x[2] for x in fresh[:60]); worst = run; worst_t = fresh[0][0]
    for i in range(60, len(fresh)):
        run += fresh[i][2] - fresh[i - 60][2]
        if run < worst:
            worst, worst_t = run, fresh[i - 59][0]

    lat = sorted(r["lat_us"] for r in rows)
    missed = sum(r["gap"] - 1 for r in rows)

    print(f"capture {d}")
    print(f"  duration {dur:.1f}s  scanout frames {len(fresh)}  windows {len(wins)}")
    print(f"  displayed new frames per 60-frame window: "
          + " ".join(f"{k}:{hist[k]}" for k in sorted(hist)))
    print(f"  windows <58: {len(below58)}   ==58: {len(eq58)} "
          f"({len(eq58) / (dur / 30):.2f} per 30 s)   engine-stalled windows: {len(stalled)}")
    print(f"  worst sliding 60-frame window: {worst} new at t={worst_t / 1e6:.1f}s")
    print(f"  repeated scanout frames: {len(repeats)} of {len(fresh)} "
          f"({100 * len(repeats) / len(fresh):.2f}%)")
    subs = sorted(w["sub"] for w in wins)
    print(f"  engine submits per window: min {subs[0]} median {subs[len(subs) // 2]} max {subs[-1]}")
    print(f"  probe: boundaries missed {missed}, detect latency p50 {lat[len(lat) // 2]}us "
          f"p99 {lat[int(len(lat) * 0.99)]}us max {lat[-1]}us")
    ok = not below58 and len(eq58) <= dur / 30
    print(f"  TARGET (no <58, ==58 <= 1/30s): {'PASS' if ok else 'FAIL'}")

    bad = [w for w in wins if w["new"] <= 58]
    if bad:
        print("  dip windows (t, new, engine submits, engine completions):")
        for w in bad[:60]:
            print(f"    t={w['t']:7.1f}s new={w['new']} sub={w['sub']} done={w['done']}")
    # Repeat clusters: runs of repeats within 1 s of each other.
    if repeats:
        clusters, cur = [], [repeats[0]]
        for x in repeats[1:]:
            if x[0] - cur[-1][0] < 1_000_000:
                cur.append(x)
            else:
                clusters.append(cur); cur = [x]
        clusters.append(cur)
        clusters.sort(key=len, reverse=True)
        print(f"  repeat clusters: {len(clusters)}; largest (t_start, repeats):")
        for c in clusters[:10]:
            print(f"    t={c[0][0] / 1e6:7.1f}s  {len(c)}")
    attribute(events, rows)
    if show_windows:
        for w in wins:
            print(f"  W t={w['t']:7.1f} new={w['new']} sub={w['sub']} done={w['done']}")
    return 0


def attribute(events, bounds):
    """Classify each repeated scanout frame from the event timeline.

    For the interval (T[k-1], T[k]] that ended in a repeat:
      skip        the fabric completed a frame (C_DONE moved) but fc did not:
                  comp_fb_dma dropped it because the reader had not adopted the
                  previous publish yet (two completions inside one period)
      fabric-busy a submit was outstanding (sub != done) for the whole interval
      host-late   the fabric sat idle (sub == done) at some point in it
    Also: per-frame fabric latency (doorbell -> C_DONE) and the host's
    C_DONE -> next doorbell gap, from the 0.5 ms event timeline.
    """
    sub_t, done_t = {}, {}
    for e in events:
        sub_t.setdefault(e["sub"], e["t_us"])
        done_t.setdefault(e["done"], e["t_us"])
    lat = sorted(done_t[s] - sub_t[s] for s in sub_t if s in done_t and done_t[s] >= sub_t[s])
    gaps = sorted(sub_t[s + 1] - done_t[s] for s in done_t if s + 1 in sub_t and sub_t[s + 1] >= done_t[s])
    pct = lambda a, q: a[min(len(a) - 1, int(len(a) * q))] / 1000 if a else float("nan")
    print(f"  fabric doorbell->done ms: p50 {pct(lat, .5):.2f} p90 {pct(lat, .9):.2f} "
          f"p99 {pct(lat, .99):.2f} max {pct(lat, 1):.2f}  (0.5 ms resolution)")
    print(f"  host done->next doorbell ms: p50 {pct(gaps, .5):.2f} p90 {pct(gaps, .9):.2f} "
          f"p99 {pct(gaps, .99):.2f} max {pct(gaps, 1):.2f}")

    # Walk the timeline boundary to boundary.
    cls = Counter()
    ei = 0
    skips_total = 0
    for k in range(1, len(bounds)):
        a, b = bounds[k - 1], bounds[k]
        idle = a["sub"] == a["done"]
        while ei < len(events) and events[ei]["t_us"] <= a["t_us"]:
            ei += 1
        j = ei
        while j < len(events) and events[j]["t_us"] <= b["t_us"]:
            if events[j]["sub"] == events[j]["done"]:
                idle = True
            j += 1
        ddone = (b["done"] - a["done"]) & 0xFFFFFFFF
        dfc = (b["fc"] - a["fc"]) & 0x3FFFFFFF
        skips_total += max(0, ddone - dfc)
        if dfc == 0 and b["gap"] == 1:
            if ddone > 0:
                cls["skip"] += 1
            elif idle:
                cls["host-late"] += 1
            else:
                cls["fabric-busy"] += 1
    print(f"  repeat attribution: " + ", ".join(f"{k} {v}" for k, v in cls.most_common())
          + f"; completions dropped by comp_fb_dma: {skips_total}")


if __name__ == "__main__":
    sys.exit(main())
