#include "maldita_core_context.h"

#include <stdio.h>
#include <string.h>
#include <strings.h>

#include "cfg.h"
#include "osd.h"
#include "user_io.h"
#include "video.h"

namespace {

constexpr const char *kCoreName = MALDITA_CORE_NAME;

char g_core_name[32] = MALDITA_CORE_NAME;

const char *basename_ptr(const char *path)
{
	if (!path || !path[0]) return nullptr;

	const char *slash = strrchr(path, '/');
	return slash ? slash + 1 : path;
}

void copy_core_name(char *dst, size_t dst_size, const char *path)
{
	if (!dst || !dst_size) return;

	const char *base = basename_ptr(path);
	if (!base || !base[0])
	{
		snprintf(dst, dst_size, "%s", kCoreName);
		return;
	}

	snprintf(dst, dst_size, "%s", base);
	char *dot = strrchr(dst, '.');
	if (dot) *dot = 0;
}

}  // namespace

int maldita_core_context_init(const char *rbf_path, char *error, size_t error_size)
{
	(void)error; (void)error_size;

	copy_core_name(g_core_name, sizeof(g_core_name), rbf_path);

	/* The sibling wrappers hard-fail on an identity mismatch, but their RBF is
	 * named exactly after the core. Ours carries a date suffix
	 * (MalditaCastilla_YYYYMMDD.rbf) and drops the space, so the derived name
	 * never matches. Failing here would skip video_init() below — which is the
	 * very bug this function exists to fix — so warn and carry on with the
	 * CONF_STR name, which is what MiSTer.ini and the framework agree on. */
	if (strcasecmp(g_core_name, kCoreName))
	{
		printf("maldita: core name from RBF is \"%s\", using \"%s\"\n",
		       g_core_name, kCoreName);
	}

	user_io_wrapper_set_core_names(kCoreName, kCoreName);
	OsdCoreNameSet(kCoreName);
	cfg_parse();     /* MiSTer.ini: video_mode / vga_mode / vga_scaler / hdmi_* */
	video_init();    /* configure the video output — without this: no signal */
	return 0;
}

const char *maldita_core_context_core_name(void)
{
	return g_core_name;
}
