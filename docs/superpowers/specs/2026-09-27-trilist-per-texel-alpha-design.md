# TRILIST per-texel alpha (PALPHA) — design note

Date: 2026-09-27. Status: **draft, step 1 (wire format + staged-texel storage)**.
Applies to both fabric cores (Maldita, Cursed Castilla EX); RTL lands in Maldita's
`fpga/rtl/` first and is cherry-picked to Cursed (logic-identical once Maldita #56
is ported).

## 1. Problem

The TRILIST path has no per-texel alpha. Host staging (`mf_texel565`) folds every
texel to RGB565 and cuts alpha at 128 into the colorkey sentinel `0xF81F`. A TRILIST
header carries one blend mode, so a draw is either:

- `COLORKEY` — hard 1-bit cutout, no fade; or
- `CONST_ALPHA` — fade by the interpolated vertex alpha, **no cutout** (the sentinel
  is written as visible magenta).

Observed consequences:

| symptom | game | source |
|---|---|---|
| small text reduced to stroke cores; 40–50% of a glyph's visible texels are AA edge | EX | e3f85fe TEXALPHA histogram |
| magenta band while the title logo's vertex alpha pulses | EX | 67f1d20 (worked around for COPY only) |
| faded keyed sprites (RB_ALPHA, vtx a < 1) paint the sentinel | both, documented hole | `raster_backend_mfgpu.cpp:45-64` |

Goal: a TRILIST draw blends each texel at `texel_alpha × vertex_alpha × header alpha`,
so cutout and fade compose and AA edges survive.

## 1a. G0 results (2026-09-27, device `.62`, Cursed engine 695ef9b + diag ed4365b)

**G0a — EX blends exactly like Maldita; "EX uses ONE/ZERO" was a tracking bug.**
- Program 6 (every EX draw) = shaders 4 + 5, GameMaker's built-in default shader.
  The fragment shader is compiled **without** `USE_ALPHATEST`, so `DoAlphaTest` is
  empty: no discard. Output = `v_vColour * texel`.
- `BLENDCALL` log: the game calls `glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)`
  during init, **while `g_enabled=0`**, then only toggles `glEnable/glDisable(GL_BLEND)`
  per frame. `Blitter_OnBlendState` starts with `if (!g_enabled) return;`, so the
  factors are never recorded and stay at the defaults `GL_ONE/GL_ZERO`. Every
  `BLENDSTAT` line (f=600..1800) reads `blend=1 src=0x0001 dst=0x0000`.
- Second defect in the same hook: `if (dst) g_blendDst = dst;` cannot record
  `GL_ZERO` (== 0).
- Consequences: 3976a1c ("enabled ONE/ZERO is a replace") and 67f1d20 (COPY +
  key → COLORKEY at any alpha) were built on the misread state. With tracking
  fixed, EX draws become `RB_ALPHA`, and the pulsing title logo lands in the
  COLORKEY/CONST_ALPHA hole (magenta) again until PALPHA exists. The
  `PALPHA_REPLACE` knob below is no longer needed.

**G0b — straight alpha, not premultiplied.** Offline census of every TPAG region
in both `game.droid` files (md5s match `.62`). Of partial-alpha texels, 44% (EX)
and 19% (Maldita) have `max(r,g,b) > a + 8`, which premultiplied storage cannot
produce. Straight PALPHA is correct; no premultiplied variant is needed.

**G0c — ARGB4444 is lossless where it matters, lossy on EX's painted art.**

| region class (examples) | partial texels | colour under 4444 |
|---|---|---|
| alpha masks, one colour: EX `system_font`, `spr_login_subtitle`, `spr_torch_darkness`; Maldita `spr_current_weapon`, `spr_torch_darkness`, `spr_old_tv_small` | most of the partial-alpha texels in both games | exact (1 colour) |
| EX painted backgrounds with soft edges: `bck_check`, `bck_aqueduct`, `bck_well`, controller art, bezel | 4–293k per region | 1100–2500 colours → 140–310; mean error 3.7/255, max 9 |

EX gameplay sprites have essentially no partial alpha. Maldita has three regions
with partial alpha in total, all single-colour masks.

