#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
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
constexpr const char *kLogDir       = "/media/fat/games/gmloader/logs";
constexpr const char *kLogPath      = "/media/fat/games/gmloader/logs/osd-wrapper.log";
constexpr const char *kEngineLog    = "/media/fat/games/gmloader/logs/engine.log";
// The wrapper's OWN stdout/stderr are MiSTer's, i.e. /dev/console — so every
// framework message (cfg_print, video mode, core name) was unrecoverable. Same
// blindness the engine log fixed, one level up.
constexpr const char *kWrapperLog   = "/media/fat/games/gmloader/logs/wrapper.log";
// Independent bisect flags (touch/rm on the device, no rebuild needed):
//   NOENGINE   — do not spawn gmloader; run the stock framework loop only.
//   NORECOVER  — do not zero the fabric control block at boot.
// Kept orthogonal so each suspect can be tested alone. These are what isolated
// the core-reset-kills-video result; retained because the fabric wedge is still
// unsolved and the next bisect will need them.
constexpr const char *kNoEngineFlag  = "/media/fat/games/gmloader/NOENGINE";
constexpr const char *kNoRecoverFlag = "/media/fat/games/gmloader/NORECOVER";
constexpr int  kMaxCrashes = 3;
constexpr long kCrashWindowMs = 10000;

volatile sig_atomic_t g_signal = 0;
pid_t g_child_pid = -1;

void on_signal(int s) { g_signal = s; if (g_child_pid > 0) kill(g_child_pid, s); }

// Wrapper progress log. Deliberately write(2) and not printf: the framework
// reconfigures stdio during user_io_init(), which silently swallowed every
// printf the wrapper made after that point — and cost real debugging time
// chasing a "hang" that was only a buffering artifact.
__attribute__((format(printf, 1, 2)))
void wlog(const char *fmt, ...) {
    char buf[512];
    int n = snprintf(buf, sizeof(buf), "maldita: ");
    va_list ap;
    va_start(ap, fmt);
    n += vsnprintf(buf + n, sizeof(buf) - n - 2, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n > sizeof(buf) - 2) n = sizeof(buf) - 2;
    buf[n++] = '\n';
    (void)!write(STDERR_FILENO, buf, (size_t)n);
}

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
// stdout+stderr go to kEngineLog: the wrapper inherits MiSTer's stdio, which is
// /dev/console, so without this the engine's output is unrecoverable (and every
// write is a slow console write on the render thread).
pid_t spawn_engine(int argc, char *argv[]) {
    (void)argc; (void)argv;
    std::vector<char*> child_argv;
    child_argv.push_back(const_cast<char*>(kEngineBinary));
    child_argv.push_back(const_cast<char*>("-c"));
    child_argv.push_back(const_cast<char*>(kEngineConfig));
    child_argv.push_back(nullptr);
    set_engine_env();
    return maldita_child_spawn(child_argv.data(), environ, kGameDir, kEngineLog);
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

// Zero the fabric control block (+ first ring qwords) at 0x3B000000 so no stale
// doorbell/command survives a reload. gmloader also zeros it, but only on its
// first frame (~10s in) — long after the fabric polled the DDR at core load.
void zero_fabric_ctrl(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) return;
    // Blitter DDR region base 0x3B000000: 8-qword control block @ +0, ring @ +0x40.
    void *m = mmap(nullptr, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x3B000000);
    close(fd);
    if (m == MAP_FAILED) return;
    volatile uint32_t *p = (volatile uint32_t *)m;
    for (int i = 0; i < 0x80 / 4; i++) p[i] = 0;   // control block 0x00..0x3F + ring 0x40..0x7F
    munmap(m, 0x1000);
}

