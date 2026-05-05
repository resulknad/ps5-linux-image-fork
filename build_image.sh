#!/bin/bash
set -e

export DOCKER_DEFAULT_PLATFORM=linux/amd64

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DISTRO="ubuntu2604"
KERNEL_SRC=""
CLEAN=false
IMG_SIZE=12000
KERNEL_ONLY=false
LOCAL=false
PATCHES_DIR_ARG=""
FORMAT=""
PATCHES_TOKEN=""

MULTI_DISTROS="ubuntu2604 ubuntu2404 arch alpine"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --distro <distro>   Distribution: ubuntu2604, ubuntu2404, arch, alpine, all (default: ubuntu2604)
  --kernel <path>     Kernel source directory (default: auto-clone to work/linux/)
  --img-size <MB>     Disk image size in MB (default: 12000, 32000 for --distro all)
  --clean             Remove all cached build artifacts and start from scratch
  --kernel-only       Build and package the kernel only, then exit
  --local             Skip repull/repatch, use existing kernel source
  --patches-dir <p>   Use this patches directory instead of cloning
  --format <fmt>      Package format: deb, arch, all (default: auto from distro)
  --patches-token <t> GitHub token for HTTPS patches repo access
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --distro)         DISTRO="$2";          shift 2 ;;
        --kernel)         KERNEL_SRC="$2";      shift 2 ;;
        --img-size)       IMG_SIZE="$2";        shift 2 ;;
        --clean)          CLEAN=true;           shift ;;
        --kernel-only)    KERNEL_ONLY=true;     shift ;;
        --local)          LOCAL=true;           shift ;;
        --patches-dir)    PATCHES_DIR_ARG="$2"; shift 2 ;;
        --format)         FORMAT="$2";          shift 2 ;;
        --patches-token)  PATCHES_TOKEN="$2";   shift 2 ;;
        -h|--help)        usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
LINUX_DEFAULT_DIR="$SCRIPT_DIR/work/linux"

PATCHES_REPO="git@github.com:resulknad/ps5-linux-patches.git"
PATCHES_BRANCH="v1.0"
PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches"

if [ -n "$PATCHES_DIR_ARG" ]; then
    PATCHES_DIR="$(cd "$PATCHES_DIR_ARG" && pwd)"
fi

if [ -z "$KERNEL_SRC" ]; then
    KERNEL_SRC="$LINUX_DEFAULT_DIR"
fi

KERNEL_OUT="$SCRIPT_DIR/linux-bin"
OUTPUT_DIR="$SCRIPT_DIR/output"
CHROOT_DIR="$SCRIPT_DIR/work/chroot"
CACHE_DIR="$SCRIPT_DIR/work/cache"
CCACHE_DIR="${CCACHE_DIR:-$SCRIPT_DIR/ccache}"
LOG_FILE="$SCRIPT_DIR/build.log"
DOCKER_NAME="ps5-build-$$"

if [ "$LOCAL" = true ] && [ -n "$PATCHES_DIR_ARG" ]; then
    echo "Error: --local and --patches-dir are mutually exclusive"; exit 1
fi
if [ "$LOCAL" = true ] && [ ! -d "$KERNEL_SRC/.git" ]; then
    echo "Error: kernel source not found at $KERNEL_SRC"; exit 1
fi

if [ "$DISTRO" = "all" ] && [ "$IMG_SIZE" = "12000" ]; then
    IMG_SIZE=32000
fi

if [ -z "$FORMAT" ]; then
    case "$DISTRO" in arch) FORMAT="arch" ;; all) FORMAT="all" ;; *) FORMAT="deb" ;; esac
fi

BUILD_PID=""

cleanup() {
    echo ""
    echo "Interrupted. Cleaning up..."
    docker kill "$DOCKER_NAME" 2>/dev/null || true
    [ -n "$BUILD_PID" ] && kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
    exit 130
}
trap cleanup INT TERM

SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

