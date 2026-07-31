# Phase 4 Stage B — the fabric stage

**Date:** 2026-07-30
**Status:** design, user-approved 2026-07-30. Not yet a plan.
**Predecessor:** `specs/2026-07-30-phase4-host-coupling-design.md` (Stage A), whose
outcome is `findings/2026-07-30-phase4-stage-a-seam.md`.
**Re-gate:** Stage A measured the seam and closed it as a lever. Stage B is an
**RTL + host-emission** stage targeting the fabric `frame` term.

---

## 0. The correction this design rests on

Both prior documents locate the redundant full-screen clear in the RTL control
block and cite `blitter_top.sv:1322-1353` (`S_GOT_CLEAR` → `S_CLR_FILL`).

**Observed.** That path does not execute on device. The sole production call site
is `raster_backend_mfgpu.cpp:1390`:

```c
blt_begin_frame(&g_e, /*target_buf=*/0, /*clear=*/0, /*clear_color=*/0);
```

`clear` is hard-zero, so `cfg_flags[0]` is always 0 and `S_CLR_FILL` is never
entered. (The other `blt_begin_frame` call sites are `raster_backend_test.cpp:681`
and the `3rdparty/mfgpu/host` self-tests; only `test_emitter.c:77` passes
`clear=1`, and it is not production.)

**Observed.** The real 62,208-pixel full-screen fill is the game's own `glClear`,
arriving at `mf_clear()` and emitted as an ordinary ring `BLT_OP_FILL`:

```c
// raster_backend_mfgpu.cpp:1426
blt_fill(&g_e, 0, 0, w, h, mf_rgb565(r, g, b));
```

**Two consequences, and they shape the whole stage:**

1. **Eliminating the clear is a pure host change.** No RTL, no control bit, no
   Quartus cycle. It ships and is device-measured on its own, which removes the
   attribution confounding that a bundled bitstream would have introduced.
2. **It relocates the `ovhd` residual.** `ovhd = frame − tri`, and `tri` counts
   only `state >= S_TRI_VFETCH` (`blitter_top.sv:1243`). A ring `BLT_OP_FILL`
   dispatches through `comp_pipeline`, **not** through the `S_TRI_*` states, so the
   clear's ~62,208 cycles (**0.632 ms** at 98.4375 MHz) are already inside the
   measured device `ovhd` of 2.32 ms. That leaves **~1.69 ms** unattributed.

   The option register (`findings/2026-07-30-phase4-option-space.md`) names
   single-beat DDR3 traffic as the leading suspect (`blitter_top.sv:2454`,
   `mem_burstcnt = ... : 8'd1`), sizing it as ~424 round trips against a platform
   figure of "~20 cycles". **That arithmetic does not close:** 1.69 ms is ~166,000
   cycles, i.e. ~390 cycles per round trip. Either the DDR3 latency under arbiter
   contention is an order of magnitude worse than the platform figure, or the
   residual is somewhere else entirely.

   **Unknown, and deliberately not acted on this stage.** W3 adds the counter that
   decides it. **What would answer it:** the `ovhd` split counter of §4.9.

---

## 1. Gate

**Primary gate.** Fabric `frame` ≤ **16.13 ms** on the sustained heavy scenes.

Derivation, from Stage A §3.2/§8: in the fabric-bound regime the identity
`period = frame + notice + pub` holds exactly. A locked 59.9228 fps needs
`period ≤ 16.6882`. Measured `notice` = 0.56 median, `pub` = 0.00. Therefore
`frame ≤ 16.6882 − 0.56 − 0.00 = 16.13`.

**Anchors** (fabric `frame`, measured):

| scene | `cov_px` | `frame` | needs |
|---|---|---|---|
| Phase 3 quiet, 216 tris | 182,661 | 16.20 | −0.07 |
| Stage A heavy-A | 195,084 | 17.21 | −1.08 |
| **Stage A heavy-B — the gate anchor** | 213,358 | **18.02** | **−1.89** |
| Phase 3 arrival | 245,346 | 21.37 | −5.24 |

