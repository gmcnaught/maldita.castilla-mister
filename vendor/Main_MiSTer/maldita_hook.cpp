/* Maldita Castilla `main=` hook.
 *
 * This file plus a one-line call in scheduler.cpp is the ENTIRE local change to
 * Main_MiSTer. That is deliberate and it is the design (see
 * docs/superpowers/specs/2026-08-04-hps-takeover-launcher-design.md §2b.1).
 *
 * WHY `main=` AT ALL. MiSTer's Cores browser lists only .rbf/.mra/.mgl
 * (menu.cpp:438) and skips anything that is not DT_DIR or DT_REG, so a script
 * cannot appear there. Exactly two ini options can execute anything, MAIN and
 * WAITMOUNT, and WAITMOUNT is a system() string interpolation rather than an
 * interface. So `main=` is the only way to get a Cores-browser entry that also
 * starts the engine without a resident watcher.
 *
 * WHY THIS IS NOT THE WRAPPER THAT WAS REVERTED. That one replaced upstream
 * main() with a hand-rolled loop (maldita_main.cpp -> maldita_wrapper_run),
 * which was the dead `#else` branch of main() — USE_SCHEDULER is unconditional
 * (scheduler.h:4) — so the scheduler's per-iteration
 * `while (!is_fpga_ready(1)) fpga_wait_to_reset();` guard never ran, and the
 * engine was spawned before the first readiness check. Device-measured: 3/5
 * frame-1 wedges vs stock main 0/5.
 *
 * Here upstream's main() and scheduler run verbatim and we hook AFTER
 * scheduler_wait_fpga_ready(). The contract is honoured by the code that owns
 * it, and we cannot get it wrong because we never took it over.
 *
 * WHAT THIS DOES NOT DO. No supervision, no respawn, no joystick publishing, no
 * OSD polling. Those existed in the reverted wrapper because it had to coexist
 * with the engine forever. Under the HPS takeover this process is killed a few
 * seconds after the engine proves itself live, so its whole job is one fork at
 * one correct moment.
 */

#include "maldita_hook.h"
#include "maldita_child.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

/* Upstream Main_MiSTer symbols, resolved at the armhf link. */
#include "user_io.h"

namespace {

/* Must equal the RBF's CONF_STR setname (fpga/Maldita.sv) — the same string
 * MiSTer writes to /tmp/CORENAME (user_io.cpp:1171) and the same directory name
 * the handler lives under. */
constexpr const char *kCoreName = "Maldita Castilla";

/* NOT _handler.sh: that name is Master_Daemon's discovery predicate, and a
 * daemon that also spawns it races this fork onto one fabric control block.
 * See games/Maldita Castilla/launch.sh's header. */
constexpr const char *kHandler = "/media/fat/games/Maldita Castilla/launch.sh";
constexpr const char *kLogDir  = "/media/fat/logs/MalditaCastilla";
constexpr const char *kLogPath = "/media/fat/logs/MalditaCastilla/wrapper.log";

/* Bisect affordance carried over from the reverted wrapper, where it earned its
 * keep: touch this on the device to get the stock framework with no engine, no
 * rebuild required. */
constexpr const char *kNoEngineFlag = "/media/fat/games/gmloader/NOENGINE";

/* CONTRACT WITH games/Maldita Castilla/mister_takeover.sh — keep in sync.
 *
 * tk_restore() stamps this file with the epoch seconds at which it restarted
 * MiSTer. Restarting MiSTer means MiSTer loads a core, and if it loads OURS it
 * execs this binary again — at which point spawning the engine would put the
 * user straight back in the game they were trying to leave, and the follow-up
 * `load_core menu.rbf` would never get them to the menu.
 *
 * The handler has its own guard on the same stamp, but that one only suppresses
 * the *takeover*; this one suppresses the *spawn*, which is what a restore
 * actually needs. The window matches MALDITA_TAKEOVER_REENTRY_S's default. */
constexpr const char *kRestoreStamp = "/tmp/maldita_takeover_restore.stamp";
constexpr long kRestoreWindowS = 60;

/* Deliberately write(2) rather than printf: the framework reconfigures stdio
 * during user_io_init(), which silently swallowed every printf the reverted
 * wrapper made after that point and cost real debugging time chasing a "hang"
 * that was only a buffering artifact. */
void hlog(const char *msg)
{
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "maldita_hook: %s\n", msg);
    if (n > 0) (void)!write(STDERR_FILENO, buf, (size_t)(n > (int)sizeof(buf) ? (int)sizeof(buf) : n));
}

bool file_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0;
}

/* True when a takeover restore stamped the file within the window. Unreadable
 * or unparseable stamps read as "not fresh": the failure mode of spawning when
 * we should not is a user who has to leave the core again, while refusing to
 * spawn when we should have is a core that never starts at all. */
bool restore_in_progress()
{
    FILE *f = fopen(kRestoreStamp, "r");
    if (!f) return false;

    long stamped = 0;
    int got = fscanf(f, "%ld", &stamped);
    fclose(f);
    if (got != 1 || stamped <= 0) return false;

    long now = (long)time(NULL);
    return (now >= stamped) && ((now - stamped) < kRestoreWindowS);
}

pid_t g_child = -1;
bool  g_decided = false;

} // namespace

void maldita_hook_poll(void)
{
    if (g_decided)
    {
        /* Keep the process table tidy in the no-takeover case, where this
         * process outlives the handler. Free: WNOHANG on a known pid. Under
         * takeover we are killed long before this matters. */
        if (g_child > 0)
        {
            int code = 0;
            if (maldita_child_reap(g_child, &code))
            {
                char buf[96];
                snprintf(buf, sizeof(buf), "handler exited rc=%d", code);
                hlog(buf);
                g_child = -1;
            }
        }
        return;
    }

    /* One decision, whatever it is. Everything below sets g_decided so a
     * refusal cannot be retried on the next iteration — a hook that keeps
     * re-deciding is a hook that eventually spawns two engines onto one fabric
     * control block, which is the documented dual-engine corruption. */
    g_decided = true;

    /* `main=` is a per-core ini setting, so in the intended configuration this
     * binary only ever runs for our core. The check is for the footgun: a
     * `main=` line left in a global section would otherwise spawn the engine
     * under every core on the device. */
    const char *core = user_io_get_core_name();
    if (!core || strcmp(core, kCoreName) != 0)
    {
        hlog("not the Maldita core — running as stock MiSTer");
        return;
    }

    if (file_exists(kNoEngineFlag))
    {
        hlog("NOENGINE flag present — not spawning the handler");
        return;
    }

    if (restore_in_progress())
    {
        hlog("takeover restore in progress — not spawning, leaving the way out clear");
        return;
    }

    /* The handler mkdir -p's this itself, but not before its own first write,
     * and maldita_child_spawn()'s log redirect happens earlier than that. */
    mkdir("/media/fat/logs", 0755);
    mkdir(kLogDir, 0755);

    /* argv[0] must be the ABSOLUTE handler path: the handler derives its own
     * directory from $0 to find mister_takeover.sh and takeover.env beside it. */
    char *const argv[] = { (char *)kHandler, NULL };

    g_child = maldita_child_spawn(argv, NULL, NULL, kLogPath);
    if (g_child < 0)
    {
        hlog("FAILED to spawn the handler — running as stock MiSTer");
        return;
    }

    char buf[96];
    snprintf(buf, sizeof(buf), "handler spawned pid=%d", (int)g_child);
    hlog(buf);
}
