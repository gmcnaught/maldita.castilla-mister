#include "maldita_child.h"
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <signal.h>
#ifdef __linux__
#include <sched.h>
#endif

extern char **environ;

pid_t maldita_child_spawn(char *const argv[], char *const envp[], const char *cwd,
                          const char *log_path)
{
    pid_t pid = fork();
    if (pid < 0) {
        return -1;  /* fork failed */
    }
    if (pid == 0) {
        /* Child process */

        /* Own session. Keeps the handler off this process's controlling
         * terminal and out of its process group, so a group-wide signal aimed
         * at MiSTer cannot reach the engine. */
        setsid();

        if (cwd && chdir(cwd) != 0) {
            _exit(126);  /* chdir failed */
        }

        int devnull = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            close(devnull);
        }

        /* Redirect stdout+stderr to the log. Otherwise they stay pointed at the
         * parent's stdio — under MiSTer that is /dev/console, which both loses
         * the output and makes every write a slow console write. O_APPEND so a
         * relaunch adds to the log instead of erasing what came before.
         * Failure here is non-fatal: better to run with inherited stdio than
         * not at all. */
        if (log_path && *log_path) {
            int logfd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (logfd >= 0) {
                dup2(logfd, STDOUT_FILENO);
                dup2(logfd, STDERR_FILENO);
                if (logfd > STDERR_FILENO) close(logfd);
            }
        }

        /* NO PR_SET_PDEATHSIG — see the header. The takeover kills our parent
         * on purpose, and this child must outlive it. */

#ifdef __linux__
        /* Reset CPU affinity. Upstream main() pins MiSTer's main worker to core
         * 1 (main.cpp:44-48, "core #0 is the hardware interrupt handler"), and
         * a fork inherits that mask — so without this the engine would run on
         * one core, sharing it with the very process it is about to displace. */
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

    if (result <= 0) {
        /* <0: no such child (or error). 0: still running. */
        return false;
    }
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

void maldita_child_signal_group(pid_t pid, int sig)
{
    if (pid <= 0) return;

    /* The child called setsid(), so it leads its own process group with
     * pgid == pid, and the engine it starts is in that group. Signalling the
     * GROUP is what makes an OSD Reset reach gmloader itself rather than only
     * the launcher shell: in the normal path launch.sh keeps the engine as a
     * background job and waits on it, so a signal to the shell alone leaves the
     * engine orphaned and alive — its SIGTERM teardown (ack the in-flight batch,
     * zero the command ring, park the control block) would never run, and the
     * ring would only be cleaned up later by the next launcher's stray reap.
     *
     * If setsid() failed the child is still in OUR group, whose pgid is not
     * pid — so the negative-pid send finds no such group and fails with ESRCH
     * rather than signalling MiSTer's own group. Fall back to the single pid. */
    if (kill(-pid, sig) != 0) kill(pid, sig);
}
