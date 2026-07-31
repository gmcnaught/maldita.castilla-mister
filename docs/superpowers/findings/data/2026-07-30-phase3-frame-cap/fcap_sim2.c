/* Leaky-bucket cap vs the strict per-frame test, against a virtual 16.6882 ms
 * scanout counter. Includes the BIMODAL loop shape .62 actually shows (the
 * Phase 2 host lever pipelines the C_DONE await, so frame times alternate
 * short/long around an 18.09 ms mean) -- the case that made the strict test
 * deliver 19.05 ms instead of 18.09. */
#include <stdio.h>
#include <stdint.h>

static const double SCAN_US = 16688.2;

/* body_us[] cycles; n frames. mode: 0 = strict per-frame, else bucket depth. */
static void sim(const double *body, int nb, int n, int burst, const char *label) {
    double t = 0.0, waited = 0.0; int waits = 0;
    uint32_t last = 0; int32_t credit = 0;
    int64_t bnd = 0;                       /* integer boundary count = hw counter */
    for (int i = 0; i < n; i++) {
        t += body[i % nb];
        bnd = (int64_t)(t / SCAN_US);
        uint32_t cnt = (uint32_t)bnd;
        if (burst == 0) {                  /* strict: must have advanced */
            if (cnt == last) {
                double nb2 = (double)(last + 1) * SCAN_US;
                waited += nb2 - t; waits++; t = nb2; cnt = last + 1;
            }
            last = cnt;
        } else {
            credit += (int32_t)(cnt - last); last = cnt;
            if (credit > burst) credit = burst;
            credit -= 1;
            if (credit < 0) {
                double nb2 = (double)(last + 1) * SCAN_US;
                waited += nb2 - t; waits++; t = nb2;
                credit += 1; last = last + 1;
            }
        }
    }
    printf("%-22s %-14s period=%6.3f ms (%5.2f fps)  wait_avg=%5.2f ms  waits=%4.1f%%\n",
           label, burst ? (burst == 1 ? "bucket(1)" : burst == 2 ? "bucket(2)" : "bucket(N)")
                        : "strict",
           t / 1000.0 / n, 1e6 / (t / n), waited / 1000.0 / n, 100.0 * waits / n);
}

int main(void) {
    double slow[]     = { 18090.0 };
    double bimodal[]  = { 10000.0, 26180.0 };            /* mean 18.09 */
    double bimodal2[] = { 12000.0, 24180.0 };            /* mean 18.09, milder */
    double light[]    = { 13000.0 };
    double light_bi[] = { 8000.0, 18000.0 };             /* mean 13.0 */
    double fast[]     = { 2000.0 };
    double arrival[]  = { 21370.0 };
    struct { double *b; int n; const char *l; } c[] = {
        { slow,     1, "slow flat 18.09" },
        { bimodal,  2, "slow bimodal 10/26" },
        { bimodal2, 2, "slow bimodal 12/24" },
        { light,    1, "light flat 13.0" },
        { light_bi, 2, "light bimodal 8/18" },
        { fast,     1, "free-run 2.0" },
        { arrival,  1, "arrival 21.37" },
    };
    for (unsigned i = 0; i < sizeof c / sizeof c[0]; i++) {
        sim(c[i].b, c[i].n, 40000, 0, c[i].l);
        sim(c[i].b, c[i].n, 40000, 1, c[i].l);
        sim(c[i].b, c[i].n, 40000, 2, c[i].l);
        printf("\n");
    }
    return 0;
}
