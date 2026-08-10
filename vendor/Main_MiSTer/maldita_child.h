#ifndef MALDITA_CHILD_H
#define MALDITA_CHILD_H

#include <sys/types.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Spawn the launch handler as a detached child.
 *
 * argv[0] is the absolute path to exec. envp NULL inherits environ; cwd NULL
 * keeps the parent's. log_path receives the child's stdout+stderr (O_APPEND);
 * NULL or an unopenable path is non-fatal and leaves the parent's stdio, which
 * under MiSTer is /dev/console — so pass a real path in production.
 *
 * Returns the child pid, or -1 if fork() failed.
 *
 * DETACHED IS LOAD-BEARING, NOT TIDINESS. The child gets its own session and
 * deliberately does NOT set PR_SET_PDEATHSIG. The reverted wrapper set it, which
 * was right when the wrapper supervised the engine for the whole session — and
 * is exactly wrong now: the HPS takeover KILLS THIS PROCESS a few seconds after
 * the engine proves itself live, and a PDEATHSIG child would die with it. */
pid_t maldita_child_spawn(char *const argv[], char *const envp[], const char *cwd,
                          const char *log_path);

/* WNOHANG reap. True when the child changed state, and then exit_code_out (if
 * given) is its exit status, or 128+signal if it was killed. */
bool  maldita_child_reap(pid_t pid, int *exit_code_out);

void  maldita_child_signal(pid_t pid, int sig);

/* Signal the child's whole process group (the launcher shell AND the engine it
 * started), falling back to the single pid if the child is not a group leader.
 * This is what an OSD Reset uses — see the definition for why signalling only
 * the launcher shell is not enough. */
void  maldita_child_signal_group(pid_t pid, int sig);

#ifdef __cplusplus
}
#endif

#endif /* MALDITA_CHILD_H */
