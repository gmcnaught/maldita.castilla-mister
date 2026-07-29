/*
 *  audio_ring_probe.c — Tier 0 audio/video sync probe for the Maldita core.
 *
 *  Plan: docs/superpowers/plans/2026-07-28-audio-video-sync-diagnostics.md §3.
 *
 *  Answers one question with no rebuild of engine or RBF: is the FPGA actually
 *  draining the audio ring at 48 000 Hz? Everything else in the audio chain is
 *  closed-loop on that rate, so if it holds, the "wrong speed" symptom is NOT
 *  the sink; if it does not hold, the reader's FIFO is starving and the sample-
 *  hold path in openbor_video_reader.sv is stretching the audio.
 *
 *  Reads (never writes) three DDR locations:
 *    0x3A000030  audio wr_ptr — ARM writes  (byte offset into the 64 KiB ring)
 *    0x3A000038  audio rd_ptr — FPGA writes (byte offset into the 64 KiB ring)
 *    0x3B000000  C_SUBMIT     — blitter doorbell sequence, the engine's frame rate
 *
 *  The ring is 64 KiB and drains at 192 000 B/s, so it wraps every 341 ms. The
 *  sample interval must stay well under that or a wrap is indistinguishable
 *  from a stall — hence the 100 ms default and the hard cap in main().
 *
 *  Build (from this repo root, using the gmloader armhf image):
 *    docker run --rm -v "$PWD:/src" -w /src gmloader-armhf-build:bullseye \
 *        make -f tools/Makefile.audio_ring_probe
 *  Run (on the MiSTer, after the game is up):
 *    scp tools/audio_ring_probe.armhf root@192.168.20.81:/tmp/
 *    ssh root@192.168.20.81 /tmp/audio_ring_probe.armhf 10
 *
 *  GPL-3.0
 */

#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* Audio region — must match openbor_video_reader.sv's absolute audio map
 * (AUDIO_WR_ADDR / AUDIO_RD_ADDR / AUDIO_RING_ADDR) and
 * gmloader/mister/native_audio_writer.c's NA_* constants. */
#define AUD_BASE        0x3A000000u
#define AUD_SPAN        0x00100000u   /* 1 MB, same window the host writer maps */
#define AUD_WR_OFF      0x00000030u
#define AUD_RD_OFF      0x00000038u
#define RING_BYTES      0x00010000u   /* 64 KiB */
#define RING_MASK       (RING_BYTES - 1u)

/* Blitter control block — C_SUBMIT is qword 0 of the region at 0x3B000000. */
#define BLT_BASE        0x3B000000u
#define BLT_SPAN        0x00001000u
#define BLT_C_SUBMIT    0x00000000u

#define BYTES_PER_FRAME 4u            /* stereo S16 */
#define NOMINAL_HZ      48000.0
#define SCANOUT_HZ      59.923        /* 380x262 @ 53.693 MHz / 9 */

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* Forward distance from `prev` to `cur` on a RING_BYTES modular counter.
 * Valid only while the true advance is < RING_BYTES — the caller's sample
 * interval is what guarantees that. */
static uint32_t ring_delta(uint32_t prev, uint32_t cur) {
    return (cur - prev) & RING_MASK;
}

