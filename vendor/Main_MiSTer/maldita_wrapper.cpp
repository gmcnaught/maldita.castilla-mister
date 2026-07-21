#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

#include "maldita_wrapper.h"
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
#include "file_io.h"

extern char **environ;

namespace {
constexpr const char *kEngineBinary = "/media/fat/games/gmloader/gmloader";
constexpr const char *kGameDir      = "/media/fat/games/gmloader";
constexpr const char *kEngineConfig = "gmloader.json";
constexpr const char *kEngineLibPath = "/media/fat/games/gmloader/mesa:/media/fat/games/gmloader";
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
    setenv("LD_LIBRARY_PATH", kEngineLibPath, 1);  // GLES-sw / mesa libs
    // GMLOADER_JOY_SHM is exported by maldita_joy_open() (feat #2) when it succeeds.
}

// Spawn the engine; child runs from the game dir (so gmloader.json + game
// paths resolve), with the config arg and library path the launcher provides.
pid_t spawn_engine(int argc, char *argv[]) {
    (void)argc; (void)argv;
    std::vector<char*> child_argv;
    child_argv.push_back(const_cast<char*>(kEngineBinary));
    child_argv.push_back(const_cast<char*>("-c"));
    child_argv.push_back(const_cast<char*>(kEngineConfig));
    child_argv.push_back(nullptr);
    set_engine_env();
    return maldita_child_spawn(child_argv.data(), environ, kGameDir);
}

void return_to_menu(void) {
    input_switch(0);
    // KNOWN LIMITATION (tracked for device bring-up): stock fpga_load_rbf() at
    // the pinned commit calls app_restart() unconditionally, which re-execs
    // getappname() (== MiSTer_Maldita, not the real MiSTer binary) with argv
    // "menu.rbf". Because maldita_main.cpp ignores argv, that self-exec re-enters
    // maldita_wrapper_run() and respawns the game instead of reaching the system
    // menu. No upstream fpga_load_rbf_no_restart() exists at this commit.
    // Proper fix (deferred): overlay a patched fpga_io.cpp providing
    // fpga_load_rbf_no_restart + exec the real MiSTer menu binary here, per
    // sonic-mania's restart_to_menu(). The core value path (auto-launch,
    // supervise, crash-respawn, Reset) is unaffected by this limitation.
    fpga_load_rbf(kMenuCore);
}
} // namespace

int maldita_wrapper_run(int argc, char *argv[]) {
    signal(SIGINT,  on_signal);
    signal(SIGHUP,  on_signal);
    signal(SIGTERM, on_signal);

    // Initialise the MiSTer framework for the loaded core exactly as stock
    // main() does. user_io_init reads the core config and applies the analog
    // video output settings (vga_sog / vga_mode / composite_sync); without it
    // the analog output never gets sync-on-green, so the CRT can't lock and the
    // green channel (carrying sync) is corrupted (purple-ish image).
    FindStorage();
    user_io_init((argc > 1) ? argv[1] : "", (argc > 2) ? argv[2] : NULL);

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

            // Drive the MiSTer framework main loop (stock main.cpp order) so the
            // video/OSD/input state stays maintained while the engine renders.
            if (!is_fpga_ready(1)) fpga_wait_to_reset();
            user_io_poll();
            frame_timer();
            input_poll(0);
            maldita_joy_publish(user_io_osd_is_visible());  // inert until feat #2

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
