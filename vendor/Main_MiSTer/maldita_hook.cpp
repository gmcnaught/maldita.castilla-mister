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
 * WHAT THIS DOES NOT DO. No crash respawn, no joystick publishing, no
 * supervision of the engine's health. Those existed in the reverted wrapper
 * because it had to coexist with the engine forever. Under the HPS takeover this
 * process is killed a few seconds after the engine proves itself live.
 *
 * The ONE thing it does beyond the initial fork is take the OSD "Reset" trigger
 * and restart the engine (see maldita_reset.h for what that resets and why it is
 * stepped rather than done inline). That is here rather than in the engine or in
 * launch.sh for a simple reason: this process IS MiSTer, so it can read the
 * status pulse directly. Every other consumer would have to receive it over the
 * fabric, and the fabric's only publisher of that bit (blitter_top's
 * S_WR_STATUS -> C_STATUS bit0) stops writing during exactly the wedge a user
 * most wants to Reset out of.
 */

#include "maldita_hook.h"
#include "maldita_child.h"
#include "maldita_reset.h"

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

/* Upstream Main_MiSTer symbols, resolved at the armhf link. user_io.h also
 * declares user_io_status_trigger_take(), which is a Maldita overlay addition to
 * upstream's user_io.cpp — a CONF_STR "T" pulse is set and cleared inside one
 * HandleUI() call and cannot be seen any other way. */
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

/* CONF_STR "TJ,Reset;" -> status bit 19 (fpga/Maldita.sv). The letter and the
 * bit must agree; if the CONF_STR ever gains or loses an option before this one,
 * BOTH move. */
constexpr uint32_t kResetTriggerBit = 19;

/* launch.sh's fabric-recovery attempt counter. A deliberate Reset must not
 * inherit a spent recovery budget from an earlier bad start, or the fresh
 * engine's gate gives up without ever trying. launch.sh removes it itself on a
 * healthy verdict; this clears it on the way in. Keep in sync with
 * MALDITA_RETRY_MARK's default in games/Maldita Castilla/launch.sh. */
constexpr const char *kRetryMark = "/tmp/maldita_fabric_retry";

/* launch.sh's atomic launch mutex (MALDITA_LOCKDIR's default) — keep in sync.
 *
 * Dropped before a Reset respawn. The fresh handler would USUALLY take the lock
 * over on its own, because its owner check is liveness-then-freshness and by
 * then the owner pid is dead. The exception is the one case that matters: a
 * child that survived even SIGKILL (stuck in uninterruptible DDR I/O) is still
 * "alive", and if the lock is also younger than MALDITA_LOCK_FRESH_S the fresh
 * handler stands down and the user's Reset produces NO engine at all. Clearing
 * it here is safe precisely because we just killed the only launcher this core
 * load has: there is no concurrent racer for the mutex to protect against, which
 * is the only thing it exists for. */
constexpr const char *kLockOwner = "/tmp/maldita-launch.lock/owner";
constexpr const char *kLockDir   = "/tmp/maldita-launch.lock";

/* SIGTERM budget before SIGKILL, and SIGKILL budget before spawning anyway.
 * 3000 ms mirrors launch.sh's own reap budget for the same child; the engine's
 * teardown budget is 250 ms, so a healthy engine is gone long before either. */
constexpr int64_t kTermBudgetMs = 3000;
constexpr int64_t kKillBudgetMs = 2000;

/* Deliberately write(2) rather than printf: the framework reconfigures stdio
 * during user_io_init(), which silently swallowed every printf the reverted
 * wrapper made after that point and cost real debugging time chasing a "hang"
 * that was only a buffering artifact.
 *
 * AND to a file, not only to stderr. MiSTer execs this binary with fd 1 and 2 on
 * /dev/console (verified on .62 2026-08-09: /proc/<pid>/fd/2 -> /dev/console),
 * so every line here has historically gone somewhere no `ssh` and no bug report
 * can read — which was survivable while the hook only ever logged one spawn at
 * startup, and is not now that it also logs OSD Resets. "I pressed Reset and
 * nothing happened" needs a trace.
 *
 * kLogPath is the handler's own log and the interleaving is deliberate: the
 * child holds it O_APPEND too, so one file carries the whole launch path in
 * order — the hook's decision, then the handler's, then the engine's. Best
 * effort throughout; a wrapper that cannot open its log still has a game to
 * start. */
void hlog(const char *msg)
{
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "maldita_hook: %s\n", msg);
    if (n <= 0) return;
    size_t len = (size_t)(n > (int)sizeof(buf) ? (int)sizeof(buf) : n);

    (void)!write(STDERR_FILENO, buf, len);

    int fd = open(kLogPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)!write(fd, buf, len);
    close(fd);
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

