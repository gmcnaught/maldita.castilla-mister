#include "maldita_reset.h"

void maldita_reset_init(maldita_reset_t *st, int64_t term_budget_ms, int64_t kill_budget_ms)
{
	if (!st) return;
	st->phase = MALDITA_RESET_IDLE;
	st->deadline_ms = 0;
	st->term_budget_ms = term_budget_ms;
	st->kill_budget_ms = kill_budget_ms;
	st->restarts = 0;
}

maldita_reset_action maldita_reset_step(maldita_reset_t *st, bool requested,
                                        bool child_alive, int64_t now_ms)
{
	if (!st) return MALDITA_RESET_ACT_NONE;

	switch (st->phase)
	{
	case MALDITA_RESET_IDLE:
		if (!requested) return MALDITA_RESET_ACT_NONE;
		if (!child_alive)
		{
			/* Nothing to kill — the engine already exited on its own (a crash,
			 * or the user quit it) and nothing respawns it on this path. Reset
			 * is then the only way back into the game, so honour it directly. */
			st->restarts++;
			return MALDITA_RESET_ACT_SPAWN;
		}
		st->phase = MALDITA_RESET_TERM;
		st->deadline_ms = now_ms + st->term_budget_ms;
		return MALDITA_RESET_ACT_TERM;

	case MALDITA_RESET_TERM:
		if (!child_alive)
		{
			st->phase = MALDITA_RESET_IDLE;
			st->restarts++;
			return MALDITA_RESET_ACT_SPAWN;
		}
		if (now_ms >= st->deadline_ms)
		{
			st->phase = MALDITA_RESET_KILL;
			st->deadline_ms = now_ms + st->kill_budget_ms;
			return MALDITA_RESET_ACT_KILL;
		}
		return MALDITA_RESET_ACT_NONE;

	case MALDITA_RESET_KILL:
		/* Spawn once the child is gone, and spawn ANYWAY if even SIGKILL has not
		 * cleared it inside the budget. A child that survives SIGKILL is stuck in
		 * uninterruptible I/O, which on this box means a stalled DDR access — and
		 * leaving the user with no engine at all is strictly worse than starting
		 * one over the top. The fresh launch.sh reaps strays (SIGTERM, then
		 * SIGKILL after 3 s) and takes the launch lock over from a dead owner
		 * before it starts anything, so the overlap is handled there. */
		if (!child_alive || now_ms >= st->deadline_ms)
		{
			st->phase = MALDITA_RESET_IDLE;
			st->restarts++;
			return MALDITA_RESET_ACT_SPAWN;
		}
		return MALDITA_RESET_ACT_NONE;
	}

	return MALDITA_RESET_ACT_NONE;
}
