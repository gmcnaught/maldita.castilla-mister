#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include "maldita_child.h"

static int fails = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL: %s (line %d)\n", #cond, __LINE__); fails++; } } while (0)

static void test_decide(void) {
    // Clean exit → return to menu regardless of crash count.
    CHECK(maldita_crash_decide(0, 0, 3) == MALDITA_CHILD_MENU);
    CHECK(maldita_crash_decide(0, 2, 3) == MALDITA_CHILD_MENU);
    // Non-zero exit under budget → respawn.
    CHECK(maldita_crash_decide(139, 0, 3) == MALDITA_CHILD_RESPAWN);
    CHECK(maldita_crash_decide(1,   2, 3) == MALDITA_CHILD_RESPAWN);
    // Non-zero exit at/over budget → halt (preserve fabric for post-mortem).
    CHECK(maldita_crash_decide(139, 3, 3) == MALDITA_CHILD_HALT);
    CHECK(maldita_crash_decide(1,   4, 3) == MALDITA_CHILD_HALT);
}

static void test_backoff(void) {
    CHECK(maldita_crash_backoff_ms(0) == 0);     // no crash yet
    CHECK(maldita_crash_backoff_ms(1) == 250);
    CHECK(maldita_crash_backoff_ms(2) == 500);
    CHECK(maldita_crash_backoff_ms(3) == 1000);
    CHECK(maldita_crash_backoff_ms(9) == 2000);  // capped
}

static void test_count_update(void) {
    // A fresh crash long after the last one resets the window to 1.
    CHECK(maldita_crash_count_update(2, 60000, 10000) == 1);
    // A crash inside the window increments.
    CHECK(maldita_crash_count_update(2, 500, 10000) == 3);
    // First crash ever (prev 0) inside window → 1.
    CHECK(maldita_crash_count_update(0, 0, 10000) == 1);
}

static void test_spawn(void) {
    // Spawn a child that exits cleanly with code 42.
    char *argv[] = { (char *)"/bin/sh", (char *)"-c", (char *)"exit 42", NULL };
    char *envp[] = { NULL };
    pid_t pid = maldita_child_spawn(argv, envp, NULL);
    CHECK(pid > 0);  // Valid PID

    // Poll for reap (up to 1 second, sleeping 10ms between polls).
    bool reaped = false;
    int exit_code = -1;
    for (int i = 0; i < 100; i++) {
        if (maldita_child_reap(pid, &exit_code)) {
            reaped = true;
            break;
        }
        usleep(10000);  // 10 ms
    }
    CHECK(reaped);           // Should have reaped within 1 second
    CHECK(exit_code == 42);  // Correct exit code
}

static void test_spawn_zero_exit(void) {
    // Spawn a child that exits with code 0 (clean exit).
    char *argv[] = { (char *)"/bin/sh", (char *)"-c", (char *)"exit 0", NULL };
    char *envp[] = { NULL };
    pid_t pid = maldita_child_spawn(argv, envp, NULL);
    CHECK(pid > 0);

    // Poll for reap.
    bool reaped = false;
    int exit_code = -1;
    for (int i = 0; i < 100; i++) {
        if (maldita_child_reap(pid, &exit_code)) {
            reaped = true;
            break;
        }
        usleep(10000);
    }
    CHECK(reaped);
    CHECK(exit_code == 0);  // Clean exit
}

static void test_signal(void) {
    // Spawn a child that sleeps for 30 seconds.
    char *argv[] = { (char *)"/bin/sh", (char *)"-c", (char *)"sleep 30", NULL };
    char *envp[] = { NULL };
    pid_t pid = maldita_child_spawn(argv, envp, NULL);
    CHECK(pid > 0);

    // Give the child time to start.
    usleep(100000);  // 100 ms

    // Send SIGTERM.
    maldita_child_signal(pid, SIGTERM);

    // Poll for reap (up to 1 second).
    bool reaped = false;
    int exit_code = -1;
    for (int i = 0; i < 100; i++) {
        if (maldita_child_reap(pid, &exit_code)) {
            reaped = true;
            break;
        }
        usleep(10000);
    }
    CHECK(reaped);
    // Signal termination: 128 + signal_number
    CHECK(exit_code == (128 + SIGTERM));  // 128 + 15 = 143
}

static void test_spawn_cwd(void) {
    // Child runs from cwd="/"; exit 7 iff $PWD is / (symlink-free, unlike /tmp
    // which resolves to /private/tmp on macOS), else 8. The test process runs
    // from the worktree dir, so reaching / proves chdir(cwd) took effect.
    char *argv[] = { (char *)"/bin/sh", (char *)"-c",
                     (char *)"[ \"$(pwd)\" = / ] && exit 7 || exit 8", NULL };
    char *envp[] = { NULL };
    pid_t pid = maldita_child_spawn(argv, envp, "/");
    CHECK(pid > 0);
    int exit_code = -1;
    for (int i = 0; i < 100; i++) {
        if (maldita_child_reap(pid, &exit_code)) break;
        usleep(10000);
    }
    CHECK(exit_code == 7);  // chdir(cwd) took effect before exec
}

int main(void) {
    test_decide();
    test_backoff();
    test_count_update();
    test_spawn();
    test_spawn_zero_exit();
    test_signal();
    test_spawn_cwd();
    if (fails) { printf("%d checks FAILED\n", fails); return 1; }
    printf("maldita_child spawn/reap/signal OK\n");
    return 0;
}
