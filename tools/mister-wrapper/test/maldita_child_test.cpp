/* Host-native tests for vendor/Main_MiSTer/maldita_child.cpp.
 *
 * Build+run: make -C tools/mister-wrapper/test
 *
 * These run natively rather than armhf because maldita_child.cpp is plain POSIX
 * with no Main_MiSTer dependencies — which is why it is a separate file from
 * the hook in the first place.
 *
 * The property that matters most is the NEGATIVE one:
 * test_survives_parent_death(). maldita_child.cpp deliberately does NOT set
 * PR_SET_PDEATHSIG, because the HPS takeover kills the wrapper on purpose a few
 * seconds after the engine comes up. Restore that flag and this test fails —
 * which is the point of writing it, since on the device the symptom would look
 * like an engine crash rather than a wrapper bug.
 *
 * The crash-decide/backoff/count-update tests that used to live here went with
 * maldita_wrapper.cpp: respawn policy is the takeover's restore-on-exit now,
 * and the launch policy that remains is in the handler shell script.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include "maldita_child.h"

static int fails = 0;
#define CHECK(cond) do { if (!(cond)) { printf("  FAIL — %s (line %d)\n", #cond, __LINE__); fails++; } \
                         else { printf("  ok   — %s\n", #cond); } } while (0)

static char tmpdir[256];

static void mktmp(void)
{
    snprintf(tmpdir, sizeof(tmpdir), "/tmp/maldita_child_test.%d", (int)getpid());
    mkdir(tmpdir, 0755);
}

static void rmtmp(void)
{
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "rm -rf '%s'", tmpdir);
    if (system(cmd)) { /* best effort */ }
}

static void path_in_tmp(char *out, size_t n, const char *name)
{
    snprintf(out, n, "%s/%s", tmpdir, name);
}

static bool file_has(const char *path, const char *needle)
{
    FILE *f = fopen(path, "r");
    if (!f) return false;
    char buf[4096];
    size_t got = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[got] = 0;
    return strstr(buf, needle) != NULL;
}

/* Poll-reap with a 2 s ceiling; returns the exit code or -999 on timeout. */
static int reap_within(pid_t pid)
{
    int code = -999;
    for (int i = 0; i < 200; i++) {
        if (maldita_child_reap(pid, &code)) return code;
        usleep(10000);
    }
    return -999;
}

static pid_t spawn_sh(const char *script, const char *cwd, const char *log)
{
    char *const argv[] = { (char *)"/bin/sh", (char *)"-c", (char *)script, NULL };
    return maldita_child_spawn(argv, NULL, cwd, log);
}

static void test_spawn_and_reap(void)
{
    printf("== spawn / reap ==\n");
    pid_t pid = spawn_sh("exit 7", NULL, NULL);
    CHECK(pid > 0);
    CHECK(reap_within(pid) == 7);

    pid = spawn_sh("exit 0", NULL, NULL);
    CHECK(reap_within(pid) == 0);

    /* Reaping an already-reaped pid reports no change rather than blocking. */
    int again = -1;
    CHECK(maldita_child_reap(pid, &again) == false);
}

static void test_signal_exit_code(void)
{
    printf("== a signalled child reports 128+signal ==\n");
    pid_t pid = spawn_sh("sleep 30", NULL, NULL);
    CHECK(pid > 0);
    usleep(100000);
    maldita_child_signal(pid, SIGTERM);
    CHECK(reap_within(pid) == 128 + SIGTERM);
}

static void test_log_redirect(void)
{
    printf("== stdout and stderr both reach log_path, appending ==\n");
    char log[512];
    path_in_tmp(log, sizeof(log), "child.log");

    pid_t pid = spawn_sh("echo to-stdout; echo to-stderr 1>&2", NULL, log);
    CHECK(pid > 0);
    CHECK(reap_within(pid) == 0);
    CHECK(file_has(log, "to-stdout"));
    CHECK(file_has(log, "to-stderr"));

    /* O_APPEND, not O_TRUNC: a relaunch must not erase what came before it. */
    pid = spawn_sh("echo second-run", NULL, log);
    CHECK(reap_within(pid) == 0);
    CHECK(file_has(log, "to-stdout"));
    CHECK(file_has(log, "second-run"));
}

static void test_cwd(void)
{
    printf("== cwd is honoured ==\n");
    /* "/" rather than tmpdir: symlink-free on every platform, where /tmp
     * resolves to /private/tmp on macOS and would fail a string compare. */
    pid_t pid = spawn_sh("[ \"$(pwd)\" = / ] && exit 7 || exit 8", "/", NULL);
    CHECK(pid > 0);
    CHECK(reap_within(pid) == 7);
}

static void test_bad_exec(void)
{
    printf("== an unexecutable target exits 127 rather than hanging ==\n");
    char *const argv[] = { (char *)"/nonexistent/maldita/handler.sh", NULL };
    pid_t pid = maldita_child_spawn(argv, NULL, NULL, NULL);
    CHECK(pid > 0);            /* fork succeeded; exec failure is the child's rc */
    CHECK(reap_within(pid) == 127);
}

/* THE load-bearing test — see the file header. */
static void test_survives_parent_death(void)
{
    printf("== the child outlives its parent (no PDEATHSIG) ==\n");
    char marker[512], script[1024];
    path_in_tmp(marker, sizeof(marker), "alive");
    /* Sleep PAST the parent's death, then touch. A marker written before the
     * kill would prove nothing. */
    snprintf(script, sizeof(script), "sleep 2; touch '%s'", marker);

    pid_t middle = fork();
    CHECK(middle >= 0);
    if (middle == 0) {
        spawn_sh(script, NULL, NULL);
        /* Stay alive so the kill lands on a live parent — that is what makes
         * PDEATHSIG fire, if it were set. */
        for (;;) pause();
    }

    usleep(300000);            /* let the grandchild get going */
    kill(middle, SIGKILL);     /* what the takeover does to MiSTer */
    int st = 0;
    waitpid(middle, &st, 0);

    sleep(3);                  /* past the grandchild's own sleep */
    struct stat sb;
    CHECK(stat(marker, &sb) == 0);
}

int main(void)
{
    mktmp();

    test_spawn_and_reap();
    test_signal_exit_code();
    test_log_redirect();
    test_cwd();
    test_bad_exec();
    test_survives_parent_death();

    rmtmp();

    printf("\n%s\n", fails ? "FAILED" : "all maldita_child tests passed");
    return fails ? 1 : 0;
}
