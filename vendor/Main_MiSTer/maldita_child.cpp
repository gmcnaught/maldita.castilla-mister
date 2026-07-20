#include "maldita_child.h"
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

MalditaChildAction maldita_crash_decide(int exit_code, int consecutive_crashes, int max_crashes)
{
    if (exit_code == 0) return MALDITA_CHILD_MENU;
    if (consecutive_crashes >= max_crashes) return MALDITA_CHILD_HALT;
    return MALDITA_CHILD_RESPAWN;
}

int maldita_crash_backoff_ms(int consecutive_crashes)
{
    if (consecutive_crashes <= 0) return 0;
    int ms = 250;
    for (int i = 1; i < consecutive_crashes; i++) {
        ms <<= 1;
        if (ms >= 2000) return 2000;
    }
    return ms;
}

int maldita_crash_count_update(int prev_count, long ms_since_last_crash, long window_ms)
{
    if (ms_since_last_crash > window_ms) return 1;
    return prev_count + 1;
}

/* ---- syscall wrappers ---- */

pid_t maldita_child_spawn(char *const argv[], char *const envp[])
{
    pid_t pid = fork();
    if (pid < 0) {
        return -1;  /* fork failed */
    }
    if (pid == 0) {
        /* Child process */
#ifdef __linux__
        prctl(PR_SET_PDEATHSIG, SIGTERM);  /* die if parent dies */
#endif
        execve(argv[0], argv, envp);
        exit(127);  /* execve failed */
    }
    /* Parent process */
    return pid;
}

bool maldita_child_reap(pid_t pid, int *exit_code_out)
{
    int status;
    pid_t result = waitpid(pid, &status, WNOHANG);

    if (result < 0) {
        /* Error (child doesn't exist or other error) */
        return false;
    }
    if (result == 0) {
        /* Child still running */
        return false;
    }
    /* Child has changed state */
    if (WIFEXITED(status)) {
        *exit_code_out = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        *exit_code_out = 128 + WTERMSIG(status);
    } else {
        *exit_code_out = -1;  /* Unexpected status */
    }
    return true;
}

void maldita_child_signal(pid_t pid, int sig)
{
    kill(pid, sig);
}
