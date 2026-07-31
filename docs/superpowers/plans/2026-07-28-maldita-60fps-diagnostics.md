# Maldita 60 FPS Phase 0 — Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a populated 16.67 ms frame budget for a reproducible in-game Maldita Castilla scene on the `.81` bench unit, measured under a *proven* instrument, ending in an arithmetic statement of what 60 fps requires.

**Architecture:** Four independent pieces feed one join point. A forward-ported SSH harness drives the device; a scripted joystick driver writes `/dev/shm/maldita-joy` to reach a fixed gameplay scene deterministically; host-side instrumentation is extended so the input transport and per-frame coverage are observable; and the in-fabric `fabric_ms` counters are root-caused against four ranked hypotheses behind a trust gate. Only then is a budget captured.

**Tech Stack:** bash (SSH harness, busybox 1.33 on target), C11 (device tools, cross-compiled armhf via Docker), C++17 (gmloader host engine), SystemVerilog + Quartus (conditional RTL task only).

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include this section.

- **Correctness envelope: pixel-exact, and the timing slack must close.** Full native 288×216. No tearing. Bit-exact versus the golden refmodel. The −0.732 ns tint-path slack must close before any lever ships.
- **Forbidden levers, permanently, in this phase and the next:** `GMLOADER_RENDER_W/H` below 288×216, `GMLOADER_MFSUBMIT_NOWAIT` (tears), shipping on the fragile fit.
- **Bench device is `root@192.168.20.81` only.** `.62` numbers are not interchangeable — the SDRAM_CLK phase finding proves the boards differ.
- **No optimization work ships in this phase.** No RTL optimization, no host pacing changes, no lever implementation, no tint-slack fit-cycle.
- **Launch via the Master_Daemon handler, never by hand.** Hand launches measure something different (halt point 33 versus 21) and an interactive shell masks the `LD_LIBRARY_PATH` requirement.
- **Assert exactly one `gmloader` process inside every sample**, not once at the start. Abort the run otherwise.
- **busybox 1.33 has no `pkill`/`pgrep`.** They fail silently, so every guard using them passes vacuously. Kill by explicit PID.
- **A sample is healthy only if `|C_SUBMIT − C_DONE| ≤ 1`.** The words are read non-atomically.
- **Provenance on every recorded number:** engine build id, RBF tree hash via `deploy.py --fetch-rbf`, per-sample process count, shm path, scene-script hash, per-frame triangle count.
- **Three runs minimum per configuration, reporting spread.** A difference smaller than run-to-run spread is not a result.
- **Determinism gate:** mean per-frame triangle count must agree within ±5% across the three runs, or the runs are void.
- **Instrument trust gate:** no budget number is recorded until a controlled A/B at two known triangle counts yields proportionally different `tri_ms`.

## File Structure

| File | Responsibility | Repo |
|---|---|---|
| `scripts/mister_run.sh` | remote driver: deploy, daemon-path launch, timed capture, teardown, log pull | mister-gmloader |
| `scripts/gmloader_diag.sh` | on-device env mapping and presets (device copy) | mister-gmloader |
| `scripts/lib/device_pids.sh` | busybox-safe PID discovery, kill, and sole-instance assertion | mister-gmloader |
| `scripts/scenes/ingame-stage1.joy` | the version-controlled input script | mister-gmloader |
| `tools/joy_script_parse.h/.c` | pure script parser, no I/O — host-testable | gmloader-next |
| `tools/joy_script_parse_test.c` | host-native parser test | gmloader-next |
| `tools/joy_script.c` | shm writer, timed replay, marker logging | gmloader-next |
| `gmloader/input.cpp` | +1 transport log line | gmloader-next |
| `gmloader/mister/raster_backend_mfgpu.cpp` | +`covered_px_est` in the MFSUBMIT line, **and** the triangle-area accumulator itself (`mf_cov_add_triangle` — planned below for `blitter_raster.cpp`, landed here instead; see `docs/superpowers/investigations/2026-07-28-fabric-ms-insensitivity.md`) | gmloader-next |
| ~~`gmloader/mister/blitter_raster.cpp`~~ | ~~triangle-area accumulator feeding `covered_px_est`~~ — **correction: did not land here**, see row above | gmloader-next |
| `fpga/rtl/blitter_top.sv` | **conditional** counter fix + `perf_covered_px` | maldita.castilla-mister |

Parser and writer are split so the parser carries a host test with no device in the loop. The PID helpers are extracted to `scripts/lib/` because three call sites need identical busybox-safe behaviour and divergence between them is exactly how the vacuous-guard bug survived.

---

### Task 1: Harness forward-port with busybox-safe process discipline

The harness exists only on branch `perf/mfgpu-submit-profiling` (`07bf085`). Bring it to `master` and fix the process handling that the audio-wedge investigation proved defective.

**Files:**
- Create: `scripts/lib/device_pids.sh`
- Create: `scripts/lib/device_pids_test.sh`
- Restore then modify: `scripts/mister_run.sh`, `scripts/gmloader_diag.sh`

**Interfaces:**
- Consumes: nothing
- Produces: `scripts/lib/device_pids.sh` defining `DEVPID_CMD` (a remote shell snippet string printing one PID per line), `devpid_count <ssh-fn>` → integer on stdout, `devpid_list <ssh-fn>` → the PID list itself (one per line, empty if none — the separate list-returning helper; do not conflate with `devpid_count`), `devpid_kill <ssh-fn>` → void, `devpid_assert_one <ssh-fn>` → exit 0 if exactly one engine, exit 1 otherwise. Task 3, 5, 6 and 8 all call these.

- [ ] **Step 1: Restore the harness from the profiling branch**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git checkout perf/mfgpu-submit-profiling -- scripts/mister_run.sh scripts/gmloader_diag.sh
ls -l scripts/
```

Expected: both files present, `mister_run.sh` and `gmloader_diag.sh`.

- [ ] **Step 2: Write the failing test for PID discovery**

The test runs against a *local* fake `ps`, so it needs no device. Create `scripts/lib/device_pids_test.sh`:

```bash
#!/bin/bash
# Host-side test for device_pids.sh. Substitutes a fake remote shell that
# replays captured busybox `ps` output, so the parsing logic is exercised
# without a MiSTer in the loop.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/device_pids.sh"

fails=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1: expected '$2' got '$3'"; fails=$((fails+1)); fi
}

# Captured busybox 1.33 `ps` output. Note the grep line itself must NOT match,
# and the harness's own script name must NOT match — only './gmloader' does.
FAKE_PS='  PID USER       VSZ STAT COMMAND
    1 root      2384 S    init
  871 root     11276 S    ./gmloader -c gmloader.json
  902 root      1200 S    grep gmloader
  915 root      1200 S    /bin/sh /tmp/bench_gmloader_wrapper.sh'

FAKE_PS_TWO='  PID USER       VSZ STAT COMMAND
  871 root     11276 S    ./gmloader -c gmloader.json
  988 root     11276 S    ./gmloader -c gmloader.json'

FAKE_PS_NONE='  PID USER       VSZ STAT COMMAND
    1 root      2384 S    init'

FAKE_OUT=""
fake_ssh() { echo "$FAKE_OUT" | eval "$(printf '%s' "$1" | sed "s|^ps|cat|")"; }