**Scope decision (user, 2026-07-30):** the gate is the sustained scenes. The
arrival transient is **measured and must not regress**, but is explicitly
best-effort and does not block completion.

**Lock is proven, not inferred.** `period ≤ 16.6882` from C_DONE deltas, **and**
the `scan_frame_cnt` ratio showing repeated frames ≈ 0. A fabric `frame` under the
gate with a period over it is a failure, not a pass.

**Non-regression gates** (carried from Phase 3, unchanged):

- `exact_bad == 0` against the refmodel on every stream vector.
- synthquad / spanedge hand-computed bucket counts unchanged.
- `grep 276007 *.map.rpt` empty — no M10K uninference.
- STA TNS not worse than the shipping bitstream's.
- `MisterAudio_StarvedFrames()` == 0 on every reporting window.

---

## 2. Shape — three workstreams, decoupled by deploy vehicle

| # | workstream | vehicle | expected on `frame` |
|---|---|---|---|
| **W1** | Scene corpus + Candidate A sizing | host/offline, no device change | 0 — produces the anchors and the prediction |
| **W2** | CLEAR elimination | **engine only**, ships alone | **−0.63 ms** |
| **W3** | Candidate A (pb pipelining) + attribution counters | **one Quartus cycle** | **−4.7 ms paper**; gate needs 27 % of it after W2 |

**Ordering.** W1 gates W3 — no Quartus time is spent until the stream bench
reproduces the gate anchor. W2 is independent of both and lands first, which
yields an early real device measurement and de-risks the stage if W3 slips.

**Why the gate needs only 27 % of Candidate A.** After W2 the anchor is
18.02 − 0.63 = 17.39. The gate is 16.13, so the residual ask is **1.26 ms** against
a paper 4.7 ms. A partial realization still clears — that margin is the reason this
lever was chosen over the cheap bundle.

---

## 3. Explicitly out of scope

Each of these was considered and declined for a stated reason. None is deferred
silently.

- **Opaque cull (general, per-triangle).** Host↔fabric contract change; the Phase 3
  sizing puts its arrival value at a 64 % realization fraction against an idealized
  ceiling (perfect per-pixel occlusion, zero cull cost). Unfunded until an arrival
  gate exists.
- **`ovhd` / DDR3 burst widening.** No instrument attributes the 1.69 ms today, and
  §0 shows the published sizing arithmetic does not close. W3's counter makes it
  fundable next stage. Acting now would be a guess in the subsystem with this
  project's three worst bugs (poll-before-issue livelock, late-f2h mis-steer,
  startup wedge).
- **`notice` reduction (Stage A lever L2, 0.56 ms).** The split between `S_SNAP`
  (~0.158 by design) and doorbell/DDR visibility is Unknown. Same counter rider
  decides it. It is also already inside the gate arithmetic of §1 — reducing it
  *relaxes* the gate rather than moving `frame`.
- **Candidate B (2-px/cyc blend).** Declined in Phase 3 §5 on value/risk; it also
  shrinks the prefetch lead furthest. Nothing measured since has changed that.
- **LW bridge / f2h port reallocation** (option register Options A and B). Both
  require editing `sys_top.v` or the Platform Designer system. Out of proportion to
  a 1.26 ms residual ask.

---

## 4. Workstreams in detail

### W1 — corpus and sizing

The Stage A corpus cannot anchor this gate. Its §9 caveats 1–2 record that captures
A and C are the same scripted trajectory frame-for-frame, that no screenshot
confirmation was taken, and that the logs carry no scene argument. Both scene
scripts exist (`scripts/scenes/ingame-stage1.joy`,
`scripts/scenes/ingame-stage1-busy.joy`), so one workload appearing where two were
intended is a defect to be found, not a property of the game.

**4.1 Scene provenance.** Echo the resolved `--scene` name and the joy script's md5
into the bench log at launch, and pull a screenshot at a fixed frame offset.
Root-cause why `ingame-stage1-busy` did not diverge from `ingame-stage1` in the
Stage A run.

*Acceptance:* a log line naming the scene and md5, one screenshot per run, and a
stated root cause for the Stage A collapse.

