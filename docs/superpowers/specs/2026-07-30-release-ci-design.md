# Release CI for Maldita Castilla on MiSTer — Design

**Date:** 2026-07-30
**Status:** Approved (brainstorm session)
**Repo:** mister-gmloader (the bundler repo hosts the release workflow)

## Goal

A tag-triggered CI pipeline that produces a production GitHub Release of the
Maldita Castilla MiSTer port: one install bundle containing the FPGA core RBF
(MiSTer `<CoreName>_YYYYMMDD.rbf` naming convention) plus the full gmloader
engine tree — everything a user needs except the game data.

## Decisions (from brainstorm)

| Decision | Choice |
|---|---|
| Release scope | Full install bundle (SD-card layout zip); game data stays user-provided |
| GL runtime | Included, from a stored (committed) copy of the known-good closure |
| Trigger / version | `v*` tag pushed to mister-gmloader; tag pins all sources via submodules |
| Build sourcing | Approach A — build RBF and engine in the release workflow from submodule pins (hermetic; no cross-repo PAT, no artifact-expiry dependence) |

Rejected alternatives: fetching prebuilt artifacts cross-repo (PAT management,
90-day artifact expiry breaks re-releases, pin↔artifact matching is the exact
staleness class `deploy.py --fetch-rbf` exists to fight); hybrid (same problems
for the RBF, the hardest artifact to rebuild elsewhere).

## 1. Repo changes (mister-gmloader)

- **New submodule** `external/maldita.castilla-mister` pinned at the release
  commit. (Currently only `external/gmloader-next` and
  `external/mister-fpga-blitter` exist; the RBF source was unpinned.)
- **Commit the GL runtime closure** — not tracked in any repo today, exists
  only as a working tree in `epic-mister-sdl-buffer-output/games/gmloader/`
  (the tree `deploy.py --with-runtime` pushes):
  - `runtime/mesa/{libdrm.so.2, libEGL.so.1, libglapi.so.0, libGLESv2.so.2, swrast_dri.so}`
  - `runtime/lib/armeabi-v7a/libstdc++.so`

  `libGLES_sw.so` is NOT copied — it is already tracked in the gmloader-next
  submodule at `3rdparty/gles2-sw/libGLES_sw.so`. Mesa is MIT-licensed;
  redistribution is fine.
- **New workflow** `.github/workflows/release.yml`.

## 2. Workflow structure

**Triggers:** push of a `v*` tag → full release. `workflow_dispatch` → dry run:
builds and uploads the bundle as a CI artifact, skips the GitHub Release.

**Jobs:**

1. **build-rbf** (ubuntu-latest)
   - Checkout with `submodules: recursive`.
   - Free-disk-space step (Quartus needs ~24 GB) — same as the existing
     `build-rbf.yml` Linux job.
   - `docker run raetro/quartus:17.0 … bash build_maldita.sh` inside
     `external/maldita.castilla-mister/fpga/` — the proven Linux fallback path;
     the maldita workflow's own parity note says Windows/Linux outputs match.
   - Emits `_Other/MalditaCastilla_YYYYMMDD.rbf` (script's existing naming —
     already the MiSTer convention; date = build date).
   - Uploads the RBF and the Quartus reports (`*.rpt`, `*.summary`, build/STA
     logs) as artifacts.
2. **build-engine** (ubuntu-latest, parallel with build-rbf)
   - QEMU setup for arm, then `docker run --platform linux/arm/v7
     arm32v7/debian:bullseye-slim bash .github/scripts/build_mister_arm.sh`
     inside `external/gmloader-next/` — the existing engine recipe.
   - Emits the armhf `gmloader` binary; uploads as artifact.
3. **assemble-release** (needs: build-rbf, build-engine)
   - Downloads both artifacts, assembles the bundle (layout below).
   - Generates `sha256sums.txt` over every file in the zip plus the zip itself.
   - `v*` tag: creates the GitHub Release via `gh release create` with the
     zip, the standalone `.rbf`, and `sha256sums.txt` attached. Release notes
     include the three submodule SHAs and the `fpga/` tree hash of the maldita
     pin (the same provenance key `deploy.py --fetch-rbf` gates on).
   - Dry run: uploads the same files as a workflow artifact instead.