FAKE_OUT="$FAKE_PS"
check "single engine -> one pid"  "871" "$(devpid_count fake_ssh)"
FAKE_OUT="$FAKE_PS_TWO"
check "two engines -> two pids"   "2"   "$(devpid_count fake_ssh | wc -l | tr -d ' ')"
FAKE_OUT="$FAKE_PS_NONE"
check "no engine -> empty"        ""    "$(devpid_count fake_ssh)"

exit $((fails > 0))
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
chmod +x scripts/lib/device_pids_test.sh && ./scripts/lib/device_pids_test.sh
```

Expected: FAIL — `scripts/lib/device_pids.sh: No such file or directory`.

- [ ] **Step 4: Implement `device_pids.sh`**

Create `scripts/lib/device_pids.sh`:

```bash
# device_pids.sh — busybox-safe engine process discipline for MiSTer targets.
#
# WHY THIS FILE EXISTS: MiSTer busybox 1.33 has NO pkill and NO pgrep. Calls to
# them fail SILENTLY, so every "I killed the old instance" guard written with
# them passes vacuously. That produced the false "native audio wedges the
# fabric" conclusion (two engines writing one control block, 2026-07-27) and
# contaminated the fabric-park diagnosis before it.
#
# Two further traps encoded here:
#   - A pattern of plain 'gmloader' matches the *grep itself* and any harness
#     script whose argv contains the name. Only the engine invocation has the
#     './' prefix, so match "[.]/gmloader": the bracket keeps grep from
#     matching its own command line.
#   - awk '{print $1}' cannot be nested inside the single-quoted remote command
#     without escaping that differs between bash and busybox sh. sed does the
#     same field extraction with only double quotes.

# Remote snippet: prints one engine PID per line, nothing else.
DEVPID_CMD='ps | grep "[.]/gmloader" | sed -e "s/^ *//" -e "s/ .*//"'

# devpid_count <ssh-fn> -> prints the PIDs (one per line); empty if none.
devpid_count() {
  "$1" "$DEVPID_CMD"
}

# devpid_kill <ssh-fn> -> SIGKILL every engine PID. Never kills the caller.
devpid_kill() {
  "$1" "for p in \$($DEVPID_CMD); do kill -9 \$p 2>/dev/null; done; true"
}

# devpid_assert_one <ssh-fn> -> exit 0 iff exactly one engine is running.
# Prints the observed count so callers can log it per sample.
devpid_assert_one() {
  local n
  n=$("$1" "$DEVPID_CMD | wc -l" | tr -d ' ')
  # `wc -l` on empty input yields 0 on busybox; guard both spellings.
  [ -z "$n" ] && n=0
  echo "$n"
  [ "$n" = "1" ]
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
./scripts/lib/device_pids_test.sh
```

Expected: three `ok -` lines, exit status 0.

- [ ] **Step 6: Replace the vacuous kill guard in `gmloader_diag.sh`**

In `scripts/gmloader_diag.sh`, find:

```bash
# Avoid a double-launch / ETXTBSY when re-running from the menu.
pkill -9 -f "gmloader -c" 2>/dev/null
sleep 1
```

Replace with:

```bash
# Avoid a double-launch / ETXTBSY when re-running from the menu.
# busybox has NO pkill — it fails silently and this guard would pass vacuously.
# Match "[.]/gmloader" so neither grep nor this script matches itself.
for p in $(ps | grep "[.]/gmloader" | sed -e "s/^ *//" -e "s/ .*//"); do
    kill -9 "$p" 2>/dev/null
done
sleep 1
```

- [ ] **Step 7: Add the joy-shm knob and correct the stale geometry comments**

In `scripts/gmloader_diag.sh`, add alongside the other `E_*` declarations:

```bash
E_JOYSHM=""       # GMLOADER_JOY_SHM        scripted-input shm path override
```

Add to the argument parser, beside `--render`:

```bash
    --joy-shm)       E_JOYSHM="$2";  shift 2 ;;
```

Add to the env builder, beside the other `[ -n ... ] && ENV+=` lines:

```bash
[ -n "$E_JOYSHM" ] && ENV+=("GMLOADER_JOY_SHM=$E_JOYSHM")
```

Correct the two stale geometry comments — the native mode is 288×216, not 320×240:

```bash
E_RW=""           # GMLOADER_RENDER_W       render width  (<=288, level 2 only)
E_RH=""           # GMLOADER_RENDER_H       render height (<=216, level 2 only)
```

- [ ] **Step 8: Wire the helpers into `mister_run.sh`**

In `scripts/mister_run.sh`, after the `SSH()` definition, add:

```bash
. "$HERE/lib/device_pids.sh"
```

Replace the whole `do_stop()` body:

```bash
do_stop() {
  devpid_kill SSH
  echo "[stop] engine PIDs killed on $HOST"
}
```

Add a new sampling assertion used by every capture:

```bash
# assert_sole_engine <label> — abort the run unless exactly one engine is up.
# Called per SAMPLE, not once per run: the Master_Daemon can spawn a second
# engine at any point, and a mid-run second instance silently corrupts the
# control block (see lib/device_pids.sh).
assert_sole_engine() {
  local n
  if ! n=$(devpid_assert_one SSH); then
    echo "[ABORT] $1: expected exactly 1 gmloader process, found ${n:-0}" >&2
    return 1
  fi
  echo "[assert] $1: engine count = $n"
}
```

- [ ] **Step 9: Verify the harness against the live device**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
./scripts/mister_run.sh ping
./scripts/mister_run.sh deploy
```

Expected: `ping` reports SSH reachable and prints the current core; `deploy` prints `[deploy] installed /media/fat/Scripts/gmloader_diag.sh on root@192.168.20.81`.

- [ ] **Step 10: Verify the assertion fires correctly in both directions**

```bash
./scripts/mister_run.sh stop
ssh root@192.168.20.81 'ps | grep "[.]/gmloader" | sed -e "s/^ *//" -e "s/ .*//" | wc -l'
```

Expected: `0` — and a subsequent `assert_sole_engine` call must ABORT rather than pass. Confirm the negative case explicitly:

```bash
bash -c '. scripts/lib/device_pids.sh; SSH() { ssh -o BatchMode=yes root@192.168.20.81 "$@"; };
         n=$(devpid_assert_one SSH) && echo "PASS n=$n" || echo "ABORT n=$n"'
```

Expected: `ABORT n=0` with no engine running. A guard that cannot fail is the bug this task exists to prevent — do not proceed until you have *seen* it abort.

- [ ] **Step 11: Commit**

