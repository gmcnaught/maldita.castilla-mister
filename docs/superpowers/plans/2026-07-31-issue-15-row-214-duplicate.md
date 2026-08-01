# Issue #15 — display row 214 duplicates row 0: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **EXECUTION STATUS (updated 2026-07-31 22:45).** Tasks 1 and 2 are **complete**; do not re-run them.
> **Task 1 verdict: `DDR-CLEAN`, decisive** — a paired device measurement shows the screen carrying
> row 0's content at row 214 while the DDR framebuffer's row 214 is intact in the same window.
> **Take branch A (Task 3). Task 4 (producer side) is closed — `comp_fb_dma`/the compositor are
> exonerated.** Task 2 found the reader clean for all 216 rows under an ideal-latency DDR model with
> zero bank collisions, so the live work is **Task 3 Step 2**. Full evidence and the corrected symptom
> statement: `docs/superpowers/findings/2026-07-31-issue-15-row-214.md`. Read that before this plan —
> it supersedes several assumptions below, including the Phase 1 section's applicability to the build
> the issue was filed against.

**Goal:** Find and fix the mechanism that makes display row 214 a byte-exact copy of row 0, with a sim test that fails before the fix and passes after.

**Architecture:** The published hypothesis on the issue is refuted by static reading of the current RTL (see *Phase 1 findings* below), so this plan does **not** open with a patch. It opens with one decisive device measurement that partitions the search space into "the DDR framebuffer already contains the duplicate" (producer: `comp_fb_dma`/compositor) vs "DDR is clean and the duplicate is created during scanout" (`openbor_video_reader` read side or downstream). Task 2 closes the sim blind spot that let this ship, and runs regardless of which branch Task 1 selects. Only then does a fix get written, TDD, against whichever bench now reproduces.

**Tech Stack:** SystemVerilog (Icarus for sim), armhf C cross-build via the `gmloader-armhf-build:bullseye` Docker image, MiSTer device at `192.168.20.81`.

## Global Constraints

- **No blind patch.** Nothing lands in `fpga/rtl/` for this issue until a sim bench or a device probe reproduces the defect and that reproduction is recorded in the plan's progress notes. This is the whole reason the issue is still open.
- **`SOLARUS_DBG_PROBES` is not available as an instrumentation route.** `fpga/Maldita.qsf:31-37` records that a build with it defined (698dc8a) wedged the fabric permanently at frame 1 on device, and that it moves emu STA from +0.051 to −0.061 ns. Any new device instrumentation must add **zero DDR traffic**.
- **Scanout geometry (never retype — derive from `fpga/rtl/blitter_defs.vh`):** `FB_W=288`, `FB_H=216`, `FB_STRIDE_QW=72` (576 bytes/row), `FB_QWORDS=15552`.
- **Ship DDR framebuffer map** (`fpga/Maldita.sv:226`, `FB_QW_BASE = 29'h077E8000`): control word @ byte `0x3BF40000`, BUF0 @ `0x3BF40040`, BUF1 @ `0x3BF80040`, row *N* of a buffer at `buf_base + N*576`. Control word bit 0 = active buffer, bits [31:2] = frame counter.
- **RBF builds cost ~12 min of CI on the self-hosted Windows runner and are Quartus 17.0 Lite only.** Prefer sim and host-side probes; only build an RBF when an RTL change is actually being verified.
- **Do not bundle the black-column-0 fix into the #15 PR.** It is a separate, already-diagnosed defect (Task 6) and must ship as its own change so a bisect can tell the two apart.

---

## Phase 1 findings (read before starting — this is the investigation state, not speculation)

**Observed** (static read of `fpga/rtl/openbor_video_reader.sv` and `fpga/rtl/openbor_video_timing.sv` at `1072a4d`):

