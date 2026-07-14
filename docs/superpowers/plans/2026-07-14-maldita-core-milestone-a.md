# Maldita Castilla Core — Milestone A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an independent Maldita Castilla MiSTer RBF, forked from
`solarus-mister`, that scans out gmloader-next's A9-rendered frames cleanly at
320×224, with the blitter fabric carried but dormant.

**Architecture:** Copy the Solarus FPGA project into the empty
`maldita.castilla-mister` repo, rebrand the Quartus project `Solarus→Maldita`,
retarget the `openbor_video_*` scanout from 320×240 to 320×224 (timing + reader,
kept consistent), optionally letterbox gmloader's present so no content lands in
the cropped rows, then build the RBF and verify on device via MiSTer Remote.

**Tech Stack:** SystemVerilog (Intel Cyclone V), Quartus Prime **17.0.x** (Lite;
CI `raetro/quartus:17.0`), C++ (gmloader-next present path), Python (deploy.py),
MiSTer DE10-Nano at `192.168.20.81`, MiSTer Remote screenshot API `:8182`.

## Global Constraints

- **Quartus Prime 17.0.x only** — newer Quartus is not compatible with MiSTer cores.
- **Top-level entity stays `emu`** (in `Solarus.sv`/renamed `.sv`) — rebrand only the
  Quartus *project revision* and RBF filename prefix, never the `emu`/`sys_top` wiring.
- **DDR contract is fixed:** frames at physical `0x3A000000`, layout per
  `openbor_video_reader.sv` (control word `0x000`, BUF0 `0x040`, BUF1 `0x40040`),
  320-wide RGB565, 80 qwords/scanline. Do not change addresses.
- **Fabric stays dormant:** `comp_*`/`blitter_top`/`bgplane`/CLUT RTL remain
  compiled-in and unfed. Do not rip them out (out of scope; delicate).
- **Reader and timing `V_ACTIVE` must always match** — they live in two files
  (`openbor_video_timing.sv` and `openbor_video_reader.sv`); a mismatch is exactly
  the OpenBOR_7533 garbling this core exists to fix.
- **RBF is a build artifact** — gitignored (`_Other/*.rbf`), built locally or in CI.
- gmloader (the engine) is **reused as-is** from `/media/fat/games/gmloader`; this
  plan does not rebuild it except the optional letterbox in Task 4.

---

## Task 1: Bootstrap the Maldita repo from the Solarus core (rebranded, still 320×240)

**Goal:** `maldita.castilla-mister` contains a complete, buildable copy of the
Solarus FPGA project, rebranded to Maldita, that produces
`_Other/MalditaCastilla_YYYYMMDD.rbf`. Timing is still 320×240 at this point — Task 2
retargets it. This isolates "the fork builds" from "the retarget is correct."

**Files:**
- Copy: `solarus-mister/{fpga,cmake,scripts,deploy.py,Dockerfile.solarus-build}` and
  `solarus-mister/.github/workflows/build-rbf.yml` → `maldita.castilla-mister/…`
  (preserve layout). Exclude: `build/`, `work/`, `deploy/` artifacts, `games/Solarus/`
  (Maldita gets its own launcher in Task 4), `_Other/*.rbf`, `*.profile`, `*.db`.
- Rename: `fpga/Solarus.qpf`→`fpga/Maldita.qpf`, `fpga/Solarus.qsf`→`fpga/Maldita.qsf`,
  `fpga/Solarus.sdc`→`fpga/Maldita.sdc`, `fpga/Solarus.sv`→`fpga/Maldita.sv`.
- Modify: `fpga/Maldita.qpf` (revision), `fpga/Maldita.qsf` (project/top refs,
  `files.qip` include of the renamed top `.sv`), `fpga/files.qip` (the
  `Solarus.sv`→`Maldita.sv` line), `fpga/build_solarus.sh`→`fpga/build_maldita.sh`
  (`PROJECT`/`RBF_PREFIX`), `.github/workflows/build-rbf.yml` (project/artifact names),
  `.gitignore` (add `_Other/*.rbf`, `build/`, `work/`, `deploy/`).

**Interfaces:**
- Produces: a Quartus project whose revision is `Maldita` and whose top entity is
  `emu`; `fpga/build_maldita.sh` emitting `_Other/MalditaCastilla_YYYYMMDD.rbf`.