run_stage() {
    local name="$1"
    shift

    if [ "${CI:-}" = "true" ]; then
        echo "::group::$name"
        local rc=0
        "$@" || rc=$?
        echo "::endgroup::"
        [ $rc -ne 0 ] && { echo "::error::Build failed at: $name"; exit $rc; }
        return
    fi

    local status_msg="$name" spin_i=0
    local log_start
    log_start=$(wc -l < "$LOG_FILE")
    "$@" >> "$LOG_FILE" 2>&1 &
    BUILD_PID=$!
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        if (( spin_i % 10 == 0 )); then
            local new
            new=$(tail -n +$((log_start + 1)) "$LOG_FILE" 2>/dev/null \
                | grep -oP '(?<=^=== ).*(?= ===$)' | tail -1)
            [ -n "$new" ] && status_msg="$new"
        fi
        printf "\r  %s %-60s" "${SPIN_CHARS:spin_i%${#SPIN_CHARS}:1}" "$status_msg"
        spin_i=$((spin_i + 1))
        sleep 0.1
    done
    local rc=0
    wait "$BUILD_PID" || rc=$?
    BUILD_PID=""
    if [ $rc -eq 0 ]; then
        printf "\r  ✓ %-60s\n" "$name"
    else
        printf "\r  ✗ %-60s\n" "$status_msg"
        echo ""
        echo "Build failed at: $status_msg"
        echo "Logs: $LOG_FILE"
        echo "Try running with --clean to start fresh."
        exit 1
    fi
}

# --- Clean ---
if [ "$CLEAN" = true ]; then
    echo "Cleaning all build artifacts..."
    for dir in "$SCRIPT_DIR/work" "$KERNEL_OUT" "$SCRIPT_DIR/cache" "$OUTPUT_DIR"; do
        [ -d "$dir" ] && docker run --rm \
            -v "$(dirname "$dir")":/parent \
            alpine rm -rf "/parent/$(basename "$dir")"
    done
    echo "Done."
    echo ""
fi

# --- Auto-detect what can be skipped ---
SKIP_KERNEL=false
SKIP_CHROOT=false

case "$FORMAT" in
    arch) ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    all)  ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && \
          ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    *)    ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
esac

if [ "$DISTRO" = "all" ]; then
    SKIP_CHROOT=true
    for d in $MULTI_DISTROS; do
        [ -d "$SCRIPT_DIR/work/chroot-$d/bin" ] || SKIP_CHROOT=false
    done
else
    [ -d "$CHROOT_DIR/bin" ] && SKIP_CHROOT=true
fi

# --- Build plan summary ---
echo ""
echo "PS5 Linux Image Builder"
echo "======================="
if [ "$KERNEL_ONLY" = true ]; then
    echo "  Mode:         kernel only"
    echo "  Format:       $FORMAT"
else
    echo "  Distro:       $DISTRO"
    [ "$DISTRO" = "all" ] && echo "                ($MULTI_DISTROS)"
    echo "  Image size:   ${IMG_SIZE}MB"
fi
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
elif [ "$LOCAL" = true ]; then
    echo "  1. Kernel            build (local source)"
elif [ -d "$KERNEL_SRC/.git" ]; then
    echo "  1. Kernel            build (source cached)"
else
    echo "  1. Kernel            clone + build"
fi
if [ "$KERNEL_ONLY" = false ]; then
    if [ "$SKIP_CHROOT" = true ]; then
        echo "  2. Root filesystem   cached"
    else
        echo "  2. Root filesystem   build"
    fi
    echo "  3. Disk image        build"
