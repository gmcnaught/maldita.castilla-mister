# Phase 4 W3 — setup/vfetch overlap and the notice lever

**Date:** 2026-07-31
**Status:** design, user-approved 2026-07-31. Not yet a plan.
**Predecessor:** `findings/2026-07-30-phase4-stage-b-w1-w2.md` (W2 shipped and merged;
pin bumped to `d6e9874`, merged artifact re-validated on `.62`).
**Supersedes** the W3 framing in `specs/2026-07-30-phase4-stage-b-fabric-design.md` §2,
which assumed Candidate A was the phase's centre. It is not — see §1.

---

## 0. Why the previous W3 framing no longer holds

Three W2 measurements changed what this phase should be. All are device-measured on
`.62` and recorded in the W2 findings.

1. **`notice` is now the binding term on heavy-B, not coverage.** Post-W2 heavy-B
   `frame` is **16.69 ms** against a scanout period of **16.6882 ms** — the fabric
   term now *fits the period on its own*. The Stage B spec ranked the notice lever
   second behind any `cov_px` reduction because heavy scenes needed 0.52–1.33 ms off
   `frame` before a lock was arithmetically possible. They no longer do; W2 took it.
2. **Heavy-B is reachable without Candidate A.** The residual ask fell from 1.89 ms
   to **0.56 ms**. §2b plus a strong notice fix covers it (§2). Candidate A's paper
   −4.7 ms is now far more lever than the target needs.
3. **The DDR3-burst theory is dead.** 87 % of the 1.53 ms `ovhd` residual was two
   redundant full-screen clears per frame, not single-beat bursts. The `ovhd`
   attribution counter that the Stage B spec planned as a W3 rider has lost most of
   its value; post-W2 device `ovhd` (0.97) sits 0.184 ms from the sim's 0.786.

**A fourth measurement bounds what this phase can claim.** On quiet, `MFSEAM host`
averages **15.72 ms** against a `frame` of 14.86 — quiet is **host-bound**. No fabric
lever moves it, and its delivered rate is 58.89 Hz. Quiet is therefore out of scope
here, and any claim about delivered frame rate on quiet belongs to a host phase.

---

## 1. Gate

**`period ≤ 16.6882 ms` on heavy-B** (`cov_px` 213,358), proven by **C_DONE delta with
repeated frames ≈ 0**.

Stated that way deliberately. The W2 findings had to correct a claim that inferred a
59.9228 Hz lock from a fabric-gate comparison (`frame ≤ gate`) and reported it as
observed, when the measured rate was 58.89 Hz. **A fabric term under its gate is not a
lock.** This phase's gate is the delivered period or it is nothing.

**Secondary, non-blocking:** arrival (`cov_px` 245,346) measured and not regressed
against its post-W2 21.37 → 20.04 ms. Reaching it needs −3.91 ms, which no lever in
this phase is sized for.

**Non-regression gates, unchanged from Stage B:** `exact_bad == 0` on every stream
vector; synthquad/spanedge hand-computed bucket counts unchanged;
`grep 276007 *.map.rpt` empty (no M10K uninference); STA TNS not worse;
`MisterAudio_StarvedFrames()` == 0.

---

## 2. The budget, and why both levers are required

| term | post-W2 measured | after this phase |
|---|---|---|
| heavy-B `frame` | 16.69 | 16.48 (§2b, −0.21) |
| `notice` | 0.56 | must reach ≤ 0.21 |
| `pub` | 0.00 | 0.00 |
| **`period`** | **17.25** | **≤ 16.6882** |

§2b alone leaves `period` at 17.04 — **over by 0.35**. So `notice` must supply at least
**0.35 of its 0.56**, and `S_SNAP` (~0.158 ms, by design) cannot supply it alone. **The
fix has to land on the ~0.40 ms doorbell / DDR-visibility component**, whose existence
is *inferred and never measured*. That inference is this phase's central risk and is
what Stage A exists to settle.

---

## 3. Three stages; only the last spends a Quartus cycle

### Stage A — host-side notice probe (engine only, `.62`, no Quartus)

Characterise `notice` from the host before any RTL is written. Vary the C_DONE poll
strategy, memory barriers, and cache handling, and measure whether the observed
`notice` moves.

