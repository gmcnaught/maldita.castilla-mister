#ifndef MISTER_JOY_SHM_H
#define MISTER_JOY_SHM_H

/*
 * Maldita Castilla MiSTer — host↔engine joystick shared-memory contract.
 *
 * The MiSTer_Maldita wrapper (producer) publishes a normalized per-player
 * button mask here each frame; gmloadernext (consumer) mmaps it read-only and
 * translates it into yoyo_gamepads[] button state. See spec
 * docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md.
 *
 * Bit layout of joy_mask[i] (MiSTer standard digital joystick order, then the
 * CONF_STR J1 buttons "Sword,Action,Item 1,Item 2,Pause"):
 *   bit0=right bit1=left bit2=down bit3=up
 *   bit4=Sword bit5=Action bit6=Item1 bit7=Item2 bit8=Pause
 * NOTE: the mapping from these bits onto the engine's gamepad button indices
 * is verified on hardware (feat #2), not assumed.
 */

#include <stdint.h>

#define MALDITA_JOY_SHM_PATH    "/dev/shm/maldita-joy"
#define MALDITA_JOY_SHM_MAGIC   0x4D414C44u   /* "MALD" */
#define MALDITA_JOY_SHM_VERSION 1u
#define MALDITA_JOY_MAX_PLAYERS 2

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MalditaJoyShm {
    uint32_t magic;                            /* MALDITA_JOY_SHM_MAGIC once initialised */
    uint32_t version;                          /* MALDITA_JOY_SHM_VERSION */
    uint32_t generation;                       /* ++ on each engine respawn; consumer may ignore */
    uint32_t joy_mask[MALDITA_JOY_MAX_PLAYERS];/* naturally-aligned; atomic single-word access */
} MalditaJoyShm;

#ifdef __cplusplus
}
#endif

#endif /* MISTER_JOY_SHM_H */
