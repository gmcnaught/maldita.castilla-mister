#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <vector>

#include "maldita_child.h"
#include "maldita_joy_shm.h"
#include "maldita_osd.h"

// Upstream Main_MiSTer symbols (resolved at armhf link):
#include "fpga_io.h"
#include "input.h"
#include "user_io.h"
#include "menu.h"
#include "osd.h"
#include "frame_timer.h"

extern char **environ;

namespace {
constexpr const char *kEngineBinary = "/media/fat/games/gmloader/gmloader";
constexpr const char *kMenuCore     = "menu.rbf";
constexpr const char *kLogPath      = "/media/fat/games/gmloader/logs/osd-wrapper.log";
constexpr int  kMaxCrashes = 3;
constexpr long kCrashWindowMs = 10000;

volatile sig_atomic_t g_signal = 0;
pid_t g_child_pid = -1;

void on_signal(int s) { g_signal = s; if (g_child_pid > 0) kill(g_child_pid, s); }

long now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

void set_engine_env(void) {
    setenv("SDL_VIDEODRIVER", "dummy", 1);
    setenv("GMLOADER_BLITTER", "2", 1);   // fabric path (CLAUDE.md device section)
    setenv("GMLOADER_RASTER", "mfgpu", 1);
    // GMLOADER_JOY_SHM is exported by maldita_joy_open() (feat #2) when it succeeds.
}

// Spawn the engine; child sets affinity/env, execs. Returns pid or -1.
pid_t spawn_engine(int argc, char *argv[]) {
    (void)argc; (void)argv;
    std::vector<char*> child_argv;
    child_argv.push_back(const_cast<char*>(kEngineBinary));
    child_argv.push_back(nullptr);
    set_engine_env();
    return maldita_child_spawn(child_argv.data(), environ);
}

void return_to_menu(void) {
    input_switch(0);
    fpga_load_rbf_no_restart((char*)kMenuCore);
    // Falls through to MiSTer's normal menu exec path via the outer program exit.
}
} // namespace

int maldita_wrapper_run(int argc, char *argv[]) {
    signal(SIGINT,  on_signal);
    signal(SIGHUP,  on_signal);
    signal(SIGTERM, on_signal);

    (void)maldita_joy_open();   // inert until feat #2; success exports GMLOADER_JOY_SHM

    int consecutive_crashes = 0;
    long last_crash_ms = 0;

    for (;;) {
        pid_t child = spawn_engine(argc, argv);
        if (child < 0) { return_to_menu(); return 1; }
        g_child_pid = child;
        maldita_joy_bump_generation();

        // ---- supervise: waitpid(WNOHANG) while servicing the MiSTer UI ----
        int exit_code = -1;
        bool deliberate_restart = false;   // OSD Reset (feat #4) — NOT a crash
        for (;;) {
            if (maldita_child_reap(child, &exit_code)) break;
            if (g_signal) { /* forwarded to child in handler; keep reaping */ }

            if (is_fpga_ready(1)) {
                frame_timer();
                input_poll(0);
                maldita_joy_publish(user_io_osd_is_visible());  // inert until feat #2
            }

            int restart = 0;
            maldita_osd_poll(child, &restart);                   // inert until feat #4
            if (restart) { deliberate_restart = true; maldita_child_signal(child, SIGTERM); }

            HandleUI();
            OsdUpdate();
            usleep(1000);
        }
        g_child_pid = -1;

        // ---- decide what to do with the exit ----
        // OSD Reset: respawn in place immediately. Do NOT count it as a crash
        // (otherwise pressing Reset 3x would trip the halt threshold).
        if (deliberate_restart) { consecutive_crashes = 0; continue; }

        if (g_signal) { return_to_menu(); return 0; }  // core unload / kill → menu

        long t = now_ms();
        if (exit_code != 0) {
            consecutive_crashes = maldita_crash_count_update(
                consecutive_crashes,
                last_crash_ms ? (t - last_crash_ms) : (kCrashWindowMs + 1),
                kCrashWindowMs);
            last_crash_ms = t;
        }

        MalditaChildAction act = maldita_crash_decide(exit_code, consecutive_crashes, kMaxCrashes);
        if (act == MALDITA_CHILD_MENU) { return_to_menu(); return exit_code; }
        if (act == MALDITA_CHILD_HALT) {
            // Halt: leave the RBF loaded so 0x3B000000 is devmem-peekable for post-mortem.
            fprintf(stderr, "maldita: crash budget exhausted (%d), halting; fabric preserved\n",
                    consecutive_crashes);
            for (;;) { HandleUI(); OsdUpdate(); usleep(10000); }
        }
        // RESPAWN: back off, then loop.
        int backoff = maldita_crash_backoff_ms(consecutive_crashes);
        fprintf(stderr, "maldita: engine exit=%d crash=%d respawn in %dms\n",
                exit_code, consecutive_crashes, backoff);
        usleep(backoff * 1000);
    }
}