```bash
git add scripts/
git commit -m "tooling: forward-port bench harness to master with busybox-safe PID discipline

The harness lived only on perf/mfgpu-submit-profiling @07bf085. Bring it to
master and replace the pkill-based guards, which fail silently on busybox 1.33
and therefore passed vacuously — the mechanism behind the false 'native audio
wedges the fabric' conclusion.

PID discovery, kill and sole-instance assertion move to scripts/lib/device_pids.sh
with a host-side test using captured busybox ps output, so the parsing is
covered without a device in the loop.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Scene-script parser

A pure, host-testable parser. No I/O, no shm, no timing — those belong to Task 3.

**Files:**
- Create: `tools/joy_script_parse.h`, `tools/joy_script_parse.c`, `tools/joy_script_parse_test.c` (all in `gmloader-next`)
- Modify: `Makefile.gmloader` (add the `joy-script-test` target)

**Interfaces:**
- Consumes: nothing
- Produces: `JoyScript` struct and `int JoyScript_ParseText(const char *text, JoyScript *out, int *err_line)` returning `0` on success and a negative code on error. Task 3 links this directly.

- [ ] **Step 1: Write the header**

Create `tools/joy_script_parse.h`:

```c
#ifndef JOY_SCRIPT_PARSE_H
#define JOY_SCRIPT_PARSE_H
/*
 * Scene-script parser for the bench joystick driver.
 *
 * Script grammar (one directive per line; '#' starts a comment, blank lines
 * are ignored):
 *
 *     settle <ms>          how long to wait after the LAST step before the
 *                          scene is declared settled (optional, default 0)
 *     <at_ms> <mask>       hold <mask> from <at_ms> onward. <at_ms> is
 *                          milliseconds from driver start and must be
 *                          non-decreasing. <mask> accepts decimal or 0x hex.
 *
 * Mask bits (mister_joy_shm.h):
 *   bit0=right bit1=left bit2=down bit3=up
 *   bit4=Sword bit5=Action bit6=Item1 bit7=Item2 bit8=Pause
 */
#include <stdint.h>
#include <stddef.h>

#define JOY_SCRIPT_MAX_STEPS 256
#define JOY_SCRIPT_MASK_MAX  0x1FFu

typedef struct { uint32_t at_ms; uint32_t mask; } JoyScriptStep;

typedef struct {
    JoyScriptStep steps[JOY_SCRIPT_MAX_STEPS];
    size_t        n;
    uint32_t      settle_ms;
} JoyScript;

/* Error codes (all negative). *err_line receives the 1-based offending line. */
#define JOY_SCRIPT_ERR_ARGS       (-1)
#define JOY_SCRIPT_ERR_LONG_LINE  (-2)
#define JOY_SCRIPT_ERR_SETTLE     (-3)
#define JOY_SCRIPT_ERR_SYNTAX     (-4)
#define JOY_SCRIPT_ERR_MASK_RANGE (-5)
#define JOY_SCRIPT_ERR_NOT_MONO   (-6)
#define JOY_SCRIPT_ERR_TOO_MANY   (-7)

int JoyScript_ParseText(const char *text, JoyScript *out, int *err_line);

#endif /* JOY_SCRIPT_PARSE_H */
```

- [ ] **Step 2: Write the failing test**

Create `tools/joy_script_parse_test.c`:

```c
#include "joy_script_parse.h"
#include <stdio.h>
#include <string.h>

static int fails = 0;
#define CHECK(c) do { if (!(c)) { \
    printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

int main(void) {
    JoyScript js; int line = 0;

    /* 1. A minimal two-step script parses. */
    CHECK(JoyScript_ParseText("0 0\n1500 0x008\n", &js, &line) == 0);
    CHECK(js.n == 2);
    CHECK(js.steps[0].at_ms == 0u   && js.steps[0].mask == 0x000u);
    CHECK(js.steps[1].at_ms == 1500u && js.steps[1].mask == 0x008u);

    /* 2. Comments, blank lines and indentation are ignored. */
    CHECK(JoyScript_ParseText("# lead-in\n\n   \n  200 16  \n", &js, &line) == 0);
    CHECK(js.n == 1);
    CHECK(js.steps[0].at_ms == 200u && js.steps[0].mask == 16u);

    /* 3. The settle directive is captured and is not a step. */
    CHECK(JoyScript_ParseText("0 0\nsettle 3000\n", &js, &line) == 0);
    CHECK(js.n == 1);
    CHECK(js.settle_ms == 3000u);

    /* 4. Non-decreasing timestamps are required: a benchmark whose steps run
     *    out of order lands on a different scene than the file describes. */
    CHECK(JoyScript_ParseText("1000 0\n999 0\n", &js, &line) == JOY_SCRIPT_ERR_NOT_MONO);
    CHECK(line == 2);

    /* 5. Equal timestamps ARE allowed (two presses on the same tick). */
    CHECK(JoyScript_ParseText("100 1\n100 2\n", &js, &line) == 0);
    CHECK(js.n == 2);

    /* 6. Masks above bit8 are rejected — they would silently set no button. */
    CHECK(JoyScript_ParseText("0 0x200\n", &js, &line) == JOY_SCRIPT_ERR_MASK_RANGE);
    CHECK(line == 1);

    /* 7. A line missing its mask is a syntax error, not a zero mask. */
    CHECK(JoyScript_ParseText("0\n", &js, &line) == JOY_SCRIPT_ERR_SYNTAX);
    CHECK(line == 1);

    /* 8. Trailing garbage is rejected rather than silently ignored. */
    CHECK(JoyScript_ParseText("0 1 oops\n", &js, &line) == JOY_SCRIPT_ERR_SYNTAX);

    /* 9. An empty script parses to zero steps (the caller rejects it). */
    CHECK(JoyScript_ParseText("# nothing\n", &js, &line) == 0);
    CHECK(js.n == 0);

    /* 10. A file with no trailing newline still parses its last line. */
    CHECK(JoyScript_ParseText("0 0\n50 4", &js, &line) == 0);
    CHECK(js.n == 2 && js.steps[1].mask == 4u);

    if (fails == 0) printf("joy_script_parse_test: all checks passed\n");
    return fails != 0;
}
```

- [ ] **Step 3: Add the make target**

In `Makefile.gmloader`, after the `native-audio-writer-test` target, add:

```make
.PHONY: joy-script-test
joy-script-test:
	cc -std=c11 -O0 -g -Itools \
	  tools/joy_script_parse_test.c \
	  tools/joy_script_parse.c \
	  -o /tmp/jspt && /tmp/jspt
```

- [ ] **Step 4: Run the test to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
make -f Makefile.gmloader joy-script-test
```

Expected: FAIL — `tools/joy_script_parse.c: No such file or directory`.

- [ ] **Step 5: Implement the parser**

Create `tools/joy_script_parse.c`:

```c
#include "joy_script_parse.h"
#include <stdlib.h>
#include <string.h>

static const char *skip_ws(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\r') p++;
    return p;
}

int JoyScript_ParseText(const char *text, JoyScript *out, int *err_line) {
    if (!text || !out) return JOY_SCRIPT_ERR_ARGS;
    memset(out, 0, sizeof(*out));

    const char *p = text;
    int   line_no = 0;
    long  last_ms = -1;

    while (*p) {
        const char *eol = strchr(p, '\n');
        size_t len = eol ? (size_t)(eol - p) : strlen(p);
        char buf[160];
        line_no++;
        if (len >= sizeof(buf)) {
            if (err_line) *err_line = line_no;
            return JOY_SCRIPT_ERR_LONG_LINE;
        }
        memcpy(buf, p, len);
        buf[len] = '\0';
        p = eol ? eol + 1 : p + len;

        const char *s = skip_ws(buf);
        if (*s == '\0' || *s == '#') continue;

        if (strncmp(s, "settle", 6) == 0 && (s[6] == ' ' || s[6] == '\t')) {
            char *end;
            unsigned long v = strtoul(s + 6, &end, 10);
            if (end == s + 6 || *skip_ws(end) != '\0') {
                if (err_line) *err_line = line_no;
                return JOY_SCRIPT_ERR_SETTLE;
            }
            out->settle_ms = (uint32_t)v;
            continue;
        }

        char *end;
        unsigned long at = strtoul(s, &end, 10);
        if (end == s) {
            if (err_line) *err_line = line_no;
            return JOY_SCRIPT_ERR_SYNTAX;
        }
        const char *m = skip_ws(end);
        if (*m == '\0') {
            if (err_line) *err_line = line_no;
            return JOY_SCRIPT_ERR_SYNTAX;
        }
        unsigned long mask = strtoul(m, &end, 0);   /* base 0: accepts 0x hex */
        if (end == m || *skip_ws(end) != '\0') {
            if (err_line) *err_line = line_no;
            return JOY_SCRIPT_ERR_SYNTAX;
        }
        if (mask > JOY_SCRIPT_MASK_MAX) {
            if (err_line) *err_line = line_no;
            return JOY_SCRIPT_ERR_MASK_RANGE;
        }
        if ((long)at < last_ms) {
            if (err_line) *err_line = line_no;
            return JOY_SCRIPT_ERR_NOT_MONO;
        }
        if (out->n >= JOY_SCRIPT_MAX_STEPS) {
            if (err_line) *err_line = line_no;
            return JOY_SCRIPT_ERR_TOO_MANY;
        }
        last_ms = (long)at;
        out->steps[out->n].at_ms = (uint32_t)at;
        out->steps[out->n].mask  = (uint32_t)mask;
        out->n++;
    }
    return 0;
}
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
make -f Makefile.gmloader joy-script-test
```