**4.2 The 4-scene corpus.** Capture with `mister_run.sh bench --scene NAME
--capture START:FRAMES` (which stages `GMLOADER_MFGPU_TRACE`): quiet (182,661),
heavy-A (195,084), heavy-B (213,358), arrival (245,346). Each screenshot-confirmed,
each with an `MFTRACE` draw stream pulled.

*Acceptance:* four traces on disk, four screenshots, `cov_px` within ±1 % of the
figures above, `suspect=0` / `incomplete=0` / no `submit timeout` on every window.

**4.3 Sim vectors.** `gen_tri_stream.c --frame N` over the heavy-B trace →
`stream_heavy_*_ddr.hex` / `_exp.hex`. Register in `tb_blitter_trilist_stream`
(GATING, bit-exact) and `tb_blitter_trilist_streamcache` (NIGHTLY, real-cache).
Follow the existing `stream_quiet_f0_*` pattern and
`gen_tri_golden.mk`'s stream-vectors target.

*Acceptance:* both TBs green on unmodified RTL; `exact_bad == 0`.

**4.4 Calibration — the gate on spending a Quartus cycle.** Run the *unmodified*
RTL on the new vectors. The streamcache bench must reproduce the measured device
18.02 ms to within the ±0.7 % it achieved in Phase 3 (where it called device fabric
to +0.31 % and texwait to +1.1 %).

*Acceptance:* prediction within ±0.7 % of the device anchor. **If it misses, W3 is
not funded** — fall back to §7 R2.

### W2 — CLEAR elimination

**4.5 Defer, don't predict.** `mf_clear()` runs before the frame's draws are known,
so it cannot decide. Instead it records a **pending full-screen fill**; the decision
happens at the first subsequent draw on that target:

- drop the pending fill iff that draw is **opaque, non-keyed, non-blended, and
  covers the target's full extent** — the same clamped `w`/`h` the pending fill was
  itself recorded with (`mf_clear()` clamps to `BLT_FB_WIDTH`/`BLT_FB_HEIGHT`), so
  the comparison is against that recorded extent and not a hardcoded 288×216;
- otherwise emit the fill first, in its original ring position;
- if the frame ends with a pending fill undecided, emit it.

Any condition not provably met emits the fill. **The failure mode is a lost 0.63 ms,
never a stale pixel.**

**Composition constraints, all load-bearing:**

- **Per target.** `mf_select_target()` switches WORK vs APPSURF; a pending fill on
  one target is not discharged by a draw on the other. Track one pending fill per
  target.
- **`g_frame_dropped`.** `mf_clear()` returns early when the in-flight-batch guard
  is set; a pending fill must not survive into the next frame.
- **`g_last_draw` coalescing.** `mf_clear()` currently sets `g_last_draw.valid =
  false` to break a duplicate-draw run. Deferring the emission must not change when
  that break happens.
- **`g_appsurf_presented` / CRT strip.** `raster_backend_mfgpu.cpp:200-215` records
  that the preceding-opaque-present condition is load-bearing: `obj_fade_in` /
  `obj_fade_out` legitimately draw the app surface translucently over a **cleared**
  target, and dropping that clear would blank the whole transition. A translucent
  first draw fails the opacity test above and therefore emits the fill — but this
  interaction must be tested explicitly, not argued.

**4.6 Witness counters.** `clears_dropped` / `clears_emitted` per window in the
engine's stat line, so the device measurement is direct rather than inferred from
`ovhd`.

**4.7 Device A/B on `.62`.** Same corpus, engine-only swap (scp to `gmloader.new`,
`mv -f` over the running binary, `killall -9 gmloader`; never hand-launch after).

*Acceptance:* `frame` and `ovhd` each down ~0.63 ms; `clears_dropped` > 0 on every
corpus scene; all four screenshots visually identical to the W1 baselines.

### W3 — Candidate A and the counter riders

