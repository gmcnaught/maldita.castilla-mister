#include <stdio.h>
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

int main(void) {
    test_decide();
    test_backoff();
    test_count_update();
    if (fails) { printf("%d checks FAILED\n", fails); return 1; }
    printf("maldita_child crash-policy OK\n");
    return 0;
}