Expected: `joy_script_parse_test: all checks passed`, exit status 0.

- [ ] **Step 7: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git add tools/joy_script_parse.h tools/joy_script_parse.c tools/joy_script_parse_test.c Makefile.gmloader
git commit -m "tools: scene-script parser for deterministic bench input

Pure parser, no I/O, so the grammar is covered by a host-native test with no
device in the loop. Rejects non-monotonic timestamps and out-of-range masks
rather than silently accepting them — a benchmark that runs its steps out of
order lands on a different scene than the script describes, which is worse
than no benchmark.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Joystick script driver

The device tool: owns the shm file, replays the parsed script on a monotonic clock, holds the final mask.

**Files:**
- Create: `tools/joy_script.c` (gmloader-next)
- Create: `scripts/scenes/ingame-stage1.joy` (mister-gmloader)

**Interfaces:**
- Consumes: `JoyScript_ParseText` from Task 2; `MalditaJoyShm`, `MALDITA_JOY_SHM_MAGIC`, `MALDITA_JOY_SHM_VERSION`, `MALDITA_JOY_SHM_PATH` from `gmloader/mister/mister_joy_shm.h`
- Produces: device binary `joy_script.armhf`, invoked as `joy_script <shm-path> <script-file>`. Emits `JOYSCRIPT start …`, `JOYSCRIPT step=…`, `JOYSCRIPT settled …` lines on stdout. Tasks 5, 6 and 8 depend on the `settled` marker to know when to begin capture.

- [ ] **Step 1: Implement the driver**

Create `tools/joy_script.c`:

```c
/*
 * joy_script — deterministic joystick replay for bench runs.
 *
 * Creates and owns the joy-shm file, then walks a script of timed button
 * masks on the monotonic clock. gmloader's input path (input.cpp:307-319)
 * prefers shm over the FPGA's DDR joystick words whenever JoyShm_Init()
 * succeeds, so simply creating a valid file diverts the engine from the
 * physical joystick to this script.
 *
 * ORDERING IS LOAD-BEARING: g_joyshm_ready latches on the engine's FIRST input
 * poll and is never re-evaluated. Start this driver BEFORE loading the core.
 * If the file is not valid by then, the run silently uses the real joystick
 * for its entire life and the capture is meaningless.
 *
 * The magic word is written LAST, after version/generation/masks, so a reader
 * that maps the file mid-initialisation cannot validate a half-built header —
 * the same doorbell-last discipline blitter_top.sv uses for C_DONE.
 */
#define _POSIX_C_SOURCE 200809L
#include "joy_script_parse.h"
#include "../gmloader/mister/mister_joy_shm.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    rewind(f);
    char *buf = (char *)malloc((size_t)sz + 1u);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1u, (size_t)sz, f);
    fclose(f);
    buf[got] = '\0';
    return buf;
}

/* Absolute-deadline sleep: each step fires at base+ms, so per-step scheduling
 * jitter cannot accumulate across a long script. */
static void sleep_until_ms(const struct timespec *base, uint32_t ms) {
    struct timespec d = *base;
    d.tv_sec  += (time_t)(ms / 1000u);
    d.tv_nsec += (long)(ms % 1000u) * 1000000L;
    if (d.tv_nsec >= 1000000000L) { d.tv_nsec -= 1000000000L; d.tv_sec += 1; }
    int rc;
    while ((rc = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &d, NULL)) == EINTR)
        if (g_stop) return;
    (void)rc;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: joy_script <shm-path> <script-file>\n"
                        "       shm-path is normally %s\n", MALDITA_JOY_SHM_PATH);
        return 2;
    }
    const char *shm_path    = argv[1];
    const char *script_path = argv[2];

    char *text = read_file(script_path);
    if (!text) {
        fprintf(stderr, "joy_script: cannot read %s: %s\n", script_path, strerror(errno));
        return 1;
    }
    JoyScript js;
    int err_line = 0;
    int rc = JoyScript_ParseText(text, &js, &err_line);
    free(text);
    if (rc != 0) {
        fprintf(stderr, "joy_script: parse error %d at %s:%d\n", rc, script_path, err_line);
        return 1;
    }
    if (js.n == 0) {
        fprintf(stderr, "joy_script: %s contains no steps\n", script_path);
        return 1;
    }

    int fd = open(shm_path, O_RDWR | O_CREAT, 0666);
    if (fd < 0) {
        fprintf(stderr, "joy_script: open %s: %s\n", shm_path, strerror(errno));
        return 1;
    }
    if (ftruncate(fd, (off_t)sizeof(MalditaJoyShm)) != 0) {
        fprintf(stderr, "joy_script: ftruncate %s: %s\n", shm_path, strerror(errno));
        close(fd);
        return 1;
    }
    MalditaJoyShm *p = (MalditaJoyShm *)mmap(NULL, sizeof(MalditaJoyShm),
                                             PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        fprintf(stderr, "joy_script: mmap %s: %s\n", shm_path, strerror(errno));
        return 1;
    }

    p->joy_mask[0] = 0u;
    p->joy_mask[1] = 0u;
    p->version     = MALDITA_JOY_SHM_VERSION;
    p->generation += 1u;
    __sync_synchronize();
    p->magic = MALDITA_JOY_SHM_MAGIC;      /* doorbell LAST */
    __sync_synchronize();

    signal(SIGINT,  on_sig);
    signal(SIGTERM, on_sig);

    struct timespec base;
    clock_gettime(CLOCK_MONOTONIC, &base);
    printf("JOYSCRIPT start steps=%zu settle_ms=%u shm=%s script=%s\n",
           js.n, js.settle_ms, shm_path, script_path);
    fflush(stdout);

    for (size_t i = 0; i < js.n && !g_stop; i++) {
        sleep_until_ms(&base, js.steps[i].at_ms);
        if (g_stop) break;
        p->joy_mask[0] = js.steps[i].mask;   /* single naturally-aligned word */
        __sync_synchronize();
        printf("JOYSCRIPT step=%zu t=%ums mask=0x%03X\n",
               i, js.steps[i].at_ms, js.steps[i].mask);
        fflush(stdout);
    }

    if (!g_stop) {
        uint32_t settled_at = js.steps[js.n - 1u].at_ms + js.settle_ms;
        sleep_until_ms(&base, settled_at);
        printf("JOYSCRIPT settled t=%ums mask=0x%03X capture-may-begin\n",
               settled_at, js.steps[js.n - 1u].mask);
        fflush(stdout);
    }

    /* Hold the final mask until killed: the scene must not drift while the
     * capture runs. */
    while (!g_stop) sleep(1);

    printf("JOYSCRIPT stop\n");
    fflush(stdout);
    munmap((void *)p, sizeof(MalditaJoyShm));
    return 0;
}
```

