#ifndef MALDITA_HOOK_H
#define MALDITA_HOOK_H

#ifdef __cplusplus
extern "C" {
#endif

/* Called from scheduler_co_poll() immediately after scheduler_wait_fpga_ready()
 * returns — i.e. on every scheduler iteration, with the FPGA readiness contract
 * already satisfied by upstream's own guard.
 *
 * Spawns the Maldita launch handler exactly once, then degenerates into a
 * cheap no-op (plus an occasional WNOHANG reap of the handler).
 *
 * Everything about the decision is in maldita_hook.cpp; this header exists so
 * the one-line overlay in scheduler.cpp needs no other local change. */
void maldita_hook_poll(void);

#ifdef __cplusplus
}
#endif

#endif /* MALDITA_HOOK_H */
