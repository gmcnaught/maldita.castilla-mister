#!/usr/bin/env bash
# Maldita Castilla MiSTer HPS wrapper build driver.
#
# Forked from sonic-mania-mister/tools/mister-wrapper/build-hps.sh. Produces
# the ARM hard-float ELF MiSTer_Maldita that sits between the MiSTer menu
# and the gmloader engine binary. Vendors the pinned Main_MiSTer upstream on
# demand, then layers the Maldita Castilla overlay (see
# tools/mister-wrapper/main-mister-overlay.files) and applies the
# (currently no-op) menu.cpp patch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_DIR="${ROOT_DIR}/vendor/Main_MiSTer"
UPSTREAM_FILE="${ROOT_DIR}/vendor/Main_MiSTer.UPSTREAM.md"
OVERLAY_MANIFEST="${ROOT_DIR}/tools/mister-wrapper/main-mister-overlay.files"
BUILD_MANIFEST="${ROOT_DIR}/tools/mister-wrapper/Makefile.full.maldita"
MENU_PATCH="${ROOT_DIR}/tools/mister-wrapper/main-mister-full-menu.patch"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/build/mister-wrapper-hps}"
BUILD_SRC_DIR="${OUTPUT_DIR}/src"
TOOLCHAIN_PREFIX="${MISTER_TOOLCHAIN_PREFIX:-arm-none-linux-gnueabihf}"
CC_BIN="${TOOLCHAIN_PREFIX}-gcc"
LD_BIN="${TOOLCHAIN_PREFIX}-ld"
STRIP_BIN="${TOOLCHAIN_PREFIX}-strip"
UPSTREAM_URL="${MISTER_WRAPPER_HPS_UPSTREAM_URL:-https://github.com/MiSTer-devel/Main_MiSTer.git}"
UPSTREAM_COMMIT="${MISTER_WRAPPER_HPS_UPSTREAM_COMMIT:-3380931329b8acb442bd3d35a24d89f88641b7cf}"
# Native debian:bullseye-slim + Debian's own arm-linux-gnueabihf cross
# toolchain (see tools/mister-wrapper/Dockerfile.wrapper), mirroring the
# gmloader-next / solarus-mister recipe. This replaces the upstream
# .devcontainer, which downloads an x86_64-hosted ARM-vendor toolchain and
# therefore forces `--platform linux/amd64` (full QEMU emulation on arm64
# hosts). The Debian cross-toolchain's binary prefix differs from the
# Makefile's default BASE (arm-none-linux-gnueabihf, the ARM-vendor prefix),
# so the docker build path overrides BASE explicitly (see run_make_in_docker).
DOCKER_CONTEXT_DIR="${ROOT_DIR}/tools/mister-wrapper"
DOCKERFILE_PATH="${DOCKER_CONTEXT_DIR}/Dockerfile.wrapper"
DOCKER_IMAGE="${MISTER_WRAPPER_HPS_IMAGE:-maldita-mister-wrapper-hps}"
DOCKER_TOOLCHAIN_PREFIX="${MISTER_WRAPPER_HPS_DOCKER_TOOLCHAIN_PREFIX:-arm-linux-gnueabihf}"
CONTAINER_ROOT="${MISTER_WRAPPER_HPS_CONTAINER_ROOT:-/workspaces/maldita-castilla-mister}"
CONTAINER_BUILD_SRC_DIR="${CONTAINER_ROOT}/build/mister-wrapper-hps/src"

