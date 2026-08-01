# Fabric arithmetic review — multiplies, divides, shifts, DSP mapping

Date: 2026-07-30
Scope: every `*`, `/`, `%` site in the **synthesized** RTL set (`fpga/files.qip`).
Repo/commit: `maldita.castilla-mister` @ `38e1490`, `fpga/rtl/`.

## Headline

No naive divides and no power-of-two multiplies remain on any live path. All
five `/255`-class reductions are already the divide-free shift-add identities
(`red255`/`red31`/`red63`, `COMP_DIV255`, and the `((x<<8)+x+257)>>16` truncating
form at `blitter_top.sv:2077`). The one surviving real divider in a compiled file
is in **dead code**.

The remaining arithmetic items are **area and timing headroom, not frame time**.
The A-pipeline and comp_pipeline are 1 px/cycle regardless of how the multipliers
map, so restructuring them does not move fabric ms. The single item that *is*
wall clock is the per-triangle reciprocal divider (§2), worth ~0.10 ms/frame.

## Method

Enumerated operator sites with a comment-stripped grep over `rtl/*.sv|*.vh`, then
read each site in context. `blt_tri.sv` is excluded — `files.qip:15` states it is
the sim-only golden and it is not in the file list.

**Unknown:** no `.fit.rpt` / `.map.rpt` exists in the tree, so every DSP-block
count below is *inferred* from Cyclone V variable-precision modes (one 27×27, or
two 18×19, or three 9×9 per block), not read from a fit report. Confirm with
`grep -A20 'DSP' output_files/Maldita.fit.rpt` after the next build.

---

## 1. `blitter_top.sv:1797-1802` — 12 per-pixel 48×24 multipliers (largest DSP consumer)

```systemverilog
pp_u_lo <= $unsigned(wu_q) * recip_q[23:0];  pp_u_hi <= $unsigned(wu_q) * recip_q[47:24];
... (×6 attributes)
```

**Observed.** `recip_q` is loaded from `ts_area_recip` and is **constant for the
whole triangle** (`blitter_top.sv:1699`). `wu_q` is sampled at dispatch from `Wu`,
which the span walk maintains by *pure forward differencing* — never by a
multiply:

- `step_right` (`:1147`): `Wu <= Wu + ts_dWudx`
- `step_left`  (`:1159`): `Wu <= Wu - ts_dWudx`
- `step_row`   (`:1189`): `row_Wu <= row_Wu + ts_dWudy; Wu <= row_Wu + ts_dWudy`
- init (`:1601`): `Wu <= ts_Wu_0; row_Wu <= ts_Wu_0`

**Inferred.** Because the walk is already a DDA and `recip` is a per-triangle
constant, the product distributes exactly:

```
Wu * recip = Wu_0*recip + (steps_x)*(dWudx*recip) + (steps_y)*(dWudy*recip)
```

So the multiply can be hoisted **out of the per-pixel path entirely** by running
the DDA in product space:

| | today | product-space DDA |
|---|---|---|
| per pixel | 12 × 48×24 mult (~24 DSP blocks) + 6 recombine adds | 6 × 96-bit add/sub |
| per triangle | — | 18 × 48×48 (6 attrs × {W_0, dWdx, dWdy}), sequenced on one multiplier |
| A-pipeline depth | stages 1+2 exist | both stages disappear (−2 cycles latency) |
| registers | `W*`/`row_W*` (12×48) + `pp_*` (12×~72) + `mul_*` (6×96) | `MU*`/`row_MU*` (12×96) |

This is **bit-exact by construction** — integer multiplication distributes over
the integer adds, and the only rounding (`(mul_u + (1<<39)) >>> 40`) happens after
accumulation, unchanged.

