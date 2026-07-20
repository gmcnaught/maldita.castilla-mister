#include "maldita_child.h"

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
