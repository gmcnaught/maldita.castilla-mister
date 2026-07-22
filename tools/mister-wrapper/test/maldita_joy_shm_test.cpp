#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include "mister_joy_shm.h"
#include "maldita_joy_shm.h"

// --- stubs standing in for MiSTer input.cpp symbols (real ones added in Task 2) ---
static uint32_t g_test_mask[MALDITA_JOY_MAX_PLAYERS] = {0};
extern "C" void input_get_joy_mask(uint32_t *masks, int n) {
    for (int i = 0; i < n; i++) masks[i] = g_test_mask[i];
}
extern "C" void input_set_joy_passthrough(int) { }

static int fails = 0;
#define CHECK(c) do { if(!(c)){printf("FAIL %s (line %d)\n",#c,__LINE__);fails++;} } while(0)

static MalditaJoyShm *map_ro(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    MalditaJoyShm *p = (MalditaJoyShm*)mmap(NULL, sizeof(MalditaJoyShm), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    return (p == MAP_FAILED) ? NULL : p;
}

int main(void) {
    char path[] = "/tmp/maldita-joy-test";
    setenv("MALDITA_JOY_SHM_PATH", path, 1);   // test path override
    unlink(path);

    CHECK(maldita_joy_open() == true);
    MalditaJoyShm *ro = map_ro(path);
    CHECK(ro != NULL);
    CHECK(ro->magic == MALDITA_JOY_SHM_MAGIC);
    CHECK(ro->version == MALDITA_JOY_SHM_VERSION);

    // Publish a known mask when OSD is not visible → mirrored to SHM.
    g_test_mask[0] = 0x110; g_test_mask[1] = 0x0;   // Pause(0x100)|Action(0x20)? just a bit pattern
    maldita_joy_publish(0);
    CHECK(ro->joy_mask[0] == 0x110);

    // OSD visible → masks zeroed (no input leak into the game).
    maldita_joy_publish(1);
    CHECK(ro->joy_mask[0] == 0x0);

    // Generation bumps on respawn.
    uint32_t g0 = ro->generation;
    maldita_joy_bump_generation();
    CHECK(ro->generation == g0 + 1);

    // Env var was exported for the engine.
    CHECK(getenv("GMLOADER_JOY_SHM") != NULL);

    maldita_joy_close();
    if (fails) { printf("%d checks FAILED\n", fails); return 1; }
    printf("maldita_joy_shm publisher OK\n");
    return 0;
}