- [ ] **Step 2: Verify the cross toolchain is present**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
/opt/homebrew/bin/docker run --rm -v "$(pwd):/src" -w /src \
  gmloader-armhf-build:bullseye arm-linux-gnueabihf-gcc --version
```

Expected: a gcc version banner. If the image is missing, build it first:
`/opt/homebrew/bin/docker build -f Dockerfile.gmloader-build -t gmloader-armhf-build:bullseye .`

- [ ] **Step 3: Cross-compile the driver**

```bash
/opt/homebrew/bin/docker run --rm -v "$(pwd):/src" -w /src \
  gmloader-armhf-build:bullseye \
  arm-linux-gnueabihf-gcc -std=c11 -O2 -Itools \
    tools/joy_script.c tools/joy_script_parse.c \
    -o tools/joy_script.armhf
file tools/joy_script.armhf
```

Expected: `ELF 32-bit LSB ... ARM, EABI5`.

- [ ] **Step 4: Write the scene script**

Create `mister-gmloader/scripts/scenes/ingame-stage1.joy`. The timings below are a **starting point to be tuned on device in Step 6** — the intro length is not known a priori.

```
# ingame-stage1.joy — drive Maldita Castilla from cold launch into stage 1.
#
# Mask bits: bit0=right bit1=left bit2=down bit3=up
#            bit4=Sword bit5=Action bit6=Item1 bit7=Item2 bit8=Pause
# Each line holds its mask until the next line. Times are ms from driver start.
#
# The engine needs several seconds to load 49MB of game data before it reads
# any input at all, so nothing before ~8000 will register.

0     0x000      # idle through engine startup and the intro
9000  0x100      # Pause/Start — skip the intro
9200  0x000      # release
11000 0x100      # Start — title screen into the game
11200 0x000      # release
14000 0x100      # Start — dismiss any remaining prompt
14200 0x000      # release

# Hold neutral once in-game. A held direction would walk the player into a
# different part of the stage on every run, defeating the whole point.
16000 0x000

# Let the scene reach steady state (parallax settled, sprites spawned) before
# any frame is counted.
settle 6000
```

- [ ] **Step 5: Deploy the driver and script to the device**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
scp tools/joy_script.armhf root@192.168.20.81:/media/fat/games/gmloader/joy_script
ssh root@192.168.20.81 'chmod +x /media/fat/games/gmloader/joy_script'
scp ../mister-gmloader/scripts/scenes/ingame-stage1.joy \
    root@192.168.20.81:/media/fat/games/gmloader/scene.joy
```

- [ ] **Step 6: Device smoke test — tune the script until it reliably reaches gameplay**

```bash
ssh root@192.168.20.81 'cd /media/fat/games/gmloader && \
  for p in $(ps | grep "[.]/gmloader" | sed -e "s/^ *//" -e "s/ .*//"); do kill -9 $p; done; \
  rm -f /dev/shm/maldita-joy; \
  setsid ./joy_script /dev/shm/maldita-joy scene.joy > /tmp/joyscript.log 2>&1 &
  sleep 1; echo "load_core /media/fat/_Other/MalditaCastilla_20260717.rbf" > /dev/MiSTer_cmd'
```

Wait ~30 s, then inspect:

```bash
ssh root@192.168.20.81 'cat /tmp/joyscript.log; echo ---; \
  tail -20 /media/fat/logs/MalditaCastilla/maldita.log'
```

Expected: `JOYSCRIPT start`, each `step=`, then `JOYSCRIPT settled … capture-may-begin`; and the engine log showing a rising `tris=` count consistent with gameplay rather than the ~28-triangle menu.

**This step iterates.** If the game has not reached stage 1, adjust the timings in `ingame-stage1.joy`, re-copy, and re-run. Do not proceed until three consecutive runs land in gameplay.

- [ ] **Step 7: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git add tools/joy_script.c
git commit -m "tools: joy_script — deterministic scripted input for bench runs

Creating a valid joy-shm file diverts gmloader from the physical joystick to a
timed script (input.cpp prefers shm over the FPGA DDR joystick words). The
handler launch path provides no shm producer of its own, so there is no
competing writer.

Magic is written last, after the other header fields, so a reader mapping the
file mid-initialisation cannot validate a half-built header — the same
doorbell-last discipline the fabric uses for C_DONE. Steps fire on absolute
monotonic deadlines so jitter cannot accumulate across a long script.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"

cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git add scripts/scenes/ingame-stage1.joy
git commit -m "bench: version-controlled scene script for the in-game capture

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Host observability — input transport and coverage estimate

Two blind spots close here. Which input transport won is currently unloggable, so a silently-failed injection is indistinguishable from a working one. And `covered_px` has no source at all — the ~3.1× overdraw figure was back-calculated by dividing device `dpath` by the sim's cyc/px, which assumes the throughput it is then used to characterize.

**Files:**
- Modify: `gmloader/input.cpp` (gmloader-next)
- Modify: `gmloader/mister/raster_backend_mfgpu.cpp` (gmloader-next)

**Interfaces:**
- Consumes: nothing from prior tasks
- Produces: a `JOYSRC transport=shm|ddr|sdl` log line emitted once; and an extra `cov_px=<n> overdraw=<f>` field on the existing `MFSUBMIT …` line. Tasks 5, 6 and 8 grep for both.

- [ ] **Step 1: Add the transport log line**

In `gmloader/input.cpp`, replace:

```c
    if (g_joyshm_ready == -1) g_joyshm_ready = JoyShm_Init() ? 1 : 0;
    if (g_joyddr_ready == -1) g_joyddr_ready = JoyDdr_Init() ? 1 : 0;
```

with:

```c
    if (g_joyshm_ready == -1 || g_joyddr_ready == -1) {
        if (g_joyshm_ready == -1) g_joyshm_ready = JoyShm_Init() ? 1 : 0;
        if (g_joyddr_ready == -1) g_joyddr_ready = JoyDdr_Init() ? 1 : 0;
        // Log the winning transport ONCE. Selection latches here and is never
        // re-evaluated, and a failed shm injection is otherwise indistinguishable
        // from a working one — a scripted bench run would silently fall back to
        // the physical joystick and sit on the title screen for its whole life.
        fprintf(stderr, "JOYSRC transport=%s\n",
                (g_joyshm_ready == 1) ? "shm"
                                      : (g_joyddr_ready == 1) ? "ddr" : "sdl");
    }
```

- [ ] **Step 2: Verify the log line appears on device**

