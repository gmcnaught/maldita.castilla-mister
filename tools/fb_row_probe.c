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