- **If it moves:** the ~0.40 ms really is DDR read-visibility, the Stage C target is
  confirmed, and the probe itself may indicate the cheapest fix.
- **If it does not move:** the inference is wrong. `notice` lives in the fabric
  (`S_SNAP` longer than designed, or submit-observe latency), and Stage C's content
  changes — see §5.

This mirrors how the real-cache stream bench de-risked Phase 3 before its Quartus
cycle: spend the cheapest decisive measurement first.

*Acceptance:* a stated, measured answer to "does host-side polling strategy change
`notice`?", with the same integrity gates every device run in this project carries
(`suspect=0`, `incomplete=0`, no `submit timeout`).

### Stage B — §2b, setup/vfetch overlap (RTL, sim-gated, bit-exact)

Overlap per-triangle setup and vertex fetch with the previous triangle's walk.

**Measured size, not estimated:** the streamcache run on `stream_heavy_f0` reports
`setup=10,976` and `vfetch=9,940` cycles for the frame — **20,916 cycles = 0.2125 ms**
at 98.4375 MHz. `10,976 / 48 = 228.7`, matching the scene's ~228 triangles, which
independently confirms the 48-cycle divide is the whole of `setup`.

**Why it is safe:** zero arithmetic change. `blt_tri_setup.sv`'s divider
(`ITERS=48, UNROLL=1`, radix-2 restoring) is untouched; only *when* it runs changes.
That matters against a strict `exact_bad == 0` gate.

**Scope, corrected from the initial proposal — this is a two-module change:**
`blt_tri_setup` holds a `busy` flag and cannot accept a new `start` while the previous
triangle's outputs are still being consumed. It needs an **output register bank plus a
ready/valid handshake**, not merely a second copy of the outputs in `blitter_top`.

**What must be duplicated, and what must not:** only the values read *throughout* the
walk — the 18 dx/dy deltas, `ts_area_recip`, and the bbox — roughly 950–1,100 flops
(~1.2 % ALM against the current 42 %). The seeds (`ts_Wu_0` …) are latched once into
`blitter_top`'s own `Wu`/`Wv`/… at `S_TRI_SWAIT` and need no second copy.

**This retires the DSP-reciprocal alternative on scenes like this one.** Heavy-B
averages 936 px/tri ≈ 5,600 cycles of walk against 48 cycles of setup, so once
overlapped the divider hides completely and shortening it 48 → 5 cycles buys nothing.
⚠️ Scene-dependent: a scene of many tiny triangles could drop the walk below 48 cycles
and re-expose setup. 0.2125 ms is the measured value *on heavy-B*.

*Acceptance:* `exact_bad == 0` on `stream_quiet_f0` and `stream_heavy_f0`; the
streamcache `setup`+`vfetch` cycle counts fall to ~0 of the serial path; sim `frame`
drops by ~0.21 ms.

### Stage C — the notice fix, plus the attribution counter as a rider

Content determined by Stage A. Ships in the **same Quartus cycle as Stage B**.

The counter rides along regardless: stamp **doorbell-observed** against **`C_DONE`
written**, splitting `notice` into `S_SNAP` serialization versus doorbell/DDR
visibility. Even if Stage A settles the question behaviourally, the counter makes the
result durable and re-checkable.

**Publish-slot constraint, carried from the Stage B spec and still true:**
`C_SRCSEL.hi`, `C_STATUS.hi`, `C_FLAGS.hi` and `C_DONE.hi` are all taken. A new counter
needs either spare qwords or a control-word-selected counter mux, and
`tb_perf_publish_order` must stay green — the C_DONE-last ordering exists because
publishing it first left an 8-cycle window in which a host read could straddle a submit.

---

## 4. Explicitly out of scope

- **Candidate A (pb pipelining).** Deferred for the third time, and now for a better
  reason than cost: heavy-B does not need it. Its calibration (`dpath` −0.03 %) stands
  and it remains the arrival lever whenever arrival is funded.
- **The product-space DDA hoist** (`blitter_top.sv:1797-1802`). Bit-exact, frees ~24 DSP
  blocks and two pipeline stages, but worth ~0 ms because `pa_hold` is 85.4 % — its
  payoff is DSP headroom *for Candidate A*, which is not being built. YAGNI. It is an
  enabler to sequence before Candidate A, never a throughput lever.