Rebuild and deploy the engine (full recipe in `gmloader-next/CLAUDE.md`):

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
/opt/homebrew/bin/docker run --rm -v "$(pwd):/src" -w /src gmloader-armhf-build:bullseye bash -c '
  touch thunks/thunk_gen_dyn.h
  make -f Makefile.gmloader ARCH=arm-linux-gnueabihf MISTER_BUILD=1 MISTER_NATIVE_VIDEO=1 \
    "LLVM_INC=/usr/arm-linux-gnueabihf/include /usr/arm-linux-gnueabihf/include/c++/10/arm-linux-gnueabihf" \
    -j$(nproc)'
scp build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf \
    root@192.168.20.81:/media/fat/games/gmloader/gmloader
```

Run once **with** the driver active and once **without** it:

```bash
ssh root@192.168.20.81 'grep JOYSRC /media/fat/logs/MalditaCastilla/maldita.log'
```

Expected: `JOYSRC transport=shm` when `joy_script` started first; `JOYSRC transport=ddr` when `/dev/shm/maldita-joy` was removed beforehand. **Both cases must be observed** — a log line that always prints the same value proves nothing.

- [ ] **Step 3: Add the coverage accumulator**

In `gmloader/mister/raster_backend_mfgpu.cpp`, add above `mf_submit_stat`:

```c
// Host-side covered-pixel estimate. No fabric counter publishes covered_px, and
// the ~3.1x overdraw figure on record was back-calculated by dividing device
// dpath by the sim's 13 cyc/px — which assumes the very throughput the number is
// then used to characterize. This breaks that circularity.
//
// Sum of |cross product| / 2 over submitted triangles = covered area INCLUDING
// overdraw. It is an ESTIMATE: it ignores scissor and clipping, and counts
// degenerate triangles as zero. Reported as cov_px_est, never as exact.
static double g_cov_px_accum = 0.0;

void mf_cov_add_triangle(float x0, float y0, float x1, float y1, float x2, float y2) {
    const double cross = (double)(x1 - x0) * (double)(y2 - y0)
                       - (double)(x2 - x0) * (double)(y1 - y0);
    g_cov_px_accum += (cross < 0.0 ? -cross : cross) * 0.5;
}
```

In `mf_submit_stat`, extend the accumulators and the print. Replace:

```c
    static unsigned n = 0, to = 0; static double lo = 1e12, hi = 0, sum = 0; static long it_sum = 0;
    static double fsum = 0, tsum = 0, xsum = 0;
    n++; to += timeout ? 1u : 0u; sum += us; it_sum += iters; fsum += frame_ms; tsum += tri_ms; xsum += texw_ms;
```

with:

```c
    static unsigned n = 0, to = 0; static double sum = 0; static long it_sum = 0;
    static double fsum = 0, tsum = 0, xsum = 0, csum = 0;
    n++; to += timeout ? 1u : 0u; sum += us; it_sum += iters; fsum += frame_ms; tsum += tri_ms; xsum += texw_ms;
    csum += g_cov_px_accum; g_cov_px_accum = 0.0;   // per-frame: reset after folding in
```

Note the `lo` / `hi` accumulators are **dropped**, not carried forward. They were computed and reset every window but never printed — the min/max they tracked has not appeared in the output since the line was last reworked. This edit already rewrites both statements that touch them, so leaving them in place would be knowingly preserving dead code.

Then delete the now-orphaned `if (us < lo) lo = us; if (us > hi) hi = us;` line directly below.

Replace the `fprintf` and the reset line:

```c
    if (n % 30 == 0) {
        double f=fsum/30.0, t=tsum/30.0, x=xsum/30.0, c=csum/30.0;
        // cyc_px uses the fabric clock: dpath_ms * clk_MHz * 1000 / covered_px.
        double dpath_ms = t - x;
        double cyc_px = (c > 1.0) ? (dpath_ms * MF_CLK_SYS_MHZ * 1000.0) / c : 0.0;
        // Screen area comes from the fabric geometry macros, never a literal:
        // MISTER_WIDTH/HEIGHT arrive as -D flags, so a hardcoded 288x216 here
        // would silently survive a geometry change and report a wrong overdraw.
        const double screen_px = (double)BLT_FB_WIDTH * (double)BLT_FB_HEIGHT;
        fprintf(stderr, "MFSUBMIT n=%u wait_ms[avg=%.2f] fabric_ms[frame=%.2f tri=%.2f "
                "texwait=%.2f dpath=%.2f ovhd=%.2f] cov_px_est=%.0f overdraw=%.2f "
                "cyc_px=%.1f spin_avg=%ld to=%u\n",
                n, (sum/30.0)/1e3, f, t, x, dpath_ms, f-t,
                c, c / screen_px, cyc_px, it_sum/30, to);
        sum = 0; it_sum = 0; to = 0;
        fsum = 0; tsum = 0; xsum = 0; csum = 0;
    }
```

- [ ] **Step 4: Call the accumulator from the triangle emitter**

**Correction (post-implementation): this landed in `gmloader/mister/raster_backend_mfgpu.cpp`, not `blitter_raster.cpp`** — see the file map above and `docs/superpowers/investigations/2026-07-28-fabric-ms-insensitivity.md`'s "Is Task 7 required?" section, which names `mf_cov_add_triangle` in `raster_backend_mfgpu.cpp`. Left as originally planned below for history; do not follow the `blitter_raster.cpp` path literally.

In `gmloader/mister/blitter_raster.cpp`, find the point where each triangle's screen-space vertices are finalized for submission. Add the declaration near the other backend externs:

```c
// Defined in raster_backend_mfgpu.cpp — host-side covered-pixel estimate.
void mf_cov_add_triangle(float x0, float y0, float x1, float y1, float x2, float y2);
```

and call it once per emitted triangle with the same screen-space coordinates handed to the backend.

- [ ] **Step 5: Verify coverage scales with scene complexity**

This is the acceptance test for the estimate — a coverage number that does not move with the scene is as useless as the counter it replaces.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
./scripts/mister_run.sh bench --secs 20 --preset fabric   # menu, ~28 tris
```

then re-run with the scene driver active so the capture lands in gameplay. Compare:

```bash
grep -o 'cov_px_est=[0-9]*' bench-results/<menu-log> | tail -3
grep -o 'cov_px_est=[0-9]*' bench-results/<ingame-log> | tail -3
```

Expected: the in-game `cov_px_est` is **several times** the menu value, and `overdraw` in-game is plausibly above 1.0. If in-game coverage equals menu coverage, the accumulator is not wired into the real emit path — fix that before continuing.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git add gmloader/input.cpp gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/blitter_raster.cpp
git commit -m "instr: log the input transport and estimate covered pixels host-side

Two blind spots. JoyShm_Init() logged nothing, so a scripted bench run that
silently fell back to the physical joystick was indistinguishable in the log
from a working injection. And covered_px had no source at all — the ~3.1x
overdraw on record was back-calculated by dividing device dpath by the sim's
13 cyc/px, assuming the throughput it was then used to characterize.

The coverage figure is an estimate (ignores scissor and clipping) and is named
cov_px_est accordingly.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Instrument repair — hypotheses H1 and H2

Both are free and between them explain the observation completely. Use `superpowers:systematic-debugging`.

**Files:**
- Create: `docs/superpowers/investigations/2026-07-28-fabric-ms-insensitivity.md` (mister-gmloader)

**Interfaces:**
- Consumes: harness from Task 1, driver from Task 3, transport log from Task 4
- Produces: a written verdict for H1 and H2, each CONFIRMED or REFUTED with the evidence inline. Task 6 reads this to decide whether H3/H4 still need testing.

