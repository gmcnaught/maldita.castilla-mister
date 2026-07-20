#include "maldita_joy_shm.h"
#include "mister_joy_shm.h"

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

/* MiSTer input.cpp API (added by the overlay in Task 2). */
extern "C" void input_get_joy_mask(uint32_t *masks, int n);
extern "C" void input_set_joy_passthrough(int on);

static MalditaJoyShm *g_shm = 0;

static const char *shm_path(void) {
    const char *o = getenv("MALDITA_JOY_SHM_PATH");   /* test-only override */
    return (o && *o) ? o : MALDITA_JOY_SHM_PATH;
}

bool maldita_joy_open(void) {
    const char *path = shm_path();
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    bool ok = (ftruncate(fd, sizeof(MalditaJoyShm)) == 0);
    if (ok) {
        g_shm = (MalditaJoyShm*)mmap(0, sizeof(MalditaJoyShm),
                                     PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (g_shm == MAP_FAILED) { g_shm = 0; ok = false; }
    }
    close(fd);
    if (!ok) return false;

    g_shm->magic      = MALDITA_JOY_SHM_MAGIC;
    g_shm->version    = MALDITA_JOY_SHM_VERSION;
    g_shm->generation = 0;
    memset(g_shm->joy_mask, 0, sizeof(g_shm->joy_mask));

    setenv("GMLOADER_JOY_SHM", path, 1);
    input_set_joy_passthrough(1);   /* export the MiSTer-normalized mask */
    return true;
}

void maldita_joy_publish(int osd_visible) {
    if (!g_shm) return;
    uint32_t masks[MALDITA_JOY_MAX_PLAYERS];
    if (osd_visible) {
        memset(masks, 0, sizeof(masks));         /* no input leak while OSD is up */
    } else {
        input_get_joy_mask(masks, MALDITA_JOY_MAX_PLAYERS);
    }
    for (int i = 0; i < MALDITA_JOY_MAX_PLAYERS; i++)
        g_shm->joy_mask[i] = masks[i];           /* single-word atomic store */
}

void maldita_joy_bump_generation(void) { if (g_shm) g_shm->generation++; }

void maldita_joy_close(void) {
    if (g_shm) { munmap(g_shm, sizeof(MalditaJoyShm)); g_shm = 0; }
}
