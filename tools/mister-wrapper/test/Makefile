# Host-native tests for the `main=` wrapper overlay.
#
#   make -C tools/mister-wrapper/test          build and run
#   make -C tools/mister-wrapper/test clean
#
# Host-native, not armhf: maldita_child.cpp and maldita_reset.cpp are plain
# POSIX/pure C with no Main_MiSTer dependencies, which is exactly why they are
# separate translation units from maldita_hook.cpp. The hook itself links against
# upstream symbols (user_io_get_core_name, user_io_status_trigger_take) and is
# only built by tools/mister-wrapper/build-hps.sh against the pinned upstream
# tree — `make check-hook` below compiles it against a stub header so at least
# its syntax and includes are checked here.

VENDOR  := ../../../vendor/Main_MiSTer
CXX     ?= c++
CXXFLAGS ?= -std=gnu++14 -Wall -Wextra -O1 -I$(VENDOR)
BUILD   := build

.PHONY: all test check-hook clean
all: test check-hook

test: $(BUILD)/maldita_child_test $(BUILD)/maldita_reset_test
	$(BUILD)/maldita_child_test
	$(BUILD)/maldita_reset_test

$(BUILD)/maldita_child_test: maldita_child_test.cpp $(VENDOR)/maldita_child.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ $^

$(BUILD)/maldita_reset_test: maldita_reset_test.cpp $(VENDOR)/maldita_reset.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ $^

# Syntax/include check for the hook. It calls upstream user_io functions, so
# compile it against a minimal stub of just those declarations rather than
# vendoring the whole tree. This catches typos and bad includes; it does NOT
# check that the real signatures still match, which is build-hps.sh's job
# against the pinned commit.
#
# user_io_status_trigger_take() is itself a Maldita addition to the vendored
# user_io.cpp/.h, so the stub must declare it too — and if the overlay ever
# loses it, build-hps.sh's link is what fails, not this.
#
# The hook is compiled from a COPY in $(BUILD)/hookchk rather than in place, and
# that is not tidiness. `#include "user_io.h"` resolves relative to the including
# file's own directory first, and $(VENDOR) now contains the real vendored
# user_io.h — which pulls in file_io.h and the rest of the upstream tree that is
# deliberately not here. No -I ordering can beat quoted-include-relative-to-file,
# so the only way to interpose the stub is to move the .cpp next to it.
HOOKCHK := $(BUILD)/hookchk
check-hook: | $(BUILD)
	@mkdir -p $(HOOKCHK)
	@cp $(VENDOR)/maldita_hook.cpp $(VENDOR)/maldita_hook.h \
	    $(VENDOR)/maldita_child.h $(VENDOR)/maldita_reset.h $(HOOKCHK)/
	@printf '#ifndef USER_IO_H\n#define USER_IO_H\n#include <stdint.h>\nchar *user_io_get_core_name(int orig = 0);\nuint32_t user_io_status_trigger_take();\n#endif\n' > $(HOOKCHK)/user_io.h
	$(CXX) $(CXXFLAGS) -fsyntax-only $(HOOKCHK)/maldita_hook.cpp
	@echo "  ok   — maldita_hook.cpp compiles"

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	@rm -rf $(BUILD)