1. `openbor_video_timing.sv:162` — `new_frame` pulses at `hcount == H_TOTAL-1 && vcount == V_ACTIVE-1`, i.e. on the **last pixel of line 215**, simultaneously with `vblank` asserting (`:143-144`).
2. `openbor_video_reader.sv:540` — `new_frame_ddr` (the CDC'd pulse) is the only thing that sets `new_frame_pending`.
3. `openbor_video_reader.sv:624-647` — `ST_IDLE` has **no unconditional path onward**. It leaves only on `new_frame_pending`, `cart_write_pending`, `cart_size_pending`, or `beacon_pending`.
4. `openbor_video_reader.sv:959-963` — after fetching line 215 (which is issued during line 214's hblank), `ST_LINE_DONE` parks the FSM in `ST_IDLE`.

**Inferred — the issue's published hypothesis is refuted.** The comment on the issue argues that `ST_CHECK_CTRL` restarts at `display_line <= 0` with no vblank gate, so the line-0 fetch clobbers bank 0 while row 214 is being displayed. That path cannot be reached during row 214's active video: after the line-215 fetch the FSM sits in `ST_IDLE` until `new_frame_pending`, and per (1) that is set at the *end of line 215*. The `ST_IDLE → ST_WRITE_JOY0 → … → ST_POLL_CTRL → ST_CHECK_CTRL → ST_READ_LINE` chain therefore runs inside vblank, after rows 214 **and** 215 have both been fully scanned out. The gate the issue said was missing exists; it is just in `ST_IDLE`, not in `ST_CHECK_CTRL`. The hypothesis' own stated gap ("why is row 215 clean") is not explained by `!vblank_ddr` in `ST_WAIT_DISPLAY` either — line 215 is the last *active* line, not a vblank line.

The one path that does reach `ST_CHECK_CTRL` without `new_frame` is `ST_IDLE → ST_BEACON → ST_POLL_CTRL` (`:645`, `:658`). The `ST_IDLE` window is exactly line 215 long, so a beacon-triggered restart would fill bank 0 with line 0 while line **215** (bank 1) is on screen — harmless — and it is periodic, which cannot produce 11/11.

**Inferred — the reader's fetch path is already covered and clean in sim.** `fpga/sim/tb_reader_ddr.sv` checks (a) at `:250-262` and (b) at `:265-277` are **ungated**: they verify, on every line of every frame, that the burst address is `buf_base + display_line*72` and that every captured line-buffer beat equals the DDR content at that line. Those passing means the defect is *not* in fetch addressing or fetch data.

**Observed — the existing bench is structurally blind to row 214.** Check (c), the only output-orientation check (`:288-305`), is armed by `orient_arm` for just `wait_lines(25)` (`:347`, `:357`) — the top 25 lines of a frame — and additionally excludes the last active line via `tim_vc < (VACT-1)` (`:292`). Rows 25..215 are never orientation-checked. It also probes `u_reader.cur_pix`, an internal net, not the module's `r_out/g_out/b_out` outputs.

**Unknown:** the actual mechanism. Remaining candidates, in the order Task 1 discriminates them:
- (i) the DDR buffer that `comp_fb_dma` publishes already has row 214 == row 0;
- (ii) DDR is clean and the reader's line-buffer read side produces it (a real-DDR-timing effect the ideal-latency bench model cannot show, e.g. a fill overrunning hblank into active video);
- (iii) DDR and the reader are both clean and it is downstream (video_mixer / ascal / the screenshot capture path).

**Also resolved — the "possibly related" black column 0 is a different bug, and its mechanism is known.** `openbor_video_reader.sv:1057-1082` registers `r_out/g_out/b_out` on the same `ce_pix` at which `hcol` is current, so the RGB outputs lag `hcol` by one `ce_pix`. `fpga/rtl/openbor_video_top.sv:182-186` drives `vga_de <= tim_de` **undelayed**. Net effect: at the first `de` pixel the mixer samples the blanking value (black), screen column *c* shows framebuffer pixel *c−1*, and framebuffer column 287 is never emitted. That is a whole-line, per-column phase error with no vertical term — it cannot produce a duplicated row. Task 6 fixes it separately.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `tools/fb_row_probe.c` | Create | Read-only `/dev/mem` probe: dumps rows 0/213/214/215 of the *currently displayed* DDR buffer in one frame-coherent pass and reports whether the duplicate exists in DDR. |
| `tools/Makefile.fb_row_probe` | Create | armhf cross-build for the probe, mirroring `tools/Makefile.audio_ring_probe`. |
| `fpga/sim/tb_reader_ddr.sv` | Modify | Extend orientation check (c) to every active row 0..215 of a full frame with per-row coverage proof; add ungated check (f), the line-buffer bank-collision detector the issue asked for. |
| `fpga/sim/tb_fb_dma.sv` | Modify (branch B only) | Full-frame WORK→DDR equivalence including the last rows. |
| `fpga/rtl/openbor_video_reader.sv` | Modify (branch A only, and Task 5) | The fix, once reproduced. Also delete two stale comments. |
| `docs/superpowers/findings/2026-07-31-issue-15-row-214.md` | Create | The verdict from Task 1 and the reproduction record, linked from the issue. |

---

### Task 1: Decide producer vs scanout with a frame-coherent DDR readback

The single measurement that halves the search space. No RBF build, no RTL change.

**Files:**
- Create: `tools/fb_row_probe.c`
- Create: `tools/Makefile.fb_row_probe`
- Create: `docs/superpowers/findings/2026-07-31-issue-15-row-214.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a verdict string, **`DDR-DUP`** or **`DDR-CLEAN`**, that selects Task 3 (branch A) or Task 4 (branch B). Task 3 and Task 4 are mutually exclusive; run only the one Task 1 selects.

- [ ] **Step 1: Write the probe**

Create `tools/fb_row_probe.c`:

```c
// tools/fb_row_probe.c — issue #15 decision probe.
//
// Question: does the DDR scanout framebuffer ITSELF contain the row-214 ==
// row-0 duplicate, or is DDR clean and the duplicate created downstream (reader
// line buffer / scanout / scaler)?
//
// Read-only. Adds ZERO DDR traffic from the FPGA side (see Maldita.qsf:31-37 —
// instrumentation that adds fabric DDR traffic wedges this core). It mmaps
// /dev/mem over the framebuffer region, reads the control word to learn which
// buffer the FPGA is displaying, copies rows 0/213/214/215 out of that buffer in
// ONE pass, then re-reads the control word and discards the sample if the frame
// counter moved — so every reported sample is frame-coherent.
//
// Build (from the repo root):
//   docker run --rm -v "$PWD:/src" -w /src gmloader-armhf-build:bullseye \
//       make -f tools/Makefile.fb_row_probe
// Run on the device with the game up:
//   scp tools/fb_row_probe.armhf root@192.168.20.81:/tmp/
//   ssh root@192.168.20.81 /tmp/fb_row_probe.armhf 32

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// Ship framebuffer map: fpga/Maldita.sv:226 FB_QW_BASE = 29'h077E8000.
#define FB_BASE    0x3BF40000u
#define CTRL_OFF   0x00000u
#define BUF0_OFF   0x00040u
#define BUF1_OFF   0x40040u
// Geometry: fpga/rtl/blitter_defs.vh FB_W=288, FB_H=216 -> 576 bytes per row.
#define ROW_BYTES  576
#define FB_ROWS    216
#define MAP_LEN    0x60000u

static int diff_bytes(const uint8_t *a, const uint8_t *b, int n)
{
    int d = 0;
    for (int i = 0; i < n; i++)
        if (a[i] != b[i]) d++;
    return d;
}

// Count non-black RGB565 pixels in a row. Row 0 being all-black makes a
// row214==row0 match trivial, so those samples must be excluded.
static int nonblack_px(const uint8_t *row)
{
    int n = 0;
    for (int i = 0; i < ROW_BYTES; i += 2) {
        uint16_t px = (uint16_t)(row[i] | (row[i + 1] << 8));
        if (px) n++;
    }
    return n;
}

int main(int argc, char **argv)
{
    int samples = (argc > 1) ? atoi(argv[1]) : 16;
    if (samples < 1) samples = 1;

    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    volatile uint8_t *m = mmap(NULL, MAP_LEN, PROT_READ, MAP_SHARED, fd, FB_BASE);
    if (m == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    uint8_t r0[ROW_BYTES], r213[ROW_BYTES], r214[ROW_BYTES], r215[ROW_BYTES];
    int taken = 0, dup = 0, torn = 0, blank0 = 0;

    printf("frame  buf   nonblack(r0)  diff(214,0)  diff(214,213)  diff(214,215)\n");

    for (int s = 0; s < samples; s++) {
        volatile uint32_t *ctrl = (volatile uint32_t *)(m + CTRL_OFF);
        uint32_t c0 = *ctrl;
        const volatile uint8_t *buf = m + ((c0 & 1u) ? BUF1_OFF : BUF0_OFF);

        memcpy(r0,   (const void *)(buf +   0 * ROW_BYTES), ROW_BYTES);
        memcpy(r213, (const void *)(buf + 213 * ROW_BYTES), ROW_BYTES);
        memcpy(r214, (const void *)(buf + 214 * ROW_BYTES), ROW_BYTES);
        memcpy(r215, (const void *)(buf + 215 * ROW_BYTES), ROW_BYTES);

        uint32_t c1 = *ctrl;
        if (c1 != c0) { torn++; usleep(20000); continue; }

        int nb = nonblack_px(r0);
        int d0 = diff_bytes(r214, r0,   ROW_BYTES);
        int d3 = diff_bytes(r214, r213, ROW_BYTES);
        int d5 = diff_bytes(r214, r215, ROW_BYTES);

        printf("%-6u %-5u %-13d %-12d %-14d %-14d%s\n",
               c0 >> 2, c0 & 1u, nb, d0, d3, d5,
               (nb <= 20) ? "   [row0 blank - excluded]" : "");

        if (nb <= 20) { blank0++; usleep(20000); continue; }
        taken++;
        if (d0 == 0) dup++;
        usleep(20000);
    }

    printf("\nsamples=%d usable=%d dup=%d torn=%d row0-blank=%d\n",
           samples, taken, dup, torn, blank0);
    printf("VERDICT: %s\n",
           (taken == 0)   ? "INCONCLUSIVE (no usable sample - row 0 was blank; "
                            "re-run on a scene with content in the top row)"
         : (dup == taken) ? "DDR-DUP (the duplicate is already in the DDR "
                            "framebuffer -> producer side, go to Task 4)"
         : (dup == 0)     ? "DDR-CLEAN (DDR has no duplicate -> created during "
                            "scanout, go to Task 3)"
                          : "MIXED (intermittent - record the counts on the "
                            "issue before choosing a branch)");

    munmap((void *)m, MAP_LEN);
    close(fd);
    return 0;
}
```

- [ ] **Step 2: Write the build file**

Create `tools/Makefile.fb_row_probe`:

```make
# Makefile.fb_row_probe — standalone armhf cross-build of the issue #15
# framebuffer row probe. No mfgpu dependency: it only mmaps /dev/mem read-only.
#
# Build (from this repo root, reusing the gmloader armhf image):
#   docker run --rm -v "$PWD:/src" -w /src gmloader-armhf-build:bullseye \
#       make -f tools/Makefile.fb_row_probe
# Host-native build (compile check only — it needs /dev/mem to run):
#   make -f tools/Makefile.fb_row_probe ARCH=native
# Output: tools/fb_row_probe.armhf

ARCH ?= arm-linux-gnueabihf

ifeq ($(ARCH),native)
CC  := cc
OUT := tools/fb_row_probe.native
else
CC  := $(ARCH)-gcc
OUT := tools/fb_row_probe.armhf
endif

# gnu11, not c11: mmap/usleep sit behind glibc's __STRICT_ANSI__ gate under -std=c11.
CFLAGS ?= -O2 -std=gnu11 -Wall -Wextra
ifeq ($(ARCH),arm-linux-gnueabihf)
CFLAGS += -mtune=cortex-a9
endif

SRC := tools/fb_row_probe.c

.PHONY: all clean
all: $(OUT)

$(OUT): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC)

clean:
	rm -f tools/fb_row_probe.armhf tools/fb_row_probe.native
```

- [ ] **Step 3: Compile-check natively, then cross-build**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
make -f tools/Makefile.fb_row_probe ARCH=native
docker run --rm -v "$PWD:/src" -w /src gmloader-armhf-build:bullseye \
    make -f tools/Makefile.fb_row_probe
file tools/fb_row_probe.armhf
```
Expected: no warnings from either build; `file` reports `ELF 32-bit LSB ... ARM, EABI5`.

- [ ] **Step 4: Run on the device with the game up**

The game must be running and the scene must have content in the top row — issue #15's evidence used castle scenes where the HUD occupies row 0. The probe self-excludes blank-row-0 samples and says so.

Run:
```bash
scp tools/fb_row_probe.armhf root@192.168.20.81:/tmp/
ssh root@192.168.20.81 /tmp/fb_row_probe.armhf 32
```
Expected: a 32-line table, then a `VERDICT:` line. `dup=usable` means the DDR buffer already contains the duplicate; `dup=0` means DDR is clean.

Cross-check the same run against a screenshot so the two observables are known to agree:
```bash
ssh root@192.168.20.81 'echo screenshot > /dev/MiSTer_cmd'
ssh root@192.168.20.81 'ls -t "/media/fat/screenshots/Maldita Castilla/" | head -1'
```
then re-run the issue's Python check on that PNG. If the screenshot shows the duplicate and the probe says `DDR-CLEAN`, that is the (ii)/(iii) branch and is itself the finding.

- [ ] **Step 5: Record the verdict**

Create `docs/superpowers/findings/2026-07-31-issue-15-row-214.md` containing: the probe's full output, the screenshot cross-check result, the verdict, and the Phase 1 refutation from this plan (so the issue's superseded hypothesis is not re-derived by the next reader). Post the same content as a comment on issue #15.

- [ ] **Step 6: Commit**

```bash
git add tools/fb_row_probe.c tools/Makefile.fb_row_probe \
        docs/superpowers/findings/2026-07-31-issue-15-row-214.md
git commit -m "diag(#15): frame-coherent DDR row probe; partition producer vs scanout"
```

---

### Task 2: Close the sim blind spot in `tb_reader_ddr`

Run this **regardless of Task 1's verdict**. It is the regression gate for whichever fix lands, and it may reproduce the defect outright. Two changes: orientation-check every active row of a whole frame (today: 25 rows, last row excluded), and add the line-buffer bank-collision detector the issue asked for.

**Files:**
- Modify: `fpga/sim/tb_reader_ddr.sv` (check (c) at `:288-305`, arming at `:346-347` and `:356-357`, thresholds at `:362-371`)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `check_full_frame()` (a bench task, no arguments), `rows_seen[0:VACT-1]` (per-row orientation-check counters), `collide_errs` (integer, count of fill-vs-display bank collisions). Task 3 and Task 4 both use `./run_sims.sh tb_reader_ddr` as their pass gate.

- [ ] **Step 1: Add the bank-collision detector (check (f))**

This is the instrumentation the issue's "Suggested next step" asks for, as a procedural check rather than an SVA — Icarus does not support concurrent assertions. `lb_waddr = {display_line[0], beat_count}` (`openbor_video_reader.sv:562`), so `lb_waddr[7]` **is** the fill bank; the read bank is `vcount[0]`.

Insert into `fpga/sim/tb_reader_ddr.sv` immediately after check (c)'s `always` block (after line 305):

```systemverilog
    // ── (f) [#15] line-buffer bank collision ─────────────────────────────────────
    // A fill must never write the bank the display is reading out of while active
    // video is on. lb_waddr[7] is the fill bank ({display_line[0], beat_count}),
    // tim_vc[0] is the read bank (linebuf[{vcount[0], hcol[8:2]}]). Ungated and
    // free-running for the whole sim — a collision anywhere is a defect.
    integer collide_errs = 0;
    always @(posedge clk) begin
        if (!reset && u_reader.lb_we && tim_de && (u_reader.lb_waddr[7] == tim_vc[0])) begin
            if (collide_errs < 8)
                $display("  LINEBUF COLLISION row=%0d bank=%0b beat=%0d display_line=%0d",
                         tim_vc, u_reader.lb_waddr[7], u_reader.lb_waddr[6:0],
                         u_reader.display_line);
            collide_errs = collide_errs + 1;
        end
    end
```

- [ ] **Step 2: Add per-row coverage counters to check (c) and drop the last-row exclusion**

Replace check (c)'s `always` block (`fpga/sim/tb_reader_ddr.sv:288-305`) with:

```systemverilog
    reg orient_arm = 1'b0;
    // [#15] per-row coverage: a row that is never checked is a blind spot, not a pass.
    integer rows_seen [0:VACT-1];
    always @(posedge clk) begin
        if (!reset && orient_arm && ce_pix && tim_de && u_reader.frame_ready_vid
            && (u_reader.display_line == (tim_vc + 9'd1))
            && u_reader.hcol < HACT) begin
            // Display (col c, row d) must show framebuffer pixel (col c, row d) UNCHANGED:
            // comp_fb_dma publishes a top-down frame, so scanout must not re-order it. Both an
            // X reversal (col `FB_W-1-c) and a Y reversal (row `FB_H-1-d) fail this.
            // [#15] the `tim_vc < VACT-1` exclusion is GONE: row 215 is the last ACTIVE line,
            // not a vblank line, and rows 214/215 are exactly where the defect lives.
            if (u_reader.cur_pix !== bufpix(u_reader.active_buffer, u_reader.hcol, tim_vc)) begin
                if (orient_errs < 8) $display("  ORIENT MISMATCH screen(%0d,%0d) got=%h exp=%h (buf px %0d,%0d)",
                    u_reader.hcol, tim_vc, u_reader.cur_pix,
                    bufpix(u_reader.active_buffer, u_reader.hcol, tim_vc),
                    u_reader.hcol, tim_vc);
                orient_errs = orient_errs + 1;
            end
            orient_checks = orient_checks + 1;
            rows_seen[tim_vc] = rows_seen[tim_vc] + 1;
        end
    end
```

- [ ] **Step 3: Add the whole-frame arming task**

`new_frame` pulses on the last pixel of line `V_ACTIVE-1` (`openbor_video_timing.sv:162`), so arming just after one `new_frame` edge and disarming at the next covers rows 0..215 exactly once.

Insert after the existing `wait_frames` task (after `fpga/sim/tb_reader_ddr.sv:332`):

```systemverilog
    // [#15] arm orientation checking across ONE complete active region (rows 0..VACT-1).
    // new_frame fires at the last pixel of the last active line, so the window between two
    // consecutive new_frame edges is exactly one frame of active video plus its vblank.
    task check_full_frame;
        begin
            wait_frames(1);          // sit at a frame boundary (start of vblank)
            orient_arm = 1'b1;
            wait_frames(1);          // one complete active region
            orient_arm = 1'b0;
        end
    endtask
```

- [ ] **Step 4: Use the new task, initialise the counters, and assert full coverage**

In the `initial` block, initialise `rows_seen` alongside the memory fill. Insert immediately after `fpga/sim/tb_reader_ddr.sv:339` (the `end` of the `for (qw = ...)` loop):

```systemverilog
        for (r_i = 0; r_i < VACT; r_i = r_i + 1) rows_seen[r_i] = 0;
```

Declare `r_i` and `rows_missing` next to the other bench integers — extend the declaration at `fpga/sim/tb_reader_ddr.sv:101`:

```systemverilog
    integer i, qw, ln, xx, r_i, rows_missing;
```

Replace the BUF0 arming line (`:347`):

```systemverilog
        orient_arm = 1'b1; wait_lines(25); orient_arm = 1'b0;
```
with:
```systemverilog
        check_full_frame();
```

Replace the BUF1 arming line (`:357`) with the same call:
```systemverilog
        check_full_frame();
```

Then add the coverage assertion immediately before the existing `if (addr_checks < 30 …)` block (`:362`):

```systemverilog
        // [#15] every active row must have been orientation-checked. A row that the
        // pacing gate skipped is a hole in the test, and rows 214/215 are precisely the
        // rows the old 25-line window and the `tim_vc < VACT-1` exclusion left uncovered.
        rows_missing = 0;
        for (r_i = 0; r_i < VACT; r_i = r_i + 1)
            if (rows_seen[r_i] == 0) begin
                if (rows_missing < 8) $display("  ROW NEVER ORIENTATION-CHECKED: %0d", r_i);
                rows_missing = rows_missing + 1;
            end
        if (rows_missing) begin
            $display("RESULT: FAIL — %0d of %0d active rows were never checked", rows_missing, VACT);
            $fatal;
        end
        if (collide_errs) begin
            $display("RESULT: FAIL — %0d linebuf bank collisions (fill wrote the bank being displayed)",
                     collide_errs);
            $fatal;
        end
```

- [ ] **Step 5: Run the bench**

Run:
```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh tb_reader_ddr
```

Three possible outcomes — **record which one you got**, it decides what happens next:
- `RESULT: FAIL — … linebuf bank collisions …` or `ORIENT MISMATCH … row 214` → **the defect reproduces in sim.** Go straight to Task 3 with a failing test in hand; no device instrumentation needed.
- `RESULT: FAIL — N of 216 active rows were never checked` → the bench's own pacing gate (`display_line == tim_vc + 1`) does not hold on those rows. That is a finding, not a bench bug: print `display_line` and `tim_vc` for the uncovered rows and work out why the fetch is not one line ahead there before proceeding.
- `RESULT: PASS` → the reader is correct under the bench's ideal-latency DDR model across all 216 rows, with no bank collision. Combined with the already-passing checks (a)/(b), that is strong evidence the defect is either producer-side (Task 4) or a real-DDR-timing effect the model cannot show (Task 3, Step 2).

- [ ] **Step 6: Confirm no other bench regressed**

Run:
```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh
```
Expected: the same pass/fail set as before your change. Pre-existing failure that is NOT yours: `tb_scanout_fbram`.

- [ ] **Step 7: Commit**

```bash
git add fpga/sim/tb_reader_ddr.sv
git commit -m "test(#15): orientation-check all 216 rows + linebuf bank-collision detector"
```

---

### Task 3 — BRANCH A (only if Task 1 said `DDR-CLEAN`): root-cause and fix the scanout side

DDR holds a correct frame and the duplicate appears on screen, so it is created between the DDR read and the pixel output.

**Files:**
- Modify: `fpga/rtl/openbor_video_reader.sv`
- Modify: `fpga/sim/tb_reader_ddr.sv` (only if a new bench condition is needed to reproduce)

**Interfaces:**
- Consumes: Task 1's `DDR-CLEAN` verdict; Task 2's `check_full_frame()` / `collide_errs` gate.
- Produces: an RTL change plus the bench condition that fails without it.

- [ ] **Step 1: If Task 2 already reproduced it, skip to Step 3**

- [ ] **Step 2: If Task 2 passed, make the bench model real DDR latency**

The bench's DDR model (`fpga/sim/tb_reader_ddr.sv:129-141`) answers a read the cycle after it is accepted, with no arbiter contention. On device the reader shares `ddr_blitter_arb` with the blitter and `comp_fb_dma`, and a line fetch issued at hblank can be delayed. If a 72-beat fill slips past hblank into active video, it writes the bank the display is reading — which check (f) will now catch.

Add a stall generator to the model: hold `r_ddr_busy` high for a parameterised number of cycles after each read request, sweep that delay from 0 upward, and find the threshold at which check (f) fires and which row it fires on. Expected: the collision appears on the row whose fill overruns hblank. If the first row to collide is 214, that is the mechanism, and the asymmetry (215 clean) follows from the frame-restart fetch landing in vblank rather than in line 215's active region.

- [ ] **Step 3: Write the fix against the failing bench, smallest change first**

Do not widen scope. The candidate fixes, in increasing order of cost:
- **Bank the read side against the fill:** make the display read bank an explicit register that only advances when a fill has completed, instead of deriving it from `vcount[0]` (`openbor_video_reader.sv:1050`). This removes the parity coupling entirely rather than gating one FSM edge.
- **Gate the fill:** hold `lb_we` off (or stall the fetch) whenever `display_line[0] == vcount_ddr[0] && !vblank_ddr && de`. Cheaper but it converts a corrupt row into a stale row; only acceptable if the collision is proven rare.

Whichever is chosen, the `ST_CHECK_CTRL` edge does **not** need a vblank gate — Phase 1 finding (3) shows `ST_IDLE` already provides one. Adding a second gate there would eat the line-0 preload slack (`preloading <= 1'b1`, `fifo_aclr_cnt <= 4'd8` at `:877-878`) for no benefit.

- [ ] **Step 4: Delete the two stale comments while in this file**

Both describe removed code and will make the next reader re-derive a bug that is not there:
- `openbor_video_reader.sv:1041-1045` — the "[device-fix: vertical (Y) flip] … reads the reversed SOURCE line (239 - display_line)" block. The fetch is forward (`:929`) and the flip lives in `raster_backend_mfgpu.cpp`.
- `openbor_video_reader.sv:924-928` — "this module's V_ACTIVE=240 while openbor_video_timing.sv displays 224 lines". Both are `FB_H` = 216 now (`:206`, `openbor_video_timing.sv:57`).

- [ ] **Step 5: Verify in sim**

Run:
```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh tb_reader_ddr && ./run_sims.sh
```
Expected: `tb_reader_ddr` PASS with `collide_errs=0` and all 216 rows covered; no new failures elsewhere (`tb_scanout_fbram` still fails, pre-existing).

- [ ] **Step 6: Commit and go to Task 5**

```bash
git add fpga/rtl/openbor_video_reader.sv fpga/sim/tb_reader_ddr.sv
git commit -m "fix(#15): <one-line mechanism>; scanout no longer duplicates row 0 into row 214"
```

---

### Task 4 — BRANCH B (only if Task 1 said `DDR-DUP`): root-cause and fix the producer side

The DDR buffer `comp_fb_dma` publishes already contains the duplicate, so the reader is innocent and the bug is in the compositor framebuffer or the WORK→DDR copy.

**Files:**
- Modify: `fpga/sim/tb_fb_dma.sv`
- Modify: `fpga/rtl/comp_fb_dma.sv` and/or `fpga/rtl/comp_fbram.sv`

**Interfaces:**
- Consumes: Task 1's `DDR-DUP` verdict.
- Produces: an RTL change plus a full-frame bench that fails without it.

- [ ] **Step 1: Narrow producer vs compositor with the probe you already have**

`comp_fb_dma` is a flat linear copy of WORK qwords `0..FB_QWORDS-1` (`comp_fb_dma.sv:13`, `:72-73`) with no per-row logic, so a copy bug that singles out one row is unlikely — but the copy is also the only writer. Re-run `fb_row_probe.armhf` against **both** buffers (extend it to dump BUF0 and BUF1 in the same pass) . If the duplicate is present in both, it is in WORK, i.e. upstream of the DMA and in the compositor/rasterizer. If it is present in only the buffer being published, it is the DMA.

- [ ] **Step 2: Extend `tb_fb_dma` to a full-frame equivalence check**

Add a check that every one of the 15552 published qwords equals the WORK qword at the same index, with a per-row coverage counter proving all 216 rows were compared (same pattern as Task 2, Step 4). Seed WORK with a per-row-distinct pattern so a row-214 == row-0 copy cannot pass.

Run:
```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh tb_fb_dma
```
Expected before any fix: FAIL naming row 214 if the DMA is at fault; PASS if it is not, which moves the investigation into `comp_fbram`/`comp_pipeline` (`tb_fbram`, `tb_comp_pipeline`).

- [ ] **Step 3: Fix, re-run, commit**

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh
git add fpga/sim/tb_fb_dma.sv fpga/rtl/comp_fb_dma.sv
git commit -m "fix(#15): <one-line mechanism>; WORK->DDR copy no longer duplicates row 0 into row 214"
```

---

### Task 5: Device verification and issue closure

**Files:**
- Modify: `docs/superpowers/findings/2026-07-31-issue-15-row-214.md`

**Interfaces:**
- Consumes: the RBF built from Task 3 or Task 4; `tools/fb_row_probe.armhf` from Task 1.
- Produces: the evidence that closes issue #15.

- [ ] **Step 1: Build and fetch the RBF**

Push the branch to trigger `.github/workflows/build-rbf.yml` (~12 min, self-hosted Windows runner), then:
```bash
gh run download <id> -n maldita-rbf -D _Other
gh run download <id> -n quartus-reports -D _Other
```
Check `_Other/output_files/Maldita.sta.summary`. The `emu` clock is placement-fragile and commonly closes slightly negative (−0.02 to −0.7 ns); the worst path is usually `pll_hdmi`, which is out of scope. Record the number, do not chase it.

- [ ] **Step 2: Deploy and load**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
./deploy.py --no-content
ssh root@192.168.20.81 'echo "load_core /media/fat/_Other/MalditaCastilla_YYYYMMDD.rbf" > /dev/MiSTer_cmd'
```
Master_Daemon auto-runs the handler; the game comes up on its own. Confirm via a new gmloader pid — `load_core` of an already-loaded RBF is a no-op.

- [ ] **Step 3: Re-run both observables**

```bash
ssh root@192.168.20.81 /tmp/fb_row_probe.armhf 32
```
Expected: `dup=0` with `usable >= 11`.

Then the issue's own screenshot criterion over ≥11 frames with a non-black row 0 — `row[214] == row[0]` must be `False` on all of them.

- [ ] **Step 4: Check for the underflow regression the fix could introduce**

Any change that delays a line fetch trades row 214 for a possible underflow at the top of the frame. Confirm rows 0 and 1 are still correct: in the same screenshots, `dist(row 0, row 1)` must remain in the normal adjacent-row range (the issue measured mean adjacent-row difference 13.7 and neighbour distances of 65-91 for unrelated rows) and neither row may be a duplicate of any other row. Also confirm no new tearing across ≥ 60 s of play.

- [ ] **Step 5: Close the issue**

Update `docs/superpowers/findings/2026-07-31-issue-15-row-214.md` with the confirmed mechanism, the fix, and the before/after probe output. Post it to issue #15 and close it. Note explicitly in the comment that the earlier `ST_CHECK_CTRL` hypothesis was refuted and why, so it is not resurrected.

```bash
git add docs/superpowers/findings/2026-07-31-issue-15-row-214.md
git commit -m "docs(#15): device-verified fix; record the refuted hypothesis"
```

---

### Task 6: Black column 0 — SEPARATE issue, separate PR

Mechanism already established in Phase 1; included here because the issue raises it and because leaving it undocumented invites someone to re-couple it to #15. **Do not put this in the #15 PR.**

**Files:**
- Modify: `fpga/rtl/openbor_video_reader.sv:1057-1082` or `fpga/rtl/openbor_video_top.sv:182-186`
- Modify: `fpga/sim/tb_reader_ddr.sv`

**Interfaces:**
- Consumes: Task 2's bench structure.
- Produces: a check on the module's `r_out/g_out/b_out` outputs sampled against `vga_de` phase — distinct from check (c), which probes the internal `cur_pix` and therefore cannot see this.

- [ ] **Step 1: File the issue**

Title: `Scanout: column 0 is black on every row and the image is shifted right one pixel`. Body: `r_out/g_out/b_out` are registered on the same `ce_pix` at which `hcol` is current (`openbor_video_reader.sv:1064-1070`), so RGB lags `hcol` by one `ce_pix`, while `openbor_video_top.sv:184` drives `vga_de <= tim_de` undelayed. At the first `de` pixel the mixer samples the blanking value (black); screen column *c* shows framebuffer pixel *c−1*; framebuffer column 287 is never emitted. Evidence: 216/216 rows have a black column 0 on both rigs.

- [ ] **Step 2: Write the failing test**

Extend `tb_reader_ddr` with check (g): sample `u_reader.r_out/g_out/b_out` on every `ce_pix` where `tim_de` is high, and require the RGB565 recomposition to equal `bufpix(active_buffer, screen_col, tim_vc)` where `screen_col` is derived from `hcount`, not from the reader's internal `hcol`. Assert specifically that screen column 0 is not black on a row whose framebuffer column 0 is non-black.

- [ ] **Step 3: Run it and confirm it fails**

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh tb_reader_ddr
```
Expected: FAIL, reporting screen column 0 black and every column off by one.

- [ ] **Step 4: Fix**

Prefer advancing the read one pixel ahead (address the line buffer with `hcol+1` so `lb_q` is pre-settled and `r_out` lands in phase with `de`) over delaying `vga_de/vga_hs/vga_vs` in the top level — delaying the syncs shifts the whole raster relative to the MiSTer framework's expectations and interacts with the OSD H/V position offsets (`h_adj`/`v_adj`).

- [ ] **Step 5: Verify and commit**

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh
git add fpga/rtl/openbor_video_reader.sv fpga/sim/tb_reader_ddr.sv
git commit -m "fix: pixel output was one ce_pix behind de — black column 0, image shifted right"
```

Device check after the RBF build: a screenshot's column 0 must carry content, and a known-X feature (the `fabric_probe` magenta triangle) must land at its emitted X, not X+1.