// REMOVED: the fpga_core_reset() pulse that used to follow zero_fabric_ctrl().
//
// It was a fabric-wedge mitigation: the blitter's reset is the framework RESET
// (blitter_top.rst = emu RESET = gp_out[31:30]), so pulsing it restarted the
// hung FSM against a freshly-zeroed control block. But fpga_core_reset() resets
// the WHOLE core, including its video timing generator and the DDR-scanout
// double-buffer handshake — and that leaves the display with no signal at all.
//
// Isolated on hardware with the NOENGINE flag (framework loop only, no engine,
// no child process), so nothing else was in play:
//   recover_fabric skipped -> video + OSD work
//   recover_fabric run     -> no display, while the wrapper itself stays
//                             healthy (gdb backtrace: user_io_poll, normal loop)
//
// Losing the picture is strictly worse than the wedge it was papering over, so
// the reset is gone. zero_fabric_ctrl() is kept — it only writes DDR, cannot
// touch video, and still stops a stale doorbell surviving a core reload. The
// fabric wedge is a real and separate bug; the durable fix belongs in RTL (the
// B_WAIT/fill_busy watchdog), not in a host-side core reset.
} // namespace

int maldita_wrapper_run(int argc, char *argv[]) {
    signal(SIGINT,  on_signal);
    signal(SIGHUP,  on_signal);
    signal(SIGTERM, on_signal);

    // Log dir for the engine's redirected stdout/stderr (spawn_engine). Ignore
    // EEXIST; if it can't be created the spawn just falls back to inherited stdio.
    mkdir(kLogDir, 0755);

    // Capture the wrapper's OWN stdout/stderr before any framework call, so the
    // framework's startup output (core name, cfg_print, video mode) is readable
    // instead of vanishing into /dev/console. Non-fatal on failure.
    {
        int logfd = open(kWrapperLog, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (logfd >= 0) {
            dup2(logfd, STDOUT_FILENO);
            dup2(logfd, STDERR_FILENO);
            if (logfd > STDERR_FILENO) close(logfd);
            setvbuf(stdout, NULL, _IOLBF, 0);   // line-buffered: survive a hang
            setvbuf(stderr, NULL, _IONBF, 0);
        }
    }
    const bool no_engine  = (access(kNoEngineFlag,  F_OK) == 0);
    const bool no_recover = (access(kNoRecoverFlag, F_OK) == 0);
    wlog("==== start (pid=%d argc=%d argv1=%s) engine=%s ctrl_zero=%s ====",
         getpid(), argc, (argc > 1 && argv[1]) ? argv[1] : "(none)",
         no_engine  ? "OFF (NOENGINE)"  : "on",
         no_recover ? "OFF (NORECOVER)" : "on");

    // Initialise the MiSTer framework for the loaded core exactly as stock
    // main() does. user_io_init reads the core config and applies the analog
    // video output settings (vga_sog / vga_mode / composite_sync); without it
    // the analog output never gets sync-on-green, so the CRT can't lock and the
    // green channel (carrying sync) is corrupted (purple-ish image).
    FindStorage();
    user_io_init((argc > 1) ? argv[1] : "", (argc > 2) ? argv[2] : NULL);

    wlog("user_io_init done, core_name=\"%s\"", user_io_get_core_name());

    // Zero the fabric control block so no stale doorbell survives a core reload.
    // DDR writes only — no core reset (see the note above zero_fabric_ctrl).
    if (!no_recover) {
        wlog("zeroing fabric control block (no core reset)");
        zero_fabric_ctrl();
    } else {
        wlog("NORECOVER — skipping fabric control-block zeroing");
    }

    // Framework-only loop: no child process, so the display depends on nothing
    // but the wrapper.
    if (no_engine) {
        wlog("NOENGINE — framework-only loop, no child");
        for (;;) {
            if (!is_fpga_ready(1)) fpga_wait_to_reset();
            user_io_poll();
            frame_timer();
            input_poll(0);
            HandleUI();
            OsdUpdate();
        }
    }

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
        // OSD Reset: recover the fabric (zero control block + pulse core reset —
        // also un-wedges a hung blitter) and respawn the engine in place. Do NOT
        // count it as a crash (otherwise pressing Reset 3x would trip halt).
        // OSD Reset: zero the control block and respawn. It no longer pulses the
        // core reset — that killed the display (see the note by zero_fabric_ctrl),
        // so Reset can no longer un-stick a genuinely wedged blitter. That needs
        // the RTL watchdog instead.
        if (deliberate_restart) { consecutive_crashes = 0; zero_fabric_ctrl(); continue; }

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
