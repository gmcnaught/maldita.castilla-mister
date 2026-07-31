# Architecture — maldita castilla on MiSTer

**What this answers:** where every part of the runtime system lives across
this repo and its submodule, and which doc to open for a given question.

## The two repos
| Repo | Role | Ground truth for |
|---|---|---|
| `maldita.castilla-mister` (this repo) | umbrella + shipping core: **vendored** RTL, Quartus project, deploy/bench tooling | integration, this doc set, everything that runs on the FPGA |
| `external/gmloader-next` (submodule) | the engine: GM runner loading, GLES dispatch, MiSTer backends | host-side runtime code |

`mister-fpga-blitter` is a separate sibling repo, not a submodule of this one —
it is the contract/sim home for the raster core (protocol spec, refmodel, sim
harness) and its RTL never ships. `mister-gmloader`, the former umbrella repo,
is retired; its docs, bench tooling, `Makefile`, `LICENSE` and README were
absorbed into this repo (release-consolidation, task 9) and it remains
readable read-only at its existing URLs.

## Traps
1. Production RTL is the vendored copy in `maldita.castilla-mister/fpga/rtl/`.
   `mister-fpga-blitter` RTL is a non-shipping v1 spike — never edit or cite it
   as the shipping implementation.
2. Sibling checkouts (notably `../gmloader-next`) can be stale relative to the
   submodule pins in this repo. Ground truth for the integration is the pin.

## Doc map

| Question | Open this | Section |
|---|---|---|
| Where do triangles get rasterized? | `04-code-fabric-raster.md` | §2 Stage / dataflow structure, §3 Main FSM state table (`S_TRI_PIX` umbrella, `pa`/`pb` sub-FSMs) |
| …and where does the host prepare them? | `04-code-libmfgpu-pipeline.md` | §1 Call graph, §2 Submit path (`handle_draw` → `mf_emit_group` → `blt_trilist`) |
| Where does input come from? | `05-data-flows.md` | §2 Input — gamepad to GameMaker VM (both channels + the one-time transport latch) |
| What are the shared-memory addresses? | `02-containers.md` | DDR3 / SDRAM address map |
| …word by word, with writer and reader? | `05-data-flows.md` | §3 Control-word contract (`BLTCTRL` table, `FB_QW_BASE` table) |
| What runs on the A9 vs the fabric? | `02-containers.md` | Containers (HPS vs FPGA fabric subgraphs), f2h / h2f bridge terminology |
| …in host-code detail? | `03-components-engine.md` / `03-components-libmfgpu.md` | Components |
| …in RTL detail? | `03-components-fabric.md` | (a) Blitter raster core, (b) Scanout reader, (c) gm_audio |
| How does a frame reach the screen? | `05-data-flows.md` | §1 Frame lifecycle — draw call to lit pixel |
| Why is the screen black / input dead / the fabric wedged? | `05-data-flows.md` | §1 Failure modes (stale-frame watchdog, `S_RD_WAIT` reissue), §2 Failure mode (`ST_IDLE` starvation) |
| How does audio get out? | `05-data-flows.md` | §4 Audio — AudioTrack to DAC |
| Who talks to this system at all? | `01-context.md` | Actors |

## Out of scope here
- Build & deploy: `Makefile`, `deploy.py` (tree-hash-gated RBF fetch).
- Device process model: Master_Daemon/handler exec chain, single-engine invariant.
- Bench harness: `scripts/mister_run.sh`, wedge gates, sim lockstep.

## Conventions

Every doc in this set opens with `**What this answers:**`, ends with a
`## Sources` list, and closes with a `Repo pins:` line naming the commit each
citation was read at. Line citations are written `path:N` against those pins
and will drift as the pinned repos move — the pin, not the line number, is the
ground truth. Container, component, FSM-state, and register names are the
literal identifiers in source and are spelled identically across all nine docs.

`bash scripts/check_arch_docs.sh` validates the set: every ```` ```mermaid ````
fence must render, and every backticked path beginning `mister-gmloader/`,
`maldita.castilla-mister/`, or `external/` must exist. It must exit 0.

## Sources

- `README.md` (this repo's top-level one) — the two-repo stack and the
  submodule's role.
- `Makefile`, `deploy.py`, `scripts/mister_run.sh` — named above only to mark
  them out of scope.
- `docs/architecture/01-context.md` … `docs/architecture/05-data-flows.md` —
  the docs this index routes to; each carries its own Sources and pins.

Repo pins: `external/gmloader-next` = `d585b38`; `maldita.castilla-mister`
(this repo) = `4ef1353` (milestone-a). `mister-fpga-blitter` (sibling, dev-only,
not a submodule) = `9ccd57a` (also the `3rdparty/mfgpu` submodule pin inside
`gmloader-next`).
