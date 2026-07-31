# Release consolidation: retire mister-gmloader, release from maldita.castilla-mister

**Date:** 2026-07-31
**Status:** Approved design, not yet implemented
**Supersedes:** `mister-gmloader/docs/superpowers/specs/2026-07-30-release-ci-design.md`

## Problem

The release workflow was built in `mister-gmloader`, but the artifact it
publishes is the Maldita Castilla MiSTer core. Consumers look for a core in the
core's own repository, not in a bundling shell.

Inspecting the three repos shows the split is wrong for a second reason:
`mister-gmloader` contains **no source code**. It tracks 50 files outside its
submodules and docs — a Makefile, bench/deploy wrappers, bench logs, a vendored
Mesa closure, and two release documents. The MiSTer implementation of gmloader
lives in `gmloader-next` (`gmloader/mister/`, 48 files: `blitter.cpp`,
`raster_backend_mfgpu.cpp`, `joy_ddr_reader`, `mister_native_audio`,
`frame_capture`, `native_video_writer`), together with
`.github/scripts/build_mister_arm.sh` and `scripts/Maldita_Castilla.sh`.

`mister-gmloader` is therefore a workspace, not a component. Once the release
moves out, nothing repo-shaped remains in it.

## Findings that shape the design

Two facts were discovered during design and change what the work has to cover.

### Finding 1 — the production gates do not exist where they are needed

`maldita/.github/workflows/build-rbf.yml` has **no** `332148` (timing) or
`276007` (M10K inference) gate steps. The gates existed only in
`mister-gmloader/.github/workflows/release.yml`, and that is precisely the step
its single run failed on (run `30573313353`, 2026-07-30, dry run).

Consequence: today, every RBF artifact `build-rbf.yml` publishes is ungated. Any
design that reuses those artifacts for a release must move the gates into
`build-rbf.yml` first, or it will ship an unverified bitstream.

### Finding 2 — the two engine build paths differ in toolchain, not in flags

| path | container | make invocation | output |
|---|---|---|---|
| dev (`make build-engine`) | cached arm64-host cross image (`Dockerfile.gmloader-build`) | `MISTER_BUILD=1 MISTER_NATIVE_VIDEO=1`, two-path `LLVM_INC` | `build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf` |
| CI (`build_mister_arm.sh`) | `arm32v7/debian:bullseye-slim` under QEMU | `MISTER_BUILD=1`, `LLVM_FILE` + single-path `LLVM_INC` | same path, then **stripped** and copied to `games/gmloader/gmloader` |

Both run the same `Makefile.gmloader`. `MISTER_BUILD=1` alone sets
`-DMISTER_NATIVE_VIDEO=1 -DMISTER_WIDTH=288 -DMISTER_HEIGHT=216` and pulls in
`MISTER_SRCS` (`Makefile.gmloader:149-155`), so the dev path's extra
`MISTER_NATIVE_VIDEO=1` is a redundant no-op, not a difference. Geometry and
feature defines are therefore identical across the two paths.

The real differences are the toolchain container, the `LLVM_INC` value, and the
strip step.

The mixed-geometry trap recorded for 2026-07-27 — where a flag-only change left
stale `.o` files and linked translation units that disagreed about geometry — is
a **local incremental-build** hazard. CI builds from a clean checkout with no
`build/` directory, so it cannot occur there.

Consequence: this does not block the release, and no geometry assertion is
warranted. What is warranted is a cheap positive check that the MiSTer sources
were actually linked in, since a silent `MISTER_BUILD` regression would produce
a plausible-looking binary with no fabric path at all.

## End state

Two repositories.

| repo | owns |
|---|---|
| `gmloader-next` | engine + MiSTer port (`gmloader/mister/`), and the **GL runtime closure** (`runtime/mesa/`, moved to sit beside `3rdparty/gles2-sw/libGLES_sw.so` and `lib/armeabi-v7a/libstdc++.so`) |
| `maldita.castilla-mister` | core RTL (`fpga/`), `games/Maldita Castilla/_handler.sh`, `deploy.py`, the release workflow and assets, all project docs, bench tooling. Gains `external/gmloader-next` as its single submodule |

`mister-gmloader` is archived read-only on GitHub after the migration
completes and a real release has published.

`mister-fpga-blitter` is untouched. The shipping blitter RTL is the vendored
copy in `maldita/fpga/rtl/`; the blitter repo is a non-shipping v1 spike and
never enters the release path.

### Why the Mesa closure goes to gmloader-next

The 5 `.so` files (13 MB) are engine runtime dependencies — `libEGL.so.1`,
`libGLESv2.so.2`, `libglapi.so.0`, `libdrm.so.2`, `swrast_dri.so`. Without
`LD_LIBRARY_PATH` pointing at them the engine dies at `eglInitialize` before any
game code runs. They belong with the binary that loads them, next to the two
other runtime `.so` files gmloader-next already vendors.

