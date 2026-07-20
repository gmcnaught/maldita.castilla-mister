# Feature 1 — `MiSTer_Maldita` Wrapper / Engine Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A patched Main_MiSTer fork, `MiSTer_Maldita`, that MiSTer selects via `MiSTer.ini` `main=`, which forks/execs `gmloadernext.armhf`, supervises it (respawn-on-crash with bounded retry then halt-and-preserve), and tears it down on core unload.

**Architecture:** Four focused C++ units instead of one 3000-line file (spec § "Module boundaries"). `maldita_child` owns process lifecycle + the pure crash-policy logic (host-testable, no MiSTer deps). `maldita_joy_shm` and `maldita_osd` land here as **inert stubs** so the supervisor loop compiles and links; feat #2 fills the joy publisher, feat #4 fills the OSD poll. `maldita_wrapper` is the supervisor loop wiring them together; `maldita_main.cpp` replaces upstream `main.cpp`. The armhf binary is built by vendoring pinned upstream on demand and layering our overlay files, reusing the Docker cross-build pattern (like sonic-mania-mister's `build-hps.sh`).

**Tech Stack:** C++14 (Main_MiSTer convention), POSIX (`fork`/`execve`/`waitpid`/`prctl`/`mmap`), armhf cross-toolchain via Docker, host-native `c++` for unit tests.

## Global Constraints

