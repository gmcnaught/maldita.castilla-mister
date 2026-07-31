# Architecture Documentation (C4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `docs/architecture/` in mister-gmloader: C4 diagrams (Context, Container, Component ×3, Code ×2) plus a data-flows doc, derived from source at the current pins.

**Architecture:** Nine Markdown files with Mermaid flowchart diagrams, one file per C4 level/target, plus an index. A checker script validates every Mermaid fence parses and every referenced source path exists. Each doc ends with a Sources section naming repo+commit+paths it was derived from.

**Tech Stack:** Markdown, Mermaid (`flowchart`/`graph` and `sequenceDiagram` only — NOT Mermaid C4 syntax), `@mermaid-js/mermaid-cli` via npx for validation, bash checker script.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-30-architecture-docs-design.md`. Read it before starting any task.
- Scope is runtime data flows ONLY. Build/deploy, device process model, bench harness get one-line pointers in the index and nothing else.
- Diagrams derive from source at these pins — record the actual hashes at write time with the commands in Task 1, do not trust this plan's snapshot: `external/gmloader-next` (d585b38), `external/mister-fpga-blitter` (9ccd57a), `../maldita.castilla-mister` (milestone-a, 4ef1353).
- Fabric truth is the VENDORED RTL `maldita.castilla-mister/fpga/rtl/` — never diagram `mister-fpga-blitter/rtl/` (non-shipping v1 spike).
- Component/node names in diagrams must match real module/function/file names in source. If you did not open the file, mark the claim **unverified** in the doc rather than asserting it.
- Every doc: opens with a one-line "What this answers:" statement; ends with a `## Sources` section listing repo, commit, and file paths used.
- Cross-repo paths written explicitly from the MisterFPGA-Projects root, e.g. `maldita.castilla-mister/fpga/rtl/blitter_top.sv`.
- Known facts from project memory you may use as leads but MUST re-verify in source before asserting: control block at byte 0x3BF40000 (FB_QW_BASE), reader is poll-before-issue, JOY writeback anchored at ST_POLL_CTRL, stale-frame watchdog blanks VGA ~0.5 s after VCTRL stops, texels come from SDRAM atlas (`src_in_sdram=1'b1`), scanout counters at 0x3BFB0018/1C.
- Commit after every task, message prefix `docs(arch):`.

---

### Task 1: Checker script + directory scaffold + index skeleton

**Files:**
- Create: `scripts/check_arch_docs.sh`
- Create: `docs/architecture/README.md`

**Interfaces:**
- Produces: `scripts/check_arch_docs.sh [file...]` — validates given Markdown files (default: all of `docs/architecture/*.md`). Exit 0 = every Mermaid fence parses via mmdc AND every backtick-quoted cross-repo source path exists on disk. All later tasks run this as their test.

- [ ] **Step 1: Write the checker script**

