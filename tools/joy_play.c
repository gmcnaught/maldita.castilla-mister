/*
 *  joy_play.c — endless scripted play for the fps-dip harness (scripts/fpsdip/).
 *
 *  gmloader-next's tools/joy_script replays a fixed .joy file of at most 256
 *  steps, which cannot hold a 10-minute route. This driver owns the same joy-shm
 *  file (contract: gmloader-next gmloader/mister/mister_joy_shm.h, duplicated
 *  below) and generates input itself:
 *    0 .. 20 s          nothing (the engine loads)
 *    20 s .. INTRO_MS   Sword pulse every 2 s (title -> Chapter I, as
 *                       scripts/scenes/ingame-stage1.joy)
 *    INTRO_MS ..        seeded pseudo-random play until SIGTERM: mostly right
 *                       with jump (Action) and Sword pulses, short left / up /
 *                       down excursions. Sword pulses also restart the game
 *                       from the title after a game over.
 *  Needs GMLOADER_GODMODE=1 so contact damage cannot stall the route.
 *
 *  Same ordering contract as joy_script: start it BEFORE load_core — the engine
 *  latches the shm transport on its first input poll or never.
 *
 *  usage: joy_play [shm-path=/dev/shm/maldita-joy] [seed=1] [intro_ms=64000]
 *  Build: docker run --rm -v "$PWD:/src" -w /src gmloader-armhf-build:bullseye \
 *             make -f tools/Makefile.joy_play
 *
 *  GPL-3.0
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* gmloader-next gmloader/mister/mister_joy_shm.h */
#define MALDITA_JOY_SHM_PATH    "/dev/shm/maldita-joy"
#define MALDITA_JOY_SHM_MAGIC   0x4D414C44u
#define MALDITA_JOY_SHM_VERSION 1u
typedef struct {
    uint32_t magic, version, generation;
    uint32_t joy_mask[2];
} MalditaJoyShm;

enum { RIGHT = 0x001, LEFT = 0x002, DOWN = 0x004, UP = 0x008, SWORD = 0x010, JUMP = 0x020 };

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static uint64_t g_rng;
static uint32_t rnd(void) {            /* xorshift64*, deterministic per seed */
    g_rng ^= g_rng >> 12; g_rng ^= g_rng << 25; g_rng ^= g_rng >> 27;
    return (uint32_t)((g_rng * 2685821657736338717ull) >> 32);
}
static uint32_t rnd_range(uint32_t lo, uint32_t hi) { return lo + rnd() % (hi - lo + 1u); }

static struct timespec g_base;
static void sleep_until_ms(uint64_t ms) {
    struct timespec d = g_base;
    d.tv_sec  += (time_t)(ms / 1000u);
    d.tv_nsec += (long)(ms % 1000u) * 1000000L;
    if (d.tv_nsec >= 1000000000L) { d.tv_nsec -= 1000000000L; d.tv_sec += 1; }
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &d, NULL) == EINTR && !g_stop) {}
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : MALDITA_JOY_SHM_PATH;
    g_rng = (argc > 2 ? strtoull(argv[2], NULL, 0) : 1u) * 0x9E3779B97F4A7C15ull | 1u;
    const uint64_t intro_ms = argc > 3 ? strtoull(argv[3], NULL, 0) : 64000u;

    int fd = open(path, O_RDWR | O_CREAT, 0666);
    if (fd < 0 || ftruncate(fd, (off_t)sizeof(MalditaJoyShm)) != 0) {
        fprintf(stderr, "joy_play: %s: %s\n", path, strerror(errno));
        return 1;
    }
    MalditaJoyShm *p = mmap(NULL, sizeof *p, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { perror("joy_play: mmap"); return 1; }
    p->joy_mask[0] = p->joy_mask[1] = 0u;
    p->version = MALDITA_JOY_SHM_VERSION;
    p->generation += 1u;
    __sync_synchronize();
    p->magic = MALDITA_JOY_SHM_MAGIC;          /* doorbell LAST */
    __sync_synchronize();
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    clock_gettime(CLOCK_MONOTONIC, &g_base);
    printf("JOYPLAY start shm=%s intro_ms=%llu\n", path, (unsigned long long)intro_ms);
    fflush(stdout);

#define SET(m) do { p->joy_mask[0] = (m); __sync_synchronize(); } while (0)
    uint64_t t;
    for (t = 20000; t < intro_ms && !g_stop; t += 2000) {
        sleep_until_ms(t);       SET(SWORD);
        sleep_until_ms(t + 250); SET(0);
    }
    unsigned long segs = 0;
    while (!g_stop) {
        const uint32_t r = rnd() % 100u;
        const uint32_t base = r < 70 ? RIGHT : r < 82 ? LEFT
                            : r < 90 ? (UP | ((rnd() & 1u) ? RIGHT : 0)) : r < 95 ? DOWN : 0;
        const uint64_t seg_end = t + rnd_range(800, 3000);
        while (t < seg_end && !g_stop) {
            const uint32_t a = rnd() % 100u;
            const uint32_t pulse = a < 35 ? JUMP : a < 70 ? SWORD : 0;
            const uint32_t hold = rnd_range(150, 450);
            sleep_until_ms(t); SET(base | pulse);
            if (pulse) { sleep_until_ms(t + hold); SET(base); }
            t += hold + rnd_range(100, 500);
        }
        segs++;
    }
    /* Clear the doorbell before unlinking: a stale file with a valid magic would
     * latch the next production launch onto a frozen mask (see joy_script.c). */
    p->magic = 0u;
    __sync_synchronize();
    munmap((void *)p, sizeof *p);
    unlink(path);
    printf("JOYPLAY stop t=%llums segments=%lu\n", (unsigned long long)t, segs);
    return 0;
}