- [ ] **Step 1: Copy the Solarus FPGA tree into the Maldita repo.** From
  `maldita.castilla-mister/`:
```bash
S=../solarus-mister
rsync -a --exclude build/ --exclude work/ --exclude deploy/ \
  --exclude '_Other/*.rbf' --exclude '*.profile' --exclude '*.db' \
  --exclude 'games/Solarus/' \
  "$S/fpga" "$S/cmake" "$S/scripts" "$S/deploy.py" "$S/Dockerfile.solarus-build" .
mkdir -p .github/workflows
cp "$S/.github/workflows/build-rbf.yml" .github/workflows/
```

- [ ] **Step 2: Rename the Quartus project files.**
```bash
cd fpga
for ext in qpf qsf sdc sv; do git mv 2>/dev/null Solarus.$ext Maldita.$ext || mv Solarus.$ext Maldita.$ext; done
mv build_solarus.sh build_maldita.sh
cd ..
```

- [ ] **Step 3: Rebrand project references.** In `fpga/Maldita.qpf` change the
  `PROJECT_REVISION` value `Solarus`→`Maldita`. In `fpga/Maldita.qsf` change every
  `Solarus` token (`PROJECT_OUTPUT_DIRECTORY`, any `-name … Solarus`, and the
  top-level/revision references) to `Maldita`; confirm `TOP_LEVEL_ENTITY` is still
  `emu`. In `fpga/files.qip` change the `SYSTEMVERILOG_FILE Solarus.sv` line to
  `Maldita.sv`. In `fpga/build_maldita.sh` set `PROJECT="Maldita"` and
  `RBF_PREFIX="MalditaCastilla"`.
  Sanity grep — the only remaining `Solarus` tokens should be comments/attribution:
```bash
grep -rniE 'solarus' fpga/Maldita.qpf fpga/Maldita.qsf fpga/files.qip fpga/build_maldita.sh
```

- [ ] **Step 4: Rebrand the CI workflow.** In `.github/workflows/build-rbf.yml`
  replace `Solarus`→`Maldita`/`MalditaCastilla` in the project name, build invocation
  (`build_maldita.sh`), and uploaded-artifact name. Keep the `raetro/quartus:17.0`
  image and steps otherwise identical.

- [ ] **Step 5: Add `.gitignore`.**
```
_Other/*.rbf
build/
work/
deploy/solarus-run
deploy/libs/
*.qws
*.rpt
db/
incremental_db/
```

- [ ] **Step 6: Build the RBF to prove the fork compiles.** Requires Quartus 17.0.x
  in PATH (or the `raetro/quartus:17.0` Docker image). From `fpga/`:
```bash
./build_maldita.sh
```
  Expected: a full compile with **no errors**, producing
  `_Other/MalditaCastilla_YYYYMMDD.rbf`. (Warnings are fine; this is an unmodified
  Solarus datapath other than the rename.) If Quartus is unavailable locally, push the
  branch and let the `build-rbf` CI job produce the RBF; treat a green CI build as the
  pass condition for this step.

- [ ] **Step 7: Commit.**
```bash
git add -A
git commit -m "feat(core): fork Solarus FPGA project into Maldita (rebrand only, 320x240)"
```

---

## Task 2: Retarget scanout to 320×224 (timing + reader, kept consistent)

**Goal:** The Maldita core outputs **320×224** active video and its DDR reader
fetches 224 lines starting 8 rows into gmloader's 320×240 frame, so the displayed
image is the middle 224 rows — pixel-exact, no shear.

**Files:**
- Modify: `fpga/rtl/openbor_video_timing.sv` (the `V_*` localparams, ~lines 44–54)
- Modify: `fpga/rtl/openbor_video_reader.sv` (`V_ACTIVE` ~line 167; per-frame line-fetch
  base offset near `BUF0_ADDR`/`BUF1_ADDR`, lines 146–147)

**Interfaces:**
- Consumes: the Task 1 rebranded project.
- Produces: a core whose `openbor_video_timing` and `openbor_video_reader` both use
  `V_ACTIVE=224` with an 8-line read offset (`ROW_OFFSET_QW = 8*80 = 640` qwords).