- [ ] **Step 1: Test H1 — are the counter words carrying wedge snapshots?**

Under `SOLARUS_DBG_PROBES`, `C_STATUS.hi` publishes `wedge_snap2` and `C_SRCSEL.hi` publishes `wedge_snap` — persistent worst-case snapshots, structurally scene-insensitive. Read both words raw while the engine runs:

```bash
ssh root@192.168.20.81 'for i in 1 2 3 4 5; do \
  printf "status_hi="; devmem 0x3B000034; \
  printf "srcsel_hi="; devmem 0x3B00003C; \
  printf "done_hi=";   devmem 0x3B00002C; \
  echo; sleep 1; done'
```

Interpretation, decided **before** looking:
- A packed bbox (`maxx | maxy<<16`) has a low half under 288 and a high half under 216 — both small, and **monotonically non-decreasing** across samples (it is a worst-case latch).
- A cycle counter at ~25 ms and 98.4375 MHz is ≈ 2.5e6, and **varies** sample to sample.

Record which pattern each word shows.

- [ ] **Step 2: Confirm H1 against the bitstream's build configuration**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
grep -n "SOLARUS_DBG_PROBES" fpga/Maldita.qsf
git log --oneline -5 -- fpga/Maldita.qsf
```

Expected: the define is absent or commented, with the `2026-07-24` warning note at line 21. Cross-check which RBF is actually loaded on the device and which commit built it — `deploy.py --fetch-rbf` resolves the RBF by `fpga/` tree hash and refuses a mismatched pair.

- [ ] **Step 3: Test H2 — re-run the original A/B under the sole-instance assertion**

The 2026-07-17 measurement predates the discipline that later overturned the audio-wedge result. Repeat it, asserting per sample:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
./scripts/mister_run.sh bench --secs 25 --preset fabric   # menu scene, ~28 tris
# then, with joy_script driving into gameplay:
./scripts/mister_run.sh bench --secs 25 --preset fabric --scene ingame-stage1
```

For every sample the harness must print `[assert] …: engine count = 1`. If any sample reports 2, the run is void — that alone confirms H2 as the cause of the original observation.

- [ ] **Step 4: Compare `tri_ms` between the two tri counts**

```bash
grep -o 'tri=[0-9.]*' bench-results/<menu-log>   | tail -5
grep -o 'tri=[0-9.]*' bench-results/<ingame-log> | tail -5
grep -o 'tris=[0-9]*' bench-results/<menu-log>   | tail -3
grep -o 'tris=[0-9]*' bench-results/<ingame-log> | tail -3
```

Record whether `tri_ms` now differs between the two scenes, and by how much relative to the triangle-count ratio.

- [ ] **Step 5: Write the investigation note**

Create `docs/superpowers/investigations/2026-07-28-fabric-ms-insensitivity.md` recording, for H1 and H2 each: the hypothesis, the exact command run, the raw output, and a CONFIRMED or REFUTED verdict. Include the RBF tree hash and engine build id for every number.

State plainly if a hypothesis is refuted. The value of this note is that the next person does not re-test a dead hypothesis — the same reason the poll-wait and ch5-cache refutations are on record.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git add docs/superpowers/investigations/2026-07-28-fabric-ms-insensitivity.md
git commit -m "investigation: fabric_ms scene-insensitivity — H1/H2 verdicts

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Instrument repair — H3, H4, and the trust gate

**Files:**
- Modify: `docs/superpowers/investigations/2026-07-28-fabric-ms-insensitivity.md` (mister-gmloader)

**Interfaces:**
- Consumes: Task 5's verdicts
- Produces: a trust-gate verdict — PASS or FAIL — that Task 8 requires before recording any budget number.

- [ ] **Step 1: Test H3 — does `frame` track vblank rather than workload?**

`perf_frame_cyc` accumulates under `if (!idle)` (`blitter_top.sv:853`), and `idle` is set only in `S_POLL_SUBMIT` — so `S_SNAP_WAIT` and the vblank snapshot are counted. Compare the two slopes across the menu and in-game captures from Task 5:

```bash
grep -oE 'frame=[0-9.]+ tri=[0-9.]+' bench-results/<menu-log>   | tail -5
grep -oE 'frame=[0-9.]+ tri=[0-9.]+' bench-results/<ingame-log> | tail -5
```

Expected if H3 holds: `frame` is roughly flat and close to a scanout period while `tri` scales with the scene. That makes `frame` a wall-clock-to-vblank measure, not a workload measure — **not necessarily a defect**, but it means `tri` is the only throughput metric and `ovhd = frame − tri` is meaningless.

- [ ] **Step 2: Measure the actual scanout period**

Do not assume 60 Hz. From the core's video timing:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
grep -nE "V_FP|V_BP|V_SYNC|H_FP|H_BP|H_SYNC|262|CLK_VIDEO" fpga/Maldita.sv | head -20
```

The 288×216 design records 262 lines total at 59.92 Hz — confirm that is still what the RTL produces, and record the period in ms. This is the quantum any vsync-quantization claim is measured against.

- [ ] **Step 3: Test H4 — are the counter reads stable?**

Add a temporary double-read in `mf_submit_stat` (read each `hi` word twice back to back, print both) or read via `devmem` twice in rapid succession:

```bash
ssh root@192.168.20.81 'for i in 1 2 3 4 5 6 7 8 9 10; do \
  a=$(devmem 0x3B00003C); b=$(devmem 0x3B00003C); echo "$a $b"; done'
```

Expected if H4 is refuted: the two reads agree on every sample. Disagreement indicates the publish/read race survives the C_DONE-last ordering.

- [ ] **Step 4: Run the trust gate**

Two known, materially different triangle counts. The menu (~28 tris) and the settled in-game scene provide them; record the exact `tris=` for each.

The gate PASSES only if `tri_ms` differs **proportionally** — that is, the ratio of `tri_ms` between scenes is of the same order as the ratio of covered pixels (`cov_px_est`, from Task 4), not merely "different by a bit".

```bash
grep -oE 'tri=[0-9.]+ .*cov_px_est=[0-9]+' bench-results/<menu-log>   | tail -3
grep -oE 'tri=[0-9.]+ .*cov_px_est=[0-9]+' bench-results/<ingame-log> | tail -3
```

- [ ] **Step 5: Record the gate verdict**

Append to the investigation note: H3 and H4 verdicts, the measured scanout period, the two `(tris, cov_px_est, tri_ms)` triples, and **TRUST GATE: PASS** or **FAIL**.

If FAIL and H1–H4 are all refuted, stop and proceed to Task 7. If FAIL because a confounder was found, fix it and re-run this task. **Do not proceed to Task 8 on a FAIL.**

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/investigations/2026-07-28-fabric-ms-insensitivity.md
git commit -m "investigation: H3/H4 verdicts and the instrument trust gate

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7 (CONDITIONAL): RTL counter fix and exact coverage counter

**Entry condition:** Task 6 recorded **TRUST GATE: FAIL** with H1–H4 all refuted. If the gate passed, **skip this task entirely.**

Because a Quartus cycle is being spent anyway, bundle the exact `perf_covered_px` counter into the same build so the host estimate gains a cross-check. A build is not spent for that counter alone.

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (maldita.castilla-mister)
- Modify: `fpga/sim/tb_blitter_trilist_pipe.sv` (maldita.castilla-mister)

**Interfaces:**
- Consumes: Task 6's refutation evidence
- Produces: a rebuilt RBF whose `tri_ms` passes the Task 6 trust gate, plus `perf_covered_px` published to a spare control word.

- [ ] **Step 1: Add the failing simulation assertion**

In `fpga/sim/tb_blitter_trilist_pipe.sv`, add a check that `perf_covered_px` equals the testbench's independently counted covered-pixel total, and that `perf_tri_cyc` differs between a one-triangle and a many-triangle submission.

- [ ] **Step 2: Run the simulation to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
./fpga/sim/run_sims.sh tb_blitter_trilist_pipe
```

