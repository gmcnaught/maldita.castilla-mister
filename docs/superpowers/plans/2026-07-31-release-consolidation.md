# Release Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire `mister-gmloader`, moving the Maldita Castilla MiSTer release into `maldita.castilla-mister` (the core's own repo) with `gmloader-next` pinned as its single submodule.

**Architecture:** Three repos become two. `gmloader-next` absorbs the GL runtime closure (an engine dependency) and gains a link-parity check. `maldita.castilla-mister` absorbs the release workflow, release assets, bench tooling, all project docs, and pins `gmloader-next` at `external/gmloader-next`. The release resolves an already-gated, device-validated RBF artifact by `fpga/` tree hash rather than rebuilding one.

**Tech Stack:** GitHub Actions, Docker (QEMU armhf + `raetro/quartus:17.0`), Python 3 stdlib only (`deploy.py`, `unittest` — no test dependencies), Bash, GNU Make, `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-07-31-release-consolidation-design.md`

## Global Constraints

- **Worktree:** all `maldita.castilla-mister` work happens in `/Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release` on branch `chore/release-consolidation`. Never `git checkout -b` in the shared checkout — concurrent sessions run on it.
- **`gmloader-next` work** needs its own worktree, created in Task 1. The plain `../gmloader-next` clone is often stale.
- **No device work.** No task in this plan touches `192.168.20.62` or `192.168.20.81`. Devices are shared with concurrent agents.
- **The existing release path must keep working** until Task 12. Task 1 and Task 2 must not break `mister-gmloader`'s `release.yml`.
- **Fail closed.** Every gate added here must refuse on missing evidence rather than pass silently. A missing report is a failure, not a pass.
- **Exact literals** used throughout, copied from the spec:
  - Quartus gate IDs: `332148` (setup violation), `276007` (uninferred `ramstyle` array)
  - Known-benign `276007` file: `ddr_blitter_arb.sv`
  - RBF artifact name: `maldita-rbf`; workflow: `build-rbf.yml`
  - Engine link-check symbol: `NativeVideoWriter_WriteFrame` (non-static, in `gmloader/mister/native_video_writer.c`)
  - Test device default `192.168.20.62`; production `192.168.20.81` requires `PROD=1`
  - Core name (must match `fpga/Maldita.sv:270` exactly, including the space): `Maldita Castilla`

## File Structure

**Created in `gmloader-next`:**
- `runtime/mesa/*.so` (5 files, moved), `runtime/README.md` (moved)

**Modified in `gmloader-next`:**
- `.github/scripts/build_mister_arm.sh` — link-parity check before strip

**Created in `maldita.castilla-mister`:**
- `scripts/lib/resolve_rbf.py` — tree-hash RBF resolution, shared by `deploy.py` and the release workflow
- `scripts/tests/test_resolve_rbf.py` — its tests
- `scripts/tests/test_check_quartus_gates.sh`, `scripts/tests/test_assemble_bundle.sh`
- `fpga/scripts/check_quartus_gates.sh` — the gate logic both `build-rbf.yml` jobs call
- `.github/workflows/release.yml` — moved and rewritten
- `scripts/release/assemble_bundle.sh` — moved, paths rebased
- `release/README.md`, `release/APKs-README.txt` — moved
- `Makefile`, `LICENSE` — moved
- `README.md` — rewritten for the two-repo layout
- `docs/superpowers/**` (86 files), `docs/architecture/**` (9 files), `bench-results/**` (25 files) — moved
- `scripts/check_arch_docs.sh`, `scripts/mister_run.sh`, `scripts/gmloader_diag.sh`, `scripts/mftrace_analyze.py`, `scripts/lib/*.sh` (4), `scripts/scenes/*.joy` (2) — moved
- `.gitmodules` — new, one entry

**Modified in `maldita.castilla-mister`:**
- `.github/workflows/build-rbf.yml` — gate step in both jobs
- `deploy.py` — engine path prefers the submodule; `fetch_rbf_for_head` delegates to `resolve_rbf.py`

**Repo test conventions — follow them, do not introduce new ones:**
- Tests live in `scripts/tests/`, alongside `test_wire_constants.py` and the
  eight `test_*.sh` files already there.
- Python tests are **dependency-free**. `test_wire_constants.py` states "Pure
  regex, no deps" and signals via `exit 0` / `exit 1`. `pytest` is **not
  installed** for this repo's `python3` — use stdlib `unittest`.
- Note `scripts/tests/test_ast_grep_ramstyle.sh` already exists: the `ast-grep`
  HDL lint catches a `ramstyle` array read nested in an FSM case arm at
  **source** level. The `276007` gate added here is the **build-report**
  complement — it catches the same class of defect after synthesis, including
  causes the source lint cannot see. They are not redundant.

**Deleted from `mister-gmloader`:** everything, then the repo is archived.

---

### Task 1: Move the Mesa closure into gmloader-next

**Files:**
- Create worktree: `/Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release`
- Move: `mister-gmloader/runtime/mesa/{libEGL.so.1,libGLESv2.so.2,libglapi.so.0,libdrm.so.2,swrast_dri.so}` → `gmloader-next/runtime/mesa/`
- Move: `mister-gmloader/runtime/README.md` → `gmloader-next/runtime/README.md`

**Interfaces:**
- Produces: `runtime/mesa/` inside the `gmloader-next` checkout. Task 8's `assemble_bundle.sh` sources Mesa from `$GMNEXT/runtime/mesa/`.

- [ ] **Step 1: Create the gmloader-next worktree**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git fetch origin
git worktree add ../wt-gmloader-release -b chore/vendor-mesa-runtime origin/master
```

- [ ] **Step 2: Copy the five Mesa libraries and the README in**

`git mv` cannot cross repositories, so history for these binaries does not
follow. That is acceptable: they are vendored third-party build outputs with no
meaningful per-file history.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release
mkdir -p runtime/mesa
cp /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/runtime/mesa/*.so* runtime/mesa/
cp /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/runtime/README.md runtime/README.md
ls -1 runtime/mesa/
```

Expected output — exactly these five names:

```
libEGL.so.1
libGLESv2.so.2
libdrm.so.2
libglapi.so.0
swrast_dri.so
```