- Branch/worktree: `feat/wrapper-lifecycle` off `milestone-a`. Requires feat #0's `vendor/Main_MiSTer/mister_joy_shm.h` already on `milestone-a`.
- Binary name: `MiSTer_Maldita` (no space/hyphen — matches MiSTer HPS wrapper convention).
- Engine binary path: `/media/fat/games/gmloader/gmloader` (the deployed armhf engine; confirm against `deploy.py`/`CLAUDE.md` device section — the game runs from `/media/fat/games/gmloader`).
- Crash policy: non-zero exit → respawn with backoff while `consecutive_crashes < 3`; at 3 within the window → **halt** (engine stays dead, RBF stays loaded so `0x3B000000` is `devmem`-peekable). Clean exit (0) or core unload → return to menu. `PR_SET_PDEATHSIG(SIGTERM)` on the child.
- The supervisor MUST NOT `EVIOCGRAB` input devices away from SDL (feat #2 relies on SDL reading evdev). Do not add `input`-grab logic in this branch beyond leaving `grabbed = 0`.
- Reuse sonic-mania-mister as the transcription template: `/Users/gmcnaught/MisterFPGA-Projects/sonic-mania-mister/vendor/Main_MiSTer/sonicmania_{main,wrapper}.cpp`, `tools/mister-wrapper/{build-hps.sh,Makefile.full.sonic-mania,main-mister-overlay.files}`. **Strip the netplay/aspect-ratio/scale-mode cruft** — Maldita needs only: fork/exec, supervise, crash-respawn, joy-publish hook, osd-poll hook, return-to-menu.
- Homebrew tools for spawned agents: `export PATH="/opt/homebrew/bin:$PATH"` (docker, make, c++).
- Spec: `docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md` § features 1, "Module boundaries", "Crash policy".

---

### Task 1: Worktree + vendor metadata + overlay manifest skeleton

**Files:**
- Create: `vendor/Main_MiSTer.UPSTREAM.md`
- Create: `tools/mister-wrapper/main-mister-overlay.files`

**Interfaces:**
- Consumes: feat #0's `vendor/Main_MiSTer/mister_joy_shm.h`.
- Produces: the vendor pin (upstream URL + commit) and the overlay keep-list that `build-hps.sh` (Task 6) reads.

- [ ] **Step 1: Create the worktree**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git worktree add -b feat/wrapper-lifecycle ../maldita-feat1-wrapper milestone-a
cd ../maldita-feat1-wrapper
test -f vendor/Main_MiSTer/mister_joy_shm.h && echo "contract present" || echo "MISSING — land feat #0 first"
```
Expected: `contract present`.

- [ ] **Step 2: Write the vendor metadata**

Create `vendor/Main_MiSTer.UPSTREAM.md`:
```markdown
# Main_MiSTer Vendor Metadata (Maldita Castilla wrapper)

- Source repository: `https://github.com/MiSTer-devel/Main_MiSTer.git`
- Pinned commit: `3380931329b8acb442bd3d35a24d89f88641b7cf`
- Import intent: `MiSTer_Maldita` HPS wrapper foundation (engine lifecycle supervisor)
- Local vendor path: `vendor/Main_MiSTer`

This snapshot is an OVERLAY, not a full vendored copy. The full pinned upstream tree is
fetched on demand by `tools/mister-wrapper/build-hps.sh`; the `vendor/Main_MiSTer` overlay
files are applied on top before compilation.

Overlay files (authoritative list): `tools/mister-wrapper/main-mister-overlay.files`.
- `maldita_main.cpp` replaces upstream `main.cpp` (filtered out in the Makefile).
- `maldita_wrapper.{cpp,h}` — the supervisor loop.
- `maldita_child.{cpp,h}` — process lifecycle + crash policy.
- `maldita_joy_shm.{cpp,h}` — joystick SHM publisher (stub here; filled by feat #2).
- `maldita_osd.{cpp,h}` — OSD trigger poll (stub here; filled by feat #4).
- `mister_joy_shm.h` — the host↔engine contract (feat #0).
```

- [ ] **Step 3: Write the overlay keep-list**

Create `tools/mister-wrapper/main-mister-overlay.files` (rsync `--files-from` manifest — paths relative to `vendor/Main_MiSTer/`):
```
maldita_main.cpp
maldita_wrapper.cpp
maldita_wrapper.h
maldita_child.cpp
maldita_child.h
maldita_joy_shm.cpp
maldita_joy_shm.h
maldita_osd.cpp
maldita_osd.h
mister_joy_shm.h
```

- [ ] **Step 4: Commit**

```bash
git add vendor/Main_MiSTer.UPSTREAM.md tools/mister-wrapper/main-mister-overlay.files
git commit -m "build: vendor pin + overlay manifest for MiSTer_Maldita wrapper"
```

---

### Task 2: Crash-policy pure logic (host-native TDD)

**Files:**
- Create: `vendor/Main_MiSTer/maldita_child.h`
- Create: `vendor/Main_MiSTer/maldita_child.cpp` (pure functions only in this task)
- Create: `tools/mister-wrapper/test/maldita_child_test.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum MalditaChildAction { MALDITA_CHILD_MENU=0, MALDITA_CHILD_RESPAWN=1, MALDITA_CHILD_HALT=2 }`
  - `MalditaChildAction maldita_crash_decide(int exit_code, int consecutive_crashes, int max_crashes)`
  - `int maldita_crash_backoff_ms(int consecutive_crashes)`
  - `int maldita_crash_count_update(int prev_count, long ms_since_last_crash, long window_ms)`

- [ ] **Step 1: Write the failing test**

Create `tools/mister-wrapper/test/maldita_child_test.cpp`:
```c
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
```

- [ ] **Step 2: Run it to verify it fails to build (function not defined)**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita-feat1-wrapper
c++ -std=c++14 -Ivendor/Main_MiSTer tools/mister-wrapper/test/maldita_child_test.cpp vendor/Main_MiSTer/maldita_child.cpp -o /tmp/mct 2>&1 | tail -5
```
Expected: compile/link error — `maldita_child.h`/`maldita_child.cpp` don't exist yet.

- [ ] **Step 3: Write the header**

Create `vendor/Main_MiSTer/maldita_child.h`:
```c
#ifndef MALDITA_CHILD_H
#define MALDITA_CHILD_H

#include <sys/types.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MalditaChildAction {
    MALDITA_CHILD_MENU    = 0,  /* clean exit → return to menu */
    MALDITA_CHILD_RESPAWN = 1,  /* crash within budget → respawn with backoff */
    MALDITA_CHILD_HALT    = 2   /* crash budget exhausted → halt, leave RBF loaded */
} MalditaChildAction;

/* ---- pure decision logic (no syscalls; unit-tested) ---- */
MalditaChildAction maldita_crash_decide(int exit_code, int consecutive_crashes, int max_crashes);
int maldita_crash_backoff_ms(int consecutive_crashes);
int maldita_crash_count_update(int prev_count, long ms_since_last_crash, long window_ms);

/* ---- syscall wrappers (Task 3) ---- */
pid_t maldita_child_spawn(char *const argv[], char *const envp[]);
bool  maldita_child_reap(pid_t pid, int *exit_code_out); /* WNOHANG; true if state changed */
void  maldita_child_signal(pid_t pid, int sig);

#ifdef __cplusplus
}
#endif

#endif /* MALDITA_CHILD_H */
```

- [ ] **Step 4: Write the pure implementation**

Create `vendor/Main_MiSTer/maldita_child.cpp`:
```c
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
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
c++ -std=c++14 -Ivendor/Main_MiSTer tools/mister-wrapper/test/maldita_child_test.cpp vendor/Main_MiSTer/maldita_child.cpp -o /tmp/mct && /tmp/mct
```
Expected: `maldita_child crash-policy OK`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add vendor/Main_MiSTer/maldita_child.h vendor/Main_MiSTer/maldita_child.cpp tools/mister-wrapper/test/maldita_child_test.cpp
git commit -m "feat: maldita_child crash-policy pure logic + host-native test"
```

---

### Task 3: Child spawn/reap/signal syscall wrappers (host-native TDD with stub children)

**Files:**
- Modify: `vendor/Main_MiSTer/maldita_child.cpp` (add the three syscall wrappers)
- Modify: `tools/mister-wrapper/test/maldita_child_test.cpp` (add spawn/reap cases)

**Interfaces:**
- Consumes: `MalditaChildAction` from Task 2.
- Produces: `maldita_child_spawn`, `maldita_child_reap`, `maldita_child_signal` (declared in Task 2's header). Consumed by the supervisor loop (Task 5).

- [ ] **Step 1: Add failing spawn/reap tests**

Append to `tools/mister-wrapper/test/maldita_child_test.cpp`, and add the calls into `main()` before the `if (fails)` line:
```c
#include <unistd.h>

static void test_spawn_reap_clean(void) {
    char *argv[] = { (char*)"/bin/sh", (char*)"-c", (char*)"exit 0", NULL };
    pid_t pid = maldita_child_spawn(argv, NULL);
    CHECK(pid > 0);
    int code = -1;
    // Poll to completion (WNOHANG).
    for (int i = 0; i < 1000; i++) { if (maldita_child_reap(pid, &code)) break; usleep(2000); }
    CHECK(code == 0);
}

static void test_spawn_reap_crash(void) {
    char *argv[] = { (char*)"/bin/sh", (char*)"-c", (char*)"exit 42", NULL };
    pid_t pid = maldita_child_spawn(argv, NULL);
    CHECK(pid > 0);
    int code = -1;
    for (int i = 0; i < 1000; i++) { if (maldita_child_reap(pid, &code)) break; usleep(2000); }
    CHECK(code == 42);
}

static void test_signal_kills(void) {
    char *argv[] = { (char*)"/bin/sh", (char*)"-c", (char*)"sleep 30", NULL };
    pid_t pid = maldita_child_spawn(argv, NULL);
    CHECK(pid > 0);
    int code = -1;
    CHECK(maldita_child_reap(pid, &code) == false);   // still running
    maldita_child_signal(pid, 15 /*SIGTERM*/);
    for (int i = 0; i < 1000; i++) { if (maldita_child_reap(pid, &code)) break; usleep(2000); }
    CHECK(code == 128 + 15);                            // signalled exit encoding
}
```
Add to `main()`:
```c
    test_spawn_reap_clean();
    test_spawn_reap_crash();
    test_signal_kills();
```

- [ ] **Step 2: Run to verify it fails (undefined symbols)**

```bash
c++ -std=c++14 -Ivendor/Main_MiSTer tools/mister-wrapper/test/maldita_child_test.cpp vendor/Main_MiSTer/maldita_child.cpp -o /tmp/mct 2>&1 | tail -5
```
Expected: link error — `maldita_child_spawn`/`_reap`/`_signal` undefined.

- [ ] **Step 3: Implement the syscall wrappers**

Append to `vendor/Main_MiSTer/maldita_child.cpp` (add the includes at the top of the file):
```c
#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>

extern char **environ;

pid_t maldita_child_spawn(char *const argv[], char *const envp[])
{
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        /* Child: die if the wrapper dies; detach stdin. */
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        int devnull = open("/dev/null", O_RDONLY | O_CLOEXEC);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        execve(argv[0], argv, envp ? envp : environ);
        _exit(127); /* exec failed */
    }
    return pid;
}

bool maldita_child_reap(pid_t pid, int *exit_code_out)
{
    int status = 0;
    pid_t rc = waitpid(pid, &status, WNOHANG);
    if (rc != pid) return false; /* 0 = still running; -1 = error/no such child */
    if (exit_code_out) {
        if (WIFEXITED(status))        *exit_code_out = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) *exit_code_out = 128 + WTERMSIG(status);
        else                          *exit_code_out = -1;
    }
    return true;
}

void maldita_child_signal(pid_t pid, int sig)
{
    if (pid > 0) kill(pid, sig);
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
c++ -std=c++14 -Ivendor/Main_MiSTer tools/mister-wrapper/test/maldita_child_test.cpp vendor/Main_MiSTer/maldita_child.cpp -o /tmp/mct && /tmp/mct
```
Expected: `maldita_child crash-policy OK`, exit 0 (all spawn/reap/signal cases pass).

- [ ] **Step 5: Commit**

```bash
git add vendor/Main_MiSTer/maldita_child.cpp tools/mister-wrapper/test/maldita_child_test.cpp
git commit -m "feat: maldita_child spawn/reap/signal wrappers + tests"
```

---

### Task 4: Inert joy-shm + osd stubs (so the loop compiles/links)

**Files:**
- Create: `vendor/Main_MiSTer/maldita_joy_shm.h`
- Create: `vendor/Main_MiSTer/maldita_joy_shm.cpp` (INERT stub — feat #2 fills the body)
- Create: `vendor/Main_MiSTer/maldita_osd.h`
- Create: `vendor/Main_MiSTer/maldita_osd.cpp` (INERT stub — feat #4 fills the body)

**Interfaces:**
- Consumes: `mister_joy_shm.h` (feat #0).
- Produces (the frozen hook signatures the supervisor calls; feat #2/#4 implement these bodies without changing the loop):
  - `bool maldita_joy_open(void)` — open+mmap+seed SHM, `setenv(GMLOADER_JOY_SHM)`; stub returns `false`.
  - `void maldita_joy_publish(int osd_visible)` — publish current mask; stub is a no-op.
  - `void maldita_joy_bump_generation(void)` — stub no-op.
  - `void maldita_joy_close(void)` — stub no-op.
  - `void maldita_osd_poll(pid_t child, int *restart_out)` — take T-bit; stub sets `*restart_out = 0`.

- [ ] **Step 1: Write the joy-shm stub header + body**

Create `vendor/Main_MiSTer/maldita_joy_shm.h`:
```c
#ifndef MALDITA_JOY_SHM_H
#define MALDITA_JOY_SHM_H
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Producer side of the mister_joy_shm.h contract. Implemented by feat #2;
 * this stub lets the supervisor loop (feat #1) compile and link with the
 * publish path inert. */
bool maldita_joy_open(void);
void maldita_joy_publish(int osd_visible);
void maldita_joy_bump_generation(void);
void maldita_joy_close(void);
#ifdef __cplusplus
}
#endif
#endif /* MALDITA_JOY_SHM_H */
```
Create `vendor/Main_MiSTer/maldita_joy_shm.cpp`:
```c
#include "maldita_joy_shm.h"
/* INERT STUB — feat #2 replaces this body with the real /dev/shm publisher.
 * Do not add publish logic here in feat #1. */
bool maldita_joy_open(void)           { return false; }
void maldita_joy_publish(int)         { }
void maldita_joy_bump_generation(void){ }
void maldita_joy_close(void)          { }
```

- [ ] **Step 2: Write the osd stub header + body**

Create `vendor/Main_MiSTer/maldita_osd.h`:
```c
#ifndef MALDITA_OSD_H
#define MALDITA_OSD_H
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
/* OSD trigger poll. Implemented by feat #4 (takes the Reset T-bit and requests
 * an engine respawn). This stub keeps the loop inert until then. */
void maldita_osd_poll(pid_t child, int *restart_out);
#ifdef __cplusplus
}
#endif
#endif /* MALDITA_OSD_H */
```
Create `vendor/Main_MiSTer/maldita_osd.cpp`:
```c
#include "maldita_osd.h"
/* INERT STUB — feat #4 replaces this body with the real T-bit handler. */
void maldita_osd_poll(pid_t /*child*/, int *restart_out)
{
    if (restart_out) *restart_out = 0;
}
```

- [ ] **Step 3: Verify the stubs compile**

```bash
c++ -std=c++14 -Ivendor/Main_MiSTer -c vendor/Main_MiSTer/maldita_joy_shm.cpp -o /tmp/j.o && \
c++ -std=c++14 -Ivendor/Main_MiSTer -c vendor/Main_MiSTer/maldita_osd.cpp     -o /tmp/o.o && echo "STUBS OK"
```
Expected: `STUBS OK`.

- [ ] **Step 4: Commit**

```bash
git add vendor/Main_MiSTer/maldita_joy_shm.h vendor/Main_MiSTer/maldita_joy_shm.cpp vendor/Main_MiSTer/maldita_osd.h vendor/Main_MiSTer/maldita_osd.cpp
git commit -m "feat: inert joy-shm + osd stubs (feat #2/#4 fill the bodies)"
```

---

### Task 5: Supervisor loop + main entry

**Files:**
- Create: `vendor/Main_MiSTer/maldita_wrapper.h`
- Create: `vendor/Main_MiSTer/maldita_wrapper.cpp`
- Create: `vendor/Main_MiSTer/maldita_main.cpp`

**Interfaces:**
- Consumes: `maldita_child.h`, `maldita_joy_shm.h`, `maldita_osd.h`.
- Produces: `int maldita_wrapper_run(int argc, char *argv[])` (called by `maldita_main.cpp`).

**Note on MiSTer symbols:** The full supervisor references upstream Main_MiSTer functions (`is_fpga_ready`, `frame_timer`, `input_poll`, `HandleUI`, `OsdUpdate`, `user_io_osd_is_visible`, `fpga_load_rbf_no_restart`, `offload_start`, `fpga_io_init`). These resolve ONLY against the full vendored tree at armhf build time (Task 6), not host-native. So this task is verified by armhf compilation in Task 6, not by a host unit test. Keep MiSTer-symbol usage confined to `maldita_wrapper.cpp`; `maldita_child`/`maldita_joy_shm`/`maldita_osd` stay POSIX-only so they remain host-testable.

- [ ] **Step 1: Write the wrapper header**

Create `vendor/Main_MiSTer/maldita_wrapper.h`:
```c
#ifndef MALDITA_WRAPPER_H
#define MALDITA_WRAPPER_H
#ifdef __cplusplus
extern "C" {
#endif
int maldita_wrapper_run(int argc, char *argv[]);
#ifdef __cplusplus
}
#endif
#endif /* MALDITA_WRAPPER_H */
```

- [ ] **Step 2: Write the supervisor loop**

Create `vendor/Main_MiSTer/maldita_wrapper.cpp`. Transcribe from sonic-mania's `sonicmania_wrapper.cpp` but keep ONLY the lifecycle spine. Structure:
```c
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
```
Adjust include names to the upstream tree if the armhf compile in Task 6 reports a missing header (e.g. `frame_timer.h` vs inline). Keep the control flow exactly as above.

- [ ] **Step 3: Write the main entry**

Create `vendor/Main_MiSTer/maldita_main.cpp` (mirrors `sonicmania_main.cpp`):
```c
#include <sched.h>

#include "fpga_io.h"
#include "offload.h"
#include "maldita_wrapper.h"

const char *version = "$VER:" VDATE;

int main(int argc, char *argv[])
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(1, &set);
    sched_setaffinity(0, sizeof(set), &set);

    offload_start();
    fpga_io_init();

    return maldita_wrapper_run(argc, argv);
}
```

- [ ] **Step 4: Re-run the host-native child test (unchanged, guards against regressions)**

```bash
c++ -std=c++14 -Ivendor/Main_MiSTer tools/mister-wrapper/test/maldita_child_test.cpp vendor/Main_MiSTer/maldita_child.cpp -o /tmp/mct && /tmp/mct
```
Expected: `maldita_child crash-policy OK`. (The wrapper itself is not host-linkable; its gate is Task 6.)

- [ ] **Step 5: Commit**

```bash
git add vendor/Main_MiSTer/maldita_wrapper.h vendor/Main_MiSTer/maldita_wrapper.cpp vendor/Main_MiSTer/maldita_main.cpp
git commit -m "feat: MiSTer_Maldita supervisor loop + main entry (crash-respawn/halt)"
```

---

### Task 6: armhf build infrastructure (Makefile + build driver) and first cross-compile

**Files:**
- Create: `tools/mister-wrapper/Makefile.full.maldita`
- Create: `tools/mister-wrapper/build-hps.sh`
- Create: `tools/mister-wrapper/main-mister-full-menu.patch` (no-op placeholder — see spec § "no `main-mister-full-menu.patch` initially")

**Interfaces:**
- Consumes: overlay manifest (Task 1), all overlay `.cpp/.h` (Tasks 2-5).
- Produces: `build/mister-wrapper-hps/MiSTer_Maldita` (armhf ELF). This is the binary `deploy.py` ships (Task 7).

- [ ] **Step 1: Write the Makefile**

Create `tools/mister-wrapper/Makefile.full.maldita` by copying sonic-mania's `Makefile.full.sonic-mania` verbatim, then changing exactly two things:
1. `PRJ = MiSTer_Maldita` (was `MiSTer_SonicMania`).
2. Nothing else — the `CPP_SRC = $(filter-out main.cpp,$(wildcard *.cpp))` clause already drops upstream `main.cpp` and picks up our `maldita_main.cpp` automatically.

Reference full source: `/Users/gmcnaught/MisterFPGA-Projects/sonic-mania-mister/tools/mister-wrapper/Makefile.full.sonic-mania`. The key lines that must survive the copy:
```makefile
BASE    = arm-none-linux-gnueabihf
PRJ = MiSTer_Maldita
CPP_SRC = $(filter-out main.cpp,$(wildcard *.cpp)) \
          $(wildcard ./lib/serial_server/library/*.cpp) \
          $(wildcard ./support/*/*.cpp)
$(BUILDDIR)/main.cpp.o: $(filter-out $(BUILDDIR)/main.cpp.o, $(OBJ))
```

- [ ] **Step 2: Write the no-op menu patch placeholder**

Create `tools/mister-wrapper/main-mister-full-menu.patch` (comments only — the "hide Core entry" hunk is deferred per spec; `git apply --allow-empty` accepts this):
```
# Maldita Castilla MiSTer wrapper: menu.cpp patch (placeholder).
#
# Intentionally empty for the initial wrapper. The sonic-mania "hide Core entry"
# hunk (prevent hot-swapping cores under the running game) is deferred polish
# (spec § "no main-mister-full-menu.patch initially"). build-hps.sh applies this
# with `git apply --allow-empty`, so an empty patch is a valid no-op.
```

- [ ] **Step 3: Write the build driver**

Create `tools/mister-wrapper/build-hps.sh` by copying sonic-mania's `build-hps.sh` and retargeting the identifiers. Concretely, change these variables (everything else — the `prepare_source`/`--check-env`/`--prepare-source`/`--build-image`/docker-fallback logic — is copied verbatim):
```bash
BUILD_MANIFEST="${ROOT_DIR}/tools/mister-wrapper/Makefile.full.maldita"
DOCKER_IMAGE="${MISTER_WRAPPER_HPS_IMAGE:-maldita-mister-wrapper-hps}"
CONTAINER_ROOT="${MISTER_WRAPPER_HPS_CONTAINER_ROOT:-/workspaces/maldita-castilla-mister}"
UPSTREAM_COMMIT="${MISTER_WRAPPER_HPS_UPSTREAM_COMMIT:-3380931329b8acb442bd3d35a24d89f88641b7cf}"
```
And in `prepare_source()`, the manifest copy target and final binary path both use `MiSTer_Maldita`:
```bash
    cp "${BUILD_MANIFEST}" "${BUILD_SRC_DIR}/Makefile.maldita"
```
and at the tail:
```bash
    make -C "${BUILD_SRC_DIR}" -f Makefile.maldita BASE="${TOOLCHAIN_PREFIX}"
    ...
cp "${BUILD_SRC_DIR}/bin/MiSTer_Maldita" "${OUTPUT_DIR}/MiSTer_Maldita"
```
Full reference: `/Users/gmcnaught/MisterFPGA-Projects/sonic-mania-mister/tools/mister-wrapper/build-hps.sh`.

**Docker image reuse:** sonic-mania's driver builds its own image from `vendor/Main_MiSTer/.devcontainer/Dockerfile`. The pinned upstream tree ships that devcontainer, so the on-demand `git clone` + `--build-image` path already produces a working arm cross-toolchain image — no new Dockerfile needed. Keep `DOCKER_CONTEXT_DIR`/`DOCKERFILE_PATH` pointing at the fetched tree's `.devcontainer` exactly as sonic-mania does.

- [ ] **Step 4: Prepare source and inspect the overlay merge (no compile yet)**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita-feat1-wrapper
export PATH="/opt/homebrew/bin:$PATH"
chmod +x tools/mister-wrapper/build-hps.sh
tools/mister-wrapper/build-hps.sh --prepare-source
ls build/mister-wrapper-hps/src/maldita_*.cpp build/mister-wrapper-hps/src/mister_joy_shm.h
```
Expected: the fetched upstream tree in `build/mister-wrapper-hps/src/` with our 10 overlay files layered in. If the clone fails (network), the on-demand fetch of `Main_MiSTer` at the pinned commit is the prerequisite — retry with connectivity.

- [ ] **Step 5: Cross-compile the wrapper (armhf)**

```bash
tools/mister-wrapper/build-hps.sh --build-image   # first time only; builds the toolchain image
tools/mister-wrapper/build-hps.sh                  # prepare + compile + link
file build/mister-wrapper-hps/MiSTer_Maldita
```
Expected: `build/mister-wrapper-hps/MiSTer_Maldita` exists and `file` reports `ELF 32-bit LSB ... ARM`. This is the real compile gate for Task 5's wrapper — fix any missing-header/undeclared-symbol errors by matching the upstream API names (they are stable at the pinned commit).

- [ ] **Step 6: Commit**

```bash
git add tools/mister-wrapper/Makefile.full.maldita tools/mister-wrapper/build-hps.sh tools/mister-wrapper/main-mister-full-menu.patch
git commit -m "build: armhf cross-build for MiSTer_Maldita (Makefile + driver)"
```

---

### Task 7: Deploy wiring + on-device gate

**Files:**
- Modify: `deploy.py` (ship `MiSTer_Maldita` alongside the RBF + engine)

**Interfaces:**
- Consumes: `build/mister-wrapper-hps/MiSTer_Maldita`.
- Produces: the wrapper on-device at `/media/fat/games/gmloader/MiSTer_Maldita` (or the framework's `main=` search path — confirm below).

- [ ] **Step 1: Inspect deploy.py to find the copy list**

```bash
grep -n "scp\|copy\|\.rbf\|gmloadernext\|games/gmloader\|_Other" deploy.py | head -30
```
Identify where the RBF and engine binary are copied to `root@192.168.20.81`. Add a step that scp's `build/mister-wrapper-hps/MiSTer_Maldita` to the location MiSTer's `main=` resolves (per MiSTer convention, an absolute path in `MiSTer.ini` `[Maldita Castilla] main=` is simplest; place the binary at `/media/fat/games/gmloader/MiSTer_Maldita`). Follow deploy.py's existing sha1-verify pattern used for the engine binary.

- [ ] **Step 2: Add the wrapper to the deploy copy set**

Edit `deploy.py` to copy `MiSTer_Maldita` (mirror the exact idiom deploy.py already uses for the engine binary — same host, same sha1 check). Do not invent a new transport; reuse the existing scp helper.

- [ ] **Step 3: Document the MiSTer.ini contract**

Add to the branch PR description (and, if the repo has a device-setup doc, there) the required INI line the user must add once:
```ini
[Maldita Castilla]
main=/media/fat/games/gmloader/MiSTer_Maldita
```
This is what makes stock MiSTer hand off to the wrapper on core load (upstream `user_io.cpp` `app_restart` path).

- [ ] **Step 4: Commit**

```bash
git add deploy.py
git commit -m "deploy: ship MiSTer_Maldita wrapper binary alongside RBF + engine"
```

- [ ] **Step 5: Record the on-device gates (manual, post-deploy)**

These require the device (spec § Testing #2). Track as PR checkboxes; do not block code merge, do not close the feature until they pass:
1. Set the `MiSTer.ini` `main=` line; load the core → the engine auto-launches (no manual `gmloader_diag.sh`). Verify: game renders.
2. Unload the core (load another core) → the engine process dies. Verify: `ssh root@192.168.20.81 'ps | grep gmloader'` shows no orphan.
3. `ssh root@192.168.20.81 'killall gmloader'` while running → the wrapper respawns it; `cat /media/fat/games/gmloader/logs/osd-wrapper.log` shows `crash=1 respawn`.
4. Kill it 3× within 10 s → the wrapper halts (engine stays dead), and `busybox devmem 0x3B000000 32` still responds (fabric preserved).