Expected: FAIL — `perf_covered_px` is not defined.

- [ ] **Step 3: Implement the counter and the fix**

Add beside the existing counters (`blitter_top.sv:302`):

```systemverilog
    reg  [31:0] perf_covered_px;   // covered-pixel writes this frame (exact overdraw)
```

Reset it with the others at `S_CHK_NEW` (`:897`) and increment it on each committed covered-pixel write. Publish it to a spare control word alongside the existing perf publishes.

Apply whatever fix Task 6's evidence indicates for the insensitivity itself.

**Mandatory check before building:** this file contains `ramstyle` arrays whose reads must never be nested in an FSM case arm — the `tq_data`/`tq_tag` M10K uninference defect cost 20,480 stray flops and a 1,735-fanout mux. After synthesis run `grep 276007 *.map.rpt` and confirm no new uninference warnings. The CI ast-grep gate (`c0ce8d5`) covers this pattern; do not bypass it.

- [ ] **Step 4: Run the simulation to verify it passes**

```bash
./fpga/sim/run_sims.sh tb_blitter_trilist_pipe
```

Expected: PASS, bit-exact against the golden refmodel.

- [ ] **Step 5: Build the bitstream on the canonical runner**

The canonical build is the self-hosted **Windows Quartus runner**; do not substitute the Linux fallback. Push the branch and let CI build, then check timing:

```bash
grep -A3 "Setup Slack" output_files/*.sta.rpt
grep 276007 output_files/*.map.rpt
```

Expected: setup slack no worse than the current −0.732 ns tint path, and no `276007` inference warnings.

- [ ] **Step 6: Deploy and re-run the Task 6 trust gate**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
./deploy.py --fetch-rbf --host 192.168.20.81
```

Re-run Task 6 Steps 4-5. Do not proceed to Task 8 until the gate passes.

- [ ] **Step 7: Commit**

```bash
git add fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_trilist_pipe.sv
git commit -m "instr(blitter): fix fabric_ms scene-insensitivity, add perf_covered_px

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Budget capture and the decision gate

**Precondition:** Task 6 recorded **TRUST GATE: PASS**.

**Files:**
- Create: `docs/superpowers/investigations/2026-07-28-ingame-frame-budget.md` (mister-gmloader)

**Interfaces:**
- Consumes: everything above
- Produces: the populated budget table, the serialization verdict, and the one-sentence arithmetic statement of what 60 fps requires. This is the phase deliverable and the input to the next spec.

- [ ] **Step 1: Capture three in-game runs**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
for i in 1 2 3; do
  ./scripts/mister_run.sh bench --secs 60 --preset fabric --scene ingame-stage1
  sleep 10
done
```

Each run must show `JOYSRC transport=shm`, `JOYSCRIPT settled`, and `[assert] engine count = 1` on every sample.

- [ ] **Step 2: Apply the determinism gate**

```bash
for f in bench-results/<the three logs>; do
  echo -n "$f mean tris: "
  grep -o 'tris=[0-9]*' "$f" | cut -d= -f2 | awk '{s+=$1; n++} END {print s/n}'
done
```

Expected: all three means agree within **±5%**. If not, the runs are void — retune the scene script (longer settle, or a more quiescent hold position) and repeat Step 1.

- [ ] **Step 3: Extract the budget line items**

```bash
grep -oE 'MFSUBMIT .*' bench-results/<log> | tail -20
grep -oE 'BLITPROF .*' bench-results/<log> | tail -20
```

Record, per run: host frame wall-clock, GM logic time, `tri`, `texwait`, `dpath`, `ovhd`, `cov_px_est`, `overdraw`, `cyc_px`, plus min/max/spread for each.

- [ ] **Step 4: Compute the derived numbers**

- `overdraw` = `cov_px_est` ÷ (288 × 216)
- `cyc_px` = `dpath_ms` × 98437.5 ÷ `cov_px_est`
- `serialization factor` = frame_time ÷ max(host_logic, fabric_busy)

Report the **spread** on each, not just the mean. A difference smaller than the spread is not a result.

- [ ] **Step 5: Determine the vsync-serialization verdict**

Compare mean frame time against the scanout period measured in Task 6 Step 2. State whether frame time is quantized to an integer multiple of it, and give the serialization factor with its spread.

This is the highest-consequence output. At 60 fps the entire budget is one vsync, so surviving serialization makes rasterizer throughput irrelevant — the lever would be overlap, not speed.

- [ ] **Step 6: Write the budget report and the decision gate**

Create `docs/superpowers/investigations/2026-07-28-ingame-frame-budget.md` with: full provenance (engine build id, RBF tree hash, scene-script hash, three run logs), the populated budget table, the derived numbers with spreads, the serialization verdict, and the closing arithmetic statement in this form:

> "Fabric raster is X ms at Y× overdraw and Z cyc/px; the host is W ms and is [fully serialized / partly overlapped]. 60 fps needs …"

Every clause must carry a measurement. If the honest conclusion is that 60 fps is unreachable inside the pixel-exact envelope, **say so plainly** — that is a valid and valuable outcome of this phase, and surfacing it now is the entire reason the phase exists.

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/investigations/2026-07-28-ingame-frame-budget.md
git commit -m "investigation: in-game frame budget and the 60fps decision gate

First measurement of a real Maldita gameplay scene under a trusted instrument.
Closes Phase 0: the budget table names the top lever with measurements attached,
replacing the static-analysis hypotheses that were falsified on device three
times running.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage.** Harness forward-port → Task 1. Scene driver (contract, single-producer, script format, determinism) → Tasks 2, 3. Instrument repair H1–H4 and the trust gate → Tasks 5, 6. Conditional RTL fix with bundled `perf_covered_px` → Task 7. Budget table, derived numbers, vsync question, decision gate → Task 8. Provenance and repeatability → Global Constraints, enforced in Tasks 5 and 8.

Two spec requirements needed tasks the spec did not anticipate, both added: the input-transport log (the spec identifies silent fallback as unobservable but assigns no owner) and the coverage accumulator (the spec's derived numbers depend on `covered_px`, which no counter publishes). Both live in Task 4.

**Placeholder scan.** One deliberate underspecification remains: Task 4 Step 4 says to call `mf_cov_add_triangle` "where each triangle's screen-space vertices are finalized" without a line number, because the exact emit site was not read during planning. The implementer must locate it. Task 4 Step 5 is the acceptance test that catches a miswiring. Task 3 Step 4's script timings are explicitly a starting point with a tuning loop in Step 6 — the intro length is not knowable in advance.

**Type consistency.** `JoyScript_ParseText` / `JoyScript` / `JoyScriptStep` are consistent between Tasks 2 and 3. `devpid_count` / `devpid_kill` / `devpid_assert_one` are consistent between Task 1 and its callers. `cov_px_est` is the field name in the log line, the accumulator, and Tasks 6 and 8.