- **Opaque cull.** Arrival-only; host↔fabric contract change; unfunded.
- **The LW-bridge doorbell move.** Held as Stage C's fallback (§5), not the default —
  it means editing `sys_top.v` / the Platform Designer system, which this project has
  so far avoided.
- **Quiet's delivered rate.** Host-bound (§0). Belongs to a host phase.

---

## 5. Risks and the contingency branch

**R1 — Stage A refutes the DDR-visibility inference.** Then `notice` is fabric-side and
the ~0.40 ms is `S_SNAP` running longer than its design figure, or submit-observe
latency. *Branch:* Stage C attacks the fabric path instead, and if no fabric fix is
sized ≥0.35 ms, the **LW-bridge doorbell move** becomes the lever — it removes the DDR
round-trip regardless of how the 0.56 splits, at the cost of touching `sys_top.v`.

**R2 — Stage A shows `notice` cannot yield 0.35 ms by any means.** Then this phase
cannot reach its gate. *Branch:* ship §2b alone as a measured −0.21 ms improvement,
report heavy-B at 16.48 + `notice`, and re-open the gate with Candidate A funded — this
is the case in which Candidate A stops being avoidable. **Do not quietly redefine the
gate to match what was achieved**; the W2 phase already had to correct one inferred
claim, and that is the failure mode to avoid.

**R3 — §2b misses STA.** The double-buffer adds ~1,000 flops and a handshake, not
combinational depth, so the risk is placement rather than a long path. Mitigated by the
same pre-build gates every RTL change here carries: the `276007` map.rpt check and the
rule that a `ramstyle` array's read must never be nested in an FSM case arm.

**R4 — §2b's win is scene-dependent.** 0.2125 ms is measured on heavy-B (936 px/tri).
A scene of many small triangles recovers less. *Mitigation:* report the measured value
per corpus scene rather than a single figure.

**R5 — frame-1 fabric wedge** on ~1 in 2 core loads; a retry clears it, a reboot does
**not**. Already handled: `mister_run.sh` auto-detects `submit timeout`, retries up to
3×, and re-greps the pulled log post-hoc, exiting non-zero on a post-hoc hit.

---

## 6. Definition of done

1. heavy-B: measured `period ≤ 16.6882 ms` with repeated frames ≈ 0, on a
   screenshot- or `cov_px`-confirmed scene.
2. §2b's contribution stated **as measured per scene**, not as the single 0.2125 figure.
3. arrival measured and not regressed against 20.04 ms.
4. `notice` decomposed by counter, so the next phase's levers are funded on evidence.
5. All §1 non-regression gates green.
6. Findings written with the Stage A/W2 discipline: **Observed / Inferred / Unknown**,
   every Unknown carrying "what would answer it", and a data-trust section.

---

## 7. Device and deploy constraints (unchanged)

- **`.62` is the TEST device; `.81` is PRODUCTION.** `deploy.py --host` still defaults
  to `.81` — always pass `--host 192.168.20.62`, or use the Makefile.
- **Engine deploy = swap then kill**, never hand-launch afterwards.
- **Never background a device run.** A `mister_run.sh bench` call must complete in the
  foreground; a backgrounded one dies with the shell that started it and leaves the
  device un-torn-down. Docker builds, by contrast, survive — recover with
  `docker wait <id>`.
- **Worktree per workstream**, created before the first commit.
- The shipping blitter RTL is the vendored copy in `maldita.castilla-mister/fpga/rtl/`.

---

## 8. Evidence index

- W2 results and the corrected delivered-rate figures:
  `findings/2026-07-30-phase4-stage-b-w1-w2.md`
- §2b sizing: `fpga/sim` streamcache run on `stream_heavy_f0` —
  `CYC ... setup=10976 vfetch=9940`, `MS total=16.468`
- `notice` decomposition as it stands: `findings/2026-07-30-phase4-stage-a-seam.md` §8
- Candidate A sizing and the `dpath` calibration:
  `findings/2026-07-30-phase3-stage-a-sizing.md` §5, W2 findings §4
- `pa_hold` 85.4 % (why pa-side levers are area, not time): W2 findings, and the
  `CYCX pa_pix=1491690 pa_hold=1273607` line from the same streamcache run