## 3. Bundle layout and naming

Zip name: `MalditaCastilla-MiSTer-<tag>.zip`. Extracts over `/media/fat/`:

```
_Other/MalditaCastilla_YYYYMMDD.rbf         <- MiSTer naming convention (build date)
games/Maldita Castilla/_handler.sh          <- auto-launch dispatcher (maldita submodule)
games/gmloader/gmloader                     <- engine binary (built from pin)
games/gmloader/gmloader.json                <- gmloader-next submodule
games/gmloader/libGLES_sw.so                <- gmloader-next 3rdparty/gles2-sw/
games/gmloader/mesa/*.so                    <- committed runtime/ (5 files)
games/gmloader/lib/armeabi-v7a/libstdc++.so <- committed runtime/
games/gmloader/APKs/README.txt              <- game-data placement instructions
README.md                                   <- install guide (see below)
```

- Game content (`mygame.apk` = PortMaster malditacastilla APK,
  `saves/game.droid`, `saves/options.ini`) is user-provided; the README and
  `APKs/README.txt` document exactly where it goes.
- The `MiSTer_Maldita` HPS wrapper binary is **excluded**: unused by the
  handler launch path (see deploy.py AUTO-LAUNCH note) and would add a third
  cross-compile for dead weight.
- The bundle README documents the launch env
  (`LD_LIBRARY_PATH=<gamedir>/mesa:<gamedir>`, `-c gmloader.json`) only as a
  troubleshooting note; normal launch is via the handler.

## 4. Production quality gates

A release build FAILS (no release published) if any of:

- **Timing gate:** the STA log/reports show a setup violation
  (Critical Warning 332148 / negative setup slack). A Quartus build can
  "succeed" while failing timing; a production release must be timing-clean.
- **M10K-inference gate:** `grep 276007 *.map.rpt` matches — the
  `tq_data`-class regression (ramstyle array read nested in an FSM case arm)
  that silently costs ~20k flops and closes timing paths.
- **RBF sanity:** missing or implausibly small RBF (`if-no-files-found: error`
  plus a minimum-size check).
- **Engine sanity:** `file` on the built binary must report 32-bit ARM ELF.

## 5. Known dependency (stated, not solved)

Auto-launch requires Frontier's **Master_Daemon** on the device — it watches
`/tmp/CORENAME` and runs `games/Maldita Castilla/_handler.sh` on core load.
The bundle README states this dependency. A Frontier-independent core-load
watcher (the pattern of solarus-mister's `solarus_daemon.sh`, which
self-registers into `user-startup.sh` and defers to Master_Daemon when
present) is explicitly out of scope for this release.

## Error handling

- Every artifact upload uses `if-no-files-found: error`.
- All transfers into the bundle are followed by an existence check of the full
  expected file list before zipping (a missing mesa lib must fail assembly,
  not ship a broken bundle).
- Concurrency group keyed on the tag so a re-pushed tag cancels the stale run.
- Job timeouts: 120 min for build-rbf (matches existing workflow), 30 min for
  build-engine.

## Testing

- **Dry run first:** `workflow_dispatch` on master before tagging — verifies
  both Docker builds and assembly without publishing.
- **Bundle verification step in CI:** unzip the produced zip to a temp dir and
  diff its file list against the expected manifest.
- **Device smoke test (manual, post-release):** extract a release zip onto the
  test device (.62 — never .81/production first), load the core, confirm
  handler launch and gameplay reachability per the established screenshot
  method.

## Out of scope

- Building mesa from source in CI.
- The `MiSTer_Maldita` HPS wrapper.
- A Frontier-independent auto-launch daemon.
- Publishing to any MiSTer distribution channel (update_all / Distribution
  repo) — GitHub Release only.
