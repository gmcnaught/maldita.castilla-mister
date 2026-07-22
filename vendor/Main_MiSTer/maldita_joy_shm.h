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