**4.8 pb pipelining.** `pb` is still a sequential FSM:
`B_IDLE → B_LOOK → B_FILL → B_WAIT → B_WR → B_WR2 → B_WR3` (`blitter_top.sv:557`),
6.000 cyc/px. Convert to `pb_v`-gated pipeline stages behind a credit-limited
dispatcher, mirroring the A-chain transformation already proven on pa in Phase 3
(pa 7.09 → 1.10 cyc/px).

**Co-requisite, not a separate experiment** (Phase 3 §8.2): raise `TEXFIFO_D`
8 → 16. The prefetch lead is `TEXFIFO_D` × pb's retire interval, so halving the
interval halves the lead — 8 × 6 = 48 cycles today, 8 × 3 = 24 after this change,
against a ~12-cycle device miss. Three things co-move and must change together:
`TEXFIFO_D`/`TEXFIFO_AW`, the `ax_room` bound, and `ax_cred`'s width
(`AX_CW = $clog2(TEXFIFO_D+1)`, with the `FAIL 3B-CREDW` elaboration guard).

**Two hazards named at design time**, both from this core's history:

- **Do not collapse `B_WR3 → B_IDLE → B_LOOK`.** `blitter_top.sv:852-876` documents
  that the dst-BRAM write is presented in `B_IDLE` and the read in `B_LOOK`, always
  exactly one cycle apart, and explicitly says to re-check if pb is ever re-timed so
  those land in the same cycle.
- **Never nest a `ramstyle` array's read inside an FSM case arm.** That is what
  caused the `tq_data`/`tq_tag` M10K uninference (map.rpt 276007) — 20,480 stray
  flops and a 1,735-fanout 256:1 mux. `blitter_top.sv:738-740` records the current
  bare unconditional read and why it is bare.

**4.9 Attribution counters (riders — must have zero effect on `frame`).**

- Split `ovhd` into **clear-fill / ring-fetch-wait / prologue / publish-tail**. This
  is the instrument that decides §0's 1.69 ms.
- Stamp **doorbell-observed** against **`C_DONE`-written** to split `notice` into
  `S_SNAP` serialization vs doorbell/DDR visibility.

**Real constraint, not a freebie.** The publish slots are nearly full:
`perf_covered_px` → `C_FLAGS.hi`, `perf_frame_cyc` → `C_DONE.hi` (with
`submit_reg`), `perf_tri_cyc` → `C_SRCSEL.hi`, `perf_texwait_cyc` → `C_STATUS.hi`.
New counters need either additional spare qwords or a **control-word-selected
counter mux** (host writes a selector; fabric publishes that counter bank). Publish
ordering is guarded by `tb_perf_publish_order` and that guard must stay green — the
C_DONE-last ordering exists because publishing it first left an 8-cycle window where
a host read could straddle a submit.

**4.10 Pre-build gates, run before the Quartus cycle is requested.** `exact_bad == 0`
on every stream vector including the new heavy-B ones; synthquad/spanedge bucket
counts unchanged; `run_sims.sh --tier=nightly` green; ast lint clean.

**4.11 Build and validate.** Quartus on the self-hosted Windows runner (the
canonical build — not the Linux fallback). Then `.62` validation on the full corpus.

---

## 5. Instruments

| instrument | what it answers | pass condition |
|---|---|---|
| `MFSUBMIT` | `frame` / `tri` / `dpath` / `texwait` / `ovhd` / `cov_px` | `frame` ≤ 16.13 on sustained scenes |
| C_DONE delta | true delivered period | ≤ 16.6882 ms |
| `scan_frame_cnt` (`0x3BFB0018`), period (`0x3BFB001C`) | repeated-frame ratio | ≈ 0 repeats |
| `MFSEAM` | `period` / `host` / `block` / `pub` / `notice` | `suspect=0`, `incomplete=0` on **every** window |
| `FCAP` | cap behaviour | see the reading rule below |
| `clears_dropped` / `clears_emitted` | W2 witness | > 0 dropped on every corpus scene |
| `MisterAudio_StarvedFrames()` | audio correctness | 0 |

