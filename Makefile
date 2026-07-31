# Build + deploy entry points for the Maldita Castilla MiSTer core.
#
# The engine source is the external/gmloader-next submodule. When working on
# the engine in a worktree, pass GMDIR explicitly:
#     make build-engine GMDIR=../wt-gmloader-<topic>
#
# Deploys go through ./deploy.py on purpose: it carries the provenance gates
# (RBF matched to fpga/ tree hash, engine freshness vs gmloader-next HEAD),
# sha1-verified scp (FAT truncation guard), and kills the running engine so
# Master_Daemon respawns it with the new binary. Never bypass it with a bare
# scp, and never hand-launch gmloader afterwards -- that is how you end up with
# two engines fighting over one control block.
#
# Common invocations:
#   make build-engine
#   make build-engine GMDIR=../wt-gmloader-audioclk
#   make deploy-rbf                  # fetch the gated CI RBF for HEAD, deploy it
#   make deploy                      # RBF + engine + content
#   make deploy HOST=192.168.20.81 PROD=1   # production needs explicit PROD=1

# The engine lives in the submodule by default. GMDIR stays overridable so the
# per-workstream worktree flow (GMDIR=../wt-gmloader-<topic>) keeps working.
GMDIR ?= $(CURDIR)/external/gmloader-next
override GMDIR := $(abspath $(GMDIR))

# .62 is the TEST device and the default. .81 is PRODUCTION — deploy targets
# refuse it unless PROD=1 is passed (deploy.py's own default is .81, so HOST
# is always passed through explicitly).
HOST      ?= 192.168.20.62
PROD_HOST := 192.168.20.81

DOCKER ?= /opt/homebrew/bin/docker
IMAGE  := gmloader-armhf-build:bullseye
ENGINE ?= $(GMDIR)/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf

DEPLOY = ./deploy.py --host $(HOST)

.PHONY: help build-image build-engine rbf-status rbf-watch \
        deploy deploy-engine deploy-rbf guard-host

help: ## Show available targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'
	@echo ""
	@echo "  Vars: GMDIR=$(GMDIR)"
	@echo "        HOST=$(HOST)  (production $(PROD_HOST) requires PROD=1)"

# ---- engine (gmloader-next, armhf, Docker cross-build) ----------------------
# Toolchain is baked into the cached image; builds are incremental (build/
# persists in the checkout). Host-native arm64 image, armhf is the cross
# target — do NOT switch to an arm32v7 base image (see gmloader-next/CLAUDE.md).

build-image: ## Build the cached armhf cross-toolchain image (one-time)
	cd $(GMDIR) && $(DOCKER) build -f Dockerfile.gmloader-build -t $(IMAGE) .

build-engine: ## Cross-build the gmloader engine from GMDIR
	@$(DOCKER) image inspect $(IMAGE) >/dev/null 2>&1 || $(MAKE) build-image GMDIR=$(GMDIR)
	cd $(GMDIR) && $(DOCKER) run --rm -v "$$(pwd):/src" -w /src $(IMAGE) bash -c '\
	  touch thunks/thunk_gen_dyn.h && \
	  make -f Makefile.gmloader ARCH=arm-linux-gnueabihf MISTER_BUILD=1 MISTER_NATIVE_VIDEO=1 \
	    "LLVM_INC=/usr/arm-linux-gnueabihf/include /usr/arm-linux-gnueabihf/include/c++/10/arm-linux-gnueabihf" \
	    -j$$(nproc)'
	@ls -lh $(ENGINE)

# ---- RBF (Quartus 17.0 Lite, self-hosted Windows CI runner ONLY) ------------
# There is deliberately no local build target: pushing a change to fpga/**
# under fpga/ triggers .github/workflows/build-rbf.yml (~12 min). Fetch +
# deploy the result with `make deploy-rbf` — deploy.py resolves the artifact
# by fpga/ TREE hash and refuses anything stale.

rbf-status: ## List recent CI RBF builds for this repo
	gh run list --workflow build-rbf.yml -L 5

rbf-watch: ## Watch the latest CI RBF build until it finishes
	gh run watch $$(gh run list --workflow build-rbf.yml -L 1 \
	  --json databaseId -q '.[0].databaseId')

# ---- deploy (always via deploy.py — keep the provenance gates) --------------

guard-host:
ifeq ($(HOST),$(PROD_HOST))
ifndef PROD
	@echo "HOST=$(HOST) is the PRODUCTION unit. Pass PROD=1 to confirm." >&2; exit 1
endif
endif

deploy: guard-host ## Full deploy to HOST: RBF + engine + content
	$(DEPLOY)

deploy-engine: guard-host ## Engine binary + gmloader.json only
	$(DEPLOY) --engine-only --engine $(ENGINE)

deploy-rbf: guard-host ## Fetch the CI RBF for HEAD and deploy it (no content)
	$(DEPLOY) --fetch-rbf --no-content
