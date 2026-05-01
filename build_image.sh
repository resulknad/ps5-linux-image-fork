#!/bin/bash
set -e

export DOCKER_DEFAULT_PLATFORM=linux/amd64

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/build-common.sh
source "$SCRIPT_DIR/lib/build-common.sh"

DISTRO="ubuntu2604"
KERNEL_SRC=""
CLEAN=false
IMG_SIZE=12000

MULTI_DISTROS="ubuntu2604 ubuntu2404 arch alpine"

usage() {
    echo "Usage: $0 [--distro <distro>] [--kernel <path>] [--img-size <MB>] [--clean]"
    echo ""
    echo "Options:"
    echo "  --distro     Distribution to build: ubuntu2604, ubuntu2404, arch, alpine, all (default: ubuntu2604)"
    echo "  --kernel     Path to kernel source directory (default: auto-clone to work/linux/)"
    echo "  --img-size   Disk image size in MB (default: 12000, 32000 for --distro all)"
    echo "  --clean      Remove all cached build artifacts and start from scratch"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --distro)    DISTRO="$2";      shift 2 ;;
        --kernel)    KERNEL_SRC="$2";  shift 2 ;;
        --img-size)  IMG_SIZE="$2";    shift 2 ;;
        --clean)     CLEAN=true;       shift ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

PATCHES_REPO="git@github.com:resulknad/ps5-linux-patches.git"
PATCHES_BRANCH="v1.0"
PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches"

LINUX_DEFAULT_DIR="$SCRIPT_DIR/work/linux"
if [ -z "$KERNEL_SRC" ]; then
    KERNEL_SRC="$LINUX_DEFAULT_DIR"
fi

KERNEL_OUT="$SCRIPT_DIR/linux-bin"
OUTPUT_DIR="$SCRIPT_DIR/output"
CHROOT_DIR="$SCRIPT_DIR/work/chroot"
CACHE_DIR="$SCRIPT_DIR/work/cache"
CCACHE_DIR="${CCACHE_DIR:-$SCRIPT_DIR/cache/ccache}"
LOG_FILE="$SCRIPT_DIR/build.log"
DOCKER_NAME="ps5-build-$$"
BUILD_PID=""

if [ "$DISTRO" = "all" ] && [ "$IMG_SIZE" = "12000" ]; then
    IMG_SIZE=32000
fi

trap cleanup INT TERM

# --- Clean ---
if [ "$CLEAN" = true ]; then
    echo "Cleaning all build artifacts..."
    # Build artifacts contain root-owned files from Docker — use a container to remove them
    for dir in "$SCRIPT_DIR/work" "$KERNEL_OUT" "$SCRIPT_DIR/cache"; do
        if [ -d "$dir" ]; then
            docker run --rm --privileged -v "$dir":/clean alpine sh -c 'rm -rf /clean/*'
            rmdir "$dir" 2>/dev/null || true
        fi
    done
    rm -rf "$OUTPUT_DIR"
    echo "Done."
    echo ""
fi

# --- Auto-detect what can be skipped ---
SKIP_KERNEL=false
SKIP_CHROOT=false

# Kernel packages already built?
if [ "$DISTRO" = "arch" ]; then
    ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true
elif [ "$DISTRO" = "all" ]; then
    ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && \
    ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true
else
    ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true
fi

# Chroot already populated?
if [ "$DISTRO" = "all" ]; then
    SKIP_CHROOT=true
    for d in $MULTI_DISTROS; do
        [ -d "$SCRIPT_DIR/work/chroot-$d/bin" ] || SKIP_CHROOT=false
    done
else
    [ -d "$CHROOT_DIR/bin" ] && SKIP_CHROOT=true
fi

if [ "$DISTRO" = "arch" ]; then
    PKG_EXT="pkg.tar.zst"
else
    PKG_EXT="deb"
fi

# --- Build plan summary ---
echo ""
echo "PS5 Linux Image Builder"
echo "======================="
echo "  Distro:       $DISTRO"
if [ "$DISTRO" = "all" ]; then
    echo "                ($MULTI_DISTROS)"
fi
echo "  Image size:   ${IMG_SIZE}MB"
if [ -f "$PATCHES_DIR/.config" ]; then
    LINUX_BRANCH="v$(grep -m1 "^# Linux/" "$PATCHES_DIR/.config" | grep -oP '\d+\.\d+(\.\d+)?')"
    echo "  Kernel:       $LINUX_BRANCH"
else
    echo "  Kernel:       (will fetch)"
