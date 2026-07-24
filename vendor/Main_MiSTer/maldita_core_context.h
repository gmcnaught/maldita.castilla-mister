#ifndef MALDITA_CORE_CONTEXT_H
#define MALDITA_CORE_CONTEXT_H

#include <stddef.h>

/* Must match the core's CONF_STR header (fpga/Maldita.sv) and the MiSTer.ini
 * section name — the framework keys per-core config off it. */
#define MALDITA_CORE_NAME "Maldita Castilla"

#ifdef __cplusplus
extern "C" {
#endif

/* Establish the MiSTer framework's per-core context for the MiSTer_Maldita HPS
 * wrapper. A "main=" wrapper replaces MiSTer's main(), so none of this happens
 * on its own: without it the core has no identity, MiSTer.ini is never parsed,
 * and — the visible symptom — video_init() never runs, so the output never gets
 * valid timing and the display reports no signal.
 *
 * Call AFTER user_io_init(), mirroring sonicmania_core_context_init() /
 * thirdsarm_core_context_init() in the sibling MiSTer wrapper projects.
 *
 * rbf_path may be NULL/empty (the firmware does not pass one when launching via
 * MiSTer.ini's main= directive), in which case the built-in core name is used.
 * Returns 0 on success, -1 on core-identity mismatch (error filled in). */
int maldita_core_context_init(const char *rbf_path, char *error, size_t error_size);

/* Core name derived from rbf_path, or the built-in default. */
const char *maldita_core_context_core_name(void);

#ifdef __cplusplus
}
#endif

#endif /* MALDITA_CORE_CONTEXT_H */
