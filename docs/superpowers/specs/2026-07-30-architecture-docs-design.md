# Architecture Documentation (C4) — Design

**Date:** 2026-07-30
**Status:** Approved design, pre-implementation
**Deliverable:** `docs/architecture/` in `mister-gmloader`

## Goal

Developer documentation, usable by humans and LLMs, describing the structure
and runtime data flows of the maldita castilla MiSTer port across its four
repos: `mister-gmloader` (umbrella/bundler), `gmloader-next` (engine),
`mister-fpga-blitter` (contract + sim home), and `maldita.castilla-mister`
(shipping core with vendored RTL). C4 diagrams at Context, Container,
Component, and (two targets) Code level, plus a data-flow document.

## Decisions (user-ratified)

- **Scope:** runtime data flows only — draw submission, texel/framebuffer
  traffic, input, audio, scanout. Build/deploy tooling, the device process
  model (Master_Daemon/handler), and the bench harness are OUT of scope;
  the index names them with one-line pointers so readers know they exist.
- **Location:** `docs/architecture/` in `mister-gmloader` — one file per C4
  level plus an index. Per-repo internals are referenced by explicit
  cross-repo path, not duplicated.
- **Diagram format:** Mermaid flowcharts (styled `graph`/`flowchart` blocks)
  in Markdown fences. Not Mermaid's experimental C4 syntax; not Structurizr.
  Rationale: renders natively on GitHub, full layout control for hardware
  boundaries (HPS vs fabric vs DDR3/SDRAM).
- **Code level:** exactly two targets — the fabric raster core
  (`blitter_top.sv` stage structure) and the libmfgpu host pipeline. The
  scanout/reader FSM stays at Component level.
- **Structure:** C4 levels as the backbone plus one data-flows file with
  sequence diagrams (approach A). Flow-per-file and strict-C4-only were
  considered and declined.

## File set

| File | Level | Contents |
|------|-------|----------|
| `README.md` | index | Question→file map; four-repo layout; known traps (see below); out-of-scope pointers |
| `01-context.md` | C1 | Player, developer, game assets (game.droid + YoYo runner .so), MiSTer Main/menu, display chain, gamepad; system = gmloader+fabric stack on the DE10-Nano |
| `02-containers.md` | C2 | HPS side (gmloader engine + loaded GM runner, libmfgpu, gl4es/EGL glue) vs fabric side (maldita core = raster core + scanout reader + MiSTer framework/ascal) vs shared memory (DDR3: ring, framebuffer, control block at FB_QW_BASE, joy-shm; SDRAM: texture atlas); h2f/f2h bridges. Hardware boundaries as subgraphs |
| `03-components-fabric.md` | C3 | Maldita core: blitter FSM, TRILIST datapath (span walk, pixel backend), texel prefetch cache, ring consumer, perf counters, scanout reader (ctrl poll, fetch, JOY writeback, beacon), framework glue |
| `03-components-libmfgpu.md` | C3 | Host renderer: GLES intercept, transform/clip/cull (NEON), triangle emitter, ring submit, completion poll |
| `03-components-engine.md` | C3 | gmloader-next: loader, Android runtime shim, GLES dispatch, audio path, input reader |
| `04-code-fabric-raster.md` | C4 | `blitter_top.sv` stage structure and ports |
| `04-code-libmfgpu-pipeline.md` | C4 | Host pipeline call structure |
| `05-data-flows.md` | flows | Sequence diagrams: (1) frame lifecycle — draw → emit → C_SUBMIT → raster → C_DONE → scanout → display, including stale-frame watchdog and poll-before-issue gate; (2) input — joy producer → shm → engine, plus the reader's JOY writeback; (3) control-word contract at FB_QW_BASE; (4) audio — engine native-rate path to the core's audio output |

## Conventions

- Each file opens with a one-line "what this answers" statement.
- Each file ends with a **Sources** section: the repos, commits, and paths
  the diagrams were derived from. This is the staleness guard and the hook
  an LLM uses to find ground truth.
- Cross-repo paths are written explicitly, e.g.
  `maldita.castilla-mister/fpga/rtl/blitter_top.sv`.
- Component names in diagrams match real module/function names in source.

## Grounding rules

- Diagrams are derived by reading actual source at the current submodule
  pins (`external/gmloader-next`, `external/mister-fpga-blitter`) and the
  `maldita.castilla-mister` sibling checkout — not from memory, the README,
  or prior findings docs.
- Where a behavior is known from project memory but not re-verified in
  source during writing, the doc marks it **unverified** rather than
  asserting it.

## Known traps the index must state

1. Production RTL is the **vendored** copy in
   `maldita.castilla-mister/fpga/rtl/`; `mister-fpga-blitter/rtl/` is a
   non-shipping v1 spike. Component/Code diagrams of the fabric derive from
   the vendored copy.
2. Sibling checkouts (notably `../gmloader-next`) can be stale relative to
   the submodule pins in this repo; ground truth for the integration is the
   pin.

## Out of scope

Build & deploy pipeline (Makefile, deploy.py, Docker ARM build, Quartus
runner), device process model (Master_Daemon, handler exec chain,
single-engine invariant), bench/test harness (mister_run.sh, wedge gates,
sim lockstep). Each gets a one-line pointer in the index.

## Success criteria

- A reader (human or LLM) can answer "where does X happen and which file
  implements it" for the runtime path without opening source first.
- Every diagram element traces to a named source file at a named commit.
- Renders correctly on GitHub with no external tooling.