Placing them there also means `maldita` vendors **zero** binaries, and
`assemble_bundle.sh` sources every non-RBF file from a single submodule.

## Migration map

These are **copies**, not history-preserving moves. `git mv` cannot cross
repository boundaries, so per-file history does not follow into the destination
repo. That is acceptable here because `mister-gmloader` is archived read-only
rather than deleted: every file's full history stays readable at its existing
URLs. Each migration commit records the exact source SHA so any file can be
traced back.

**To `gmloader-next`:**

- `runtime/mesa/libEGL.so.1`, `libGLESv2.so.2`, `libglapi.so.0`, `libdrm.so.2`, `swrast_dri.so`
- `runtime/README.md`

**To `maldita.castilla-mister`:**

- `docs/superpowers/` (86 files) — merges into the existing 28, taking
  `maldita/docs/superpowers` to 114
- `docs/architecture/` (9 files) and `scripts/check_arch_docs.sh`
- `scripts/mister_run.sh`, `scripts/gmloader_diag.sh`, `scripts/mftrace_analyze.py`
- `scripts/lib/` (4 files), `scripts/scenes/` (2 files)
- `bench-results/` (25 logs)
- `release/README.md`, `release/APKs-README.txt`
- `scripts/release/assemble_bundle.sh`
- `.github/workflows/release.yml`
- `Makefile`
- `LICENSE` — `maldita.castilla-mister` currently has **no** license file
  (verified 2026-07-31: no `LICEN*` path is tracked). This move gives the repo
  that will publish the release an explicit license. `gmloader-next` already has
  its own `LICENSE.md` and needs nothing.

**Rewritten, not moved:** `README.md`. `maldita.castilla-mister` has no
top-level README (verified 2026-07-31: only `fpga/sim/README.md` is tracked),
and a repo that publishes a public release needs one. `mister-gmloader`'s README
describes a bundling shell, so it cannot move verbatim — it is rewritten for the
new two-repo layout: what the core is, where the engine comes from, how to build
and deploy, and where releases are published.

**Deleted, not moved:** `.gitmodules`, the three `external/` submodule pins.

### Docs collision handling

`mister-gmloader/docs/superpowers/` and `maldita/docs/superpowers/` both contain
`findings/`, `plans/`, and `specs/` subtrees. Filenames are date-prefixed.
Checked 2026-07-31 by comparing the sorted basenames of both trees: **zero
collisions**, so the merge is a plain union. The migration step re-runs that
same check immediately before moving and fails if any collision has appeared in
the meantime.

`HANDOFF-2026-07-30.md` moves with the rest. The session-start pointer in
project memory must be updated to the new path in the same change.

## Release workflow in maldita

`maldita/.github/workflows/release.yml`, triggered by a `v*` tag, with
`workflow_dispatch` as a dry run that assembles and uploads the bundle as a CI
artifact but never publishes.

### Job 1 — `resolve-rbf`

Locates the green `build-rbf.yml` run whose `fpga/` **tree hash** matches the
tagged commit's `fpga/` tree hash, and downloads its `maldita-rbf` and
`quartus-reports` artifacts.

This is the same resolution rule `deploy.py --fetch-rbf` already implements. It
is extracted into a shared helper (`scripts/lib/resolve_rbf.py`) that both
`deploy.py` and the workflow call, rather than reimplemented in YAML.

Ships the exact bitstream that was device-validated, since validation is
performed against a specific CI artifact.

**Fails closed.** If no green, gated run matches the tree hash, the release
aborts with an error naming the expected tree hash. It never falls back to
building a fresh RBF, because Quartus fitting is seed-sensitive and a fresh
build is a bitstream nobody validated.

Artifact retention is a real constraint: GitHub expires artifacts. If the
matching run's artifacts have expired, the correct action is to re-run
`build-rbf.yml` at that commit and re-validate on device, not to bypass the
gate. The error message states this.

### Job 2 — `build-engine`

Unchanged mechanically from the existing `release.yml`: QEMU armhf,
`arm32v7/debian:bullseye-slim`, `build_mister_arm.sh`, built from the
`external/gmloader-next` submodule pin. See "Engine build parity" below for the
verification added on top.

### Job 3 — `assemble-release`

Runs `scripts/release/assemble_bundle.sh` with paths rebased:

- `GMNEXT` → `$REPO/external/gmloader-next`
- `MALDITA` → `$REPO` (the repo itself now owns `_handler.sh`)
- Mesa `.so` → `$GMNEXT/runtime/mesa/` instead of `$REPO/runtime/mesa/`

The exhaustive manifest check and the emitted bundle tree are unchanged. The
staged output must remain byte-identical in structure to what the current
script produces; this is the primary regression test for the migration.

Provenance notes record the maldita commit, the `gmloader-next` submodule SHA,
the `fpga/` tree hash, and the `build-rbf.yml` run ID the RBF came from.

## Resolving the two findings

### Gates move into build-rbf.yml

