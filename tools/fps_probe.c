/*
 *  fps_probe.c — displayed-frame-rate probe for the Maldita core.
 *
 *  Answers "how many NEW frames did the screen show per second?" without
 *  touching the engine, which is the metric the fps-dip target is written in
 *  (>= 58 displayed frames in every 1-s window, a 58 at most once per 30 s).
 *  The engine's own counters (C_SUBMIT, the OSD FPS overlay) count frames the
 *  host PRODUCED; a produced frame can still be skipped by comp_fb_dma (it
 *  never overwrites a frame the reader has not adopted — comp_fb_dma.sv
 *  "START only when the reader has CONSUMED our last publish") or shown for
 *  two scanout frames.
 *
 *  Reads (never writes), all uncached through /dev/mem:
 *    0x3BF40000  scanout control word, {frame_counter[31:2], 0, active[0]} —
 *                comp_fb_dma bumps frame_counter on every publish; the reader
 *                (openbor_video_reader.sv ST_CHECK_CTRL) adopts the latest one
 *                at a frame boundary
 *    0x3BFB0018  scan_frame_cnt, +1 per scanout frame boundary
 *    0x3B000000  C_SUBMIT (qword 0) and 0x3B000028 C_DONE (qword 5)
 *
 *  Poll loop: sleep POLL_US, read all four words, and emit one CSV line
 *  whenever any of them changed — an event timeline at poll resolution: the
 *  doorbell (sub), the fabric's completion (done), the publish (fc) and the
 *  scanout boundary (scan). The control word read a few hundred us after a
 *  boundary is the one the reader adopted unless a publish landed in between;
 *  `lat_us` (time since the previous poll, i.e. the upper bound on how late
 *  the change was seen) lets the analysis discount those. `gap` is the scan
 *  delta on this line (> 1 means boundaries were missed: the probe was
 *  descheduled).
 *
 *  Output: CSV to OUTFILE (put it on /tmp — /media/fat is mounted sync):
 *    t_us,scan,fc,sub,done,lat_us,gap
 *  and a one-screen summary on stdout.
 *
 *  Build (repo root, gmloader armhf image):
 *    docker run --rm -v "$PWD:/src" -w /src gmloader-armhf-build:bullseye \
 *        make -f tools/Makefile.fps_probe
 *  Run on the MiSTer with the game up:
 *    /tmp/fps_probe.armhf <seconds> /tmp/fps.csv [poll_us=500] [cpu=1]
 *
 *  GPL-3.0
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define FB_BASE     0x3BF40000u     /* scanout region (ship FB_QW_BASE * 8) */
#define FB_SPAN     0x00080000u     /* covers ctrl @ +0 and scan_frame_cnt @ +0x70018 */
#define FB_CTRL_OFF 0x00000000u
#define FB_SCAN_OFF 0x00070018u     /* 0x3BFB0018 */
#define BLT_BASE    0x3B000000u
#define BLT_SPAN    0x00001000u
#define BLT_SUB_OFF 0x00000000u     /* C_SUBMIT, qword 0 */
#define BLT_DONE_OFF 0x00000028u    /* C_DONE,   qword 5 */

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static volatile uint8_t *map(int fd, uint32_t base, uint32_t span) {
    void *p = mmap(NULL, span, PROT_READ, MAP_SHARED, fd, base);
    if (p == MAP_FAILED) { perror("mmap"); exit(1); }
    return (volatile uint8_t *)p;
}
#define RD32(b, off) (*(volatile uint32_t *)((b) + (off)))

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <seconds> <out.csv> [poll_us=500] [cpu=1]\n", argv[0]);
        return 2;
    }
    const double secs = atof(argv[1]);
    const long poll_us = argc > 3 ? atol(argv[3]) : 500;
    const int cpu = argc > 4 ? atoi(argv[4]) : 1;

    if (cpu >= 0) {
        cpu_set_t set; CPU_ZERO(&set); CPU_SET(cpu, &set);
        if (sched_setaffinity(0, sizeof(set), &set) != 0) perror("sched_setaffinity");
    }
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    volatile uint8_t *fb = map(fd, FB_BASE, FB_SPAN);
    volatile uint8_t *blt = map(fd, BLT_BASE, BLT_SPAN);
    FILE *out = fopen(argv[2], "w");
    if (!out) { perror(argv[2]); return 1; }
    fprintf(out, "t_us,scan,fc,sub,done,lat_us,gap\n");

    const struct timespec nap = { 0, poll_us * 1000 };
    uint32_t last_scan = RD32(fb, FB_SCAN_OFF);
    uint32_t last_fc = RD32(fb, FB_CTRL_OFF) >> 2;
    const uint64_t t0 = now_us(), tend = t0 + (uint64_t)(secs * 1e6);
    uint64_t tprev = t0;
    uint32_t last_sub = RD32(blt, BLT_SUB_OFF), last_done = RD32(blt, BLT_DONE_OFF);
    uint32_t last_fc2 = last_fc;
    /* Summary: 60-boundary windows of distinct adopted frames. */
    unsigned long bounds = 0, repeats = 0, missed = 0, win_new = 0, win_n = 0;
    unsigned long hist[62] = {0};
    for (;;) {
        nanosleep(&nap, NULL);
        const uint64_t t = now_us();
        if (t >= tend) break;
        const uint32_t scan = RD32(fb, FB_SCAN_OFF);
        const uint32_t fc = RD32(fb, FB_CTRL_OFF) >> 2;
        const uint32_t sub = RD32(blt, BLT_SUB_OFF);
        const uint32_t done = RD32(blt, BLT_DONE_OFF);
        const uint32_t gap = scan - last_scan;
        if (!gap && sub == last_sub && done == last_done && fc == last_fc2) { tprev = t; continue; }
        last_sub = sub; last_done = done; last_fc2 = fc;
        fprintf(out, "%llu,%u,%u,%u,%u,%llu,%u\n",
                (unsigned long long)(t - t0), scan, fc, sub, done,
                (unsigned long long)(t - tprev), gap);
        tprev = t;
        if (!gap) continue;
        bounds += gap;
        if (gap > 1) missed += gap - 1;
        const int fresh = (fc != last_fc);
        if (!fresh) repeats++;
        win_new += fresh; win_n += gap;
        if (win_n >= 60) {
            hist[win_new > 61 ? 61 : win_new]++;
            win_new = 0; win_n = 0;
        }
        last_scan = scan; last_fc = fc;
    }
    fclose(out);
    printf("boundaries=%lu repeats=%lu missed_by_probe=%lu\n", bounds, repeats, missed);
    printf("new-frames per 60-boundary window:");
    for (int i = 0; i < 62; i++) if (hist[i]) printf(" %d:%lu", i, hist[i]);
    printf("\n");
    return 0;
}