int main(int argc, char **argv) {
    double duration_s = (argc > 1) ? atof(argv[1]) : 10.0;
    double interval_s = (argc > 2) ? atof(argv[2]) : 0.100;

    if (duration_s <= 0.0) duration_s = 10.0;
    /* Above ~150 ms a full ring wrap hides inside one sample and every number
     * below becomes a lie rather than a measurement. Refuse, don't clamp
     * silently. */
    if (interval_s <= 0.0 || interval_s > 0.150) {
        fprintf(stderr,
            "interval %.3f s is out of range: the 64 KiB ring wraps every "
            "341 ms at 48 kHz, so samples must be <= 0.150 s\n", interval_s);
        return 2;
    }

    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    volatile uint8_t *aud = mmap(NULL, AUD_SPAN, PROT_READ, MAP_SHARED, fd, AUD_BASE);
    if (aud == MAP_FAILED) { perror("mmap audio region"); close(fd); return 1; }

    volatile uint8_t *blt = mmap(NULL, BLT_SPAN, PROT_READ, MAP_SHARED, fd, BLT_BASE);
    if (blt == MAP_FAILED) {
        perror("mmap blitter region (video rate will be omitted)");
        blt = NULL;
    }

    volatile uint32_t *wr_reg = (volatile uint32_t *)(aud + AUD_WR_OFF);
    volatile uint32_t *rd_reg = (volatile uint32_t *)(aud + AUD_RD_OFF);
    volatile uint32_t *sub_reg =
        blt ? (volatile uint32_t *)(blt + BLT_C_SUBMIT) : NULL;

    uint32_t wr_prev = *wr_reg & RING_MASK;
    uint32_t rd_prev = *rd_reg & RING_MASK;
    uint32_t sub_prev = sub_reg ? *sub_reg : 0u;

    uint64_t wr_total = 0, rd_total = 0, sub_total = 0;
    uint32_t occ_min = UINT32_MAX, occ_max = 0;
    uint64_t occ_sum = 0;
    unsigned samples = 0;

    const double t0 = now_s();
    double t_prev = t0;

    printf("# audio ring probe: ring=%u B, nominal drain=%.0f Hz, scanout=%.3f Hz\n",
           RING_BYTES, NOMINAL_HZ, SCANOUT_HZ);
    /* d_rd_B is the raw, un-rate-converted byte advance of rd_ptr in this
     * sample. It is the column that identifies WHICH failure is in play: the
     * reader refills in bursts of at most 256 B, so if the deficit is whole
     * missing bursts (d_rd_B quantised to 256 B steps) the FSM is abandoning
     * planned bursts, whereas FIFO underflow starves the pop at sample
     * granularity and leaves no such quantisation. */
    printf("# %8s %10s %10s %8s %8s %8s\n",
           "t_s", "drain_hz", "submit_hz", "occ_fr", "eng_fps", "d_rd_B");

    while (now_s() - t0 < duration_s) {
        struct timespec req = {
            (time_t)interval_s,
            (long)((interval_s - (double)(time_t)interval_s) * 1e9)
        };
        nanosleep(&req, NULL);

        /* Read rd before wr: rd only ever falls further behind between the two
         * reads, so occupancy is over-stated rather than under-stated and can
         * never come out negative. */
        const uint32_t rd_cur = *rd_reg & RING_MASK;
        const uint32_t wr_cur = *wr_reg & RING_MASK;
        const uint32_t sub_cur = sub_reg ? *sub_reg : 0u;
        const double t_now = now_s();
        const double dt = t_now - t_prev;
        if (dt <= 0.0) continue;

        const uint32_t d_rd = ring_delta(rd_prev, rd_cur);
        const uint32_t d_wr = ring_delta(wr_prev, wr_cur);
        const uint32_t d_sub = sub_cur - sub_prev;   /* free-running, wraps at 2^32 */
        const uint32_t occ = ring_delta(rd_cur, wr_cur) / BYTES_PER_FRAME;

        const double drain_hz  = (double)d_rd / BYTES_PER_FRAME / dt;
        const double submit_hz = (double)d_wr / BYTES_PER_FRAME / dt;
        const double eng_fps   = sub_reg ? (double)d_sub / dt : 0.0;

        printf("  %8.3f %10.1f %10.1f %8u %8.2f %8u\n",
               t_now - t0, drain_hz, submit_hz, occ, eng_fps, d_rd);
        fflush(stdout);

        wr_total += d_wr;
        rd_total += d_rd;
        sub_total += d_sub;
        occ_sum += occ;
        if (occ < occ_min) occ_min = occ;
        if (occ > occ_max) occ_max = occ;
        samples++;

        wr_prev = wr_cur;
        rd_prev = rd_cur;
        sub_prev = sub_cur;
        t_prev = t_now;
    }

    const double elapsed = now_s() - t0;
    if (samples == 0 || elapsed <= 0.0) {
        fprintf(stderr, "no samples taken\n");
        return 1;
    }

    const double drain_hz  = (double)rd_total / BYTES_PER_FRAME / elapsed;
    const double submit_hz = (double)wr_total / BYTES_PER_FRAME / elapsed;
    const double eng_fps   = sub_reg ? (double)sub_total / elapsed : 0.0;

    printf("\n== summary over %.2f s (%u samples) ==\n", elapsed, samples);
    printf("  FPGA drain     : %.1f Hz  (%+.3f%% vs %.0f nominal)\n",
           drain_hz, (drain_hz / NOMINAL_HZ - 1.0) * 100.0, NOMINAL_HZ);
    printf("  host submit    : %.1f Hz  (%+.3f%% vs %.0f nominal)\n",
           submit_hz, (submit_hz / NOMINAL_HZ - 1.0) * 100.0, NOMINAL_HZ);
    printf("  ring occupancy : min %u  mean %.0f  max %u frames "
           "(%.1f ms mean latency)\n",
           occ_min, (double)occ_sum / samples, occ_max,
           (double)occ_sum / samples / NOMINAL_HZ * 1000.0);
    if (sub_reg)
        printf("  engine frames  : %.2f fps vs %.3f Hz scanout (ratio %.3f)\n",
               eng_fps, SCANOUT_HZ, eng_fps / SCANOUT_HZ);
    else
        printf("  engine frames  : unavailable (blitter region not mapped)\n");

    /* Reading, per the plan's §3 decision table. */
    puts("");
    if (drain_hz < NOMINAL_HZ * 0.995)
        puts("  => drain is BELOW 48 kHz: FPGA audio FIFO starvation (H1). "
             "Go to Tier 2 (RTL underflow counters).");
    else if (occ_max == 0)
        puts("  => ring never held audio: producer starvation or the pump is "
             "not running (H2/H5). Go to Tier 1.");
    else if (occ_min <= 1)
        puts("  => ring ran dry: producer cannot sustain 48 kHz (H2/H5). "
             "Go to Tier 1 and read the silence fraction.");
    else
        puts("  => drain rate is correct and the ring never ran dry: the sink "
             "is not the defect. Go to Tier 1 (silence fill / latency / "
             "engine fps).");

    munmap((void *)aud, AUD_SPAN);
    if (blt) munmap((void *)blt, BLT_SPAN);
    close(fd);
    return 0;
}
