# DSP time-multiplex of triangle setup + walk address-gen pipeline split

Date: 2026-07-15
Status: approved, implementing inline
Scope: `fpga/rtl/blt_tri_setup.sv`, `fpga/rtl/blitter_top.sv`

## Problem

`maldita.castilla-mister` RBF misses setup timing. Failing CI run
(commit `2e65918`, self-hosted Windows Quartus 17.0.2):

- **DSP: 105 / 112 blocks.**
- **Worst-case setup slack: −5.576 ns** on the main fabric clock (`gpll`,
  ~98 MHz / 10.158 ns period), TNS −7924 (many failing paths).
- Reported worst path: **`blitter|mul_v[40]` → `blitter|tri_p0_addr[26]`**,
  arrival 23.292 ns vs required 17.716 ns.

### Root cause (two linked facts)

1. **DSP hog = `blt_tri_setup.sv` Stage-3** (the `e2` block). It issues
   **54 multiplies in one cycle** — `6 attrs × 3 verts × 3 lanes`
   (`p0`/`pdx`/`pdy`) — for a computation that runs **once per triangle
   (~10/frame)**. Post-narrowing that is still ~54 of the 105 used DSPs.
2. **Measured worst path is the per-pixel walk**, `S_TRI_MUL`
   (`blitter_top.sv`): the 96-bit `W*area_recip` product (`mul_v`) is
   rounded (`>>>40`), clamped to the texel range, then fed through the
   `itv*c_src_stride` texel-address multiply **and** the address add — all
   combinationally in one cycle.

The two are linked: with DSPs exhausted, the fitter spills walk multiplies
(`itv*stride`) into **LUT soft-multipliers**, which is why that cycle blew to
23 ns. **Freeing DSPs is what lets that multiply become a hard DSP.**

## Design

### Part 1 — Time-multiplex Stage-3 (DSP-reuse core)

Replace the 54-wide parallel multiply (`e2`/`e3` blocks) with a **sequential
multiply-accumulate (MAC) engine**:

- **3 multipliers** — the `nw` / `dwdx` / `dwdy` lanes. All three share the
  same per-step attribute operand `A[a][k]`, so one step = 3 products.
- Iterate the **18 `(attr a, vert k)` pairs** over 18 steps
  (`a = idx/3`, `k = idx%3`).
- **Mult and accumulate live in separate pipeline cycles** (registered product
  → add), so no multiply→add chain is created (the same discipline that closed
  the earlier setup paths).
- Per attribute, accumulate `k = 0,1,2` in order into `W{attr}`,
  `dW{attr}dx`, `dW{attr}dy`; latch to the module outputs when `k == 2`.
- Engine is **kicked at the same point Stage-3 was** and runs **concurrently
  with the existing 48-cycle reciprocal divider**. It finishes in ~20 cycles
  (< 48), so **setup latency is unchanged** — the divider stays the long pole.
- `valid` gating: non-degenerate still rises on divider-done; the MAC completes
  earlier, so its outputs are stable by then. Degenerate path (no divider) must
  now assert `valid` when the MAC drains rather than when the old S4 landed.

**Operand widths unchanged** from today's narrowing (`nw`→27b, `dwdx/dwdy`→24b,
`A`→18b). Accumulation is the **same three integer terms in the same order** →
**bit-identical** output. `tb_tri_setup` must pass unchanged.

**Expected DSP delta:** Stage-3 54 → 3 (≈ **−50 blocks**), 105 → ~55.

### Part 2 — Split `S_TRI_MUL` into two cycles

Even with a hard DSP, the `round → clamp → itv*stride → address-add` chain in
one cycle is long. Split it, mirroring the existing `S_TRI_PIX`/`S_TRI_MUL`
rationale:

- **`S_TRI_MUL`**: compute `rnd_*`, `itu`, `itv` (round + nearest-texel clamp),
  register `itu_q`/`itv_q` and the colour bytes. No address multiply here.
- **New `S_TRI_ADDR`**: `texbyte = c_src_off + itv_q*stride + (itu_q<<<1)`;
  drive `tri_p0_addr` / `tri_p0_rd` / lane / dst qword. Then `S_TRI_GOTTEX`.

Cost: one extra cycle per covered pixel — negligible vs. the SDRAM texel-read
latency the walk already waits on.

## Verification

1. `tb_tri_setup` — Stage-3 bit-exactness (± 1 LSB envelope). MUST stay PASS.
2. `tb_blitter_trilist_pipe` / `_calpha` / `_key` / `_add` / `_quad` — walk
   correctness across blend modes. MUST stay PASS.
3. Full `run_sims.sh` gating suite green.
4. RBF rebuild: DSP count drops to ~55; the `mul_v → tri_p0_addr` path clears
   the fabric-clock period (target positive setup slack on `gpll`).

## Non-goals

- Per-pixel walk `mul_u..mul_a` (96-bit) width reduction — kept parallel for
  fill-rate; revisit only if timing still misses.
- Blend-stage multiplies — small, not on the critical path.