Script: `scratchpad g0/texalpha.py`, `regions.py` (to be moved into
`tools/` when this lands).

## 2. What already exists

- Protocol: `BLT_BLEND_PALPHA = 3` and `BLT_FMT_ARGB4444 = 1` (`blitter_ref.h`),
  defined for `BLT_OP_BLIT` only. Refmodel `blit_one()` implements it:
  `argb4444_expand` (A4→A8 by nibble replicate, R4/B4→5b, G4→6b by bit replicate),
  `A8 == 0` skip, `div255_round` straight-alpha blend.
- RTL: `comp_pipeline.sv` (BLIT path) decodes ARGB4444 and runs PALPHA through
  `comp_mixer`. The TRILIST datapath in `blitter_top.sv` (`B_WR`/`B_WR2`/`B_WR3`,
  ~l.2340-2420) has neither.
- The TRILIST texel fetch is 16 bpp (P_SRC SDRAM + 2 KB texel cache); ARGB4444 is
  also 16 bpp, so **fetch, cache, heap layout and staging bandwidth are unchanged**.

## 3. Proposal

### 3.1 Wire format — no new fields

TRILIST accepts `blend_mode = BLT_BLEND_PALPHA` and `format = BLT_FMT_ARGB4444`.
No header, vertex or flag bits change. Both values already fit the existing
`u32[0]` byte fields.

### 3.2 Reference semantics (`blt_tri.c`, the golden)

Per covered pixel, after the existing interpolation (`u,v,cr,cg,cb,ca` unchanged):

```
raw   = tex_nearest(...)                        // 16-bit, unchanged fetch
if (h->format == BLT_FMT_ARGB4444)
    argb4444_expand(raw, &a8, &r5, &g6, &b5)    // shared helper from blitter_ref.c
    rgb = r5<<11 | g6<<5 | b5
else
    a8 = 255; rgb = raw
src = blt_tint565(rgb, cr, cg, cb)              // unchanged
ea  = (ca * h->alpha) / 255                     // unchanged truncation
case PALPHA:
    if (a8 == 0) skip                           // transparent texel: no write
    pa = div255_round(a8 * ea)                  // new: one 8x8 multiply + round
    *dp = blt_blend565(src, *dp, pa)
case COLORKEY:  if (raw != h->colorkey) *dp = src   // compare RAW, as today
other modes:    unchanged, on the decoded rgb
```

