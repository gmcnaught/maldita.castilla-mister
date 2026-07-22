#include "maldita_osd.h"
#include <stdint.h>

/* MiSTer user_io API: returns the sticky-latched pulse of T-type status bits
 * captured since the last call (HandleUI pulses T bits set-then-clear within a
 * single call; user_io_status_trigger_take consumes them). */
extern "C" uint32_t user_io_status_trigger_take(void);

/* CONF_STR "TJ,Reset;" — T-trigger on status bit 19 (fpga/Maldita.sv:942). */
#define MALDITA_RESET_TBIT 19

void maldita_osd_poll(pid_t /*child*/, int *restart_out)
{
    if (restart_out) *restart_out = 0;
    uint32_t triggers = user_io_status_trigger_take();
    if (triggers & (1u << MALDITA_RESET_TBIT)) {
        if (restart_out) *restart_out = 1;   /* wrapper respawns in place (not a crash) */
    }
}