**Timing derivation (do this, don't guess):** the current 320×240 timing is
`V_ACTIVE=240, V_FP=2, V_SYNC=3, V_BP=17, V_TOTAL=262` (15 kHz NTSC-compatible, H
timing = Genesis H40, unchanged). Hold `V_TOTAL=262` so H rate / refresh are
untouched, and move the 16 freed lines into the back porch (keeps vsync well outside
active video, honoring the existing `#107` `v_sync_start >= V_ACTIVE` clamp):
`V_ACTIVE=224, V_FP=2, V_SYNC=3, V_BP=33, V_TOTAL=262` (224+2+3+33=262). Keep H
unchanged.

- [ ] **Step 1: Retarget the timing generator.** In
  `fpga/rtl/openbor_video_timing.sv` set:
```systemverilog
localparam V_ACTIVE = 224;
localparam V_FP     = 2;
localparam V_SYNC   = 3;
localparam V_BP     = 33;
localparam V_TOTAL  = 262;   // 224+2+3+33 — unchanged total: same H rate / refresh
```
  Update the header comment block (the `320x240 active … 240+2+3+17` lines) to
  `320x224 active … 224+2+3+33`.

- [ ] **Step 2: Match the reader's active-line count.** In
  `fpga/rtl/openbor_video_reader.sv` set the reader `V_ACTIVE`:
```systemverilog
localparam [8:0]  V_ACTIVE     = 9'd224;
```

- [ ] **Step 3: Offset the read base by 8 rows** so the fetched 224 lines are the
  middle band of gmloader's 320×240 buffer. Add, next to `BUF0_ADDR`/`BUF1_ADDR`:
```systemverilog
// gmloader writes 320x240; we display the middle 224 rows (8 black-bar rows top &
// bottom). One scanline = 80 qwords (320px * 2B / 8B); skip 8 rows = 640 qwords.
localparam [28:0] ROW_OFFSET_QW = 29'd640;   // 8 rows * 80 qwords
localparam [28:0] BUF0_BASE = BUF0_ADDR + ROW_OFFSET_QW;
localparam [28:0] BUF1_BASE = BUF1_ADDR + ROW_OFFSET_QW;
```
  Then replace the per-frame line-fetch base so it reads from `BUF0_BASE`/`BUF1_BASE`
  (selected by `active_buf`) instead of `BUF0_ADDR`/`BUF1_ADDR`. Find the existing
  expression that picks the frame base from `active_buf` and substitute the `_BASE`
  names; do not change the control-word / joystick / audio / cart addresses.

- [ ] **Step 4: Sim check (if the harness covers the reader).** From `fpga/sim/`:
```bash
ls    # look for an openbor_video / reader testbench
```
  If a reader/video testbench exists, run it (per `fpga/sim/README` or the existing
  `run_*.sh`) and confirm it passes with the 224 geometry. If no such bench exists,
  state that in the commit message and rely on the Task 3 on-device check.

- [ ] **Step 5: Rebuild the RBF.** From `fpga/`: `./build_maldita.sh` (or CI). Expected:
  clean compile, new `_Other/MalditaCastilla_YYYYMMDD.rbf`. Confirm no new timing-closure
  errors in the STA summary (`V_TOTAL` and H are unchanged, so Fmax should be unaffected).

- [ ] **Step 6: Commit.**
```bash
git add fpga/rtl/openbor_video_timing.sv fpga/rtl/openbor_video_reader.sv
git commit -m "feat(video): retarget scanout to 320x224 (timing + reader, +8-row read offset)"
```

---

## Task 3: Deploy the Maldita core + launcher; on-device visual verification

**Goal:** Load the Maldita RBF on the device, auto/hand-launch the existing gmloader
engine, and confirm via MiSTer Remote that a **clean, recognizable 320×224 Maldita
frame** scans out (the OpenBOR_7533 garbling is gone).

**Files:**
- Create: `games/MalditaCastilla/maldita_run.sh` (minimal launcher: env +
  `LD_LIBRARY_PATH`, `exec` gmloader with its config — one game, no quest OSD).
- Create: `scripts/MalditaCastilla.sh` (MiSTer Scripts-menu manual launcher that calls
  `maldita_run.sh`).
- Modify: `deploy.py` — Solarus→Maldita paths (`GAMEDIR=/media/fat/games/MalditaCastilla`,
  RBF glob `_Other/MalditaCastilla_*.rbf`, the game-scripts list → the two files above);
  drop the quest_manager/handler machinery (Maldita has no quest selection).

**Interfaces:**
- Consumes: the Task 2 RBF and the existing gmloader deploy at
  `/media/fat/games/gmloader`.
- Produces: `_Other/MalditaCastilla_*.rbf` + `games/MalditaCastilla/` on the device.

- [ ] **Step 1: Write the minimal launcher** `games/MalditaCastilla/maldita_run.sh`:
```bash
#!/bin/bash
# Maldita Castilla launcher — runs the gmloader engine for the Maldita core.
GMDIR=/media/fat/games/gmloader
cd "$GMDIR" || { echo "gmloader dir not found: $GMDIR" >&2; sleep 3; exit 1; }
pkill -9 -f "gmloader -c" 2>/dev/null; sleep 1
export LD_LIBRARY_PATH="$GMDIR/mesa:$GMDIR"
exec ./gmloader -c gmloader.json
```

- [ ] **Step 2: Write the Scripts-menu launcher** `scripts/MalditaCastilla.sh`:
```bash
#!/bin/bash
# MiSTer Scripts-menu entry: load the Maldita core, then run gmloader.
RBF=$(ls -1 /media/fat/_Other/MalditaCastilla_*.rbf 2>/dev/null | sort | tail -1)
[ -n "$RBF" ] && echo "load_core $RBF" > /dev/MiSTer_cmd
sleep 8
exec /media/fat/games/MalditaCastilla/maldita_run.sh
```

- [ ] **Step 3: Adapt `deploy.py`.** Change `GAMEDIR` to
  `/media/fat/games/MalditaCastilla`, the RBF glob to `_Other/MalditaCastilla_*.rbf`,
  and the pushed game-scripts list to `maldita_run.sh` + `scripts/MalditaCastilla.sh`.
  Remove the Solarus quest_manager/_handler/core_watch entries. Keep the `--host`,
  `--no-rbf`, and scp-verify helpers.

- [ ] **Step 4: Deploy.**
```bash
./deploy.py --host 192.168.20.81
```
  Expected: RBF lands in `/media/fat/_Other/`, launcher scripts under
  `/media/fat/games/MalditaCastilla/`.

- [ ] **Step 5: Load the core + run gmloader + capture.** (gmloader's ~1-in-5
  heap-corruption abort, gmloader-next#13, is pre-existing — just re-run if a launch
  aborts early.)
```bash
ssh root@192.168.20.81 'RBF=$(ls -1 /media/fat/_Other/MalditaCastilla_*.rbf | tail -1); echo "load_core $RBF" > /dev/MiSTer_cmd; sleep 8; cat /tmp/CORENAME; cd /media/fat/games/gmloader; pkill -9 -f gmloader; sleep 1; export LD_LIBRARY_PATH="$PWD/mesa:$PWD"; nohup timeout 40 ./gmloader -c gmloader.json >/tmp/mald.log 2>&1 & sleep 12; echo "ctrlA=$(busybox devmem 0x3A000000)"; sleep 1; echo "ctrlB=$(busybox devmem 0x3A000000)"; curl -s -X POST http://localhost:8182/api/screenshots >/dev/null && echo shot-ok'
```
  Expected: `CORENAME` shows the Maldita core; `ctrlA`→`ctrlB` **increments**; `shot-ok`.

- [ ] **Step 6: Fetch + inspect the screenshot.**
```bash
p=$(curl -s http://192.168.20.81:8182/api/screenshots | python3 -c "import sys,json;a=json.load(sys.stdin);a.sort(key=lambda x:x['modified']);print(a[-1]['path'])")
curl -s "http://192.168.20.81:8182/api/screenshots/$p" -o /tmp/maldita_shot.png
file /tmp/maldita_shot.png   # expect: PNG 320 x 224
```
  **Pass condition:** the image is a clean, recognizable Maldita Castilla frame at
  320×224 — not the horizontal-banding/dark garble seen through OpenBOR_7533. View the
  PNG to confirm. If content is vertically clipped or off-center, proceed to Task 4;
  otherwise Task 4 is optional.

- [ ] **Step 7: Commit.**
```bash
git add games/MalditaCastilla/maldita_run.sh scripts/MalditaCastilla.sh deploy.py
git commit -m "feat(deploy): Maldita launcher + deploy.py; on-device 320x224 scanout verified"
```

---

## Task 4 (conditional): gmloader present letterbox to fit the visible 224 rows

**Do this task only if** Task 3 Step 6 shows Maldita content clipped or mis-centered
in the 224-row window (i.e. the game draws into rows the core now crops). If the frame
is already clean, skip — the core-side offset was sufficient.

**Repo:** `gmloader-next` (branch `mister-sdl-buffer-output`) — a *different* repo from
the core. Cross-repo change; commit there.

**Files:**
- Modify: `gmloader/mister/blitter.cpp:571-589` (`Blitter_ToRGB565`) — clamp/center
  content into the middle 224 rows so nothing lands in the cropped 8-row bars.
- (Its host regression: `gmloader/mister/blitter_raster_test.cpp` / `make -f
  Makefile.gmloader raster-backend-test` must still pass.)

**Interfaces:**
- Consumes: the fixed 320×240 DDR contract; the core displaying rows 8..231.
- Produces: a present frame whose non-black content is confined to rows 8..231.

- [ ] **Step 1: Constrain the vertical letterbox offset.** In `Blitter_ToRGB565`,
  change the vertical centering so content is centered within the visible 224-row band
  (rows 8..231) rather than the full 240, guaranteeing the top/bottom 8 rows are black:
```c
    const int ox = (MISTER_WIDTH  - g_rw) / 2;
    // Center within the core's visible 224-row window (rows 8..231), not the full 240,
    // so no content lands in the 8px bars the Maldita core crops. Clamp for g_rh>224.
    const int VIS_TOP = 8, VIS_H = 224;
    int oy = VIS_TOP + (VIS_H - g_rh) / 2;
    if (oy < 0) oy = 0;
    if (oy + g_rh > MISTER_HEIGHT) oy = MISTER_HEIGHT - g_rh;
```
  Leave the `memset(...0...)` border-clear and the row-flip copy loop unchanged.

- [ ] **Step 2: Host regression — SW present path unchanged in shape.** Run:
```bash
cd <gmloader-next>; make -f Makefile.gmloader raster-backend-test
```
  Expected: all cases pass (this edit only shifts the letterbox origin; it must not
  change rasterization).

- [ ] **Step 3: armhf build.** Run the CLAUDE.md `gmloader-armhf-build:bullseye` Docker
  recipe. Expected: clean link, `gmloadernext.armhf` produced.

- [ ] **Step 4: Deploy gmloader + re-verify on device.** scp the new
  `gmloadernext.armhf` to `/media/fat/games/gmloader/gmloader` (back up first:
  `ssh root@192.168.20.81 'cp -n /media/fat/games/gmloader/gmloader{,.bak}'`), then
  repeat Task 3 Steps 5–6. Pass condition: Maldita content fully visible and centered
  in the 320×224 frame.

- [ ] **Step 5: Commit (in gmloader-next).**
```bash
git add gmloader/mister/blitter.cpp
git commit -m "feat(blitter): center present into the Maldita core's visible 224-row band"
```
  Then bump the `external/gmloader-next` submodule pointer in `mister-gmloader` if that
  superproject should track the change.

---

## Self-Review

- **Spec coverage:** §1 repo/structure → Task 1; §2 rebrand + 320×224 retarget + fabric
  dormant → Tasks 1–2 (fabric untouched = dormant by construction); §3 geometry
  reconciliation → Task 2 (core-side 8-row offset) + Task 4 (producer-side letterbox,
  conditional); §4 build/deploy/verify → Tasks 1 (build), 3 (deploy+verify); success
  criteria 1–4 → Task 1 Step 6, Task 3 Steps 5–6, Task 2 Step 5. Out-of-scope items
  (Milestone B, #13 crash, RTL stripping) are not tasked, as intended.
- **Placeholder scan:** timing values are concrete (`224/2/3/33/262`); the read-offset is
  concrete (`640` qwords); the one genuinely environment-dependent spot (the exact
  `active_buf`→base expression to substitute in the reader) is described by what to find
  and what to replace it with, not left as "handle it."
- **Type/name consistency:** `V_ACTIVE`, `BUF0_ADDR`/`BUF1_ADDR`, `BUF0_BASE`/`BUF1_BASE`,
  `ROW_OFFSET_QW`, `MalditaCastilla_*.rbf`, `maldita_run.sh` used identically across tasks.
- **Risk flag:** the 320×224 timing (Task 2 Step 1) is the highest-risk change; it holds
  `V_TOTAL=262` and H timing fixed precisely so refresh/Fmax are unperturbed and only the
  active/back-porch split moves — verified by the STA summary (Step 5) and the on-device
  frame (Task 3).