```bash
#!/usr/bin/env bash
# check_arch_docs.sh — validate docs/architecture Markdown files.
# 1) Every ```mermaid fence must parse (rendered via mmdc).
# 2) Every `backtick` path starting with a known repo prefix must exist
#    relative to the MisterFPGA-Projects root.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # mister-gmloader
PROJ="$(cd "$ROOT/.." && pwd)"                     # MisterFPGA-Projects
TMP="${TMPDIR:-/tmp}/arch-docs-check.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
FILES=("$@")
[ ${#FILES[@]} -eq 0 ] && FILES=("$ROOT"/docs/architecture/*.md)
fail=0
for f in "${FILES[@]}"; do
  # --- mermaid fences ---
  awk '/^```mermaid/{n++; out=sprintf("'"$TMP"'/%s-%d.mmd", FILENAME_SAFE, n); inblk=1; next}
       /^```/{inblk=0; next}
       inblk{print > out}' FILENAME_SAFE="$(basename "$f" .md)" "$f"
  for m in "$TMP"/$(basename "$f" .md)-*.mmd; do
    [ -e "$m" ] || continue
    if ! npx -y @mermaid-js/mermaid-cli -i "$m" -o "$m.svg" >/dev/null 2>&1; then
      echo "FAIL mermaid: $f ($(basename "$m"))"; fail=1
    fi
  done
  # --- cross-repo paths ---
  grep -o '`[^`]*`' "$f" | tr -d '`' | \
    grep -E '^(maldita\.castilla-mister|mister-gmloader|external/)' | sort -u | \
  while read -r p; do
    case "$p" in external/*) base="$ROOT";; *) base="$PROJ";; esac
    # strip trailing :line refs
    p2="${p%%:*}"
    if [ ! -e "$base/$p2" ]; then echo "FAIL path: $f -> $p"; fail=1; fi
  done
done
exit $fail
```

Note the subshell pitfall: `while` after a pipe runs in a subshell, so `fail=1` inside it is lost. Fix it in implementation by collecting failures into a temp file and testing `-s` at the end — the version you commit must fail (nonzero exit) on a bad path. Verify with Step 3.

- [ ] **Step 2: Record the pins (used in every Sources section)**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git submodule status
git -C ../maldita.castilla-mister log -1 --format='%h %d'
```

Save the three hashes; every doc's Sources section cites them.

- [ ] **Step 3: Test the checker (must fail on bad input, pass on good)**

```bash
mkdir -p docs/architecture
printf '# t\n```mermaid\ngraph TD\n  A-->B\n```\n`maldita.castilla-mister/fpga/rtl/blitter_top.sv`\n' > docs/architecture/README.md
bash scripts/check_arch_docs.sh docs/architecture/README.md && echo GOODPASS
printf '```mermaid\ngraph TD\n  A--\n```\n`maldita.castilla-mister/no/such/file.sv`\n' > /tmp/bad.md 2>/dev/null || true
printf '# bad\n```mermaid\ngraph TD\n  A--\n```\n`maldita.castilla-mister/no/such/file.sv`\n' > docs/architecture/_bad_test.md
bash scripts/check_arch_docs.sh docs/architecture/_bad_test.md; echo "exit=$?"
rm docs/architecture/_bad_test.md
```

Expected: `GOODPASS` for the first; `FAIL mermaid` + `FAIL path` lines and `exit=1` for the second. If mmdc needs a puppeteer download on first run, let it complete once; subsequent runs are fast.

- [ ] **Step 4: Write the index skeleton**

Replace `docs/architecture/README.md` with the real index. Required content (complete the question→file table in Task 9 once all files exist):

```markdown
# Architecture — maldita castilla on MiSTer

**What this answers:** where every part of the runtime system lives across
the four repos, and which doc to open for a given question.

## The four repos
| Repo | Role | Ground truth for |
|---|---|---|
| `mister-gmloader` | umbrella; pins the engine + blitter submodules, owns deploy/bench | integration, this doc set |
| `external/gmloader-next` (submodule) | the engine: GM runner loading, GLES dispatch, MiSTer backends | host-side runtime code |
| `external/mister-fpga-blitter` (submodule) | contract + sim home for the raster core | protocol spec, refmodel, sim harness |
| `maldita.castilla-mister` (sibling repo) | shipping core; **vendored** RTL + Quartus project | everything that runs on the FPGA |

## Traps
1. Production RTL is the vendored copy in `maldita.castilla-mister/fpga/rtl/`.
   `mister-fpga-blitter` RTL is a non-shipping v1 spike — never edit or cite it
   as the shipping implementation.
2. Sibling checkouts (notably `../gmloader-next`) can be stale relative to the
   submodule pins in this repo. Ground truth for the integration is the pin.

## Doc map
(question → file table; filled in as docs land)

## Out of scope here
- Build & deploy: `Makefile`, `maldita.castilla-mister/deploy.py` (tree-hash-gated RBF fetch).
- Device process model: Master_Daemon/handler exec chain, single-engine invariant.
- Bench harness: `mister-gmloader/scripts/mister_run.sh`, wedge gates, sim lockstep.
```

- [ ] **Step 5: Run checker, commit**

```bash
bash scripts/check_arch_docs.sh
git add scripts/check_arch_docs.sh docs/architecture/README.md
git commit -m "docs(arch): checker script + architecture index skeleton"
```

---

### Task 2: `01-context.md` (C1)

**Files:**
- Create: `docs/architecture/01-context.md`
- Read first: `README.md` (repo root), `external/gmloader-next/gmloader/main.cpp` (entry/asset loading), `maldita.castilla-mister/Maldita.sv` (top-level: what the core exposes to MiSTer framework)

**Interfaces:**
- Produces: canonical names used by all later docs — **Player**, **Developer**, **Game assets** (`game.droid` + armhf YoYo runner `.so`), **gmloader+fabric stack** (the system), **MiSTer Main/menu**, **Display**, **Gamepad**.

- [ ] **Step 1: Read the three listed sources** — enough to confirm: how assets are named/loaded, what external actors touch the system at runtime.

- [ ] **Step 2: Write the doc.** One Mermaid `flowchart` with the system as a single node inside a DE10-Nano boundary subgraph; actors: Player (gamepad in, display out), Game assets (loaded at start), MiSTer Main (loads the core, provides ini/OSD, joystick source), Developer (out-of-band: deploy/bench — one dashed node, labeled out-of-scope). Prose: one paragraph per actor stating the interface (e.g., "MiSTer Main writes joystick state that reaches the engine via the joy-shm bridge — see `05-data-flows.md`"). End with Sources section citing the three files + pins from Task 1 Step 2.

- [ ] **Step 3: Validate and commit**

```bash
bash scripts/check_arch_docs.sh docs/architecture/01-context.md
git add docs/architecture/01-context.md && git commit -m "docs(arch): C1 system context"
```

---

### Task 3: `02-containers.md` (C2)

**Files:**
- Create: `docs/architecture/02-containers.md`
- Read first:
  - `external/gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (how the engine reaches libmfgpu)
  - `external/gmloader-next/3rdparty/mfgpu/libmfgpu/mfgpu.h` (host↔fabric interface: ring, control words, addresses)
  - `maldita.castilla-mister/fpga/rtl/blitter_top.sv` (header/ports only: f2h/h2f, SDRAM, ring consumption)
  - `maldita.castilla-mister/fpga/rtl/openbor_video_reader.sv` (header/ports: scanout source, control block)
  - `maldita.castilla-mister/Maldita.sv` (how blitter + reader + framework glue together)

**Interfaces:**
- Consumes: actor names from Task 2.
- Produces: container names all C3/C4 docs must reuse verbatim: **gmloader engine**, **GM runner (.so)**, **gl4es/EGL glue**, **libmfgpu**, **blitter raster core**, **scanout reader**, **MiSTer framework (sys/ascal)**, **DDR3 shared regions** (ring, framebuffer, control block @ FB_QW_BASE, joy-shm), **SDRAM texture atlas**, **h2f/f2h bridges**.

- [ ] **Step 1: Read the five listed sources.** From `mfgpu.h` extract and verify the actual region addresses/names (FB_QW_BASE et al.) — these go in the diagram labels. If an address in this plan's Global Constraints disagrees with source, source wins.

- [ ] **Step 2: Write the doc.** One Mermaid `flowchart` with three subgraphs: **HPS (Linux, Cortex-A9)** containing engine→GM runner, engine→gl4es/EGL, engine→libmfgpu; **FPGA fabric** containing blitter raster core, scanout reader, MiSTer framework/ascal; **Memories** containing DDR3 regions (one node per region, address in label) and SDRAM atlas. Edges labeled with the mechanism (h2f writes, f2h reads, ring submit, scanout fetch, ascal→HDMI/VGA). Prose: one short paragraph per container — what it does, how you use it, what it depends on. Note which repo owns each container.

- [ ] **Step 3: Validate and commit** — `bash scripts/check_arch_docs.sh docs/architecture/02-containers.md`, then `git add`/`git commit -m "docs(arch): C2 containers"`.

---

### Task 4: `03-components-fabric.md` (C3, maldita core)

**Files:**
- Create: `docs/architecture/03-components-fabric.md`
- Read first (all under `maldita.castilla-mister/fpga/rtl/`): `blitter_top.sv` (FSM states, submodule instantiations), `blt_tri_setup.sv`, `blt_tri.sv`, `blt_blend.sv`, `ddr_blitter_arb.sv`, `f2h_slot_mux.sv`, `openbor_video_reader.sv`, `sdram_fb_cache.sv`, `gm_audio.sv`; plus `maldita.castilla-mister/Maldita.sv` for framework wiring.

**Interfaces:**
- Consumes: container names from Task 3.
- Produces: component names for Task 7 (code level): the TRILIST stage names as they appear in `blitter_top.sv` (S_TRI_* states, span walk, pixel backend, texel prefetch cache), plus **ring consumer**, **perf counters**, reader states (ST_POLL_CTRL etc.).

- [ ] **Step 1: Read the RTL.** Use grep for state enums (`S_TRI_`, `ST_`), module instantiations (`^\s*\w+\s+#?\s*u_`or explicit instance names), and the perf counter block. Record actual module/instance names.

- [ ] **Step 2: Write the doc.** Two Mermaid flowcharts: (a) blitter raster core — ring consumer → tri setup → span walk → pixel backend (interp, texel fetch via prefetch cache → SDRAM atlas, modulate, blend) → framebuffer writes → arb → f2h/DDR3; perf counters attached; (b) scanout reader — ctrl poll → fetch → pixel out to framework, with the JOY writeback + beacon chain anchored where source says it is. Include gm_audio as a third small component if its runtime data flow touches DDR3/framework (verify in source). Prose per component: role, key file, upstream/downstream.

- [ ] **Step 3: Validate and commit** — checker + `git commit -m "docs(arch): C3 fabric components"`.

---

### Task 5: `03-components-libmfgpu.md` (C3, host renderer)

**Files:**
- Create: `docs/architecture/03-components-libmfgpu.md`
- Read first: `external/gmloader-next/3rdparty/mfgpu/libmfgpu/mfgpu.c`, `mfgpu.h`, `mfgpu_xform.c`, `mfgpu_xform.h`; `external/gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp`, `raster_backend.h`, `blitter_raster.cpp`, `blitter.cpp`.

**Interfaces:**
- Consumes: container names from Task 3.
- Produces: function-level names for Task 7 (code level): the actual public entry points of libmfgpu (from `mfgpu.h`) and the backend seam (`raster_backend.h` interface).

- [ ] **Step 1: Read the sources.** Establish the real pipeline: where GM batched draws enter (backend seam), where transform/clip/cull happens (`mfgpu_xform.c` — confirm NEON claim or mark unverified), where triangles are packed, how the ring is submitted, how completion is polled.

- [ ] **Step 2: Write the doc.** One Mermaid flowchart: GLES/backend seam → convert → xform/clip/cull → tri emit → ring submit → completion poll, with edges to the DDR3 region nodes named as in Task 3. Prose per component with file paths.

- [ ] **Step 3: Validate and commit** — checker + `git commit -m "docs(arch): C3 libmfgpu components"`.

---

### Task 6: `03-components-engine.md` (C3, gmloader-next)

**Files:**
- Create: `docs/architecture/03-components-engine.md`
- Read first: `external/gmloader-next/gmloader/main.cpp`, `loader/` (skim structure), `gmloader/libyoyo.cpp` (hook surface — skim, it is large), `gmloader/mister/joy_shm_reader.cpp`, `joy_ddr_reader.cpp`, `mister_native_audio.cpp`, `frame_capture.cpp`.

**Interfaces:**
- Consumes: container names from Task 3.
- Produces: nothing downstream (leaf doc).

- [ ] **Step 1: Read the sources.** Establish: loader → runner .so → libyoyo hook layer → GLES dispatch to backends; input readers (shm vs DDR — state which one ships, verify from call sites, else mark unverified); audio path from engine to `gm_audio.sv`'s DDR3/bridge interface.

- [ ] **Step 2: Write the doc.** One Mermaid flowchart: loader → runner → hook layer → {render backend seam, audio writer, input readers}; edges out to libmfgpu (see `03-components-libmfgpu.md`) and DDR3 regions. Prose per component.

- [ ] **Step 3: Validate and commit** — checker + `git commit -m "docs(arch): C3 engine components"`.

---

### Task 7: `04-code-fabric-raster.md` (C4)

**Files:**
- Create: `docs/architecture/04-code-fabric-raster.md`
- Read first: `maldita.castilla-mister/fpga/rtl/blitter_top.sv` in full (it is the one file this doc describes), `blitter_defs.vh`.

**Interfaces:**
- Consumes: component/stage names recorded in Task 4.

- [ ] **Step 1: Extract the structure.** From source: the FSM state list (actual enum names), per-state one-line role, the pipeline registers between tri-setup → span walk → pixel backend, the texel cache interface, ports grouped by bus (h2f slave, f2h master, SDRAM, video). Cite line numbers as `blitter_top.sv:N` (they will drift; the Sources commit pins them).

- [ ] **Step 2: Write the doc.** One Mermaid `flowchart` of the stage/dataflow structure (states as nodes grouped by phase subgraphs) + one Markdown table: state → role → key signals. Note the two rules that must never be violated, with source anchors: reader/consumer is poll-before-issue; `ramstyle` array reads must not be nested in FSM case arms (M10K inference — check `grep 276007 *.map.rpt`).

- [ ] **Step 3: Validate and commit** — checker + `git commit -m "docs(arch): C4 fabric raster core"`.

---

### Task 8: `04-code-libmfgpu-pipeline.md` (C4)

**Files:**
- Create: `docs/architecture/04-code-libmfgpu-pipeline.md`
- Read first: `external/gmloader-next/3rdparty/mfgpu/libmfgpu/mfgpu.c` in full, `mfgpu_xform.c` in full.

**Interfaces:**
- Consumes: function names recorded in Task 5.

- [ ] **Step 1: Extract the call structure.** Public API (from `mfgpu.h`) → internal call graph for the submit path and the poll path; data structures crossing the boundary (ring entry layout, control words) as they are literally defined in the header.

- [ ] **Step 2: Write the doc.** One Mermaid flowchart of the call graph (functions as nodes, grouped submit-path vs poll-path) + a table of the boundary structs/constants with their header names. No pseudo-code — quote real signatures.

- [ ] **Step 3: Validate and commit** — checker + `git commit -m "docs(arch): C4 libmfgpu pipeline"`.

---

### Task 9: `05-data-flows.md` + finish index

**Files:**
- Create: `docs/architecture/05-data-flows.md`
- Modify: `docs/architecture/README.md` (fill the doc-map table)
- Read first: whatever Tasks 3–8 already opened (reuse those notes); additionally `external/gmloader-next/gmloader/mister/mister_joy_shm.h` and the reader's ctrl-poll block in `openbor_video_reader.sv`.

**Interfaces:**
- Consumes: every name produced by Tasks 2–8.

- [ ] **Step 1: Write the four sequence diagrams** (Mermaid `sequenceDiagram`), each with a prose intro and failure-mode note:
  1. **Frame lifecycle:** engine → libmfgpu → ring submit (C_SUBMIT++) → blitter consume/raster → C_DONE++ → scanout reader fetch → ascal → display. Notes: poll-before-issue gate; stale-frame watchdog (VCTRL stops → VGA blanks ~0.5 s — verify the mechanism in reader/framework source or mark unverified); f2h first-read reissue watchdog.
  2. **Input:** MiSTer Main → joy source → shm/DDR bridge → engine reader → GM VM; plus the fabric reader's JOY writeback chain and why it is anchored at the ctrl-poll state (ST_IDLE starvation history).
  3. **Control-word contract:** the FB_QW_BASE block — word-by-word table (offset, name, writer, reader, meaning) from `mfgpu.h` + RTL; beacon semantics; scanout counters.
  4. **Audio:** engine native-rate writer → FIFO/DDR3 → `gm_audio.sv` → core output; note the 4× refill burst underflow fix.
- [ ] **Step 2: Fill the index doc-map table** in `README.md`: at minimum rows for "where do triangles get rasterized", "where does input come from", "what are the shared-memory addresses", "what runs on the A9 vs the fabric", "how does a frame reach the screen", each pointing at file + section.
- [ ] **Step 3: Full validation sweep and commit**

```bash
bash scripts/check_arch_docs.sh
git add docs/architecture/ && git commit -m "docs(arch): data flows + completed index"
```

---

### Task 10: Whole-set review pass

**Files:**
- Modify: any `docs/architecture/*.md` needing fixes.

- [ ] **Step 1: Consistency check.** Grep the set for each container/component name and confirm identical spelling across files; confirm every "see `NN-*.md`" cross-reference targets an existing anchor; confirm every doc has "What this answers" + Sources with commit hashes.
- [ ] **Step 2: Unverified-claims audit.** List every **unverified** marker; for each, either spend ≤10 min verifying in source and remove the marker, or leave it marked with the file that would settle it.
- [ ] **Step 3: Final checker run + commit** — `bash scripts/check_arch_docs.sh` then commit any fixes as `docs(arch): review-pass fixes`.