/* True only when WE started the engine. Everything Reset does is predicated on
 * it: if the initial decision refused (not our core, NOENGINE, a takeover
 * restore in progress) there is no engine of ours to restart, and honouring the
 * OSD trigger would spawn one behind the back of whatever made us refuse. */
bool g_owns_engine = false;

maldita_reset_t g_reset;

int64_t now_ms()
{
    struct timespec ts;
    /* CLOCK_MONOTONIC, not time(): the restart deadlines must survive an NTP
     * step, and MiSTer sets its clock from the network shortly after boot —
     * which is exactly when a first Reset is plausible. */
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Fork the launch handler. Sets g_child; returns false and logs on failure. */
bool spawn_handler()
{
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
        hlog("FAILED to spawn the handler");
        return false;
    }

    char buf[96];
    snprintf(buf, sizeof(buf), "handler spawned pid=%d", (int)g_child);
    hlog(buf);
    return true;
}

/* The one-shot startup decision. True when the handler was spawned. */
bool decide_and_spawn()
{
    /* `main=` is a per-core ini setting, so in the intended configuration this
     * binary only ever runs for our core. The check is for the footgun: a
     * `main=` line left in a global section would otherwise spawn the engine
     * under every core on the device. */
    const char *core = user_io_get_core_name();
    if (!core || strcmp(core, kCoreName) != 0)
    {
        hlog("not the Maldita core — running as stock MiSTer");
        return false;
    }

    if (file_exists(kNoEngineFlag))
    {
        hlog("NOENGINE flag present — not spawning the handler");
        return false;
    }

    if (restore_in_progress())
    {
        hlog("takeover restore in progress — not spawning, leaving the way out clear");
        return false;
    }

    if (!spawn_handler())
    {
        hlog("running as stock MiSTer");
        return false;
    }
    return true;
}

} // namespace

void maldita_hook_poll(void)
{
    if (!g_decided)
    {
        /* One decision, whatever it is. This flag is set before the decision so
         * a refusal cannot be retried on the next iteration — a hook that keeps
         * re-deciding is a hook that eventually spawns two engines onto one
         * fabric control block, which is the documented dual-engine corruption.
         * Reset does not weaken that: it is a serialised kill-then-spawn gated
         * on the child actually being gone, never a second concurrent spawn. */
        g_decided = true;
        g_owns_engine = decide_and_spawn();
        if (g_owns_engine) maldita_reset_init(&g_reset, kTermBudgetMs, kKillBudgetMs);
        return;
    }

    /* Keep the process table tidy in the no-takeover case, where this process
     * outlives the handler. Free: WNOHANG on a known pid. Under takeover we are
     * killed long before this matters. Also the liveness input to the restart
     * step below, which is why it runs before it. */
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

    if (!g_owns_engine) return;

    /* Drain the trigger latch on EVERY iteration, including mid-restart. The
     * step function ignores a request while a restart is in flight, so this
     * discards a mashed second press instead of queueing it. Leaving the latch
     * set would instead fire a second restart the moment the first completed. */
    const bool requested =
        (user_io_status_trigger_take() & (1u << kResetTriggerBit)) != 0;

    switch (maldita_reset_step(&g_reset, requested, g_child > 0, now_ms()))
    {
    case MALDITA_RESET_ACT_TERM:
    {
        /* Clear the recovery budget BEFORE the kill, so the fresh launch.sh
         * cannot read a stale count no matter how fast it starts. */
        unlink(kRetryMark);
        char buf[128];
        snprintf(buf, sizeof(buf), "OSD Reset — restarting the engine (SIGTERM pid=%d)",
                 (int)g_child);
        hlog(buf);
        maldita_child_signal_group(g_child, SIGTERM);
        break;
    }
    case MALDITA_RESET_ACT_KILL:
        hlog("OSD Reset — handler ignored SIGTERM, SIGKILL");
        maldita_child_signal_group(g_child, SIGKILL);
        break;

    case MALDITA_RESET_ACT_SPAWN:
    {
        char buf[128];
        snprintf(buf, sizeof(buf), "OSD Reset — respawning the handler (restart #%u)",
                 g_reset.restarts);
        hlog(buf);
        /* See kLockDir. Order matters: the directory only goes away once the
         * owner file inside it does. */
        unlink(kLockOwner);
        rmdir(kLockDir);
        /* A failed respawn leaves g_child at -1 and g_owns_engine true, so the
         * next Reset press tries again rather than wedging the feature off. */
        spawn_handler();
        break;
    }
    case MALDITA_RESET_ACT_NONE:
        break;
    }
}
