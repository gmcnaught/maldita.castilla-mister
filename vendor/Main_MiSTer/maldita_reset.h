#ifndef MALDITA_RESET_H
#define MALDITA_RESET_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* OSD Reset -> engine restart, as a pure state machine.
 *
 * WHY A STATE MACHINE AND NOT A FUNCTION THAT JUST DOES IT. maldita_hook_poll()
 * runs on the scheduler's co_poll cothread, cooperatively scheduled against
 * co_ui (HandleUI/OsdUpdate). Blocking there for the seconds a teardown can take
 * freezes the OSD, the input poll and the frame timer — the user would select
 * Reset and watch the menu lock up. So the restart is stepped one scheduler
 * iteration at a time and this unit holds the only state involved, which also
 * makes it testable host-native with no MiSTer symbols (see
 * tools/mister-wrapper/test/maldita_reset_test.cpp).
 *
 * WHAT A RESET ACTUALLY RESETS. Nothing here touches the FPGA: the RBF stays
 * loaded and there is no core reset (fpga_core_reset() from this process cost us
 * "no signal" and a dead OSD once already). The reset is entirely a consequence
 * of the engine dying and being started again:
 *
 *   - SIGTERM reaches gmloader, whose handler runs mf_fabric_teardown(): wait
 *     for the in-flight batch to ack, zero the command ring, park the control
 *     block against the sequence the fabric last reported.
 *   - The fresh launch.sh reaps any stray engine, waits on the FPGA-ready bit,
 *     and starts a new gmloader, whose mf_fabric_bringup() clears the rings AND
 *     the ~14.75 MiB SRC heap, parks the control block, and proves the fabric
 *     with a zero-command probe batch before the first real frame.
 *   - GameMaker starts from scratch, so the game is back at its first screen.
 *
 * That covers "reset the game, the DDR ring and the control block". A wedged
 * FPGA fabric needs a real reconfigure, which is NOT done here: launch.sh's own
 * recovery gate already detects a soft-failed bring-up on the fresh engine and
 * does the menu.rbf round-trip itself, so a Reset onto a jammed fabric still
 * recovers — via the path that is already device-proven, and only when needed.
 */

typedef enum {
	MALDITA_RESET_IDLE = 0,  /* no restart in flight */
	MALDITA_RESET_TERM,      /* SIGTERM sent, waiting for the child to go */
	MALDITA_RESET_KILL,      /* SIGKILL sent, waiting for the child to go */
} maldita_reset_phase;

typedef enum {
	MALDITA_RESET_ACT_NONE = 0,
	MALDITA_RESET_ACT_TERM,   /* caller: signal the child SIGTERM */
	MALDITA_RESET_ACT_KILL,   /* caller: signal the child SIGKILL */
	MALDITA_RESET_ACT_SPAWN,  /* caller: spawn a fresh launch handler */
} maldita_reset_action;

typedef struct {
	maldita_reset_phase phase;
	int64_t deadline_ms;
	int64_t term_budget_ms;
	int64_t kill_budget_ms;
	uint32_t restarts;   /* completed restarts, for the log line */
} maldita_reset_t;

/* term_budget_ms: how long SIGTERM gets before escalating. The engine's own
 * teardown budget is 250 ms, and killing launch.sh (a shell) is immediate, so
 * seconds here is a cap and not a cost.
 * kill_budget_ms: how long SIGKILL gets before we spawn anyway. Spawning over an
 * unreapable child is safe — the fresh launch.sh reaps strays and takes the
 * launch lock over from a dead owner. */
void maldita_reset_init(maldita_reset_t *st, int64_t term_budget_ms, int64_t kill_budget_ms);

/* One scheduler iteration.
 *
 *   requested    a Reset pulse was taken since the last call
 *   child_alive  the launch handler / engine child has not been reaped yet
 *   now_ms       monotonic milliseconds
 *
 * Returns at most one action per call; the caller performs it and calls again on
 * the next iteration. `requested` is deliberately IGNORED while a restart is in
 * flight: a user mashing Reset must not stack restarts, which is how you end up
 * with two engines on one fabric control block. */
maldita_reset_action maldita_reset_step(maldita_reset_t *st, bool requested,
                                        bool child_alive, int64_t now_ms);

#ifdef __cplusplus
}
#endif

#endif /* MALDITA_RESET_H */
