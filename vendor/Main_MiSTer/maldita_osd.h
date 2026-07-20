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
