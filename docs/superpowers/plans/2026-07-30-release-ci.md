# Release CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tag-triggered GitHub Actions release pipeline in mister-gmloader that builds the Maldita Castilla RBF + gmloader engine from submodule pins and publishes a full SD-card install bundle.

**Architecture:** Three-job workflow (`build-rbf` via `raetro/quartus:17.0` Docker, `build-engine` via QEMU arm32v7 Docker, `assemble-release`), with assembly + manifest verification in a locally-testable shell script. Sources are pinned by three submodules; the mesa GL runtime closure is vendored into the repo.

**Tech Stack:** GitHub Actions, Docker (Quartus 17.0, arm32v7 Debian), bash, zip.

**Spec:** `docs/superpowers/specs/2026-07-30-release-ci-design.md`

## Global Constraints

- RBF name is produced by `build_maldita.sh` and MUST stay `MalditaCastilla_YYYYMMDD.rbf` under `_Other/` (MiSTer convention; do not rename).
- Zip name: `MalditaCastilla-MiSTer-<version>.zip`; version = tag for `v*` pushes, `dryrun-<run_number>` for dispatch.
- Release gates: fail on Quartus 332148 (timing) or 276007 (M10K inference) in reports; RBF ≥ 1,000,000 bytes; engine must be a 32-bit ARM ELF.
- Submodule URLs stay `git@github.com:` style — actions/checkout rewrites them to authenticated https during CI checkout (proven by gmloader-next's own CI, whose `3rdparty/mfgpu` submodule is SSH-URL).
- Game data (`mygame.apk`, `saves/`) is never bundled.
- All work in a dedicated worktree `../wt-release-ci`, branch `feat/release-ci` (concurrent-session rule: never `checkout -b` in the shared tree).

---

### Task 1: Worktree + maldita submodule

**Files:**
- Modify: `.gitmodules` (new entry)
- Create: `external/maldita.castilla-mister` (submodule at current origin/master)

**Interfaces:**
- Produces: `external/maldita.castilla-mister/` checkout used by Tasks 4–5 (paths `fpga/build_maldita.sh`, `games/Maldita Castilla/_handler.sh`).

- [ ] **Step 1: Create the worktree and initialize existing submodules**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git worktree add ../wt-release-ci -b feat/release-ci
cd ../wt-release-ci
git submodule update --init external/gmloader-next
```

Expected: worktree at `../wt-release-ci` on branch `feat/release-ci`; `external/gmloader-next` populated (contains `gmloader.json`, `3rdparty/gles2-sw/libGLES_sw.so`, `lib/armeabi-v7a/libstdc++.so`).

- [ ] **Step 2: Add the maldita submodule**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-release-ci
git submodule add git@github.com:gmcnaught/maldita.castilla-mister.git external/maldita.castilla-mister
git -C external/maldita.castilla-mister log --oneline -1
```

Expected: submodule cloned; HEAD is origin/master (Phase-3-merged, a723aa5 or later).

- [ ] **Step 3: Verify the files later tasks consume exist in the pin**

```bash
ls "external/maldita.castilla-mister/games/Maldita Castilla/_handler.sh" \
   external/maldita.castilla-mister/fpga/build_maldita.sh
```

Expected: both listed.

- [ ] **Step 4: Commit**

```bash
git add .gitmodules external/maldita.castilla-mister
git commit -m "feat(release): pin maldita.castilla-mister as third submodule"
```

---

### Task 2: Vendor the mesa GL runtime closure

**Files:**
- Create: `runtime/mesa/{libdrm.so.2, libEGL.so.1, libglapi.so.0, libGLESv2.so.2, swrast_dri.so}` (~13.5 MB total)
- Create: `runtime/README.md`

**Interfaces:**
- Produces: `runtime/mesa/*.so*` consumed by the assembly script (Task 4). `libstdc++.so` is NOT vendored — it is tracked in gmloader-next at `lib/armeabi-v7a/libstdc++.so`.

- [ ] **Step 1: Copy the known-good closure**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-release-ci
mkdir -p runtime/mesa
cp /Users/gmcnaught/MisterFPGA-Projects/epic-mister-sdl-buffer-output/games/gmloader/mesa/*.so* runtime/mesa/
ls -la runtime/mesa/
```

Expected: exactly 5 files — `libdrm.so.2` (~46 KB), `libEGL.so.1` (~142 KB), `libglapi.so.0` (~286 KB), `libGLESv2.so.2` (~55 KB), `swrast_dri.so` (~13 MB).

- [ ] **Step 2: Write runtime/README.md**

```markdown
# GL runtime closure (vendored)

The surfaceless-Mesa closure the gmloader engine needs at
`games/gmloader/mesa/` on-device (loaded via
`LD_LIBRARY_PATH=<gamedir>/mesa:<gamedir>`). Mesa is MIT-licensed.

Vendored 2026-07-30 from the known-good deploy tree
(`epic-mister-sdl-buffer-output/games/gmloader/mesa/`, the tree
`maldita.castilla-mister/deploy.py --with-runtime` pushes). These files are
armhf builds and rarely change; they were previously untracked in any repo.

Not vendored here (already tracked in the gmloader-next submodule):
- `libGLES_sw.so`      -> `3rdparty/gles2-sw/libGLES_sw.so`
- `libstdc++.so`       -> `lib/armeabi-v7a/libstdc++.so`
```

- [ ] **Step 3: Verify the files are armhf ELF**

```bash
file runtime/mesa/*.so* | grep -c "ELF 32-bit"
```

Expected: `5`

- [ ] **Step 4: Commit**

```bash
git add runtime/
git commit -m "feat(release): vendor surfaceless-Mesa GL runtime closure"
```

---

### Task 3: Bundle documentation files

**Files:**
- Create: `release/README.md` (bundle root README)
- Create: `release/APKs-README.txt`

**Interfaces:**
- Produces: `release/README.md` → bundle `README.md`; `release/APKs-README.txt` → bundle `games/gmloader/APKs/README.txt` (Task 4 copies them).

- [ ] **Step 1: Write release/README.md**

```markdown
# Maldita Castilla for MiSTer

FPGA-accelerated port of Locomalito's Maldita Castilla to the MiSTer
(DE10-Nano): a GameMaker loader (gmloader) on the ARM HPS drives a custom
FPGA blitter core.

## Install

1. Extract this zip over the root of your MiSTer SD card (`/media/fat/`).
   It adds:
   - `_Other/MalditaCastilla_YYYYMMDD.rbf` — the FPGA core
   - `games/Maldita Castilla/_handler.sh` — auto-launch dispatcher
   - `games/gmloader/` — the game engine + GL runtime
2. Add the game data (NOT included — see below).
3. Load **MalditaCastilla** from the MiSTer OSD (`_Other` menu).

## Game data (required, not included)

Get the free PortMaster release of Maldita Castilla and place:

- the APK at `games/gmloader/mygame.apk`
  (rename `malditacastilla.apk` to `mygame.apk`)
- game data at `games/gmloader/saves/game.droid` and
  `games/gmloader/saves/options.ini` (created on first run if your APK
  contains them)

`games/gmloader/APKs/README.txt` repeats these steps.

## Auto-launch dependency

Auto-launch on core load requires Frontier's **Master_Daemon** on the
device (it watches the loaded core's name and runs
`games/Maldita Castilla/_handler.sh`). Without it, the core loads but the
game will not start automatically.

## Troubleshooting

Manual launch over SSH (for debugging only — never run two engine
instances at once):

    cd /media/fat/games/gmloader
    export LD_LIBRARY_PATH=/media/fat/games/gmloader/mesa:/media/fat/games/gmloader
    ./gmloader -c gmloader.json

Verify file integrity against `sha256sums.txt` from the GitHub Release —
FAT can truncate files on interrupted copies.
```

- [ ] **Step 2: Write release/APKs-README.txt**

```text
Game data is NOT included in this bundle.

1. Get the free PortMaster release of Maldita Castilla.
2. Place the APK ONE LEVEL UP from this folder, at:
       games/gmloader/mygame.apk
   (rename malditacastilla.apk -> mygame.apk; gmloader.json's
   apk_path expects exactly "mygame.apk")
3. Game data lives at games/gmloader/saves/ (game.droid, options.ini).

See the bundle root README.md for full install steps.
```

- [ ] **Step 3: Commit**

```bash
git add release/
git commit -m "feat(release): bundle README + game-data placement docs"
```

---

### Task 4: Assembly script with manifest verification

**Files:**
- Create: `scripts/release/assemble_bundle.sh`

**Interfaces:**
- Consumes: `runtime/mesa/*.so*` (Task 2), `release/README.md` + `release/APKs-README.txt` (Task 3), submodule paths (Task 1).
- Produces: `assemble_bundle.sh <rbf> <engine> <out_dir> <version>` → `<out_dir>/MalditaCastilla-MiSTer-<version>.zip`, `<out_dir>/sha256sums.txt`, staged tree in `<out_dir>/bundle/`. Exit non-zero + `ASSEMBLE FAIL:` message on any gate/manifest failure. Task 5's workflow calls it with exactly this signature.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# assemble_bundle.sh -- stage, verify, and zip the Maldita Castilla MiSTer
# release bundle from a built RBF + engine plus the repo's pinned sources.
#
# Usage: assemble_bundle.sh <rbf> <engine> <out_dir> <version>
#   rbf      built _Other/MalditaCastilla_YYYYMMDD.rbf
#   engine   built armhf gmloader binary
#   out_dir  output dir (created); zip + sha256sums.txt + bundle/ land here
#   version  release version string (e.g. v1.0.0)
#
# The manifest check is exhaustive: any file missing from -- or unexpected
# in -- the staged tree fails the assembly. Run locally with stub inputs to
# test (see docs/superpowers/plans/2026-07-30-release-ci.md Task 4).
set -euo pipefail

[ $# -eq 4 ] || { echo "usage: $0 <rbf> <engine> <out_dir> <version>" >&2; exit 2; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RBF="$1"; ENGINE="$2"; OUT="$3"; VERSION="$4"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

GMNEXT="$REPO/external/gmloader-next"
MALDITA="$REPO/external/maldita.castilla-mister"

fail() { echo "ASSEMBLE FAIL: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# --- input gates -------------------------------------------------------------
[ -f "$RBF" ]    || fail "RBF not found: $RBF"
[ -f "$ENGINE" ] || fail "engine not found: $ENGINE"
RBF_SIZE=$(wc -c < "$RBF")
[ "$RBF_SIZE" -ge 1000000 ] || fail "RBF implausibly small ($RBF_SIZE bytes)"
file "$ENGINE" | grep "ELF 32-bit" | grep -q "ARM" \
    || fail "engine is not a 32-bit ARM ELF: $(file "$ENGINE")"

# --- stage the SD-card tree --------------------------------------------------
BUNDLE="$OUT/bundle"
rm -rf "$BUNDLE"
GMDIR="$BUNDLE/games/gmloader"
mkdir -p "$BUNDLE/_Other" "$BUNDLE/games/Maldita Castilla" \
         "$GMDIR/mesa" "$GMDIR/lib/armeabi-v7a" "$GMDIR/APKs"

cp "$RBF" "$BUNDLE/_Other/"
cp "$MALDITA/games/Maldita Castilla/_handler.sh" "$BUNDLE/games/Maldita Castilla/"
cp "$ENGINE" "$GMDIR/gmloader"; chmod +x "$GMDIR/gmloader"
cp "$GMNEXT/gmloader.json" "$GMDIR/"
cp "$GMNEXT/3rdparty/gles2-sw/libGLES_sw.so" "$GMDIR/"
cp "$REPO/runtime/mesa/"*.so* "$GMDIR/mesa/"
cp "$GMNEXT/lib/armeabi-v7a/libstdc++.so" "$GMDIR/lib/armeabi-v7a/"
cp "$REPO/release/APKs-README.txt" "$GMDIR/APKs/README.txt"
cp "$REPO/release/README.md" "$BUNDLE/README.md"

# --- exhaustive manifest check ----------------------------------------------
RBF_NAME=$(basename "$RBF")
EXPECTED=$(cat <<EOF
README.md
_Other/$RBF_NAME
games/Maldita Castilla/_handler.sh
games/gmloader/APKs/README.txt
games/gmloader/gmloader
games/gmloader/gmloader.json
games/gmloader/lib/armeabi-v7a/libstdc++.so
games/gmloader/libGLES_sw.so
games/gmloader/mesa/libEGL.so.1
games/gmloader/mesa/libGLESv2.so.2
games/gmloader/mesa/libdrm.so.2
games/gmloader/mesa/libglapi.so.0
games/gmloader/mesa/swrast_dri.so
EOF
)
ACTUAL=$(cd "$BUNDLE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
if [ "$ACTUAL" != "$(printf '%s\n' "$EXPECTED" | LC_ALL=C sort)" ]; then
    echo "--- expected ---" >&2; printf '%s\n' "$EXPECTED" | LC_ALL=C sort >&2
    echo "--- actual ---" >&2;   printf '%s\n' "$ACTUAL" >&2
    fail "bundle manifest mismatch"
fi

# --- zip + checksums ---------------------------------------------------------
ZIP="$OUT/MalditaCastilla-MiSTer-$VERSION.zip"
rm -f "$ZIP"
(cd "$BUNDLE" && zip -r -q "$ZIP" .)
(cd "$BUNDLE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort \
    | while IFS= read -r f; do sha "$f"; done) > "$OUT/sha256sums.txt"
(cd "$OUT" && sha "$(basename "$ZIP")") >> "$OUT/sha256sums.txt"

echo "OK: $ZIP ($(wc -c < "$ZIP") bytes, $(printf '%s\n' "$ACTUAL" | wc -l | tr -d ' ') files)"
```

```bash
chmod +x scripts/release/assemble_bundle.sh
```

- [ ] **Step 2: Failure test — undersized RBF must be rejected**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-release-ci
mkdir -p /tmp/relci
dd if=/dev/zero of=/tmp/relci/MalditaCastilla_20260730.rbf bs=1024 count=10 2>/dev/null
bash scripts/release/assemble_bundle.sh /tmp/relci/MalditaCastilla_20260730.rbf \
    external/gmloader-next/games/gmloader/gmloader /tmp/relci/out vtest; echo "exit=$?"
```

Expected: `ASSEMBLE FAIL: RBF implausibly small (10240 bytes)` and `exit=1`.
(Uses the ARM binary committed in the gmloader-next submodule as the engine input.)

- [ ] **Step 3: Success test — full assembly from stubs + pinned sources**

```bash
dd if=/dev/zero of=/tmp/relci/MalditaCastilla_20260730.rbf bs=1024 count=2048 2>/dev/null
bash scripts/release/assemble_bundle.sh /tmp/relci/MalditaCastilla_20260730.rbf \
    external/gmloader-next/games/gmloader/gmloader /tmp/relci/out vtest
unzip -l /tmp/relci/out/MalditaCastilla-MiSTer-vtest.zip
cat /tmp/relci/out/sha256sums.txt
```

Expected: `OK: … 13 files`; unzip listing shows the 13-file manifest; sha256sums.txt has 14 lines (13 files + zip).

- [ ] **Step 4: Manifest-mismatch test — extra file must fail**

```bash
touch /tmp/relci/out/bundle/games/gmloader/stray.txt || true
# Re-run stages fresh (rm -rf bundle), so instead test by removing a source:
mv release/APKs-README.txt /tmp/relci/APKs-README.txt.bak
bash scripts/release/assemble_bundle.sh /tmp/relci/MalditaCastilla_20260730.rbf \
    external/gmloader-next/games/gmloader/gmloader /tmp/relci/out vtest; echo "exit=$?"
mv /tmp/relci/APKs-README.txt.bak release/APKs-README.txt
```

Expected: `cp` fails (set -e) or `ASSEMBLE FAIL: bundle manifest mismatch`; `exit=1`.

- [ ] **Step 5: Commit**

```bash
git add scripts/release/assemble_bundle.sh
git commit -m "feat(release): bundle assembly script with exhaustive manifest gate"
```

---

### Task 5: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `scripts/release/assemble_bundle.sh <rbf> <engine> <out_dir> <version>` (Task 4), submodule pins (Task 1), `external/maldita.castilla-mister/fpga/build_maldita.sh` (emits `../_Other/MalditaCastilla_YYYYMMDD.rbf`), `external/gmloader-next/.github/scripts/build_mister_arm.sh` (expects repo mounted at `/src`, emits `games/gmloader/gmloader`).

- [ ] **Step 1: Write .github/workflows/release.yml**

```yaml
name: Release

# Tag-triggered production release of the Maldita Castilla MiSTer port.
# Design: docs/superpowers/specs/2026-07-30-release-ci-design.md
#
#   push v* tag        -> build RBF + engine from submodule pins, assemble the
#                         SD-card bundle, publish a GitHub Release.
#   workflow_dispatch  -> dry run: same builds + assembly, uploads the bundle
#                         as a CI artifact, does NOT publish a release.
#
# Submodule URLs are SSH-style; actions/checkout rewrites them to
# authenticated https (same mechanism gmloader-next's own CI relies on).

on:
  push:
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: write

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build-rbf:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Free disk space (Quartus needs ~24 GB)
        uses: jlumbroso/free-disk-space@main
        with:
          tool-cache: true
          android: true
          dotnet: true
          haskell: true
          large-packages: true
          swap-storage: true

      - name: Compile RBF (Quartus Lite 17.0 in Docker)
        run: |
          # Non-login bash -c keeps the image's Quartus PATH (see the maldita
          # repo's build-rbf.yml Linux job, which this mirrors).
          docker run --rm -v "$PWD:/build" raetro/quartus:17.0 \
            bash -c "cd /build/external/maldita.castilla-mister/fpga && bash build_maldita.sh ../_Other"

      - name: Production gates (timing 332148 / M10K 276007)
        run: |
          cd external/maldita.castilla-mister/fpga
          # Reports must exist -- a silent no-report pass is not a pass.
          ls output_files/Maldita.map.rpt output_files/Maldita.sta.rpt
          if grep -l "332148" build_*.log sta_*.log output_files/*.sta.rpt 2>/dev/null; then
            echo "::error::Timing gate failed: setup violation (Critical Warning 332148)"
            exit 1
          fi
          if grep -l "276007" output_files/*.map.rpt 2>/dev/null; then
            echo "::error::M10K gate failed: uninferred ramstyle array (map.rpt 276007)"
            exit 1
          fi
          ls -lh ../_Other/MalditaCastilla_*.rbf

      - name: Upload Quartus reports
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: quartus-reports
          path: |
            external/maldita.castilla-mister/fpga/output_files/*.rpt
            external/maldita.castilla-mister/fpga/output_files/*.summary
            external/maldita.castilla-mister/fpga/build_*.log
            external/maldita.castilla-mister/fpga/sta_*.log
          if-no-files-found: warn

      - name: Upload RBF
        uses: actions/upload-artifact@v4
        with:
          name: maldita-rbf
          path: external/maldita.castilla-mister/_Other/MalditaCastilla_*.rbf
          if-no-files-found: error

  build-engine:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3
        with:
          platforms: arm

      - name: Build ARM engine in container
        run: |
          # build_mister_arm.sh expects the gmloader-next checkout at /src.
          # It does not run git, so mounting only the submodule dir is safe.
          docker run --rm --platform linux/arm/v7 \
            -v "$PWD/external/gmloader-next:/src" -w /src \
            arm32v7/debian:bullseye-slim \
            bash .github/scripts/build_mister_arm.sh

      - name: Engine sanity (32-bit ARM ELF)
        run: |
          file external/gmloader-next/games/gmloader/gmloader | tee /dev/stderr \
            | grep "ELF 32-bit" | grep -q "ARM"

      - name: Upload engine
        uses: actions/upload-artifact@v4
        with:
          name: gmloader-engine
          path: external/gmloader-next/games/gmloader/gmloader
          if-no-files-found: error

  assemble-release:
    needs: [build-rbf, build-engine]
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - uses: actions/download-artifact@v4
        with:
          name: maldita-rbf
          path: dist/rbf

      - uses: actions/download-artifact@v4
        with:
          name: gmloader-engine
          path: dist/engine

      - name: Assemble bundle
        run: |
          VERSION="${GITHUB_REF_NAME}"
          if [ "${GITHUB_EVENT_NAME}" = "workflow_dispatch" ]; then
            VERSION="dryrun-${GITHUB_RUN_NUMBER}"
          fi
          echo "VERSION=$VERSION" >> "$GITHUB_ENV"
          RBF=$(ls dist/rbf/MalditaCastilla_*.rbf)
          bash scripts/release/assemble_bundle.sh "$RBF" dist/engine/gmloader dist/out "$VERSION"

      - name: Write provenance notes
        run: |
          {
            echo "## Provenance"
            echo '```'
            echo "mister-gmloader: ${GITHUB_SHA}"
            git submodule status
            echo "fpga tree hash: $(git -C external/maldita.castilla-mister rev-parse HEAD:fpga)"
            echo '```'
            echo ""
            echo "Game data (mygame.apk, saves/) is user-provided -- see the bundle README.md."
          } > dist/notes.md
          cat dist/notes.md

      - name: Publish GitHub Release (tag only)
        if: startsWith(github.ref, 'refs/tags/v')
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${GITHUB_REF_NAME}" \
            "dist/out/MalditaCastilla-MiSTer-${VERSION}.zip" \
            dist/rbf/MalditaCastilla_*.rbf \
            dist/out/sha256sums.txt \
            --title "Maldita Castilla MiSTer ${GITHUB_REF_NAME}" \
            --notes-file dist/notes.md

      - name: Upload dry-run bundle (dispatch only)
        if: github.event_name == 'workflow_dispatch'
        uses: actions/upload-artifact@v4
        with:
          name: release-bundle-${{ env.VERSION }}
          path: |
            dist/out/MalditaCastilla-MiSTer-*.zip
            dist/out/sha256sums.txt
          if-no-files-found: error
```

- [ ] **Step 2: Lint the workflow YAML locally**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-release-ci
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
```

Expected: `YAML OK`. (actionlint is not installed; real validation is the Task 6 dry run.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat(release): tag-triggered release workflow (RBF + engine + bundle)"
```

---

### Task 6: PR, merge, CI dry run

**Files:** none new (integration).

- [ ] **Step 1: Push the branch and open a PR**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-release-ci
git push -u origin feat/release-ci
gh pr create --title "Release CI: tag-triggered install-bundle pipeline" \
  --body "Implements docs/superpowers/specs/2026-07-30-release-ci-design.md: third submodule (maldita.castilla-mister), vendored mesa runtime, bundle docs, assembly script with manifest gate, and .github/workflows/release.yml (v* tag -> GitHub Release; workflow_dispatch -> dry-run artifact)."
```

- [ ] **Step 2: Merge the PR** (workflow_dispatch needs the workflow on the default branch)

```bash
gh pr merge --merge
```

- [ ] **Step 3: Dispatch the dry run**

```bash
gh workflow run release.yml --repo gmcnaught/mister-gmloader
sleep 10
gh run list --repo gmcnaught/mister-gmloader --workflow=release.yml --limit 1
```

Expected: a queued/in-progress run. The `build-rbf` job takes ~60–90 min (hosted-runner Quartus in Docker) — monitor in the background, report progress.

- [ ] **Step 4: Verify the dry-run output**

```bash
RUN=$(gh run list --repo gmcnaught/mister-gmloader --workflow=release.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN" --repo gmcnaught/mister-gmloader --exit-status
gh run download "$RUN" --repo gmcnaught/mister-gmloader -n "release-bundle-dryrun-1" -D /tmp/relci/ci-out
unzip -l /tmp/relci/ci-out/MalditaCastilla-MiSTer-dryrun-1.zip
```

Expected: run concludes success; downloaded zip lists the 13-file manifest with a real (multi-MB) `MalditaCastilla_YYYYMMDD.rbf`.

- [ ] **Step 5: Update the shared checkout**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git pull --ff-only
git worktree remove ../wt-release-ci
```

---

## Self-review notes

- Spec coverage: §1 repo changes → Tasks 1–2; §2 workflow → Task 5; §3 bundle/naming → Tasks 3–4; §4 gates → Task 4 (RBF size, engine ELF) + Task 5 (332148, 276007, if-no-files-found); §5 Master_Daemon dependency → Task 3 README; error handling → Task 4 manifest + Task 5 concurrency/timeouts; testing → Task 4 local tests + Task 6 dry run. Device smoke test is post-release, manual (spec).
- Type consistency: `assemble_bundle.sh <rbf> <engine> <out_dir> <version>` signature identical in Task 4 and Task 5's workflow call.