**The `FCAP` reading rule (Stage A §5), restated because misreading it optimises in
exactly the wrong direction.** At a locked 59.9228 fps the cap reports `waited` near
**100 %** with a *small* average wait — **that is the success signature, not a cost**.
High `waited%` + low `wait_ms_avg` = frames locking to consecutive boundaries. Low
`waited%` + multi-millisecond `wait_ms_avg` = frames **missing** their boundary.
Stage A measured the second signature (16–37 % at 1.2–10.0 ms), which is what "not
locked" looks like.

**Known instrument gaps carried from Stage A**, to be closed opportunistically, not
as blockers: instrument self-cost is unbounded (no capture with the stat knob off);
`period` has no second instrument to cross-check against; `host_hist` bucket edges
cannot resolve shape inside 8–20 ms.

---

## 6. Definition of done

1. Sustained heavy scenes: `frame` ≤ 16.13 ms **and** measured `period` ≤ 16.6882 ms
   with repeated frames ≈ 0, on screenshot-confirmed scenes.
2. Arrival: number stated, not regressed against its 21.37 ms baseline.
3. All §1 non-regression gates green.
4. `ovhd` and `notice` decomposed by counter, so the next stage's levers are funded
   on evidence rather than on §0's non-closing arithmetic.
5. Findings document written with the same Observed / Inferred / Unknown discipline
   as the Stage A seam document, including a data-trust section.

---

## 7. Risks

**R1 — Candidate A misses STA.** This core's timing history is combinational depth
(`maldita-tri-timing-is-comb-depth`) and M10K uninference
(`native-audio-sta-regression`). *Mitigation:* both checks are **pre-build** gates
(§4.10, §4.8), not post-build surprises, and §4.8 names the two specific hazards.

**R2 — the bench fails to reproduce the 18.02 anchor (§4.4).** *Mitigation:* W3 is
not funded. Fall back to shipping W2 alone plus a small counters-only bitstream, and
re-open sizing with the `ovhd` split in hand. This is a planned branch, not a
failure.

**R3 — a dropped CLEAR shows stale pixels.** *Mitigation:* the §4.5 design fails
safe by construction (any unproven condition emits), `clears_dropped` makes the
behaviour visible, and all four corpus scenes are screenshot-compared. The
`obj_fade_in` / `obj_fade_out` translucent-present case is tested explicitly.

**R4 — frame-1 fabric wedge on ~1 in 2 core loads.** A retry clears it; **a reboot
does not**. *Mitigation:* already handled — `mister_run.sh` auto-detects `submit
timeout`, retries up to 3×, and re-greps the pulled log post-hoc, exiting non-zero
on a post-hoc hit.

**R5 — W2 lands first and moves the anchor.** *Mitigation:* re-take W1's calibration
against post-W2 device numbers rather than subtracting 0.63 on paper. Cheap, and it
avoids compounding two predictions.

**R6 — counter riders perturb what they measure.** *Mitigation:* riders are counting
logic only, published through existing slots via a selector. The riders ship in the
same bitstream as Candidate A, so there is no pre-rider device build to compare
against; the acceptance check is therefore **in simulation** — `tb_blitter_trilist_stream`
cycle counts identical with the riders compiled in and out (`exact_bad == 0` and the
same total cycle count, not merely a similar one).

---

## 8. Device and deploy constraints

- **`.62` is the TEST device; `.81` is PRODUCTION.** `deploy.py --host` still
  defaults to `.81` — always pass `--host 192.168.20.62`, or use the Makefile
  (`HOST` defaults to `.62`; `.81` needs `PROD=1`).
- **Engine deploy = swap then kill.** scp to `gmloader.new`, `mv -f` over the running
  binary, `killall -9 gmloader`; the handler re-execs it. **Never hand-launch
  after** — that is how two engines end up on one control block.
- **Worktree per workstream.** Concurrent sessions run on these checkouts. Create
  `git worktree add ../wt-<topic> -b <branch>` **before** the first commit; never
  `checkout -b` in a shared tree.
- **The shipping blitter RTL is the vendored copy** in
  `maldita.castilla-mister/fpga/rtl/`. `mister-fpga-blitter/rtl/` is a non-shipping
  v1 spike; a green host suite there is not device evidence.