fi
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
    if [ "$LOCAL" = true ]; then
        printf "  ✓ %-60s\n" "Kernel source (local, skipping repull)"
    elif [ ! -d "$KERNEL_SRC/.git" ]; then
        if [ -z "$PATCHES_DIR_ARG" ]; then
            REPO_URL="$PATCHES_REPO"
            [ -n "$PATCHES_TOKEN" ] && REPO_URL="${PATCHES_REPO/https:\/\//https:\/\/${PATCHES_TOKEN}@}"
            mkdir -p "$(dirname "$PATCHES_DIR")"
            if [ ! -d "$PATCHES_DIR/.git" ]; then
                run_stage "Clone ps5-linux-patches" \
                    git clone --depth 1 --branch "$PATCHES_BRANCH" "$REPO_URL" "$PATCHES_DIR"
            else
                run_stage "Update ps5-linux-patches" bash -c '
                    git -C "'"$PATCHES_DIR"'" fetch --depth 1 origin tag "'"$PATCHES_BRANCH"'"
                    git -C "'"$PATCHES_DIR"'" reset --hard "'"$PATCHES_BRANCH"'"'
            fi
        fi
        LINUX_TMP_DIR="${LINUX_DEFAULT_DIR}.tmp"
        for dir in "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"; do
            [ -d "$dir" ] && docker run --rm \
                -v "$(dirname "$dir")":/parent \
                alpine rm -rf "/parent/$(basename "$dir")"
        done
        LINUX_BRANCH="v$(grep -m1 "^# Linux/" "$PATCHES_DIR/.config" | grep -oP '\d+\.\d+(\.\d+)?')"
        run_stage "Clone kernel $LINUX_BRANCH" \
            git clone --branch "$LINUX_BRANCH" --depth 1 "$LINUX_REPO" "$LINUX_TMP_DIR"
        run_stage "Apply patches" bash -c '
            set -e; shopt -s nullglob
            patches=("'"$PATCHES_DIR"'"/*.patch)
            [ ${#patches[@]} -eq 0 ] && { echo "No .patch files found in '"$PATCHES_DIR"'"; exit 1; }
            for p in "${patches[@]}"; do
                echo "Applying $p"
                git -C "'"$LINUX_TMP_DIR"'" apply --exclude=Makefile "$p"
            done'
        run_stage "Copy kernel config" cp "$PATCHES_DIR/.config" "$LINUX_TMP_DIR/.config"
        mv "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"
        KERNEL_SRC="$LINUX_DEFAULT_DIR"
    else
        printf "  ✓ %-60s\n" "Kernel source (cached)"
    fi

    KERNEL_SRC="$(cd "$KERNEL_SRC" && pwd)"
    rm -f "$KERNEL_OUT"/*.deb "$KERNEL_OUT"/*.pkg.tar.zst

    run_stage "Build kernel builder image" \
        docker build -t ps5-kernel-builder -f "$SCRIPT_DIR/docker/kernel-builder/Dockerfile" "$SCRIPT_DIR"

    run_stage "Compile kernel" \
        docker run --rm --name "$DOCKER_NAME" \
            -v "$KERNEL_SRC":/src \
            -v "$KERNEL_OUT":/out \
            -v "$CCACHE_DIR":/ccache \
            ps5-kernel-builder

    ls "$KERNEL_OUT/staging/lib/modules/" | head -1 > "$KERNEL_OUT/VERSION"

    case "$FORMAT" in deb|all)
        run_stage "Package kernel (.deb)" \
            docker run --rm --name "$DOCKER_NAME" \
                -v "$KERNEL_SRC":/src \
                -v "$KERNEL_OUT":/out \
                -v "$CCACHE_DIR":/ccache \
                ps5-kernel-builder \
                bash -c '
set -e
make -j$(nproc) DPKG_FLAGS=-d bindeb-pkg

VER=$(dpkg-deb -f "$(ls /linux-image-[0-9]*.deb | grep -v dbg | head -1)" Version)
ARCH=$(dpkg-deb -f "$(ls /linux-image-[0-9]*.deb | grep -v dbg | head -1)" Architecture)
KVER=$(ls /src/debian/linux-image-[0-9]*/lib/modules/ 2>/dev/null | head -1)

TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/DEBIAN"
for deb in $(ls /linux-image-[0-9]*.deb /linux-headers-*.deb /linux-libc-dev_*.deb 2>/dev/null | grep -v -- '-dbg_'); do
    dpkg-deb -x "$deb" "$TMPDIR"
done

cat > "$TMPDIR/DEBIAN/control" << CTRL
Package: linux-ps5
Version: $VER
Architecture: $ARCH
Maintainer: PS5 Linux
Provides: linux-image, linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Conflicts: linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Replaces: linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Description: PS5 Linux kernel $KVER (image + headers + libc-dev)
CTRL

dpkg-deb --build --root-owner-group "$TMPDIR" "/out/linux-ps5_${VER}_${ARCH}.deb"
'
    esac

    case "$FORMAT" in arch|all)
        run_stage "Build arch packager image" \
            docker build -t ps5-kernel-packager-arch \
                -f "$SCRIPT_DIR/docker/kernel-builder-arch/Dockerfile" "$SCRIPT_DIR"
        run_stage "Package kernel (.pkg.tar.zst)" \
            docker run --rm --name "$DOCKER_NAME" \
                -v "$KERNEL_OUT":/out \
                ps5-kernel-packager-arch
    esac
fi

if [ "$KERNEL_ONLY" = true ]; then
    KVER=$(cat "$KERNEL_OUT/VERSION" 2>/dev/null || echo "unknown")
    echo ""
    echo "Done! Kernel $KVER packages in $KERNEL_OUT/"
    exit 0
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
