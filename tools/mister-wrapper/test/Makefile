# Host-native tests for the `main=` wrapper overlay.
#
#   make -C tools/mister-wrapper/test          build and run
#   make -C tools/mister-wrapper/test clean
#
# Host-native, not armhf: maldita_child.cpp is plain POSIX with no Main_MiSTer
# dependencies, which is exactly why it is a separate translation unit from
# maldita_hook.cpp. The hook itself links against upstream symbols
# (user_io_get_core_name) and is only built by tools/mister-wrapper/build-hps.sh
# against the pinned upstream tree — `make check-hook` below compiles it against
# a stub header so at least its syntax and includes are checked here.

VENDOR  := ../../../vendor/Main_MiSTer
CXX     ?= c++
CXXFLAGS ?= -std=gnu++14 -Wall -Wextra -O1 -I$(VENDOR)
BUILD   := build

.PHONY: all test check-hook clean
all: test check-hook

test: $(BUILD)/maldita_child_test
	$(BUILD)/maldita_child_test

$(BUILD)/maldita_child_test: maldita_child_test.cpp $(VENDOR)/maldita_child.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) -o $@ $^

# Syntax/include check for the hook. It calls user_io_get_core_name(), which
# lives in upstream user_io.h and is not vendored here (deliberately — the
# overlay is five files), so compile it against a minimal stub of just that
# declaration. This catches typos and bad includes without pulling in the whole
# upstream tree; it does NOT check that the real signature still matches, which
# is build-hps.sh's job against the pinned commit.
check-hook: | $(BUILD)
	@printf '#ifndef USER_IO_H\n#define USER_IO_H\nchar *user_io_get_core_name(int orig = 0);\n#endif\n' > $(BUILD)/user_io.h
	$(CXX) $(CXXFLAGS) -I$(BUILD) -fsyntax-only $(VENDOR)/maldita_hook.cpp
	@echo "  ok   — maldita_hook.cpp compiles"

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	@rm -rf $(BUILD)
