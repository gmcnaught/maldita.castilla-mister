# Feature 4 — `Restart Quest` → `Reset` + Engine Restart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the OSD entry `Restart Quest` to `Reset` and make it restart the engine in place (fresh process, RBF stays loaded), by having the wrapper take the OSD trigger bit directly.

**Architecture:** Two small changes, both in this repo. (1) CONF_STR label rename in `fpga/Maldita.sv` (branches off feat #3 to avoid the CONF_STR merge collision). (2) Fill the inert `maldita_osd.cpp` stub (from feat #1) so `maldita_osd_poll` takes the Reset T-bit via `user_io_status_trigger_take()` and requests a respawn. The wrapper loop (feat #1) already routes a requested restart to a clean in-place respawn that is NOT counted as a crash. The RTL `S_WR_STATUS`/`C_STATUS` mirror is left untouched — it still carries the FPS-overlay bit (bit1) to the engine.

**Tech Stack:** SystemVerilog (one-line CONF_STR edit), C++14 (wrapper OSD unit), MiSTer `user_io` status API.

## Global Constraints

- Branch/worktree: `feat/osd-reset` off **`feat/drop-sol-mount`** (feat #3), because both edit the CONF_STR block `fpga/Maldita.sv:269-284` and feat #3 removes the `SC0` line first (spec § "Conflict surface (a)"). The `maldita_osd.cpp` fill also needs feat #1's scaffolding — so this branch must sit on top of BOTH feat #3 and feat #1. See Task 1 for the merge base.
- The Reset trigger is CONF_STR `TJ` = status **bit 19** (`fpga/Maldita.sv:942` `osd_restart = status[19]`). Keep the CONF_STR letter `TJ` — only the label text changes.
- Do NOT delete or alter the RTL `S_WR_STATUS` path in `blitter_top.sv`: it publishes `C_STATUS` low32 `bit0=osd_restart_pending, bit1=osd_fps_on` (`blitter_top.sv:1480/1482`); bit1 is the live FPS-overlay transport and has no other path (spec § "Existing plumbing this obsoletes"). This branch changes host behaviour only.
- Verified: gmloader does NOT consume `C_STATUS` bit0 today (only `C_STATUS.hi` perf words) — so there is no engine-side restart consumer to remove. The wrapper becomes the sole Reset consumer.
- Reset = respawn in place; the RBF is never reloaded. This is exactly feat #1's `deliberate_restart` path (respawn, reset crash counter, no return-to-menu).
- Spec: `docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md` § feature 4.

---

### Task 1: Worktree stacked on feat #3 + feat #1

**Files:** none (git operation).

- [ ] **Step 1: Create the worktree and establish the merge base**

This branch needs both the CONF_STR-without-SC0 state (feat #3) and the `maldita_osd.cpp` stub + wrapper loop (feat #1). Create it off feat #3, then merge feat #1:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git worktree add -b feat/osd-reset ../maldita-feat4-reset feat/drop-sol-mount
cd ../maldita-feat4-reset
git merge --no-edit feat/wrapper-lifecycle
```
Expected: a clean merge (feat #3 touches only `fpga/Maldita.sv`; feat #1 touches only `vendor/**` + `tools/**` — disjoint file sets, no conflict).
Confirm both prerequisites are present:
```bash
grep -q "SC0,SOL" fpga/Maldita.sv && echo "BAD: feat #3 not in base" || echo "feat #3 present (SC0 gone)"
test -f vendor/Main_MiSTer/maldita_osd.cpp && echo "feat #1 present (osd stub)" || echo "MISSING feat #1"
```
Expected: `feat #3 present (SC0 gone)` and `feat #1 present (osd stub)`.

### Task 2: Rename the CONF_STR label

**Files:**
- Modify: `fpga/Maldita.sv` (the `TJ,Restart Quest;` line → `TJ,Reset;`)

**Interfaces:**
- Consumes: nothing.
- Produces: OSD shows `Reset` instead of `Restart Quest`. The status bit (`TJ` = bit 19) is unchanged, so the RTL and wrapper both keep working against bit 19.

- [ ] **Step 1: Set up the syntax gate (the sim benches do NOT elaborate Maldita.sv)**

```bash
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p /tmp/mlint && printf '// stub build_id for lint\n' > /tmp/mlint/build_id.v
verilator --lint-only -sv -Wno-fatal -Wno-lint -Wno-style -DBUILD_DATE='"x"' \
  -I/tmp/mlint -Ifpga/rtl -Ifpga/sys fpga/Maldita.sv 2>&1 | tail -4
```
Expected: stops at `MODMISSING ... pll_0002` (Quartus PLL IP absent in sim), NOT a `syntax error`. That is the healthy baseline. (Icarus benches test submodules only — none elaborate the emu top, so they cannot verify a CONF_STR edit. Authoritative compile gate = Quartus RBF build on CI; functional gate = on-device OSD check.)

- [ ] **Step 2: Edit the label**

In `fpga/Maldita.sv`, change the line (post-feat-#3 it sits around line 277):
```systemverilog
	"TJ,Restart Quest;",
```
to:
```systemverilog
	"TJ,Reset;",
```
Leave the `TJ` letter code and the surrounding `-;` separators exactly as they are.

- [ ] **Step 3: Verify no CONF_STR syntax error was introduced**

```bash
export PATH="/opt/homebrew/bin:$PATH"
verilator --lint-only -sv -Wno-fatal -Wno-lint -Wno-style -DBUILD_DATE='"x"' \
  -I/tmp/mlint -Ifpga/rtl -Ifpga/sys fpga/Maldita.sv 2>&1 | grep -E ':(26[9]|27[0-9]|28[0-4]):.*syntax' || echo "CONF_STR OK (no syntax error in range)"
```
Expected: `CONF_STR OK (no syntax error in range)`. (A string-only label change cannot alter logic; this only guards against a fat-fingered quote/comma. The lint still stops later at `pll_0002`; expected.)

- [ ] **Step 4: Update the RTL comment that says "Restart Quest"**

`fpga/Maldita.sv:942` comment reads `osd_restart = status[19]; // OSD Restart Quest (momentary toggle); mirrored to ARM`. Update the human label to match:
```systemverilog
wire       osd_restart = status[19];  // OSD Reset (momentary toggle); taken by the wrapper (feat #4)
```
Do not change the wire name or the bit index — only the comment.

- [ ] **Step 5: Commit**

```bash
git add fpga/Maldita.sv
git commit -m "rtl: rename OSD 'Restart Quest' -> 'Reset' (bit 19 unchanged)"
```

### Task 3: Fill the OSD-poll stub (take the Reset T-bit)

**Files:**
- Modify: `vendor/Main_MiSTer/maldita_osd.cpp` (replace the inert stub body)

**Interfaces:**
- Consumes: MiSTer `uint32_t user_io_status_trigger_take(void)` (resolved at armhf link); the `maldita_osd_poll` signature frozen by feat #1's `maldita_osd.h`.
- Produces: `maldita_osd_poll` sets `*restart_out = 1` when the Reset T-bit (bit 19) pulses. The wrapper loop then does its `deliberate_restart` in-place respawn. No change to the loop.

- [ ] **Step 1: Replace the stub body**

Overwrite `vendor/Main_MiSTer/maldita_osd.cpp`:
```c
#include "maldita_osd.h"
#include <stdint.h>

/* MiSTer user_io API: returns the sticky-latched pulse of T-type status bits
 * captured since the last call (HandleUI pulses T bits set-then-clear within a
 * single call; user_io_status_trigger_take consumes them). */
extern "C" uint32_t user_io_status_trigger_take(void);

/* CONF_STR "TJ,Reset;" — T-trigger on status bit 19 (fpga/Maldita.sv:942). */
#define MALDITA_RESET_TBIT 19

void maldita_osd_poll(pid_t /*child*/, int *restart_out)
{
    if (restart_out) *restart_out = 0;
    uint32_t triggers = user_io_status_trigger_take();
    if (triggers & (1u << MALDITA_RESET_TBIT)) {
        if (restart_out) *restart_out = 1;   /* wrapper respawns in place (not a crash) */
    }
}
```

- [ ] **Step 2: Cross-compile the wrapper to confirm the symbol resolves**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita-feat4-reset
export PATH="/opt/homebrew/bin:$PATH"
tools/mister-wrapper/build-hps.sh
file build/mister-wrapper-hps/MiSTer_Maldita
```
Expected: `ELF ... ARM`. `user_io_status_trigger_take` resolves from the upstream `user_io.cpp` in the vendored tree (it is stock upstream — sonic-mania uses it unmodified, so no overlay needed here).
If the link reports `user_io_status_trigger_take` undefined, it means the pinned upstream predates that symbol; in that case add `user_io.cpp`/`user_io.h` to the overlay manifest and port the trigger-take helper from sonic-mania's `user_io.cpp` (mirror of the `input.cpp` overlay pattern in feat #2 Task 2). Note this fallback in the PR.

- [ ] **Step 3: Re-run the host-native child test (regression guard)**

```bash
c++ -std=c++14 -Ivendor/Main_MiSTer tools/mister-wrapper/test/maldita_child_test.cpp vendor/Main_MiSTer/maldita_child.cpp -o /tmp/mct && /tmp/mct
```
Expected: `maldita_child crash-policy OK`.

- [ ] **Step 4: Commit**

```bash
git add vendor/Main_MiSTer/maldita_osd.cpp
git commit -m "feat: maldita_osd — take Reset T-bit (19) and request in-place respawn"
```

### Task 4: On-device gate

**Files:** none (device procedure).

- [ ] **Step 1: Record the device gate in the PR**

Requires the RBF rebuild (CONF_STR change) + the wrapper deploy (spec § Testing #4). Track as a PR checkbox; do not close the feature until it passes:
1. Load the core (with `MiSTer.ini` `main=` pointing at `MiSTer_Maldita`); start the game.
2. Open the OSD → confirm the entry reads **Reset** (not "Restart Quest").
3. Select Reset → the engine restarts: a fresh process (verify `ps` PID changes / `logs/osd-wrapper.log` shows `restart`), the RBF stays loaded (no core reload flash), and the game returns to its start state.
4. Select Reset 3× quickly → the engine keeps restarting and does NOT halt (proves the `deliberate_restart` path bypasses crash accounting — the distinguishing test from feat #1's crash halt).