- [ ] **Step 3: Verify the copies are byte-identical to the originals**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release
for f in runtime/mesa/*.so*; do
  b=$(basename "$f")
  a=$(shasum -a 256 "$f" | cut -d' ' -f1)
  o=$(shasum -a 256 "/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/runtime/mesa/$b" | cut -d' ' -f1)
  [ "$a" = "$o" ] && echo "OK   $b" || { echo "FAIL $b"; exit 1; }
done
```

Expected: five `OK` lines, exit 0.

- [ ] **Step 4: Confirm these files are not excluded by .gitignore**

A vendored `.so` is exactly the kind of file a build-artifact ignore rule
silently swallows. Check before committing.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release
git check-ignore -v runtime/mesa/*.so* || echo "NOT IGNORED (good)"
```

Expected: `NOT IGNORED (good)`. If any path is listed, add a negation to
`.gitignore` (e.g. `!runtime/mesa/`) before continuing.

- [ ] **Step 5: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release
git add runtime/
git commit -m "feat(runtime): vendor the surfaceless Mesa GL closure

These five .so files are engine runtime dependencies — without
LD_LIBRARY_PATH pointing at them the engine dies at eglInitialize before any
game code runs. They belong beside 3rdparty/gles2-sw/libGLES_sw.so and
lib/armeabi-v7a/libstdc++.so rather than in the bundling repo, so the release
can source every non-RBF file from one place.

Moved from mister-gmloader/runtime/mesa/ as part of the release
consolidation (docs/superpowers/specs/2026-07-31-release-consolidation-design.md
in maldita.castilla-mister)."
```

---

### Task 2: Add the engine link-parity check to build_mister_arm.sh

**Files:**
- Modify: `gmloader-next/.github/scripts/build_mister_arm.sh` (the `=== Stripping binary ===` section)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `build_mister_arm.sh` fails the build when `MISTER_BUILD=1` did not take effect.

**Why this symbol:** `NativeVideoWriter_WriteFrame` is a non-static C function in
`gmloader/mister/native_video_writer.c`, which `Makefile.gmloader` compiles only
under `MISTER_BUILD=1` (it is the first entry in `MISTER_SRCS`,
`Makefile.gmloader:153`). If the flag is lost, the binary still links and still
runs — it simply has no fabric video path. `mf_frame_end` cannot be used: it is
`static` in `raster_backend_mfgpu.cpp:2460` and never reaches the symbol table.
The check must run **before** `${ARCH}-strip`, which removes the symbol.

- [ ] **Step 1: Write the failing check as a standalone assertion**

Add this block to `build_mister_arm.sh` immediately **before** the
`echo "=== Stripping binary ==="` line:

```bash
echo "=== Verifying MISTER_BUILD linkage ==="
# NativeVideoWriter_WriteFrame is a non-static symbol from
# gmloader/mister/native_video_writer.c, compiled ONLY when MISTER_BUILD=1
# (Makefile.gmloader:149-155). If MISTER_BUILD is ever lost, the binary still
# links and still runs — it just has no fabric video path at all, which is a
# silent, plausible-looking failure. Assert it positively, before the strip
# below removes the symbol table.
if ! ${ARCH}-nm "${BINARY}" | grep -q ' T NativeVideoWriter_WriteFrame'; then
    echo "ERROR: NativeVideoWriter_WriteFrame not found in ${BINARY}." >&2
    echo "       MISTER_BUILD=1 did not take effect — this binary has no" >&2
    echo "       MiSTer video path and must not be shipped." >&2
    exit 1
fi
echo "OK: MiSTer sources linked (NativeVideoWriter_WriteFrame present)"
```

- [ ] **Step 2: Verify the check fires on a binary built WITHOUT MISTER_BUILD**

This proves the gate is not vacuous. Build a non-MiSTer binary and confirm the
symbol is absent.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release
docker run --rm --platform linux/arm/v7 -v "$PWD:/src" -w /src \
  arm32v7/debian:bullseye-slim bash -c '
    apt-get update -qq && apt-get install -y -qq binutils-arm-linux-gnueabihf >/dev/null
    # Use an object file rather than a full link: the point is only that the
    # symbol comes from a MISTER_BUILD-only translation unit.
    arm-linux-gnueabihf-nm build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf \
      | grep -c NativeVideoWriter_WriteFrame'
```

Expected: if a MiSTer binary is present, count `>= 1`. If no build exists yet,
skip to Step 3 — CI in Step 4 exercises the positive case.

- [ ] **Step 3: Verify the check passes on a real MISTER_BUILD=1 binary**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release
docker run --rm --platform linux/arm/v7 -v "$PWD:/src" -w /src \
  arm32v7/debian:bullseye-slim bash .github/scripts/build_mister_arm.sh 2>&1 | tail -20
```

Expected: the output contains `OK: MiSTer sources linked (NativeVideoWriter_WriteFrame present)`
before `=== Stripping binary ===`, and the script exits 0.

This build takes roughly 30–45 minutes under QEMU. Run it in the background and
check back; do not let it be killed by a turn ending.

- [ ] **Step 4: Commit and push**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release
git add .github/scripts/build_mister_arm.sh
git commit -m "ci: assert MISTER_BUILD linkage before stripping the engine

MISTER_BUILD=1 sets -DMISTER_NATIVE_VIDEO=1 -DMISTER_WIDTH=288
-DMISTER_HEIGHT=216 and pulls in MISTER_SRCS. If it is ever lost the binary
still links and still runs, just with no fabric video path — a silent failure
no size or md5 check can see.

Assert it positively via NativeVideoWriter_WriteFrame, a non-static symbol
from a MISTER_BUILD-only translation unit. Runs before ${ARCH}-strip, which
would remove it. mf_frame_end is unusable here: it is static."
git push -u origin chore/vendor-mesa-runtime
```

- [ ] **Step 5: Open and merge the PR, then bump the pin in mister-gmloader**

The existing release path must keep working through this task.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-release
gh pr create --title "Vendor Mesa runtime closure + assert MISTER_BUILD linkage" \
  --body "Prep for the release consolidation: the GL runtime closure moves here from mister-gmloader, and build_mister_arm.sh gains a positive link check that MISTER_BUILD=1 took effect.

Part of maldita.castilla-mister docs/superpowers/specs/2026-07-31-release-consolidation-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01MukLwFMCfEUpLg4JMSBdoj"
```

After merge, update the submodule pin so the old workflow still resolves:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/external/gmloader-next
git fetch origin && git checkout origin/master
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git add external/gmloader-next
git commit -m "chore: bump gmloader-next pin for the vendored Mesa closure"
```

---

### Task 3: Extract the Quartus gate into a shared script

**Files:**
- Create: `fpga/scripts/check_quartus_gates.sh`
- Create: `scripts/tests/test_check_quartus_gates.sh` (repo convention — tests live in `scripts/tests/`)

**Interfaces:**
- Produces: `check_quartus_gates.sh <output_files_dir> <logs_dir>` — exits 0 when the build passes both gates, 1 otherwise. Task 4 calls it from both `build-rbf.yml` jobs.

**Why a script rather than inline YAML:** the same logic runs in two jobs on two
different operating systems, and it must be testable without triggering a
two-hour Quartus build.

**The allowlist:** `276007` currently fires on `ddr_blitter_arb.sv` and is known
benign. It is allowlisted **by name**, so a `276007` on any other file still
fails. This preserves the standing rule that a `ramstyle` array's read must
never be nested in an FSM case arm.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test_check_quartus_gates.sh`:

```bash
#!/usr/bin/env bash
# Tests for fpga/scripts/check_quartus_gates.sh. Builds synthetic report
# fixtures in a temp dir — no Quartus required. Pure bash, no deps, exit 0/1,
# matching the other scripts/tests/test_*.sh files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$(cd "$HERE/../.." && pwd)/fpga/scripts/check_quartus_gates.sh"
PASS=0; FAIL=0

run_case() {
    local name="$1" want="$2"; shift 2
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/output_files" "$tmp/logs"
    "$@" "$tmp"
    bash "$GATE" "$tmp/output_files" "$tmp/logs" >"$tmp/out" 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        echo "PASS  $name (exit $got)"; PASS=$((PASS+1))
    else
        echo "FAIL  $name (want exit $want, got $got)"; sed 's/^/      /' "$tmp/out"; FAIL=$((FAIL+1))
    fi
    rm -rf "$tmp"
}

fixture_clean() {
    printf 'Fitter completed\n' > "$1/output_files/Maldita.map.rpt"
    printf 'Timing analysis OK\n' > "$1/output_files/Maldita.sta.rpt"
    printf 'build ok\n' > "$1/logs/build_maldita.log"
    printf 'sta ok\n' > "$1/logs/sta_maldita.log"
}

fixture_missing_map() {
    fixture_clean "$1"; rm -f "$1/output_files/Maldita.map.rpt"
}

fixture_timing_violation() {
    fixture_clean "$1"
    printf 'Critical Warning (332148): Timing requirements not met\n' \
        >> "$1/output_files/Maldita.sta.rpt"
}

fixture_m10k_new_file() {
    fixture_clean "$1"
    printf 'Warning (276007): Inferred RAM node from tq_data in file blitter_top.sv\n' \
        >> "$1/output_files/Maldita.map.rpt"
}

fixture_m10k_allowlisted() {
    fixture_clean "$1"
    printf 'Warning (276007): Inferred RAM node in file ddr_blitter_arb.sv\n' \
        >> "$1/output_files/Maldita.map.rpt"
}

fixture_m10k_both() {
    fixture_m10k_allowlisted "$1"
    printf 'Warning (276007): Inferred RAM node in file blitter_top.sv\n' \
        >> "$1/output_files/Maldita.map.rpt"
}

run_case "clean build passes"                    0 fixture_clean
run_case "missing map.rpt fails"                 1 fixture_missing_map
run_case "332148 timing violation fails"         1 fixture_timing_violation
run_case "276007 on a new file fails"            1 fixture_m10k_new_file
run_case "276007 on ddr_blitter_arb.sv passes"   0 fixture_m10k_allowlisted
run_case "allowlisted plus new file still fails" 1 fixture_m10k_both

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

Make it executable: `chmod +x scripts/tests/test_check_quartus_gates.sh`

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
bash scripts/tests/test_check_quartus_gates.sh
```

Expected: every case FAILs (the gate script does not exist yet), final line
`0 passed, 6 failed`, exit 1.

- [ ] **Step 3: Write the gate script**

Create `fpga/scripts/check_quartus_gates.sh`:

```bash
#!/usr/bin/env bash
# check_quartus_gates.sh -- production gates for a Quartus build of Maldita.
#
# Usage: check_quartus_gates.sh <output_files_dir> <logs_dir>
#
# Exits 0 only when BOTH gates pass. Fails closed: a missing report is a
# failure, never a silent pass, because a build that produced no report is
# exactly the case a naive grep would wave through.
#
#   332148  setup timing violation. Any hit fails.
#   276007  an array carrying a `ramstyle` attribute did not infer to M10K.
#           When this fires the array becomes thousands of stray flops behind a
#           huge mux and timing collapses (see the 2026-07-29 tq_data
#           regression: -0.983 ns, ALMs 61%). Any hit fails EXCEPT the
#           reviewed, known-benign case listed in M10K_ALLOWLIST below.
set -uo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <output_files_dir> <logs_dir>" >&2; exit 2; }
OUT="$1"; LOGS="$2"

# Files whose 276007 hit has been reviewed and accepted. Named individually on
# purpose: a blanket skip would also hide the NEXT regression, which is the
# failure mode this gate exists to catch.
#
#   ddr_blitter_arb.sv -- pre-existing, reviewed 2026-07-31. Predates the gate;
#                         not introduced by any Phase 4 work.
M10K_ALLOWLIST="ddr_blitter_arb.sv"

fail() { echo "::error::$*"; echo "GATE FAIL: $*" >&2; exit 1; }

# --- gate 0: the reports must exist ------------------------------------------
for r in "$OUT/Maldita.map.rpt" "$OUT/Maldita.sta.rpt"; do
    [ -f "$r" ] || fail "required report missing: $r (a build with no report is not a pass)"
done

# --- gate 1: setup timing (332148) -------------------------------------------
TIMING_HITS=$(grep -l "332148" "$OUT"/*.sta.rpt "$LOGS"/build_*.log "$LOGS"/sta_*.log 2>/dev/null || true)
if [ -n "$TIMING_HITS" ]; then
    echo "--- 332148 hits ---" >&2
    grep -h "332148" "$OUT"/*.sta.rpt "$LOGS"/build_*.log "$LOGS"/sta_*.log 2>/dev/null >&2 || true
    fail "timing gate: setup violation (Critical Warning 332148) in: $(echo "$TIMING_HITS" | tr '\n' ' ')"
fi

# --- gate 2: M10K inference (276007) -----------------------------------------
M10K_LINES=$(grep -h "276007" "$OUT"/*.map.rpt 2>/dev/null || true)
if [ -n "$M10K_LINES" ]; then
    UNEXPECTED=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        allowed=0
        for f in $M10K_ALLOWLIST; do
            case "$line" in *"$f"*) allowed=1; break;; esac
        done
        [ "$allowed" -eq 1 ] || UNEXPECTED="$UNEXPECTED$line
"
    done <<< "$M10K_LINES"
    if [ -n "$UNEXPECTED" ]; then
        echo "--- unexpected 276007 hits ---" >&2
        printf '%s' "$UNEXPECTED" >&2
        fail "M10K gate: uninferred ramstyle array (map.rpt 276007) outside the allowlist. A ramstyle array's read must never be nested in an FSM case arm."
    fi
    echo "note: 276007 present only on allowlisted files ($M10K_ALLOWLIST) -- accepted"
fi

echo "OK: both production gates passed (332148 clean, 276007 within allowlist)"
```

Make it executable: `chmod +x fpga/scripts/check_quartus_gates.sh`

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
bash scripts/tests/test_check_quartus_gates.sh
```

Expected: six `PASS` lines, final line `6 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git add fpga/scripts/check_quartus_gates.sh scripts/tests/test_check_quartus_gates.sh
git commit -m "feat(fpga): extract the production gates into a tested script

build-rbf.yml has never had the 332148/276007 gates — they lived only in
mister-gmloader's release.yml, which is the step its single run failed on. So
every RBF artifact CI has published so far is ungated.

Extract the logic into a script both build-rbf.yml jobs can call, with
fixture-driven tests that need no Quartus. 276007 is allowlisted by filename
(ddr_blitter_arb.sv) rather than skipped wholesale, so a NEW uninferred
ramstyle array still fails."
```

---

### Task 4: Wire the gate into both build-rbf.yml jobs

**Files:**
- Modify: `.github/workflows/build-rbf.yml` — insert a step in `build-windows` (after `Upload Quartus reports`, before `Show result`) and the same in `build-linux`

**Interfaces:**
- Consumes: `fpga/scripts/check_quartus_gates.sh` from Task 3.
- Produces: `build-rbf.yml` runs whose `maldita-rbf` artifact is provably gated. Task 6's `resolve_rbf.py` relies on `conclusion == "success"` meaning "gated".

**Placement matters:** the gate goes *after* the report upload (so reports survive
for diagnosis when the gate fails) and *before* the RBF artifact upload (so a
failing build never publishes a bitstream).

- [ ] **Step 1: Add the gate step to build-windows**

In `.github/workflows/build-rbf.yml`, between the `Upload Quartus reports` step
(ends line 106) and the `Show result` step (line 108), insert:

```yaml
      - name: Production gates (timing 332148 / M10K 276007)
        # After the report upload so the reports survive for diagnosis when this
        # fails; before the RBF upload so a failing build never publishes a
        # bitstream. Until this existed, every artifact build-rbf.yml produced
        # was ungated.
        run: bash fpga/scripts/check_quartus_gates.sh fpga/output_files fpga
```

- [ ] **Step 2: Add the identical gate step to build-linux**

Between `Upload Quartus reports` (the `quartus-reports-linux` step, ends line
176) and `Show result` (line 178), insert the same block:

```yaml
      - name: Production gates (timing 332148 / M10K 276007)
        # Same gate as build-windows -- the fallback toolchain must not be a way
        # to ship an ungated bitstream.
        run: bash fpga/scripts/check_quartus_gates.sh fpga/output_files fpga
```

Note the logs live at `fpga/build_*.log` and `fpga/sta_*.log`, which is why the
second argument is `fpga` and not `fpga/output_files`.

- [ ] **Step 3: Verify the YAML parses and both jobs got the step**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/build-rbf.yml')); \
  jobs=d['jobs']; \
  [print(j, [s.get('name') for s in jobs[j]['steps']].count('Production gates (timing 332148 / M10K 276007)')) for j in jobs]"
```

Expected:

```
build-windows 1
build-linux 1
```

- [ ] **Step 4: Commit and push, then run the workflow for real**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git add .github/workflows/build-rbf.yml
git commit -m "ci(build-rbf): run the production gates before publishing the RBF

Placed after the report upload (reports survive a gate failure for diagnosis)
and before the RBF upload (a failing build never publishes a bitstream).
Applied to the Linux fallback too — the fallback toolchain must not be a way
to ship an ungated bitstream."
git push -u origin chore/release-consolidation
gh workflow run build-rbf.yml --ref chore/release-consolidation -f runner=windows
```

- [ ] **Step 5: Watch the run and confirm the gate PASSES on a real build**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
gh run watch "$(gh run list --workflow build-rbf.yml -L 1 --json databaseId -q '.[0].databaseId')"
```

Expected: the run succeeds (~11 min) and the gate step logs
`note: 276007 present only on allowlisted files (ddr_blitter_arb.sv) -- accepted`
followed by `OK: both production gates passed`.

If it instead fails on a `276007` hit for a file other than
`ddr_blitter_arb.sv`, **stop and report it** — that is a real RTL finding, not a
gate bug, and it must be triaged before the release can proceed.

- [ ] **Step 6: Prove the gate can fail on a real run**

A gate that has only ever passed is untested. Temporarily poison a report to
confirm the workflow actually goes red.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git checkout -b tmp/gate-negative-check
```

Add this step to `build-windows` immediately **before** the gate step:

```yaml
      - name: TEMPORARY negative check -- inject a fake 332148
        run: echo "Critical Warning (332148): injected by tmp/gate-negative-check" >> fpga/output_files/Maldita.sta.rpt
```

```bash
git commit -am "test: temporary 332148 injection to prove the gate fails"
git push -u origin tmp/gate-negative-check
gh workflow run build-rbf.yml --ref tmp/gate-negative-check -f runner=windows
gh run watch "$(gh run list --workflow build-rbf.yml -L 1 --json databaseId -q '.[0].databaseId')"
```

Expected: the run FAILS at the gate step with
`GATE FAIL: timing gate: setup violation (Critical Warning 332148)`, and **no**
`maldita-rbf` artifact is uploaded.

- [ ] **Step 7: Delete the temporary branch**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git checkout chore/release-consolidation
git push origin --delete tmp/gate-negative-check
git branch -D tmp/gate-negative-check
```

Record both run IDs (the passing one from Step 5 and the failing one from Step
6) in the PR description as the gate's evidence.

---

### Task 5: Add gmloader-next as a submodule of maldita

**Files:**
- Create: `.gitmodules`
- Create: `external/gmloader-next` (submodule pin)

**Interfaces:**
- Produces: `external/gmloader-next` inside the maldita checkout, at the merged Task 2 commit. Tasks 6, 8, and 9 all resolve paths through it.

- [ ] **Step 1: Add the submodule**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git submodule add -b master git@github.com:gmcnaught/gmloader-next.git external/gmloader-next
git submodule update --init --recursive external/gmloader-next
```

- [ ] **Step 2: Verify the pin includes the Task 1 and Task 2 work**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
ls -1 external/gmloader-next/runtime/mesa/
grep -c NativeVideoWriter_WriteFrame external/gmloader-next/.github/scripts/build_mister_arm.sh
```

Expected: the five Mesa `.so` names, and `1` or more for the grep. If either
fails, the submodule is pinned before the Task 2 merge — re-run
`git -C external/gmloader-next fetch origin && git -C external/gmloader-next checkout origin/master`.

- [ ] **Step 3: Confirm the other files the bundle needs are present**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release/external/gmloader-next
for f in gmloader.json 3rdparty/gles2-sw/libGLES_sw.so lib/armeabi-v7a/libstdc++.so; do
  [ -f "$f" ] && echo "OK   $f" || echo "MISSING $f"
done
```

Expected: three `OK` lines. These, plus `runtime/mesa/`, are every non-RBF file
the bundle takes from `gmloader-next`.

- [ ] **Step 4: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git add .gitmodules external/gmloader-next
git commit -m "chore: pin gmloader-next as this repo's engine submodule

The release publishes from here now, so the engine source must be reachable
from this checkout. This is the only submodule: the shipping blitter RTL is
the vendored copy in fpga/rtl/, so mister-fpga-blitter never enters the
release path."
```

---

### Task 6: Extract the RBF tree-hash resolver into a shared, tested module

**Files:**
- Create: `scripts/lib/resolve_rbf.py`
- Create: `scripts/tests/test_resolve_rbf.py`
- Modify: `deploy.py` — `fetch_rbf_for_head()` (lines 185-248) delegates to the new module

**Stdlib `unittest`, not pytest.** `pytest` is not installed for this repo's
`python3`, and `scripts/tests/test_wire_constants.py` is explicitly
dependency-free. Do not add a test dependency for this.

**Interfaces:**
- Consumes: nothing.
- Produces, importable from `scripts/lib/resolve_rbf.py`:
  - `fpga_tree(repo: Path, rev: str = "HEAD") -> str | None` — git tree hash of `fpga/` at `rev`
  - `list_successful_runs(workflow: str = "build-rbf.yml", limit: int = 60) -> list[dict]` — completed+successful runs, newest first, each with `databaseId` and `headSha`
  - `find_run_for_tree(repo: Path, want_tree: str, runs: list[dict]) -> dict | None` — first run whose `fpga/` tree matches
  - `resolve_run_id(repo: Path, rev: str = "HEAD", workflow: str = "build-rbf.yml") -> tuple[int, str, str]` — returns `(run_id, built_sha, want_tree)`, raises `RbfResolutionError` when nothing matches
  - `class RbfResolutionError(Exception)`
- Task 7's `release.yml` invokes `python3 scripts/lib/resolve_rbf.py --rev "$GITHUB_SHA" --json`.

**Why extract:** the same resolution rule must run in `deploy.py` and in the
release workflow. Reimplementing it in YAML would let the two drift, and this
rule is the only thing standing between a release and a stale bitstream.

**Why tree hash, not commit sha:** `build-rbf.yml` triggers only on `fpga/**`, so
a docs- or CI-only commit legitimately has no run of its own while the bitstream
from the last RTL commit remains exactly right. Gating on commit equality would
refuse those builds spuriously, which trains everyone to pass `--force` by
reflex and kills the gate.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test_resolve_rbf.py`:

```python
#!/usr/bin/env python3
# Tests for scripts/lib/resolve_rbf.py.
#
# No network and no gh: the run listing is injected. Real throwaway git repos
# are used rather than fake hashes, because the behaviour under test IS git's
# tree-hash semantics — a docs-only commit must not change fpga/'s tree, and an
# RTL change must. Faking that would test nothing.
#
# Stdlib unittest, no deps — same rule as test_wire_constants.py.
# Exit 0 = all pass; exit 1 = at least one failed.

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import resolve_rbf  # noqa: E402


def git(repo, *a, check=True):
    return subprocess.run(["git", "-C", str(repo), *a], check=check,
                          text=True, capture_output=True)


class ResolveRbfTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        subprocess.run(["git", "init", "-q", str(self.dir)], check=True)
        git(self.dir, "config", "user.email", "t@t.t")
        git(self.dir, "config", "user.name", "t")
        (self.dir / "fpga").mkdir()
        (self.dir / "fpga" / "rtl.sv").write_text("module a; endmodule\n")
        git(self.dir, "add", "-A")
        git(self.dir, "commit", "-qm", "rtl v1")

    def head_sha(self):
        return git(self.dir, "rev-parse", "HEAD").stdout.strip()

    def commit_docs_only(self):
        (self.dir / "README.md").write_text("docs\n")
        git(self.dir, "add", "-A")
        git(self.dir, "commit", "-qm", "docs")

    def commit_rtl_change(self):
        (self.dir / "fpga" / "rtl.sv").write_text("module b; endmodule\n")
        git(self.dir, "add", "-A")
        git(self.dir, "commit", "-qm", "rtl v2")

    # --- fpga_tree ---------------------------------------------------------
    def test_fpga_tree_is_stable_across_a_docs_only_commit(self):
        before = resolve_rbf.fpga_tree(self.dir)
        self.commit_docs_only()
        self.assertEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_fpga_tree_changes_when_rtl_changes(self):
        before = resolve_rbf.fpga_tree(self.dir)
        self.commit_rtl_change()
        self.assertNotEqual(resolve_rbf.fpga_tree(self.dir), before)

    def test_fpga_tree_returns_none_for_a_non_repo(self):
        self.assertIsNone(resolve_rbf.fpga_tree(self.dir / "nope"))

    # --- find_run_for_tree -------------------------------------------------
    def test_matches_the_build_for_an_unchanged_fpga_tree(self):
        rtl_sha = self.head_sha()
        self.commit_docs_only()
        want = resolve_rbf.fpga_tree(self.dir)
        got = resolve_rbf.find_run_for_tree(
            self.dir, want, [{"databaseId": 42, "headSha": rtl_sha}])
        self.assertIsNotNone(got)
        self.assertEqual(got["databaseId"], 42)

    def test_rejects_a_build_from_different_rtl(self):
        stale_sha = self.head_sha()
        self.commit_rtl_change()
        want = resolve_rbf.fpga_tree(self.dir)
        self.assertIsNone(resolve_rbf.find_run_for_tree(
            self.dir, want, [{"databaseId": 42, "headSha": stale_sha}]))

    def test_takes_the_newest_of_several_matches(self):
        sha = self.head_sha()
        want = resolve_rbf.fpga_tree(self.dir)
        # gh lists newest-first; the first match must win.
        runs = [{"databaseId": 99, "headSha": sha},
                {"databaseId": 42, "headSha": sha}]
        self.assertEqual(
            resolve_rbf.find_run_for_tree(self.dir, want, runs)["databaseId"], 99)

    def test_returns_none_for_an_empty_run_list(self):
        want = resolve_rbf.fpga_tree(self.dir)
        self.assertIsNone(resolve_rbf.find_run_for_tree(self.dir, want, []))

    # --- resolve_run_id ----------------------------------------------------
    def test_raises_with_the_wanted_tree_in_the_message(self):
        want = resolve_rbf.fpga_tree(self.dir)
        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=[]):
            with self.assertRaises(resolve_rbf.RbfResolutionError) as cm:
                resolve_rbf.resolve_run_id(self.dir)
        self.assertIn(want[:9], str(cm.exception))

    def test_error_message_names_the_expired_artifact_recovery(self):
        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=[]):
            with self.assertRaises(resolve_rbf.RbfResolutionError) as cm:
                resolve_rbf.resolve_run_id(self.dir)
        self.assertIn("EXPIRED", str(cm.exception))

    def test_returns_run_sha_and_tree(self):
        sha = self.head_sha()
        with mock.patch.object(resolve_rbf, "list_successful_runs",
                               return_value=[{"databaseId": 7, "headSha": sha}]):
            run_id, built_sha, want_tree = resolve_rbf.resolve_run_id(self.dir)
        self.assertEqual(run_id, 7)
        self.assertEqual(built_sha, sha)
        self.assertEqual(want_tree, resolve_rbf.fpga_tree(self.dir))


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
python3 scripts/tests/test_resolve_rbf.py
```

Expected: `ModuleNotFoundError: No module named 'resolve_rbf'`, exit 1.

- [ ] **Step 3: Write the implementation**

Create `scripts/lib/resolve_rbf.py`:

```python
#!/usr/bin/env python3
"""Resolve the CI RBF build that matches a given revision's fpga/ tree.

Shared by deploy.py (--fetch-rbf) and .github/workflows/release.yml so the two
cannot drift. This rule is the only thing standing between a release and a
stale bitstream, so it lives in one tested place rather than being restated in
YAML.

Resolving by fpga/ TREE hash rather than by commit sha is deliberate:
build-rbf.yml triggers only on fpga/**, so a docs- or CI-only commit
legitimately has no run of its own while the bitstream from the last RTL commit
is still exactly right. Gating on commit equality would refuse those builds
spuriously, which trains everyone to pass --force by reflex and kills the gate.
The tree hash changes if and only if fpga/ actually changed.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

RBF_WORKFLOW = "build-rbf.yml"
RBF_ARTIFACT = "maldita-rbf"


class RbfResolutionError(Exception):
    """No CI build matches the requested fpga/ tree."""


def fpga_tree(repo, rev="HEAD"):
    """git tree hash of fpga/ at `rev`, or None if it cannot be resolved."""
    r = subprocess.run(["git", "-C", str(repo), "rev-parse", f"{rev}:fpga"],
                       text=True, capture_output=True)
    return r.stdout.strip() if r.returncode == 0 else None


def list_successful_runs(workflow=RBF_WORKFLOW, limit=60):
    """Completed, successful runs of `workflow`, newest first."""
    r = subprocess.run(
        ["gh", "run", "list", "--workflow", workflow, "--limit", str(limit),
         "--json", "databaseId,headSha,status,conclusion"],
        text=True, capture_output=True)
    if r.returncode != 0:
        raise RbfResolutionError(
            f"gh run list failed -- is gh installed and authenticated?\n{r.stderr}")
    return [x for x in json.loads(r.stdout or "[]")
            if x.get("status") == "completed" and x.get("conclusion") == "success"]


def find_run_for_tree(repo, want_tree, runs):
    """First run (newest-first order preserved) whose fpga/ tree matches."""
    for run in runs:
        if fpga_tree(repo, run["headSha"]) == want_tree:
            return run
    return None


def resolve_run_id(repo, rev="HEAD", workflow=RBF_WORKFLOW):
    """(run_id, built_sha, want_tree) for the build matching `rev`'s fpga/ tree.

    Raises RbfResolutionError when nothing matches. Fails closed on purpose:
    falling back to a fresh build would ship a bitstream nobody validated, since
    Quartus fitting is seed-sensitive.
    """
    want_tree = fpga_tree(repo, rev)
    if not want_tree:
        raise RbfResolutionError(
            f"cannot read the fpga/ tree of {rev} -- is {repo} a git checkout?")
    run = find_run_for_tree(repo, want_tree, list_successful_runs(workflow=workflow))
    if run is None:
        raise RbfResolutionError(
            f"no successful {workflow} run whose fpga/ tree matches {rev}'s "
            f"({want_tree[:9]}).\n"
            f"       If the matching run's artifacts have EXPIRED, re-run "
            f"{workflow} at that commit and re-validate on device.\n"
            f"       Do not bypass this gate: a fresh build is a bitstream "
            f"nobody validated.")
    return run["databaseId"], run["headSha"], want_tree


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", default=".", help="repo checkout to resolve against")
    p.add_argument("--rev", default="HEAD", help="revision whose fpga/ tree to match")
    p.add_argument("--json", action="store_true", help="emit JSON instead of text")
    a = p.parse_args(argv)
    try:
        run_id, built_sha, want_tree = resolve_run_id(Path(a.repo), a.rev)
    except RbfResolutionError as e:
        print(f"FATAL: {e}", file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps({"run_id": run_id, "built_sha": built_sha,
                          "fpga_tree": want_tree, "artifact": RBF_ARTIFACT}))
    else:
        print(f"run_id={run_id} built_sha={built_sha} fpga_tree={want_tree}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
python3 scripts/tests/test_resolve_rbf.py
```

Expected: 10 tests, `OK`, exit 0.

- [ ] **Step 5: Point deploy.py at the shared module**

In `deploy.py`, replace the body of `fpga_tree()` (lines 153-163) and the run
resolution inside `fetch_rbf_for_head()` (lines 198-215) with calls into the
module. Add near the other imports:

```python
sys.path.insert(0, str(Path(__file__).resolve().parent / "scripts" / "lib"))
import resolve_rbf
```

Replace the `fpga_tree` definition with a thin alias so every existing caller
keeps working unchanged:

```python
# The tree-hash rule now lives in scripts/lib/resolve_rbf.py so deploy.py and
# .github/workflows/release.yml cannot drift. Kept as an alias because
# check_rbf_provenance() and the sidecar writer both call it.
fpga_tree = resolve_rbf.fpga_tree
```

Inside `fetch_rbf_for_head()`, replace the `gh run list` block and the
`if not runs:` bail (lines 198-215) with:

```python
    try:
        run_id, built_sha, want_tree = resolve_rbf.resolve_run_id(REPO)
    except resolve_rbf.RbfResolutionError as e:
        raise SystemExit(f"FATAL: {e}")
```

then delete the now-redundant `run_id = runs[0]["databaseId"]` and
`built_sha = runs[0]["headSha"]` lines that followed.

- [ ] **Step 6: Verify deploy.py still resolves correctly**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
python3 -c "import ast,sys; ast.parse(open('deploy.py').read()); print('deploy.py parses')"
python3 scripts/lib/resolve_rbf.py --repo . --rev HEAD --json
```

Expected: `deploy.py parses`, then a JSON object with a `run_id`, the
`built_sha`, and an `fpga_tree` — or, if HEAD's `fpga/` tree has no build yet, a
`FATAL:` message naming the wanted tree hash. Both are correct outcomes; a
traceback is not.

- [ ] **Step 7: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git add scripts/lib/resolve_rbf.py scripts/tests/test_resolve_rbf.py deploy.py
git commit -m "refactor(deploy): extract the RBF tree-hash resolver for reuse

The release workflow needs the same 'which CI build matches this fpga/ tree'
rule deploy.py already implements. Restating it in YAML would let the two
drift, and this rule is the only thing between a release and a stale
bitstream.

Nine tests cover the behaviour that matters: a docs-only commit must not
invalidate a good bitstream, an RTL change must, newest-match wins, and an
empty run list must raise with the wanted tree hash in the message."
```

---

### Task 7: Write the release workflow in maldita

**Files:**
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `scripts/lib/resolve_rbf.py` (Task 6), `external/gmloader-next` (Task 5), `scripts/release/assemble_bundle.sh` (Task 8).
- Produces: a GitHub Release on `v*` tags; a CI artifact on `workflow_dispatch`.

**Task 8 creates `assemble_bundle.sh`.** Write this workflow now and expect the
`assemble-release` job to fail until Task 8 lands; the dry run in Task 9 is where
both are verified together.

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

# Tag-triggered production release of the Maldita Castilla MiSTer core.
# Design: docs/superpowers/specs/2026-07-31-release-consolidation-design.md
#
#   push v* tag        -> resolve the gated, device-validated RBF, build the
#                         engine from the submodule pin, assemble the SD-card
#                         bundle, publish a GitHub Release.
#   workflow_dispatch  -> dry run: same resolve + build + assembly, uploads the
#                         bundle as a CI artifact, does NOT publish a release.
#
# The RBF is NOT rebuilt here. Quartus fitting is seed-sensitive, so a fresh
# build is a bitstream nobody validated on device. This resolves the artifact
# from the build-rbf.yml run whose fpga/ tree matches the tag -- the same rule
# deploy.py --fetch-rbf uses, shared via scripts/lib/resolve_rbf.py.

on:
  push:
    tags: ['v*']
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: true

jobs:
  resolve-rbf:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    outputs:
      run_id: ${{ steps.resolve.outputs.run_id }}
      fpga_tree: ${{ steps.resolve.outputs.fpga_tree }}
      built_sha: ${{ steps.resolve.outputs.built_sha }}
    steps:
      - uses: actions/checkout@v4
        with:
          # resolve_rbf walks history to compare fpga/ trees across runs, so a
          # shallow clone would make every comparison fail.
          fetch-depth: 0

      - name: Resolve the gated RBF build for this ref
        id: resolve
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          OUT=$(python3 scripts/lib/resolve_rbf.py --repo . --rev "${GITHUB_SHA}" --json)
          echo "$OUT"
          echo "run_id=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])')" >> "$GITHUB_OUTPUT"
          echo "built_sha=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["built_sha"])')" >> "$GITHUB_OUTPUT"
          echo "fpga_tree=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["fpga_tree"])')" >> "$GITHUB_OUTPUT"

      - name: Download the RBF from that run
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          gh run download "${{ steps.resolve.outputs.run_id }}" -n maldita-rbf -D dist/rbf
          ls -lh dist/rbf/MalditaCastilla_*.rbf

      - name: Upload the resolved RBF
        uses: actions/upload-artifact@v4
        with:
          name: resolved-rbf
          path: dist/rbf/MalditaCastilla_*.rbf
          if-no-files-found: error

  build-engine:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3
        with:
          platforms: arm

      - name: Build the ARM engine in a container
        run: |
          # build_mister_arm.sh expects the gmloader-next checkout at /src. It
          # runs no git commands, so mounting only the submodule dir is safe.
          # The script asserts MISTER_BUILD linkage before stripping.
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
    needs: [resolve-rbf, build-engine]
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - uses: actions/download-artifact@v4
        with:
          name: resolved-rbf
          path: dist/rbf

      - uses: actions/download-artifact@v4
        with:
          name: gmloader-engine
          path: dist/engine

      - name: Assemble the bundle
        run: |
          set -euo pipefail
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
            echo "maldita.castilla-mister: ${GITHUB_SHA}"
            echo "gmloader-next:           $(git -C external/gmloader-next rev-parse HEAD)"
            echo "fpga/ tree hash:         ${{ needs.resolve-rbf.outputs.fpga_tree }}"
            echo "RBF from build-rbf.yml:  run ${{ needs.resolve-rbf.outputs.run_id }} (commit ${{ needs.resolve-rbf.outputs.built_sha }})"
            echo '```'
            echo ""
            echo "The RBF was not rebuilt for this release. It is the artifact from the"
            echo "gated build-rbf.yml run above, matched by fpga/ tree hash."
            echo ""
            echo "Game data (mygame.apk, saves/) is user-provided -- see the bundle README.md."
          } > dist/notes.md
          cat dist/notes.md

      - name: Publish the GitHub Release (tag only)
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

      - name: Upload the dry-run bundle (dispatch only)
        if: github.event_name == 'workflow_dispatch'
        uses: actions/upload-artifact@v4
        with:
          name: release-bundle-${{ env.VERSION }}
          path: |
            dist/out/MalditaCastilla-MiSTer-*.zip
            dist/out/sha256sums.txt
          if-no-files-found: error
```

- [ ] **Step 2: Verify the YAML parses and the job graph is right**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
python3 -c "
import yaml
d = yaml.safe_load(open('.github/workflows/release.yml'))
print('jobs:', sorted(d['jobs']))
print('assemble needs:', d['jobs']['assemble-release']['needs'])
print('top-level perms:', d['permissions'])
print('assemble perms:', d['jobs']['assemble-release']['permissions'])
"
```

Expected:

```
jobs: ['assemble-release', 'build-engine', 'resolve-rbf']
assemble needs: ['resolve-rbf', 'build-engine']
top-level perms: {'contents': 'read'}
assemble perms: {'contents': 'write'}
```

Write access is scoped to the one job that publishes, rather than granted
workflow-wide.

- [ ] **Step 3: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git add .github/workflows/release.yml
git commit -m "feat(release): publish the core release from this repo

The published artifact is this core, so the release belongs here rather than
in the bundling repo.

The RBF is resolved, not rebuilt: Quartus fitting is seed-sensitive, so a
fresh build at tag time would ship a bitstream nobody validated on device.
resolve-rbf finds the gated build-rbf.yml run whose fpga/ tree matches the tag
and downloads its artifact, failing closed when none exists.

contents:write is scoped to the assemble job rather than the whole workflow."
```

---

### Task 8: Move and rebase the bundle assembly script

**Files:**
- Create: `scripts/release/assemble_bundle.sh` (from `mister-gmloader/scripts/release/assemble_bundle.sh`)
- Create: `release/README.md`, `release/APKs-README.txt` (moved)
- Create: `scripts/tests/test_assemble_bundle.sh` (repo convention)

**Interfaces:**
- Consumes: `external/gmloader-next` (Task 5).
- Produces: `assemble_bundle.sh <rbf> <engine> <out_dir> <version>` → `<out_dir>/MalditaCastilla-MiSTer-<version>.zip` plus `sha256sums.txt`. Task 7's `assemble-release` job calls it.

**The manifest must not change.** The staged tree is the release's contract; the
only edits here are the two source paths.

- [ ] **Step 1: Copy the three files in**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
mkdir -p scripts/release release
SRC=/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
cp "$SRC/scripts/release/assemble_bundle.sh" scripts/release/
cp "$SRC/release/README.md" "$SRC/release/APKs-README.txt" release/
chmod +x scripts/release/assemble_bundle.sh
```

- [ ] **Step 2: Rebase the two source paths**

In `scripts/release/assemble_bundle.sh`, replace:

```bash
GMNEXT="$REPO/external/gmloader-next"
MALDITA="$REPO/external/maldita.castilla-mister"
```

with:

```bash
# This repo now owns _handler.sh directly; the engine and its whole runtime
# closure (including Mesa) come from the one submodule.
GMNEXT="$REPO/external/gmloader-next"
MALDITA="$REPO"
```

and replace the Mesa copy line:

```bash
cp "$REPO/runtime/mesa/"*.so* "$GMDIR/mesa/"
```

with:

```bash
cp "$GMNEXT/runtime/mesa/"*.so* "$GMDIR/mesa/"
```

Leave `$REPO/release/APKs-README.txt` and `$REPO/release/README.md` as they are
— those files now live in this repo at exactly those paths.

- [ ] **Step 3: Write a test that stages a bundle from stub inputs**

Create `scripts/tests/test_assemble_bundle.sh`:

```bash
#!/usr/bin/env bash
# Stages a bundle from stub inputs and asserts the manifest is exactly the
# 13 expected paths. The manifest is the release's contract -- this is the
# regression test for the mister-gmloader -> maldita path rebase.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ASSEMBLE="$REPO/scripts/release/assemble_bundle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stub RBF must clear the script's 1 MB plausibility check.
dd if=/dev/zero of="$TMP/MalditaCastilla_test.rbf" bs=1024 count=1200 2>/dev/null

# A stub engine must pass `file ... | grep 'ELF 32-bit' | grep ARM`, so use the
# real thing if a build exists; otherwise skip -- a fake ELF header is not
# worth maintaining.
ENGINE="$REPO/external/gmloader-next/games/gmloader/gmloader"
if [ ! -f "$ENGINE" ]; then
    echo "SKIP: no engine at $ENGINE (run build_mister_arm.sh first)"
    exit 0
fi

bash "$ASSEMBLE" \
    "$TMP/MalditaCastilla_test.rbf" "$ENGINE" "$TMP/out" "v0.0.0-test" || {
    echo "FAIL: assemble_bundle.sh exited non-zero"; exit 1; }

ACTUAL=$(cd "$TMP/out/bundle" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
EXPECTED=$(LC_ALL=C sort <<'EOF'
README.md
_Other/MalditaCastilla_test.rbf
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

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FAIL: manifest mismatch"
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTUAL")
    exit 1
fi

[ -f "$TMP/out/MalditaCastilla-MiSTer-v0.0.0-test.zip" ] || { echo "FAIL: no zip"; exit 1; }
[ -f "$TMP/out/sha256sums.txt" ] || { echo "FAIL: no sha256sums.txt"; exit 1; }
echo "PASS: 13-file manifest, zip and checksums present"
```

Make it executable: `chmod +x scripts/tests/test_assemble_bundle.sh`

- [ ] **Step 4: Run the test**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
bash scripts/tests/test_assemble_bundle.sh
```

Expected: `PASS: 13-file manifest, zip and checksums present`.

If it prints `SKIP`, build the engine first with the Task 2 Step 3 command, then
re-run. Do not commit on a SKIP — the rebase is unverified until this passes.

- [ ] **Step 5: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git add scripts/release/ scripts/tests/test_assemble_bundle.sh release/
git commit -m "feat(release): bring the bundle assembly script into this repo

Two path changes only: MALDITA is now this repo (it owns _handler.sh
directly), and Mesa comes from the submodule's runtime/mesa/ rather than a
vendored copy in the bundling repo. Every non-RBF file now comes from one
submodule.

The 13-file manifest is unchanged -- it is the release's contract. Added a
test that stages a bundle from stub inputs and diffs the manifest, which is
the regression test for this rebase."
```

---

### Task 9: Migrate docs, bench tooling, Makefile, LICENSE and README

**Files:**
- Create (moved): `docs/superpowers/**` (86), `docs/architecture/**` (9), `bench-results/**` (25), `scripts/{check_arch_docs.sh,mister_run.sh,gmloader_diag.sh,mftrace_analyze.py}`, `scripts/lib/*.sh` (4), `scripts/scenes/*.joy` (2), `Makefile`, `LICENSE`
- Create (rewritten): `README.md`
- Modify: `deploy.py` — engine path prefers the submodule

**Interfaces:**
- Consumes: `external/gmloader-next` (Task 5).
- Produces: `make build-engine|deploy-engine|deploy-rbf|rbf-status|rbf-watch` working from the maldita repo root.

**These are copies, not history-preserving moves.** `git mv` cannot cross
repositories. That is accepted because `mister-gmloader` is archived read-only
rather than deleted, so every file's history stays readable at its existing
URLs. The commit in Step 10 **must** record the exact source SHA — capture it
first:

```bash
git -C /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader rev-parse HEAD
```

- [ ] **Step 1: Re-run the basename-collision check before moving anything**

Verified zero collisions on 2026-07-31. Re-check, because a concurrent session
may have added a file since.

```bash
cd /tmp
git -C /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader ls-files docs/superpowers/ \
  | xargs -n1 basename | LC_ALL=C sort > /tmp/gm_docs.txt
git -C /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release ls-files docs/superpowers/ \
  | xargs -n1 basename | LC_ALL=C sort > /tmp/md_docs.txt
COLLISIONS=$(comm -12 /tmp/gm_docs.txt /tmp/md_docs.txt)
[ -z "$COLLISIONS" ] && echo "OK: no basename collisions" || {
  echo "STOP -- collisions found:"; echo "$COLLISIONS"; exit 1; }
```

Expected: `OK: no basename collisions`. If any appear, **stop and report** — a
blind copy would silently overwrite one side.

- [ ] **Step 2: Copy the docs, bench results and scripts in**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
SRC=/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
mkdir -p docs/architecture bench-results scripts/lib scripts/scenes
rsync -a "$SRC/docs/superpowers/" docs/superpowers/
rsync -a "$SRC/docs/architecture/" docs/architecture/
rsync -a "$SRC/bench-results/" bench-results/
cp "$SRC/scripts/check_arch_docs.sh" "$SRC/scripts/mister_run.sh" \
   "$SRC/scripts/gmloader_diag.sh" "$SRC/scripts/mftrace_analyze.py" scripts/
cp "$SRC/scripts/lib/"*.sh scripts/lib/
cp "$SRC/scripts/scenes/"*.joy scripts/scenes/
cp "$SRC/Makefile" "$SRC/LICENSE" .
chmod +x scripts/check_arch_docs.sh scripts/mister_run.sh scripts/gmloader_diag.sh
```

- [ ] **Step 3: Verify the expected file counts arrived**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
echo "architecture: $(find docs/architecture -type f | wc -l | tr -d ' ') (want 9)"
echo "bench-results: $(find bench-results -type f | wc -l | tr -d ' ') (want 25)"
echo "superpowers: $(find docs/superpowers -type f | wc -l | tr -d ' ') (want 116)"
```

`superpowers` expects 116: the pre-existing 28, plus 86 moved in, plus the spec
and this plan added in this branch.

- [ ] **Step 4: Rewrite the Makefile for a single repo**

Apply these edits to `Makefile`:

Replace the header comment block (through the `Common invocations:` list) with:

```make
# Build + deploy entry points for the Maldita Castilla MiSTer core.
#
# The engine source is the external/gmloader-next submodule. When working on
# the engine in a worktree, pass GMDIR explicitly:
#     make build-engine GMDIR=../wt-gmloader-<topic>
#
# Deploys go through ./deploy.py on purpose: it carries the provenance gates
# (RBF matched to fpga/ tree hash, engine freshness vs gmloader-next HEAD),
# sha1-verified scp (FAT truncation guard), and kills the running engine so
# Master_Daemon respawns it with the new binary. Never bypass it with a bare
# scp, and never hand-launch gmloader afterwards -- that is how you end up with
# two engines fighting over one control block.
#
# Common invocations:
#   make build-engine
#   make build-engine GMDIR=../wt-gmloader-audioclk
#   make deploy-rbf                  # fetch the gated CI RBF for HEAD, deploy it
#   make deploy                      # RBF + engine + content
#   make deploy HOST=192.168.20.81 PROD=1   # production needs explicit PROD=1
```

Replace the path variables:

```make
PROJECTS := $(abspath $(CURDIR)/..)
GMDIR    ?= $(PROJECTS)/gmloader-next
MALDITA  ?= $(PROJECTS)/maldita.castilla-mister

# Recipes cd into MALDITA, so relative GMDIR/MALDITA values (resolved against
# this repo) must be absolutized before use.
override GMDIR   := $(abspath $(GMDIR))
override MALDITA := $(abspath $(MALDITA))
```

with:

```make
# The engine lives in the submodule by default. GMDIR stays overridable so the
# per-workstream worktree flow (GMDIR=../wt-gmloader-<topic>) keeps working.
GMDIR ?= $(CURDIR)/external/gmloader-next
override GMDIR := $(abspath $(GMDIR))
```

Replace the deploy prefix:

```make
DEPLOY = cd $(MALDITA) && ./deploy.py --host $(HOST)
```

with:

```make
DEPLOY = ./deploy.py --host $(HOST)
```

Drop the `cd $(MALDITA) && ` prefix from the `rbf-status` and `rbf-watch`
recipes, and drop `MALDITA=$(MALDITA)` from the `help` target's variable dump.

Leave `HOST ?= 192.168.20.62`, `PROD_HOST := 192.168.20.81`, and the
`guard-host` target exactly as they are.

- [ ] **Step 5: Verify the Makefile targets resolve**

`make -n` expands recipes without running them, so this is safe — no device is
contacted.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
make help
echo "--- deploy-rbf (dry) ---"; make -n deploy-rbf
echo "--- prod guard ---"; make -n deploy HOST=192.168.20.81 2>&1 | tail -2
```

Expected: `help` lists the targets and reports
`GMDIR=<repo>/external/gmloader-next` and `HOST=192.168.20.62`; `deploy-rbf`
expands to `./deploy.py --host 192.168.20.62 --fetch-rbf --no-content` with no
`cd`; the production invocation fails with
`HOST=192.168.20.81 is the PRODUCTION unit. Pass PROD=1 to confirm.`

- [ ] **Step 6: Point deploy.py's engine defaults at the submodule**

In `deploy.py`, replace the `ENGINE_DEFAULT` and `JSON_DEFAULT` definitions
(lines 106 and 108) with a submodule-first resolver:

```python
# Prefer the submodule so a fresh clone is self-sufficient; fall back to a
# sibling checkout so the per-workstream worktree flow keeps working.
_SUBMODULE_GM = REPO / "external/gmloader-next"
_SIBLING_GM   = SIBLINGS / "gmloader-next"
GMNEXT = _SUBMODULE_GM if (_SUBMODULE_GM / "Makefile.gmloader").is_file() else _SIBLING_GM

ENGINE_DEFAULT = GMNEXT / "build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf"
JSON_DEFAULT   = GMNEXT / "games/gmloader/gmloader.json"
```

Then update every other `SIBLINGS / "gmloader-next/..."` reference in the file to
use `GMNEXT`. Find them with:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
grep -n 'gmloader-next' deploy.py
```

- [ ] **Step 7: Verify deploy.py resolves the submodule**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
python3 -c "
import importlib.util, pathlib
s = importlib.util.spec_from_file_location('d', 'deploy.py')
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print('GMNEXT      =', m.GMNEXT)
print('is submodule:', 'external/gmloader-next' in str(m.GMNEXT))
print('JSON exists :', pathlib.Path(m.JSON_DEFAULT).is_file())
"
```

Expected: `GMNEXT` ends in `external/gmloader-next`, `is submodule: True`,
`JSON exists : True`.

If `exec_module` runs deploy logic rather than just defining names, the module
lacks an `if __name__ == "__main__":` guard — check with
`grep -n '__main__' deploy.py` and use `grep`-based verification instead.

- [ ] **Step 8: Write the new README**

Create `README.md`:

```markdown
# Maldita Castilla for MiSTer FPGA

A MiSTer FPGA port of *Maldita Castilla*, running the original GameMaker game
through a GameMaker loader with an FPGA-accelerated blitter doing the
rasterisation.

## What is in this repository

| path | what it is |
|---|---|
| `fpga/` | the MiSTer core — Quartus project, RTL, and the blitter fabric |
| `games/Maldita Castilla/` | the core's `_handler.sh` launcher |
| `external/gmloader-next` | submodule: the gmloader engine and its MiSTer port |
| `deploy.py` | deploy to a device, with provenance gates |
| `scripts/` | bench, diagnostic and release tooling |
| `docs/architecture/` | how the pieces fit together |

The engine — including all MiSTer-specific code (blitter host path, joystick
readers, native audio and video writers) — lives in
[gmloader-next](https://github.com/gmcnaught/gmloader-next), pinned here as a
submodule.

## Releases

Tagged `v*` releases publish an SD-card bundle containing the core `.rbf`, the
engine, and its GL runtime closure. Game data (`mygame.apk`) is user-provided;
see the bundle's own `README.md` for placement.

The released bitstream is **not** rebuilt at tag time. It is the artifact from
the gated `build-rbf.yml` run whose `fpga/` tree matches the tag — the same
bitstream that was validated on hardware.

## Building

```
git clone --recurse-submodules git@github.com:gmcnaught/maldita.castilla-mister.git
cd maldita.castilla-mister
make build-engine      # cross-build the engine (Docker)
make help              # all targets
```

The core `.rbf` is built by CI (`.github/workflows/build-rbf.yml`, Quartus Lite
17.0). There is deliberately no local RBF target — push a change under `fpga/`
and fetch the result with `make deploy-rbf`, which refuses any artifact that
does not match HEAD's `fpga/` tree.

## Deploying

`make deploy` targets `192.168.20.62` by default. `192.168.20.81` is the
production unit and requires an explicit `PROD=1`.

Always deploy through `deploy.py`. It verifies artifact provenance, checksums
the transfer, and restarts the engine correctly. Hand-launching `gmloader`
afterwards leaves two engines contending for one control block.
```

- [ ] **Step 9: Verify the architecture-docs checker still passes**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
bash scripts/check_arch_docs.sh
```

Expected: passes. If it fails on paths that assumed the `mister-gmloader`
layout, fix those references in `docs/architecture/` — the docs now describe a
two-repo layout, and a checker that passes on stale paths is worse than one that
fails.

- [ ] **Step 10: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git add docs/ bench-results/ scripts/ Makefile LICENSE README.md deploy.py
git commit -m "chore: absorb the docs, bench tooling and build entry points

mister-gmloader holds no source -- 50 tracked files, none of them code. With
the release moving here, its remaining contents belong beside the work they
describe: 86 superpowers docs, 9 architecture docs, 25 bench logs, the bench
harness, the Makefile, and the LICENSE (this repo had none).

Verified zero basename collisions across the two docs/superpowers trees before
merging them.

Copied, not git-mv'd: git mv cannot cross repositories, so per-file history
does not follow. Acceptable because mister-gmloader is archived read-only
rather than deleted — the full history stays readable at its existing URLs.
Source: mister-gmloader@<PASTE THE SHA CAPTURED ABOVE>

Makefile: MALDITA collapses to CURDIR, GMDIR defaults to the submodule but
stays overridable for the worktree flow. deploy.py prefers the submodule and
falls back to a sibling checkout. README rewritten for the two-repo layout."
```

---

### Task 10: Dry-run the release workflow end to end

**Files:** none changed unless the dry run reveals a defect.

**Interfaces:**
- Consumes: everything from Tasks 3-9.
- Produces: a `release-bundle-dryrun-N` CI artifact proving the workflow assembles a correct bundle without publishing anything.

- [ ] **Step 1: Push the branch and open the PR**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
git push -u origin chore/release-consolidation
gh pr create --title "Release consolidation: publish the core release from this repo" \
  --body "$(cat <<'BODY'
Moves the release into this repo, pins gmloader-next as a submodule, and adds
the production gates to build-rbf.yml (they never existed here).

Spec: docs/superpowers/specs/2026-07-31-release-consolidation-design.md
Plan: docs/superpowers/plans/2026-07-31-release-consolidation.md

Gate evidence:
  - passing run: <fill in from Task 4 Step 5>
  - failing run: <fill in from Task 4 Step 6>

mister-gmloader is archived only after a real release publishes.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01MukLwFMCfEUpLg4JMSBdoj
BODY
)"
```

- [ ] **Step 2: Trigger the dry run**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
gh workflow run release.yml --ref chore/release-consolidation
sleep 10
gh run watch "$(gh run list --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')"
```

Expected: all three jobs succeed. `build-engine` dominates the wall clock
(~30-45 min under QEMU).

- [ ] **Step 3: Confirm resolve-rbf found a gated run, not just any run**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
RUN=$(gh run list --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')
gh run view "$RUN" --log | grep -A3 "Resolve the gated RBF"
```

Expected: a JSON line with `run_id`, `built_sha`, `fpga_tree`. Cross-check that
`run_id` is the gated `build-rbf.yml` run from Task 4 Step 5 — not an older,
pre-gate run. If it resolved to a pre-gate run, that is a real gap to report:
the resolver cannot currently distinguish gated from ungated history.

- [ ] **Step 4: Download the dry-run bundle and verify the manifest**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
RUN=$(gh run list --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')
rm -rf /tmp/dryrun && mkdir -p /tmp/dryrun
gh run download "$RUN" -D /tmp/dryrun
cd /tmp/dryrun && find . -name '*.zip' -exec unzip -o -q {} -d /tmp/dryrun/x \;
(cd /tmp/dryrun/x && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
```

Expected: exactly the 13 paths listed in Task 8 Step 3, with the RBF's real
`MalditaCastilla_*.rbf` name in place of the stub.

- [ ] **Step 5: Verify the shipped engine has the MiSTer video path**

The Task 2 check runs before stripping, so the shipped binary has no symbol
table. Confirm the assertion actually ran in this build.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
RUN=$(gh run list --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')
gh run view "$RUN" --log | grep "MiSTer sources linked"
```

Expected: `OK: MiSTer sources linked (NativeVideoWriter_WriteFrame present)`.

- [ ] **Step 6: Record the result**

If all five steps pass, note the dry-run run ID in the PR. If any fail, fix the
defect, commit, and re-run from Step 2 — do not proceed to Task 11 on a partial
pass.

---

### Task 11: Publish the first real release

**Files:** none changed.

**Interfaces:**
- Consumes: a merged Task 10 PR.
- Produces: a published GitHub Release, which is the acceptance criterion for Task 12.

- [ ] **Step 1: Merge the PR**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-release
gh pr merge --squash --delete-branch=false
git checkout milestone-a && git pull
```

- [ ] **Step 2: Confirm the merged HEAD still resolves an RBF**

The squash creates a new commit. Its `fpga/` tree must still match a gated build.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git pull
python3 scripts/lib/resolve_rbf.py --repo . --rev HEAD --json
```

Expected: JSON naming a `run_id`. A `FATAL:` here means the merge changed
`fpga/` — push and let `build-rbf.yml` build it before tagging.

- [ ] **Step 3: Tag and push**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git tag -a v0.1.0-rc1 -m "First release from the core repo

Bundles the gated, device-validated core bitstream, the gmloader engine built
from the pinned submodule, and its GL runtime closure."
git push origin v0.1.0-rc1
```

- [ ] **Step 4: Watch the release run**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
sleep 10
gh run watch "$(gh run list --workflow release.yml -L 1 --json databaseId -q '.[0].databaseId')"
```

- [ ] **Step 5: Verify the published release**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
gh release view v0.1.0-rc1
gh release view v0.1.0-rc1 --json assets -q '.assets[].name'
```

Expected assets: `MalditaCastilla-MiSTer-v0.1.0-rc1.zip`, a
`MalditaCastilla_*.rbf`, and `sha256sums.txt`. The release body must show the
provenance block naming the `fpga/` tree hash and the originating
`build-rbf.yml` run ID.

---

### Task 12: Retire mister-gmloader

**Files:**
- Modify: `mister-gmloader/README.md` — a pointer, replacing everything else
- Delete: everything else in `mister-gmloader`

**Interfaces:**
- Consumes: a published release from Task 11.

**Do not start this task until Task 11 Step 5 passes.** Archiving before a real
release publishes removes the fallback.

- [ ] **Step 1: Confirm the release exists**

```bash
gh release view v0.1.0-rc1 -R gmcnaught/maldita.castilla-mister --json tagName -q .tagName
```

Expected: `v0.1.0-rc1`. Anything else — stop.

- [ ] **Step 2: Verify nothing unique is left behind**

Every tracked file must exist in a destination repo before deletion.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
MD=/Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
GM=$MD/external/gmloader-next
MISSING=0
for f in $(git ls-files | grep -v '^external/'); do
  base=$(basename "$f")
  if ! find "$MD" "$GM" -name "$base" -not -path '*/.git/*' | grep -q .; then
    echo "NOT MIGRATED: $f"; MISSING=$((MISSING+1))
  fi
done
echo "--- $MISSING file(s) unaccounted for ---"
```

Expected: `0 file(s) unaccounted for`, with `.gitmodules` and `README.md` the
only acceptable exceptions (deliberately not migrated). Investigate anything
else before deleting.

- [ ] **Step 3: Replace the repo contents with a pointer**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git rm -r --quiet --cached . >/dev/null
git checkout -- . 2>/dev/null || true
git rm -r --quiet docs bench-results scripts release runtime external \
  .gitmodules Makefile LICENSE .github 2>/dev/null || true
cat > README.md <<'EOF'
# mister-gmloader (archived)

This repository has been retired. It bundled three repos and held no source of
its own.

The work moved to:

- **[maldita.castilla-mister](https://github.com/gmcnaught/maldita.castilla-mister)**
  — the MiSTer core, releases, deploy and bench tooling, and all project docs
- **[gmloader-next](https://github.com/gmcnaught/gmloader-next)**
  — the gmloader engine, its MiSTer port, and the GL runtime closure

Releases are published from `maldita.castilla-mister`.
EOF
git add -A
git commit -m "chore: retire this repo in favour of maldita.castilla-mister

It held no source -- 50 tracked files, none of them code. The MiSTer gmloader
implementation was always in gmloader-next/gmloader/mister/, and the artifact
this repo released is the Maldita Castilla core, which now releases from its
own repo.

Contents distributed per
maldita.castilla-mister/docs/superpowers/specs/2026-07-31-release-consolidation-design.md.
Superseded only after v0.1.0-rc1 published successfully from the new path."
git push
```

- [ ] **Step 4: Archive the repository on GitHub**

```bash
gh repo archive gmcnaught/mister-gmloader --yes
gh repo view gmcnaught/mister-gmloader --json isArchived -q .isArchived
```

Expected: `true`.

- [ ] **Step 5: Update the session-start handoff pointer**

The project memory entry for Phase 3 points at
`docs/superpowers/HANDOFF-2026-07-30.md` in `mister-gmloader`. That path is now
`maldita.castilla-mister/docs/superpowers/HANDOFF-2026-07-30.md`.

Update these memory files under
`~/.claude/projects/-Users-gmcnaught-MisterFPGA-Projects-mister-gmloader/memory/`:

- `three-project-layout.md` — now a two-repo layout; `mister-gmloader` is archived
- `maldita-60fps-phase3-state.md` — new handoff path
- `mister-gmloader-makefile.md` — the Makefile now lives at the maldita repo root
- `deploy-engine-comes-from-sibling-worktree-not-submodule.md` — `deploy.py` now
  prefers the submodule, falling back to a sibling checkout
- `build-gmloader-arm-in-docker-container.md` — `build_mister_arm.sh` now
  asserts `MISTER_BUILD` linkage before stripping

Add a new memory recording that `build-rbf.yml` gates on `332148`/`276007` with
`ddr_blitter_arb.sv` allowlisted by name, and that pre-gate CI runs exist in
history.

---

## Verification Summary

| what | how | which task |
|---|---|---|
| Mesa closure moved intact | sha256 per file vs originals | 1.3 |
| `MISTER_BUILD` linkage asserted | `nm` finds `NativeVideoWriter_WriteFrame` pre-strip | 2.3, 10.5 |
| Gate logic correct | 6 fixture cases incl. allowlist boundary | 3.4 |
| Gate passes on a real build | `build-rbf.yml` run goes green with the accepted note | 4.5 |
| **Gate can fail** | injected `332148`, run goes red, no RBF uploaded | 4.6 |
| Submodule has what the bundle needs | 4 path existence checks | 5.2, 5.3 |
| Tree-hash resolution correct | 10 `unittest` cases, real throwaway git repos | 6.4 |
| No docs lost or overwritten | basename-collision check, then file counts | 9.1, 9.3 |
| Makefile still works | `make -n` expansion + prod guard refusal | 9.5 |
| Bundle manifest unchanged | 13-path diff from stub inputs | 8.4 |
| Workflow assembles correctly | dry-run artifact unzipped and diffed | 10.4 |
| Release publishes | three assets + provenance block present | 11.5 |
| Nothing left behind | every tracked file found in a destination | 12.2 |

**No device work anywhere in this plan.** The RBF being released was validated
on hardware separately; this plan only ensures the right one is shipped.