**Risk (the real one):** the walk's carry chain doubles from 48 to 96 bits at a
10.158 ns period. Increments are wide in the worst case (`recip` reaches 2^40 for
an area-1 sliver, so `dWudx*recip` reaches ~2^54) — you cannot truncate the low
40 bits, their carry propagates. Mitigation: split each accumulator into
`lo[39:0]` / `hi[55:0]` with the lo-carry registered and applied to hi one cycle
later; the consumer is 3 stages downstream, so the skew is absorbable. Budget
this as the main implementation cost.

**Payoff:** ~24 DSP blocks and ~800 flops freed, two pipeline stages removed, and
the historic `mul_v[40] -> tri_p0_addr` worst-path family deleted rather than
pipelined around. **No throughput change** — the pipeline is already 1 px/cycle.

---

## 2. `blt_tri_setup.sv:269-300, 570-597` — 48-cycle serial reciprocal (only wall-clock item)

```systemverilog
localparam integer DIVW = 48, UNROLL = 1;   // ITERS = 48
```

**Observed.** `area_recip = round(2^40 / area)` via restoring division, one
quotient bit per clock, 48 cycles. `valid` asserts on divider-done — the header
comment already names it "the long pole". A prior UNROLL=4 build missed setup by
~15.3 ns, which is why it is at 1.

**Inferred cost.** 48 cycles @ 98.4375 MHz = 487.6 ns/triangle. At the measured
228 tri/frame that is **10,944 cycles = 0.111 ms/frame**, ~0.7 % of a 16.2 ms
fabric frame.

**This is the one place a DSP genuinely beats the fabric logic.** A
normalize + M10K seed-ROM + one Newton–Raphson step (two 27×27 DSP multiplies)
converges in ~4-6 cycles instead of 48:

1. `clz(area)` → normalize mantissa to `[0.5, 1)`
2. 256-entry M10K ROM → 9-bit seed `y0 ≈ 1/m`
3. one NR step `y1 = y0*(2 - m*y0)` → ~18 good bits; a second → ~36
4. **exactness fix-up:** compute `q*area` (one 48×48) and correct `q` by ±1 so
   the result is bit-identical to the restoring quotient. Without step 4 this
   breaks the refmodel gate.

**Saving: ~0.10 ms/frame** for ~4 DSP blocks + 1 M10K. Worth doing only if you
are still short of the 16.6882 ms scanout period; the cheaper alternative is
§2b.

**§2b (do this first — no arithmetic change).** `blt_tri_setup` refuses a new
triangle until the whole pipeline *and* divider are idle. Double-buffering the
setup outputs so triangle N+1's setup overlaps triangle N's walk removes the
same 0.111 ms with no DSP, no ROM, and no bit-exactness argument to defend.

---

## 3. `blitter_top.sv:2090-2092` and `comp_mixer.sv:136-141` — 6 multipliers where 3 suffice

Both sites compute the same const-alpha lerp:

```systemverilog
b2_r <= b1_tsr*b1_ea + b1_dr*b1_na;          // na == 255 - ea
stB_tr <= stA_sr*stA_alpha + stA_dr*(255 - stA_alpha);
```

**Exact algebraic identity:**

```
src*a + dst*(255-a)  ==  dst*255 + (src-dst)*a  ==  (dst<<8) - dst + (src-dst)*a
```

Halves the multiplier count per stage (6 → 3), at the price of making the
multiply signed 7×8 instead of unsigned 6×8. Same result range, same downstream
`red255`. Applies identically to both files; `comp_mixer`'s `ARITH_MUL` arm is
unaffected.

**Payoff:** small — these are 6×8 products that likely land in LUTs or 9×9 DSP
modes either way. Take it as a combinational-depth reduction on the B_WR2 /
stage-B path, not as an area play.

---

## 4. `blt_blend.sv:47` — real `/255` divider in dead code

```systemverilog
ea = ({8'd0,ca} * {8'd0,g_alpha}) / 16'd255;
```

**Observed.** This is a genuine 16-bit divider by a constant. `blt_blend.sv` is
listed in `files.qip:17`, but grep across `rtl/`, `sys/`, `Maldita.sv` finds **no
instantiation** — the only consumer is `sim/tb_tri_mixer_equiv.sv`.
`blitter_top.sv:988-994` states the blend was inlined and pipelined and that
`blt_blend.sv` is "kept UNCHANGED".