Decisions:
- ARGB4444 decode applies to **every** TRILIST blend mode (matches BLIT after RTL
  #100), so one staged page can serve any blend.
- `a8 == 0` skips before the multiply, so a page staged ARGB4444 needs no colorkey
  sentinel.
- `pa == 0` with `a8 > 0` still goes through `blt_blend565` (writes `dst`
  unchanged, bit-exact to a skip). No special case.
- Straight alpha only. `RB_PREMULT` (`GL_ONE, GL_ONE_MINUS_SRC_ALPHA`) keeps the
  current path; a premultiplied variant is a follow-up if gate G0b says it is needed.

### 3.3 Staged-texel storage — ARGB4444, chosen per staged region

The host picks the format **per staged sub-region** (the per-sprite-quad staging
that already exists), not per texture page:

- Region contains a texel with alpha that ARGB4444 quantizes strictly between 0
  and 15 (`A4 ∈ 1..14`), the draw's blend asks for alpha (see 3.4), **and** the
  region's opaque colours survive 4444 unchanged (G0c: true for every
  single-colour mask, false for EX's painted backgrounds) → stage ARGB4444.
- Partial alpha but lossy under 4444 → RGB565 with the 128 cut, as today. That
  keeps EX's painted menu art at full colour with hard edges; the 1-bit-escape
  format in the table below is the follow-up if those edges matter.
- Otherwise → stage RGB565 exactly as today (colorkey sentinel, sparse maps,
  occluder texel test all unchanged).

`MfTexEntry` and the texture-cache key gain the staged format, so the same region
staged both ways gets two cache entries rather than aliasing.

Cost: ARGB4444 quantizes colour to 4 bits per channel on those regions only.
Opaque backgrounds and tiles stay RGB565.

Alternatives considered:

| option | colour | alpha | heap / fetch | RTL | verdict |
|---|---|---|---|---|---|
| **ARGB4444 per region** | 444 on AA regions | 16 levels | unchanged | decode + 1 multiply | **proposed** |
| RGB565 + separate A4/A8 plane | 565 | 16/256 levels | +25–50% heap, second fetch per texel, second cache | large | rejected unless G0c fails badly |
| ARGB8888 | 888→565 | 256 levels | 2× heap and fetch | fetch path widens | rejected (EX already 71 MB vs 14.75 MB heap) |
| 1-bit escape `{0,RGB555}` / `{1,A3,R4,G4,B4}` | 555 opaque, 444 edges | 8 levels | unchanged | new decoder | fallback if G0c shows 444 is visible on mixed regions |

### 3.4 Host policy (gmloader-next `raster_backend_mfgpu.cpp`)

Behind `GMLOADER_MFGPU_PALPHA` (default 0 until G5 passes):

| GL blend (`RBlend`) | region has partial alpha | emitted |
|---|---|---|
| `RB_ALPHA` | yes | `PALPHA` + ARGB4444 (replaces the COLORKEY / CONST_ALPHA choice) |
| `RB_ALPHA` | no | unchanged (COPY / COLORKEY / CONST_ALPHA) |
| `RB_NONE` | any | unchanged |
| `RB_PREMULT`, ADD, MULTIPLY | any | unchanged |

**Prerequisite (G0a):** `Blitter_OnBlendState` must record state while
`!g_enabled` and must accept `GL_ZERO`. Without that, EX's draws never reach the
`RB_ALPHA` row. Landing that fix before PALPHA brings EX's magenta band back
(its logo becomes a faded keyed `RB_ALPHA` draw), so the two land together, or
the tracking fix ships with 67f1d20's any-alpha COLORKEY rule extended to
`RB_ALPHA` as an interim.

Other host users of blend mode that must treat PALPHA as non-idempotent,
non-occluding (same as CONST_ALPHA):
- duplicate-draw elision (`mf_*` "idempotent blend" check, ~l.237);
- occlusion cull (`mf_occ_record`: only COPY/COLORKEY become occluders — already
  correct by construction, add a test);
- sparse keyed quads (`mf_sp_try`: COLORKEY only — PALPHA not split in v1);
- present-from-surface identity test (`RB_NONE`/`RB_ALPHA` only; the composite
  samples the surface, never an ARGB4444 page — unaffected).

### 3.5 RTL (`blitter_top.sv` TRILIST blend pipeline)

- `B_WR` (stage A): if `c_format == FMT_ARGB4444`, expand `texel_q` to 565 before
  `modch`, and derive `a8`. `b1_we` also clears on `PALPHA && a4 == 0`.
- New state `B_WR0P` between `B_WR` and `B_WR2`, **entered only when
  `c_blend == BLEND_PALPHA`**: `pa = red255(a8 * b1_ea)`, `b1_ea <= pa`,
  `b1_na <= 255 - pa`. A separate state keeps the added 8×8 multiply off stage A,
  which already holds the `ca*g_alpha` multiply on the fabric's critical path.
  Cost: +1 cycle per pixel on PALPHA draws only (~8 → ~9 cyc/px); other modes
  unchanged.
- `B_WR2`/`B_WR3`: PALPHA takes the existing `BLEND_ALPHA` MAC and reduce.
- `tri_need_dst` (l.992) adds `BLEND_PALPHA`.
- Capability: `C_STATUS` low word **bit3 = 1** ("TRILIST PALPHA supported"). The host
  never emits PALPHA against an RBF reporting 0. (bit2 is present-from-surface,
  Maldita #56; Cursed must take #56 first or reserve bit2 so both cores share the
  layout.)
- `blt_blend.sv` / sim-only `blt_tri.sv`: update to the same semantics so the
  `tb_tri_mixer_equiv` spike stays meaningful, or retire them explicitly.

## 4. Gates

**G0 — measure before code (no fabric change):**
- **G0a** EX fragment shader for `prog=6`: dump it (`glShaderSource_dump`) and read how
  it produces transparency. e3f85fe showed prog 6 never queries `gm_AlphaRefValue`
  or `gm_AlphaTestEnabled`, so whether EX discards (and at what threshold) is
  **unknown**. This sets what "authentic" looks like before we choose PALPHA_REPLACE.
- **G0b** Premultiplied? For each partial-alpha texel in both games' pages, test
  `max(r,g,b) ≤ a`. e3f85fe notes EX edge texels carry near-black RGB, which is also
  what premultiplied storage looks like. If most of EX's partial texels are
  premultiplied, straight PALPHA will darken edges and §3.2 needs a premult variant.
- **G0c** ARGB4444 fidelity: over regions that would be staged ARGB4444, measure the
  RGB565→444 error on opaque texels (max and mean per channel, and the count of
  distinct palette colours that merge). An offline tool over the `game.droid`
  texture pages is enough.

**G1 — reference model:** `blt_tri.c` PALPHA + ARGB4444 decode; `test_blt_tri`
cases: A4 = 0/1/8/15, vtx alpha 0/1/128/255, header alpha, tint composition,
COLORKEY on an ARGB4444 page compares raw. `make test` in `refmodel` and `host`.

**G2 — host:** format-per-region staging (scalar and NEON paths agree — extend
`mf_stage_texels_test`'s differential sweep), cache key, policy table in 3.4, and
capability gating. `raster-backend-test`: PALPHA emitted only with capability bit
set; sw rasterizer vs refmodel identical on PALPHA scenes.

**G3 — RTL sim:** new `tb_blitter_trilist_palpha` against the regenerated golden
(`gen_tri_golden.mk`), **exact match** (a ±1 LSB gate passes a wrong 4→5/6-bit
expansion and a truncating `pa`; measured). Note `fpga/sim/blt_tri.c` is a hand-kept
copy of the refmodel file the golden compiles; refmodel changes must be copied into it.
The `A4 == 0` skip is invisible in the framebuffer (pa = 0 writes dst back), so the
bench asserts it on coverage, not pixels. The existing `tb_blitter_trilist_*` benches must still
pass unchanged (the new state is not entered for them). Include a dst-miss case —
blitter_top's own note says no bench exercises miss + `tri_need_dst`, and PALPHA
makes that path hot.

**G4 — STA:** `emu|pll` no worse than the current accepted baseline (−0.159 ns on
Windows fits).

**G5 — device, both games, knob off vs on:**
- EX: small-text screenshots; title logo pulse shows no magenta in any frame.
- Maldita: faded keyed sprites no longer write magenta; no visual change elsewhere.
- Perf: Maldita level_1_4 and level_2_3 fabric frame time (`MFSUBMIT`) within
  noise; PALPHA pixel count per frame (`MFPALPHA` counter, new) recorded.

## 5. Order of work and repos

1. G0a–c (measurement; gmloader-next diag + offline script).
2. `mister-fpga-blitter`: refmodel + tests (G1) → bump the gmloader-next submodule →
   sync the sibling checkout (golden coupling, see CLAUDE.md).
3. gmloader-next: host staging + policy behind `GMLOADER_MFGPU_PALPHA=0` (G2).
4. `maldita.castilla-mister/fpga/rtl`: TRILIST PALPHA (G3, G4); cherry-pick to
   Cursed after #56.
5. Device A/B (G5); then default `GMLOADER_MFGPU_PALPHA=1`.

G0 is done (§1a). Step 1 of the host work is now the blend-tracking fix.

## 6. Open questions

- Maldita's blend tracking works today, presumably because its runner re-issues
  `glBlendFunc` after `Blitter_Init`. Not verified; the tracking fix must be
  regression-checked on Maldita (`BLENDSTAT` before/after).
- Sparse-quad splitting of PALPHA draws (skip `A4 == 0` spans) is a likely perf
  follow-up for large faded overlays (Maldita's `spr_torch_darkness` is 1000×540);
  out of scope for v1.
- EX's painted menu art keeps hard edges under v1 (G0c). Revisit with the
  1-bit-escape format only if that is visible.
