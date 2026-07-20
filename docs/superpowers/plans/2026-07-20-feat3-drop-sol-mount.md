# Feature 3 — Drop `SC0,SOL` "Load Quest" Mount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the vestigial `SC0,SOL,Load Quest` OSD mount slot from the core — Maldita is a single-game core, so the "load a quest file" affordance is dead.

**Architecture:** A CONF_STR edit in `fpga/Maldita.sv` plus removal of the now-unused `img_mounted`/`img_size` wires and their `hps_io` bindings. Pure RTL; no host side. Verified by Icarus sim (compile/lint gate) and, ultimately, an RBF rebuild.

**Tech Stack:** SystemVerilog, Icarus Verilog sim harness (`fpga/sim/run_sims.sh`).

## Global Constraints

- Branch/worktree: `feat/drop-sol-mount` off `milestone-a`.
- **Land this FIRST among the CONF_STR-touching branches** (#3 before #4) — both edit `fpga/Maldita.sv:269-284`; #4 branches off #3's result to avoid a merge collision (spec § "Conflict surface (a)").
- Do not touch the fabric/rasterizer path. Do not touch `status[...]` bits.
- **Verification note:** the Icarus sim benches (`fpga/sim/run_sims.sh`) test blitter/comp *submodules* — none elaborate `Maldita.sv`, so they cannot verify a CONF_STR/wire edit. The cheap syntax gate is a scoped `verilator --lint-only` of `Maldita.sv` with the build-generated bits stubbed (recipe in Task 2 Step 1). It parses through the CONF_STR block and stops only at Quartus-generated PLL IP (`pll_0002`, absent in sim) — that stop is EXPECTED. A malformed edit instead produces a `syntax error` at the CONF_STR line range. The authoritative compile gate is the Quartus RBF build (CI on push to `fpga/**`); the functional gate is the on-device OSD check.
- The `SC0` slot's only consumers are `img_mounted`/`img_size`, which are declared but never read (confirmed: `fpga/Maldita.sv:307-308` declared, `:329-330` bound to hps_io, no other reference).
- Spec: `docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md` § feature 3.

---

### Task 1: Create the worktree

**Files:** none (git operation).

- [ ] **Step 1: Create an isolated worktree off milestone-a**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git worktree add -b feat/drop-sol-mount ../maldita-feat3-drop-sol milestone-a
cd ../maldita-feat3-drop-sol
git branch --show-current   # expect: feat/drop-sol-mount
```

Confirm the contract header from feat #0 is present (it must already be on milestone-a):
```bash
test -f vendor/Main_MiSTer/mister_joy_shm.h && echo "contract present" || echo "MISSING — land feat #0 first"
```
Expected: `contract present`. (If missing, feat #0 has not landed; stop and land it.)

### Task 2: Remove the SC0 line from CONF_STR and confirm the sim still builds

**Files:**
- Modify: `fpga/Maldita.sv:271` (delete the `SC0,SOL,Load Quest;` line)

**Interfaces:**
- Consumes: nothing.
- Produces: a CONF_STR without a mount slot. Downstream: feat #4 rewrites line `TJ,Restart Quest;` in the same block; it branches off this result.

- [ ] **Step 1: Set up the syntax-gate stub and capture the baseline**

```bash
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p /tmp/mlint && printf '// stub build_id for lint\n' > /tmp/mlint/build_id.v
# Baseline lint of the UNEDITED file. Note where it stops.
verilator --lint-only -sv -Wno-fatal -Wno-lint -Wno-style -DBUILD_DATE='"x"' \
  -I/tmp/mlint -Ifpga/rtl -Ifpga/sys fpga/Maldita.sv 2>&1 | tail -4
```
Expected: it stops at `MODMISSING ... pll_0002` (Quartus PLL IP absent in sim) — NOT a `syntax error`. That "stops at pll_0002" is the healthy baseline. If you see a `syntax error` in the CONF_STR line range (269-284) on the *unedited* file, the stub/flags are wrong — fix before editing.

- [ ] **Step 2: Delete the SC0 mount line**

In `fpga/Maldita.sv`, delete line 271 entirely:
```systemverilog
	"SC0,SOL,Load Quest;",
```
The CONF_STR block becomes:
```systemverilog
localparam CONF_STR = {
	"Maldita Castilla;;",
	"-;",
	"OCE,H Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OFH,V Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OI,Vertical Crop (224p),Disabled,Enabled;",
	"-;",
	"OK,FPS Overlay,Off,On;",
	"TJ,Restart Quest;",
	"-;",
	"J1,Sword,Action,Item 1,Item 2,Pause;",
	"jn,A,B,X,Y,Start;",
	"-;",
	"V,v",`BUILD_DATE
};
```

- [ ] **Step 3: Verify no CONF_STR syntax error was introduced**

```bash
export PATH="/opt/homebrew/bin:$PATH"
verilator --lint-only -sv -Wno-fatal -Wno-lint -Wno-style -DBUILD_DATE='"x"' \
  -I/tmp/mlint -Ifpga/rtl -Ifpga/sys fpga/Maldita.sv 2>&1 | grep -E ':(26[9]|27[0-9]|28[0-4]):.*syntax' || echo "CONF_STR OK (no syntax error in range)"
```
Expected: `CONF_STR OK (no syntax error in range)`. A dangling comma or unbalanced `{}` from the deletion would print a `syntax error` at lines 269-284 instead — fix it before proceeding. (The lint still stops later at `pll_0002`; that is expected and unrelated.)

- [ ] **Step 4: Commit**

```bash
git add fpga/Maldita.sv
git commit -m "rtl: drop SC0,SOL 'Load Quest' mount — single-game core

Maldita is a single-game core; the quest-file mount slot is vestigial
Solarus lineage. img_mounted/img_size are removed next."
```

### Task 3: Remove the now-dead img_mounted/img_size wires and hps_io bindings

**Files:**
- Modify: `fpga/Maldita.sv:305-308` (remove the `img_mounted`/`img_size` wire declarations)
- Modify: `fpga/Maldita.sv:328-335` (remove the SC0 mount signal bindings in the `hps_io` instantiation)

**Interfaces:**
- Consumes: nothing.
- Produces: an `hps_io` instantiation with no mount ports wired. `hps_io`'s mount ports have defaults, so leaving them unconnected is valid.

- [ ] **Step 1: Confirm the wires are truly unused before deleting**

Run:
```bash
grep -n "img_mounted\|img_size" fpga/Maldita.sv
```
Expected: exactly the declaration lines (~307-308) and the hps_io binding lines (~329-330), and nothing else. If any OTHER line references them, STOP — they are load-bearing and this task's premise is wrong; report it.

- [ ] **Step 2: Delete the wire declarations**

Remove these lines (around `fpga/Maldita.sv:305-308`):
```systemverilog
// SC0 mounted image — config file created instantly, no ioctl streaming.
// We only need the filename (from .s0 config). No disk I/O needed.
wire        img_mounted;
wire [63:0] img_size;
```

- [ ] **Step 3: Delete the SC0 mount bindings in the hps_io instance**

In the `hps_io #(.CONF_STR(CONF_STR)) hps_io (...)` instantiation, remove the mount-signal lines (around `:328-335`):
```systemverilog
	// SC0 mount signals
	.img_mounted(img_mounted),
	.img_size(img_size),
	// Tie off disk I/O — we never read/write sectors
	.sd_lba('{32'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{8'd0})
```
Leave the preceding port (`.ioctl_wait(ioctl_wait)`) correctly terminated: ensure the port list still ends cleanly with a `)` and no trailing comma. The final connected port before the closing paren must not have a trailing comma.

**Note on `sd_*`:** these are separate SD-card ports, not part of the SC0 image, but they exist only to tie off disk I/O that the mount slot implied. `hps_io` defaults them safely when unconnected, so removing them with the mount is correct. If sim elaboration in Step 4 complains that any `sd_*` port is required, restore only the complained-about tie-offs.

- [ ] **Step 4: Verify no new elaboration error from the wire removal**

```bash
export PATH="/opt/homebrew/bin:$PATH"
verilator --lint-only -sv -Wno-fatal -Wno-lint -Wno-style -DBUILD_DATE='"x"' \
  -I/tmp/mlint -Ifpga/rtl -Ifpga/sys fpga/Maldita.sv 2>&1 | tail -6
```
Expected: the lint still stops at `MODMISSING ... pll_0002` (same boundary as the Task 2 baseline) with NO new error naming `img_mounted`, `img_size`, or an `hps_io` port. A new error about a required `hps_io` port means a tie-off that is actually mandatory was removed — restore just that one and re-run. (`pll_0002`/Quartus-IP module-missing errors are expected; ignore them.)

- [ ] **Step 5: Commit**

```bash
git add fpga/Maldita.sv
git commit -m "rtl: remove dead img_mounted/img_size wires + SC0 hps_io bindings"
```

### Task 4: Device verification note (deferred to RBF build)

**Files:** none.

- [ ] **Step 1: Record the on-device gate**

This branch's on-device gate (per spec § Testing #3-1) requires an RBF rebuild, which runs on the self-hosted Windows Actions runner (`.github/workflows/build-rbf.yml`, triggered by pushing `fpga/**`). It is NOT run from this worktree. When the RBF is built and deployed:
1. Load the core; open the OSD.
2. Confirm **no "Load Quest" entry** appears.
3. Confirm the game still boots and renders (the SC0 slot removal must not affect the fabric path).

Add a checkbox to the branch PR description tracking this manual gate; do not block the code merge on it, but do not close the feature until it passes.