usage() {
    cat <<EOF
Usage:
  tools/mister-wrapper/build-hps.sh --check-env
  tools/mister-wrapper/build-hps.sh --prepare-source
  tools/mister-wrapper/build-hps.sh --build-image
  tools/mister-wrapper/build-hps.sh

Purpose:
  Build the Main_MiSTer-derived HPS wrapper binary MiSTer_Maldita from the
  pinned full upstream tree plus the local Maldita Castilla overlay files.

Planned output:
  ${OUTPUT_DIR}/MiSTer_Maldita

Pinned source:
  ${UPSTREAM_URL} @ ${UPSTREAM_COMMIT}

Status:
  Full-source fetch + overlay build entrypoint with local-toolchain or Docker fallback.
EOF
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

have_local_toolchain() {
    have_command "${CC_BIN}" && have_command "${LD_BIN}" && have_command "${STRIP_BIN}"
}

require_base_host_tools() {
    have_command rsync || { echo "missing required command: rsync" >&2; return 1; }
    have_command git || { echo "missing required command: git" >&2; return 1; }
    [ -d "${SOURCE_DIR}" ] || { echo "missing pinned Main_MiSTer source: ${SOURCE_DIR}" >&2; return 1; }
    [ -f "${BUILD_MANIFEST}" ] || { echo "missing wrapper build manifest: ${BUILD_MANIFEST}" >&2; return 1; }
    [ -f "${OVERLAY_MANIFEST}" ] || { echo "missing Main_MiSTer overlay keep-list: ${OVERLAY_MANIFEST}" >&2; return 1; }
    [ -f "${MENU_PATCH}" ] || { echo "missing Main_MiSTer menu patch: ${MENU_PATCH}" >&2; return 1; }
}

docker_available() {
    have_command docker && [ -f "${DOCKERFILE_PATH}" ]
}

selected_build_mode() {
    if have_local_toolchain && have_command make; then
        echo "local"
        return 0
    fi

    if docker_available; then
        echo "docker"
        return 0
    fi

    echo "missing"
    return 1
}

# Guard for the one hazard this overlay shape introduces.
#
# vendor/Main_MiSTer/scheduler.cpp is a COPY of upstream's, carrying one
# inserted call. If upstream changes that file and nobody re-vendors it, the
# build silently ships a stale scheduler that looks fine and is not — the worst
# possible failure for a file whose whole job is the FPGA-readiness contract.
#
# The invariant that catches it is simple: our copy must be upstream plus
# ADDED lines, never a changed or removed one. A drifted upstream shows up as a
# removal in this diff and fails the build here, where the fix is obvious,
# rather than on the device, where it is not.
verify_overlay_is_additive() {
    local rc=0 f upstream_tmp
    upstream_tmp="$(mktemp -d)"
    while read -r f; do
        [ -n "${f}" ] || continue
        # Only files that also exist upstream can drift; ours (maldita_*) cannot.
        git -C "${BUILD_SRC_DIR}" cat-file -e "${UPSTREAM_COMMIT}:${f}" 2>/dev/null || continue
        git -C "${BUILD_SRC_DIR}" show "${UPSTREAM_COMMIT}:${f}" > "${upstream_tmp}/base"
        if diff "${upstream_tmp}/base" "${SOURCE_DIR}/${f}" | grep -q '^<'; then
            echo "OVERLAY DRIFT: vendor/Main_MiSTer/${f} changes or drops upstream lines." >&2
            echo "  The overlay must be upstream + additions only. Re-vendor it from" >&2
            echo "  ${UPSTREAM_COMMIT} and re-apply the local insert:" >&2
            diff "${upstream_tmp}/base" "${SOURCE_DIR}/${f}" | grep '^<' | head -20 >&2
            rc=1
        fi
    done < "${OVERLAY_MANIFEST}"
    rm -rf "${upstream_tmp}"
    return "${rc}"
}

prepare_source() {
    mkdir -p "${OUTPUT_DIR}"
    rm -rf "${BUILD_SRC_DIR}"

    git clone --filter=blob:none --no-checkout "${UPSTREAM_URL}" "${BUILD_SRC_DIR}"
    git -C "${BUILD_SRC_DIR}" checkout "${UPSTREAM_COMMIT}"
    verify_overlay_is_additive
    rsync -a --files-from="${OVERLAY_MANIFEST}" "${SOURCE_DIR}/" "${BUILD_SRC_DIR}/"
    # Apply menu patch. The Maldita Castilla patch file is currently a no-op
    # (comments only, no hunks); --allow-empty lets git apply succeed without
    # modifying menu.cpp. Upstream main.cpp is BUILT (the Makefile no longer
    # filters it out) -- the wrapper entry is one call inserted into
    # scheduler.cpp, see vendor/Main_MiSTer/maldita_hook.cpp.
    git -C "${BUILD_SRC_DIR}" apply --allow-empty --whitespace=nowarn "${MENU_PATCH}"
    cp "${BUILD_MANIFEST}" "${BUILD_SRC_DIR}/Makefile.maldita"
}

check_compiler_stack() {
    command -v "${CC_BIN}" >/dev/null 2>&1 || { echo "missing required compiler: ${CC_BIN}" >&2; return 1; }
    command -v "${LD_BIN}" >/dev/null 2>&1 || { echo "missing required linker: ${LD_BIN}" >&2; return 1; }
    command -v "${STRIP_BIN}" >/dev/null 2>&1 || { echo "missing required stripper: ${STRIP_BIN}" >&2; return 1; }
}

build_docker_image() {
    docker build \
        -t "${DOCKER_IMAGE}" \
        -f "${DOCKERFILE_PATH}" \
        "${DOCKER_CONTEXT_DIR}"
}

run_make_in_docker() {
    # Native arm64 (no --platform): the Debian arm-linux-gnueabihf
    # cross-toolchain baked into DOCKER_IMAGE targets armhf regardless of
    # host arch, so this never touches QEMU. BASE is overridden to the
    # Debian prefix -- the Makefile default (arm-none-linux-gnueabihf) is the
    # ARM-vendor prefix, which this image does not install.
    docker run --rm \
        -u "$(id -u):$(id -g)" \
        -v "${ROOT_DIR}:${CONTAINER_ROOT}" \
        -w "${CONTAINER_ROOT}" \
        "${DOCKER_IMAGE}" \
        make -C "${CONTAINER_BUILD_SRC_DIR}" -f Makefile.maldita BASE="${DOCKER_TOOLCHAIN_PREFIX}" -j"$(nproc)"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ "${1:-}" = "--check-env" ]; then
    require_base_host_tools || exit 1
    mkdir -p "${OUTPUT_DIR}"
    mode="$(selected_build_mode || true)"
    if [ "${mode}" = "local" ]; then
        check_compiler_stack || exit 1
        echo "build_mode=local"
    elif [ "${mode}" = "docker" ]; then
        echo "build_mode=docker"
        echo "docker_image=${DOCKER_IMAGE}"
        echo "docker_toolchain_prefix=${DOCKER_TOOLCHAIN_PREFIX}"
    else
        echo "missing required toolchain: install ${TOOLCHAIN_PREFIX} on PATH or use Docker with ${DOCKERFILE_PATH}" >&2
        exit 1
    fi
    echo "HPS wrapper build scaffold is present."
    echo "source_dir=${SOURCE_DIR}"
    echo "overlay_manifest=${OVERLAY_MANIFEST}"
    echo "build_manifest=${BUILD_MANIFEST}"
    echo "menu_patch=${MENU_PATCH}"
    echo "upstream_url=${UPSTREAM_URL}"
    echo "upstream_commit=${UPSTREAM_COMMIT}"
    if [ -f "${UPSTREAM_FILE}" ]; then
        echo "upstream_metadata=${UPSTREAM_FILE}"
    fi
    echo "toolchain_prefix=${TOOLCHAIN_PREFIX}"
    echo "planned_output=${OUTPUT_DIR}/MiSTer_Maldita"
    exit 0
fi

if [ "${1:-}" = "--prepare-source" ]; then
    require_base_host_tools || exit 1
    prepare_source
    echo "prepared_source=${BUILD_SRC_DIR}"
    echo "prepared_manifest=${BUILD_SRC_DIR}/Makefile.maldita"
    exit 0
fi

if [ "${1:-}" = "--build-image" ]; then
    docker_available || { echo "docker build prerequisites missing: docker or ${DOCKERFILE_PATH}" >&2; exit 1; }
    build_docker_image
    echo "docker_image=${DOCKER_IMAGE}"
    exit 0
fi

require_base_host_tools || exit 1

prepare_source
mode="$(selected_build_mode || true)"
if [ "${mode}" = "local" ]; then
    command -v make >/dev/null 2>&1 || { echo "missing required command: make" >&2; exit 1; }
    check_compiler_stack || exit 1
    make -C "${BUILD_SRC_DIR}" -f Makefile.maldita BASE="${TOOLCHAIN_PREFIX}"
elif [ "${mode}" = "docker" ]; then
    build_docker_image
    run_make_in_docker
else
    echo "missing required toolchain: install ${TOOLCHAIN_PREFIX} on PATH or use Docker with ${DOCKERFILE_PATH}" >&2
    exit 1
fi

cp "${BUILD_SRC_DIR}/bin/MiSTer_Maldita" "${OUTPUT_DIR}/MiSTer_Maldita"
echo "build_mode=${mode}"
echo "built_output=${OUTPUT_DIR}/MiSTer_Maldita"