Both the self-hosted Windows job and the Linux Docker fallback job gain a
gate step that runs against the Quartus reports **before** the artifact upload,
so an ungated RBF can never become a release candidate.

Gate contents, carried over from the failed `release.yml` step:

- Reports must exist (`Maldita.map.rpt`, `Maldita.sta.rpt`). A missing report is
  a failure, not a silent pass.
- `332148` (setup violation) anywhere in the build/STA logs or `*.sta.rpt` fails.
- `276007` (uninferred `ramstyle` array) in `*.map.rpt` fails.

The known-benign `276007` hit in `ddr_blitter_arb.sv` is handled by an
**explicit named allowlist entry** with a comment recording why it is benign and
when it was last reviewed — not by a blanket skip of the check. Any *new* file
producing a `276007` still fails the gate. This preserves the standing rule that
a `ramstyle` array's read must never be nested in an FSM case arm.

### Engine build parity

The release keeps `build_mister_arm.sh`, because it is clean, reproducible, and
depends on no cached host toolchain image. Per Finding 2 the compile flags
already match the device-validated build, so no geometry assertion is needed.

`build_mister_arm.sh` gains one check, run **before** the strip step, that the
MiSTer sources were actually linked in:

```
${ARCH}-nm build/${ARCH}/gmloader/gmloadernext.armhf \
  | grep -q ' T NativeVideoWriter_WriteFrame'
```

`NativeVideoWriter_WriteFrame` is a non-static C symbol in
`gmloader/mister/native_video_writer.c`, which is compiled only when
`MISTER_BUILD=1`. Its absence means the fabric video path is missing entirely.
`mf_frame_end` is deliberately *not* used for this check — it is `static` in
`raster_backend_mfgpu.cpp` and never reaches the symbol table.

The check must run before `${ARCH}-strip`, which removes the symbol.

## Path updates

**`deploy.py`** — `SIBLINGS / "gmloader-next/..."` becomes: prefer
`external/gmloader-next` (the submodule), fall back to the sibling checkout if
the submodule is absent or empty. This keeps the per-workstream worktree
workflow (`GMDIR=../wt-gmloader-<topic>`) working unchanged, while making a
fresh clone self-sufficient.

The existing provenance gates in `deploy.py` (RBF matched to `fpga/` tree hash,
engine freshness vs `gmloader-next` HEAD, sha1-verified scp) are unchanged.

**`Makefile`** — moves to the maldita repo root:

- `MALDITA` collapses to `$(CURDIR)`; the `cd $(MALDITA)` in `DEPLOY` becomes a no-op
- `GMDIR` default becomes `$(CURDIR)/external/gmloader-next`, still overridable
  with a worktree path
- `HOST` default (`192.168.20.62`, the test unit) and the `PROD=1` guard for
  `192.168.20.81` are unchanged
- `rbf-status` / `rbf-watch` drop their `cd $(MALDITA)` prefix

## Sequencing

Ordered so that each step is independently verifiable and the working release
path is never the thing under test.

1. **gmloader-next changes.** Move the 5 Mesa `.so` + README in; add the
   `NativeVideoWriter_WriteFrame` link check to `build_mister_arm.sh` before the
   strip step. Commit, push. Bump the `external/gmloader-next` pin in
   `mister-gmloader` so the existing workflow still resolves them — this step
   must not break the current release path.
2. **Gates into `build-rbf.yml`.** Add the gate step to both jobs with the
   `ddr_blitter_arb.sv` allowlist. Verify by running `build-rbf.yml` on a real
   commit and confirming it passes; then verify the gate *fires* by running it
   against a deliberately-violating input.
3. **Submodule + file migration into maldita.** Add `external/gmloader-next`,
   run the basename-collision check, copy all files per the migration map,
   update `deploy.py` and `Makefile` paths, extract `resolve_rbf.py`.
4. **Dry-run parity.** `workflow_dispatch` on the new `release.yml` must produce
   a bundle whose manifest matches `assemble_bundle.sh`'s expected list exactly.
   Compare against a bundle staged from the pre-migration script.
5. **Real release.** Tag `v0.1.0-rc1`, confirm the release publishes with the
   zip, the RBF, `sha256sums.txt`, and provenance notes.
6. **Archive `mister-gmloader`.** Only after step 5 passes. Update the
   session-start handoff pointer and project memory to the new doc paths.

## Verification

- Step 2 gate must be shown both to pass on a good build and to fail on a bad
  one. A gate that has only ever passed is untested.
- Step 4 manifest comparison is the migration's regression test.
- Step 5 is the acceptance criterion: a published release containing a
  device-validated RBF and a parity-checked engine.
- No device work is required by this design. Any device validation referenced
  here (the RBF being released) has already occurred separately.

## Out of scope

- Renaming any repository.
- Changing the RBF build toolchain or the self-hosted runner setup.
- Any change to `mister-fpga-blitter`.
- Publishing game data. `mygame.apk` and `saves/` remain user-provided; the
  bundle README documents their placement.
