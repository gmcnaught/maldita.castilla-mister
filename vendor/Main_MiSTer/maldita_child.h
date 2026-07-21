#ifndef MALDITA_CHILD_H
#define MALDITA_CHILD_H

#include <sys/types.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MalditaChildAction {
    MALDITA_CHILD_MENU    = 0,  /* clean exit → return to menu */
    MALDITA_CHILD_RESPAWN = 1,  /* crash within budget → respawn with backoff */
    MALDITA_CHILD_HALT    = 2   /* crash budget exhausted → halt, leave RBF loaded */
} MalditaChildAction;

/* ---- pure decision logic (no syscalls; unit-tested) ---- */
MalditaChildAction maldita_crash_decide(int exit_code, int consecutive_crashes, int max_crashes);
int maldita_crash_backoff_ms(int consecutive_crashes);
int maldita_crash_count_update(int prev_count, long ms_since_last_crash, long window_ms);

/* ---- syscall wrappers (Task 3) ---- */
pid_t maldita_child_spawn(char *const argv[], char *const envp[], const char *cwd);
bool  maldita_child_reap(pid_t pid, int *exit_code_out); /* WNOHANG; true if state changed */
void  maldita_child_signal(pid_t pid, int sig);

#ifdef __cplusplus
}
#endif

#endif /* MALDITA_CHILD_H */
