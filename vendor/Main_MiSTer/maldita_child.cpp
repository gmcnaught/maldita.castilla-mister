#include "maldita_child.h"
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <signal.h>
#ifdef __linux__
#include <sys/prctl.h>
#include <sched.h>
#endif

extern char **environ;

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

pid_t maldita_child_spawn(char *const argv[], char *const envp[], const char *cwd,
                          const char *log_path)
{
    pid_t pid = fork();
    if (pid < 0) {
        return -1;  /* fork failed */
    }
    if (pid == 0) {
        /* Child process */
        /* Working directory: the engine resolves gmloader.json/game paths
         * relative to CWD, so it must run from the game dir. */
        if (cwd && chdir(cwd) != 0) {
            _exit(126);  /* chdir failed */
        }
        /* Redirect stdin to /dev/null */
        int devnull = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            close(devnull);
        }
        /* Redirect stdout+stderr to the log. Otherwise they stay pointed at the
         * parent's stdio — under MiSTer that is /dev/console, which both loses
         * the engine's output and makes every write a slow console write.
         * O_APPEND so a crash-respawn adds to the log instead of erasing the
         * crash that caused it. Failure here is non-fatal: better to run the
         * engine with inherited stdio than not at all. */
        if (log_path && *log_path) {
            int logfd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (logfd >= 0) {
                dup2(logfd, STDOUT_FILENO);
                dup2(logfd, STDERR_FILENO);
                if (logfd > STDERR_FILENO) close(logfd);
            }
        }
#ifdef __linux__
        prctl(PR_SET_PDEATHSIG, SIGTERM);  /* die if parent dies */
        /* Reset CPU affinity: maldita_main pins the WRAPPER to CPU 1, but the
         * engine must use all cores (inheriting the single-core pin halves its
         * framerate). Mirrors sonic-mania's child fork. */
        {
            cpu_set_t all_cpus;
            CPU_ZERO(&all_cpus);
            CPU_SET(0, &all_cpus);
            CPU_SET(1, &all_cpus);
            sched_setaffinity(0, sizeof(all_cpus), &all_cpus);
        }
#endif
        execve(argv[0], argv, envp ? envp : environ);
        _exit(127);  /* execve failed */
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
    if (exit_code_out) {
        if (WIFEXITED(status)) {
            *exit_code_out = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            *exit_code_out = 128 + WTERMSIG(status);
        } else {
            *exit_code_out = -1;  /* Unexpected status */
        }
    }
    return true;
}

void maldita_child_signal(pid_t pid, int sig)
{
    if (pid > 0) kill(pid, sig);
}