**Inferred.** Quartus strips the unelaborated module, so there is no area or
timing cost today. The hazard is divergence: the shipping copy at
`blitter_top.sv:2077` uses `((x<<8)+x+257)>>16` and the "golden" copy still uses a
divider, so the equivalence testbench is no longer checking the shipped form.

**Action:** either drop `blt_blend.sv` from `files.qip` (keep it as a sim-only
file like `blt_tri.sv`) or port the same identity into it. Do not leave a
compiled file whose arithmetic contradicts the shipped path.

---

## 5. Checked and clear — no action

| Site | Expression | Verdict |
|---|---|---|
| `blitter_top.sv:1855` | `ax3_py*FB_STRIDE_QW16` | const 72 = 64+8 → Quartus emits shift-add, no DSP |
| `comp_pipeline.sv:882,957,982` | `cur_dst_y * FB_STRIDE_QW16` | same const 72, 3 sites |
| `openbor_video_reader.sv:929,1007` | `* LINE_STRIDE` | `LINE_STRIDE = FB_STRIDE_QW = 72`, const |
| `blitter_top.sv:1368,1376` | `cmd_idx*4` | power of two → wiring |
| `blitter_top.sv:1529,1531` | `tri_idx*16'd6` | const 6 = 4+2 → shift-add |
| `blt_tri_setup.sv:444-446` | `64'sd16 * (…)` | power of two → `<<< 4`, free |
| `blitter_top.sv:1868` | `itv_q * stride` | genuine 16×16, registered, 1 DSP — correct as-is |
| `comp_pipeline.sv:795-796` | stride mult split on byte halves | already hand-pipelined into two 17×8; per-span not per-pixel |
| `blitter_top.sv:1031` `modch` | `ch*mod` then shift-add reduce | 6×8; the `/255` was already eliminated and proved over all 16384 pairs |
| `gm_audio.sv:206-207` | `d_l * phase` | 17×17 signed @24.576 MHz, ~40 ns budget — 1 DSP, fine |
| `gm_audio.sv:114,118` | `INC_NOM`, `OUT_DIV` | elaboration-time `localparam`, no hardware |
| `cos.sv` | — | pure 256-entry LUT with quadrant fold, no arithmetic |
| all `red255/red31/red63` | `(m+(m>>k))>>k` | already divide-free everywhere |
| all `%` hits | — | `$display` format specifiers and comments only |

**Minor:** `blt_tri_setup.sv:476-478` uses six 19×19 signed products
(`dbx0*dcy0` …). 19 bits overflows the 18×19 DSP mode by one bit, forcing a
27×27 block each (~6 blocks). If the operands can be shown to fit 18 bits the
pairs share blocks (~3). Per-triangle only; check the fit report before spending
effort on this.

## Inferred DSP budget

~45 of 112 blocks on the 5CSEBA6, ~24 of them in §1 alone. **DSPs are not the
constrained resource** — ALMs and timing are (38 % ALM after the `tq_data` M10K
fix). So the framing for §1 is "delete multipliers to buy timing slack", not
"move work onto DSPs".

## Recommended order

1. **§2b** — overlap setup with the previous triangle's walk. ~0.10 ms/frame, no
   arithmetic change, no bit-exactness argument.
2. **§4** — remove `blt_blend.sv` from `files.qip` or port the divide-free form.
   5 minutes, removes a live divergence between golden and shipped.
3. **§3** — the lerp identity in both blend stages. Small, exact, low risk.
4. **§1** — product-space DDA. The big one, but it is a timing/area play, not a
   frame-time play. Only worth the split-accumulator work if you need the slack.
5. **§2** — DSP reciprocal. Only if §2b is somehow not viable; it needs the ±1
   fix-up to stay bit-exact.