fi
echo "  Kernel src:   $KERNEL_SRC"
echo ""
echo "Stages:"
if [ "$SKIP_KERNEL" = true ]; then
    echo "  1. Kernel            cached"
else
    if [ -d "$KERNEL_SRC/.git" ]; then
        echo "  1. Kernel            build (source cached)"
    else
        echo "  1. Kernel            clone + build"
    fi
fi
if [ "$SKIP_CHROOT" = true ]; then
    echo "  2. Root filesystem   cached"
else
    echo "  2. Root filesystem   build"
fi
echo "  3. Disk image        build"
echo ""
echo "Logs: $LOG_FILE"
echo ""

: > "$LOG_FILE"

# --- Setup directories ---
mkdir -p "$KERNEL_OUT" "$OUTPUT_DIR" "$CHROOT_DIR" "$CACHE_DIR" "$CCACHE_DIR"
if [ "$DISTRO" = "all" ]; then
    for d in $MULTI_DISTROS; do
        mkdir -p "$SCRIPT_DIR/work/chroot-$d"
    done
fi

# --- Step 1: Kernel ---
if [ "$SKIP_KERNEL" = true ]; then
    printf "  ✓ %-60s\n" "Kernel packages (cached)"
else
    if [ ! -d "$KERNEL_SRC/.git" ]; then
        stage_kernel_pull_patches "$PATCHES_DIR" "$PATCHES_REPO" "" "$PATCHES_BRANCH"
        stage_kernel_clone_and_patch "$KERNEL_SRC" "$PATCHES_DIR"
    else
        printf "  ✓ %-60s\n" "Kernel source (cached)"
    fi

    KERNEL_SRC="$(cd "$KERNEL_SRC" && pwd)"
    rm -f "$KERNEL_OUT"/*.$PKG_EXT

    stage_kernel_compile "$KERNEL_SRC" "$KERNEL_OUT" "$CCACHE_DIR"

    if [ "$DISTRO" = "all" ]; then
        stage_kernel_package_deb "$KERNEL_SRC" "$KERNEL_OUT" "$CCACHE_DIR"
        stage_kernel_package_arch "$KERNEL_OUT"
    elif [ "$DISTRO" = "arch" ]; then
        stage_kernel_package_arch "$KERNEL_OUT"
    else
        stage_kernel_package_deb "$KERNEL_SRC" "$KERNEL_OUT" "$CCACHE_DIR"
    fi
fi

# --- Step 2: Build distribution image ---
run_stage "Build image builder image" \
    docker build -t ps5-image-builder -f "$SCRIPT_DIR/docker/image-builder/Dockerfile" "$SCRIPT_DIR"

if [ "$DISTRO" = "all" ]; then
    DOCKER_ARGS=(
        docker run --rm --privileged --name "$DOCKER_NAME"
        --entrypoint /entrypoint-multi.sh
        -v "$SCRIPT_DIR":/repo:ro
        -v "$KERNEL_OUT":/kernel-debs:ro
        -v "$OUTPUT_DIR":/output
        -v "$CACHE_DIR":/build/cache
        -e IMG_SIZE="$IMG_SIZE"
        -e SKIP_CHROOT="$SKIP_CHROOT"
        -e "DISTROS=$MULTI_DISTROS"
    )
    for d in $MULTI_DISTROS; do
        DOCKER_ARGS+=(-v "$SCRIPT_DIR/work/chroot-$d:/build/chroot-$d")
    done
    DOCKER_ARGS+=(ps5-image-builder)

    run_stage "Build multi-distro image (${IMG_SIZE}MB)" "${DOCKER_ARGS[@]}"

    IMG_PATH="$OUTPUT_DIR/ps5-multi.img"
else
    run_stage "Build $DISTRO image (${IMG_SIZE}MB)" \
        docker run --rm --privileged --name "$DOCKER_NAME" \
            -v "$SCRIPT_DIR":/repo:ro \
            -v "$KERNEL_OUT":/kernel-debs:ro \
            -v "$OUTPUT_DIR":/output \
            -v "$CHROOT_DIR":/build/chroot \
            -v "$CACHE_DIR":/build/cache \
            -e DISTRO="$DISTRO" \
            -e IMG_SIZE="$IMG_SIZE" \
            -e SKIP_CHROOT="$SKIP_CHROOT" \
            ps5-image-builder

    IMG_PATH="$OUTPUT_DIR/ps5-${DISTRO}.img"
fi

echo ""
echo "Done! Image: $IMG_PATH"
echo "Flash: sudo dd if=$IMG_PATH of=/dev/sdX bs=4M status=progress"
