/* Host simulation of BOTH frame limiters against a virtual 16.6882 ms scanout
 * counter, to check the two regimes the design must satisfy before deploying:
 *   fast body (13 ms, intro)  -> paced to 59.9228 Hz, cap ENGAGES
 *   slow body (18.09 ms)      -> ZERO wait, i.e. GMLOADER_FPS=0 behaviour
 * and to characterise the OLD wall-clock limiter's true mechanism.
 * Time is in microseconds; SDL_GetTicks() is modelled as us/1000 (ms truncation). */
#include <stdio.h>
#include <stdint.h>

static const double SCAN_US = 16688.2;   /* 1,642,740 cyc @ 98.4375 MHz */

/* ---- OLD: main.cpp SDL_Delay cap, frame_ms = 1000/60 = 16 ---------------- */
static void sim_old(double body_us, int n, const char *label) {
    uint32_t frame_ms = 16, next_ms = 0;
    double t = 0.0, slept = 0.0; int catchups = 0, sleeps = 0;
    for (int i = 0; i < n; i++) {
        t += body_us;
        uint32_t now = (uint32_t)(t / 1000.0);
        if (next_ms == 0 || now > next_ms + frame_ms) { next_ms = now; catchups++; }
        next_ms += frame_ms;
        if (now < next_ms) {
            double d = (next_ms - now) * 1000.0;
            t += d; slept += d; sleeps++;
        }
    }
    printf("OLD  %-22s body=%6.2f -> period=%6.3f ms (%5.2f fps)  slept_avg=%5.2f ms  "
           "sleeps=%d/%d catchups=%d\n",
           label, body_us / 1000.0, t / 1000.0 / n, 1e6 / (t / n), slept / 1000.0 / n,
           sleeps, n, catchups);
}

/* ---- NEW: scanout-advance cap ------------------------------------------- */
static void sim_new(double body_us, int n, const char *label) {
    double t = 0.0, waited = 0.0; int waits = 0;
    uint32_t last = (uint32_t)(t / SCAN_US);
    for (int i = 0; i < n; i++) {
        t += body_us;
        uint32_t cnt = (uint32_t)(t / SCAN_US);
        if (cnt == last) {                       /* body fit inside one period */
            double next_boundary = (last + 1) * SCAN_US;
            waited += next_boundary - t; waits++;
            t = next_boundary;
            cnt = last + 1;   /* hardware counter has genuinely ticked */
        }
        last = cnt;                              /* release value, never last+1 */
    }
    printf("NEW  %-22s body=%6.2f -> period=%6.3f ms (%5.2f fps)  wait_avg=%5.2f ms  "
           "waits=%d/%d\n",
           label, body_us / 1000.0, t / 1000.0 / n, 1e6 / (t / n), waited / 1000.0 / n,
           waits, n);
}

/* ---- what a classic vsync SYNC would do (the trap we must avoid) --------- */
static void sim_sync(double body_us, int n, const char *label) {
    double t = 0.0;
    for (int i = 0; i < n; i++) {
        t += body_us;
        double k = (double)(int64_t)(t / SCAN_US) + 1.0;   /* always next boundary */
        t = k * SCAN_US;
    }
    printf("SYNC %-22s body=%6.2f -> period=%6.3f ms (%5.2f fps)\n",
           label, body_us / 1000.0, t / 1000.0 / n, 1e6 / (t / n));
}

int main(void) {
    struct { double body; const char *l; } c[] = {
        { 18090.0, "slow (measured quiet)" },
        { 16200.0, "fabric-only" },
        { 13000.0, "light scene / intro" },
        {  8000.0, "very fast" },
        {  2000.0, "free-running" },
        { 21370.0, "arrival transient" },
        { 27300.0, "phase-2 body" },
    };
    for (unsigned i = 0; i < sizeof c / sizeof c[0]; i++) {
        sim_old(c[i].body, 20000, c[i].l);
        sim_new(c[i].body, 20000, c[i].l);
        sim_sync(c[i].body, 20000, c[i].l);
        printf("\n");
    }
    return 0;
}
