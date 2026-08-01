// tools/fb_row_probe.c — issue #15 decision probe.
//
// Two independent tests run per sample, since screenshot evidence
// (docs/superpowers/findings/data/*.png) supports a different signature
// than originally hypothesized:
//
//   Test A: is row 214 byte-identical to row 0 (the original row-214==row-0
//   duplicate hypothesis)? Only meaningful when row 0 has content (a blank
//   row 0 makes the match trivial), so it's gated on nonblack(r0).
//
//   Test B: is row 214 entirely black while its neighbours, rows 213 and
//   215, are not (the blackout signature actually observed in 3 of 9
//   screenshots)? Gated on rows 213/215 having content — independent of
//   row 0, so it stays usable even in scenes with a blank top row.
//
// Either test tells us the same thing if it fires: does the DDR scanout
// framebuffer ITSELF already contain the defect (producer side, go to
// Task 4), or is DDR clean and the defect created downstream (reader line
// buffer / scanout / scaler, go to Task 3)? They are reported independently
// — one test being inconclusive must not hide the other's result.
//
// Read-only. Adds ZERO DDR traffic from the FPGA side (see Maldita.qsf:31-37 —
// instrumentation that adds fabric DDR traffic wedges this core). It mmaps
// /dev/mem over the framebuffer region, reads the control word to learn which
// buffer the FPGA is displaying, copies rows 0/213/214/215 out of that buffer in
// ONE pass, then re-reads the control word and discards the sample if the frame
// counter moved — so every reported sample is frame-coherent.
//
// Build (from the repo root):
//   docker run --rm -v "$PWD:/src" -w /src gmloader-armhf-build:bullseye make -f tools/Makefile.fb_row_probe
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
// row214==row0 match trivial (Test A), so those samples must be excluded;
// rows 213/215 being all-black would equally make "row 214 is also black"
// uninformative (Test B), so those are excluded on the same basis.
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
    // Test A (row214==row0 duplicate).
    int taken = 0, dup = 0, torn = 0, blank0 = 0;
    // Test B (row214 blackout while 213/215 are lit) — independent counters,
    // independent usability gate, shares only the tear count above.
    int takenB = 0, blackoutB = 0, neighBlankB = 0;

    printf("frame  buf   nonblack(r0)  nonblack(r213)  nonblack(r214)  nonblack(r215)  "
           "diff(214,0)  diff(214,213)  diff(214,215)\n");

    for (int s = 0; s < samples; s++) {
        volatile uint32_t *ctrl = (volatile uint32_t *)(m + CTRL_OFF);
        uint32_t c0 = *ctrl;
        const volatile uint8_t *buf = m + ((c0 & 1u) ? BUF1_OFF : BUF0_OFF);

        // Casting away `volatile` for memcpy is deliberate, not an oversight.
        // The source is plain DRAM (no MMIO read side effects), so a plain
        // block copy is semantically fine, and the seqlock-style coherence
        // guard only needs the two `ctrl` reads (genuinely volatile, above
        // and below) to stay ordered around the copy - which they do, since
        // memcpy is an opaque call the compiler cannot reorder across. Do not
        // "fix" this by making the copies volatile/byte-wise; that would not
        // change correctness and would just slow the copy down.
        memcpy(r0,   (const void *)(buf +   0 * ROW_BYTES), ROW_BYTES);
        memcpy(r213, (const void *)(buf + 213 * ROW_BYTES), ROW_BYTES);
        memcpy(r214, (const void *)(buf + 214 * ROW_BYTES), ROW_BYTES);
        memcpy(r215, (const void *)(buf + 215 * ROW_BYTES), ROW_BYTES);

        uint32_t c1 = *ctrl;
        if (c1 != c0) { torn++; usleep(20000); continue; }

        int nb0   = nonblack_px(r0);
        int nb213 = nonblack_px(r213);
        int nb214 = nonblack_px(r214);
        int nb215 = nonblack_px(r215);
        int d0 = diff_bytes(r214, r0,   ROW_BYTES);
        int d3 = diff_bytes(r214, r213, ROW_BYTES);
        int d5 = diff_bytes(r214, r215, ROW_BYTES);

        int exclA   = (nb0 <= 20);
        int usableB = (nb213 > 20 && nb215 > 20);
        int hitB    = usableB && (nb214 == 0);

        char flags[128];
        flags[0] = '\0';
        if (exclA)
            strncat(flags, "   [row0 blank - excluded from A]",
                    sizeof(flags) - strlen(flags) - 1);
        if (!usableB)
            strncat(flags, "   [213/215 blank - excluded from B]",
                    sizeof(flags) - strlen(flags) - 1);
        else if (hitB)
            strncat(flags, "   [row214 BLACKOUT]",
                    sizeof(flags) - strlen(flags) - 1);

        printf("%-6u %-5u %-13d %-15d %-15d %-15d %-12d %-14d %-14d%s\n",
               c0 >> 2, c0 & 1u, nb0, nb213, nb214, nb215, d0, d3, d5, flags);

        if (exclA) {
            blank0++;
        } else {
            taken++;
            if (d0 == 0) dup++;
        }

        if (!usableB) {
            neighBlankB++;
        } else {
            takenB++;
            if (hitB) blackoutB++;
        }

        usleep(20000);
    }

    printf("\nsamples=%d torn=%d\n", samples, torn);
    printf("Test A (row214==row0 dup): usable=%d dup=%d row0-blank=%d\n",
           taken, dup, blank0);
    printf("Test B (row214 blackout vs 213/215): usable=%d blackout=%d "
           "neighbors-blank=%d\n", takenB, blackoutB, neighBlankB);

    // Minimum usable-sample count before a call on either test is reported
    // as decisive. Below this, still report the determination (never
    // suppress the measurement) but flag it low-confidence so the reader
    // doesn't branch a whole task on a single lucky/unlucky frame.
    const int MIN_USABLE = 8;
    char verdictA[512], verdictB[512];

    if (taken == 0) {
        // taken==0 has three distinct root causes that must not be
        // conflated: a blank row 0 (nothing to say about the bug), a torn
        // control word (the tear guard itself is firing - a separate signal
        // worth its own finding), or a mix of both. Reporting "row 0 was
        // blank" when the real cause is tearing sends the next investigator
        // chasing HUD visibility instead of the control word churning.
        if (torn == samples) {
            snprintf(verdictA, sizeof(verdictA),
                "INCONCLUSIVE (Test A: 0/%d usable - every sample was torn, "
                "i.e. the control word changed mid-copy every time; row 0 "
                "blankness is not the cause here - the control word is "
                "churning faster than expected and that needs its own look "
                "before re-running)", samples);
        } else if (blank0 == samples) {
            snprintf(verdictA, sizeof(verdictA),
                "INCONCLUSIVE (Test A: 0/%d usable - row 0 was blank in "
                "every sample; re-run on a scene with content in the top "
                "row)", samples);
        } else {
            snprintf(verdictA, sizeof(verdictA),
                "INCONCLUSIVE (Test A: 0/%d usable - blank0=%d torn=%d, a "
                "mix of both and neither alone; re-run on a scene with "
                "top-row content, and note the tear count in case it's also "
                "worth investigating)", samples, blank0, torn);
        }
    } else {
        const char *conf = (taken < MIN_USABLE)
            ? " [LOW-CONFIDENCE: below the 8-sample floor (MIN_USABLE=8); "
              "re-run for more samples before branching a task on this]"
            : "";
        if (dup == taken) {
            snprintf(verdictA, sizeof(verdictA),
                "DDR-DUP (Test A: N=%d usable, %d/%d duplicated - the "
                "duplicate is already in the DDR framebuffer -> producer "
                "side, go to Task 4)%s", taken, dup, taken, conf);
        } else if (dup == 0) {
            snprintf(verdictA, sizeof(verdictA),
                "DDR-CLEAN (Test A: N=%d usable, 0/%d duplicated - DDR has "
                "no duplicate -> created during scanout, go to Task 3)%s",
                taken, taken, conf);
        } else {
            snprintf(verdictA, sizeof(verdictA),
                "MIXED (Test A: N=%d usable, %d/%d duplicated - "
                "intermittent; record the counts on the issue before "
                "choosing a branch)%s", taken, dup, taken, conf);
        }
    }

    if (takenB == 0) {
        // Same three-way split as Test A, but "not usable" here means rows
        // 213/215 were blank (not row 0) - a torn run makes BOTH tests
        // inconclusive for the same underlying reason, and that must show
        // up independently in each line rather than only in Test A's.
        if (torn == samples) {
            snprintf(verdictB, sizeof(verdictB),
                "INCONCLUSIVE (Test B: 0/%d usable - every sample was torn, "
                "i.e. the control word changed mid-copy every time; this is "
                "the same control-word churn affecting Test A above, not a "
                "row-content problem)", samples);
        } else if (neighBlankB == samples) {
            snprintf(verdictB, sizeof(verdictB),
                "INCONCLUSIVE (Test B: 0/%d usable - rows 213 and/or 215 "
                "were blank in every sample, so a black row 214 would be "
                "uninformative; re-run on a scene with content in those "
                "rows)", samples);
        } else {
            snprintf(verdictB, sizeof(verdictB),
                "INCONCLUSIVE (Test B: 0/%d usable - neighbors-blank=%d "
                "torn=%d, a mix of both and neither alone; re-run on a "
                "scene with content in rows 213/215, and note the tear "
                "count in case it's also worth investigating)",
                samples, neighBlankB, torn);
        }
    } else {
        const char *conf = (takenB < MIN_USABLE)
            ? " [LOW-CONFIDENCE: below the 8-sample floor (MIN_USABLE=8); "
              "re-run for more samples before branching a task on this]"
            : "";
        if (blackoutB == takenB) {
            snprintf(verdictB, sizeof(verdictB),
                "DDR-BLACKOUT (Test B: N=%d usable, %d/%d show row 214 "
                "entirely black while 213/215 are lit - the corruption is "
                "already in the DDR framebuffer -> producer side, go to "
                "Task 4)%s", takenB, blackoutB, takenB, conf);
        } else if (blackoutB == 0) {
            snprintf(verdictB, sizeof(verdictB),
                "DDR-CLEAN (Test B: N=%d usable, 0/%d show a blackout - row "
                "214 is intact in DDR whenever its neighbors are lit; if "
                "the on-screen defect persists it is created downstream, go "
                "to Task 3)%s", takenB, takenB, conf);
        } else {
            snprintf(verdictB, sizeof(verdictB),
                "MIXED (Test B: N=%d usable, %d/%d show a blackout - "
                "intermittent; record the counts on the issue before "
                "choosing a branch)%s", takenB, blackoutB, takenB, conf);
        }
    }

    printf("VERDICT A: %s\n", verdictA);
    printf("VERDICT B: %s\n", verdictB);

    munmap((void *)m, MAP_LEN);
    close(fd);
    return 0;
}
