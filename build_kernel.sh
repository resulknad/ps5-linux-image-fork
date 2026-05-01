#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/build-common.sh
source "$SCRIPT_DIR/lib/build-common.sh"

LOCAL=false
PATCHES_DIR_ARG=""
FORMAT="deb"
CLEAN=false
PATCHES_TOKEN=""

PATCHES_REPO="https://github.com/resulknad/ps5-linux-patches.git"
PATCHES_BRANCH="v1.0"
PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches"
KERNEL_SRC="$SCRIPT_DIR/work/linux"
KERNEL_OUT="$SCRIPT_DIR/linux-bin"
CCACHE_DIR="$SCRIPT_DIR/cache/ccache"
LOG_FILE="$SCRIPT_DIR/build.log"
DOCKER_NAME="ps5-kernel-$$"
BUILD_PID=""

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --local              Rebuild using existing work/linux (skip repull and repatch)
  --patches-dir <path> Use this patches directory instead of cloning
  --format <fmt>       Package format: deb, arch, all (default: deb)
  --patches-token <t>  GitHub token for HTTPS access to the patches repo
  --clean              Remove kernel source and packages before building
  -h, --help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --local)          LOCAL=true;              shift ;;
        --patches-dir)    PATCHES_DIR_ARG="$2";    shift 2 ;;
        --format)         FORMAT="$2";             shift 2 ;;
        --patches-token)  PATCHES_TOKEN="$2";      shift 2 ;;
        --clean)          CLEAN=true;              shift ;;
        -h|--help)        usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

trap cleanup INT TERM

if [ "$LOCAL" = true ] && [ -n "$PATCHES_DIR_ARG" ]; then
    echo "Error: --local and --patches-dir are mutually exclusive."
    exit 1
fi

if [ "$LOCAL" = true ] && [ ! -d "$KERNEL_SRC/.git" ]; then
    echo "Error: --local requires work/linux to exist. Run without --local first."
    exit 1
fi

if [ "$CLEAN" = true ]; then
    echo "Cleaning kernel build artifacts..."
    for dir in "$KERNEL_SRC" "$KERNEL_OUT"; do
        if [ -d "$dir" ]; then
            docker run --rm --privileged -v "$dir":/clean alpine sh -c 'rm -rf /clean/*'
            rmdir "$dir" 2>/dev/null || true
        fi
    done
    rm -rf "$CCACHE_DIR"
    echo "Done."
    echo ""
fi

mkdir -p "$KERNEL_OUT" "$CCACHE_DIR"
: > "$LOG_FILE"

echo ""
echo "PS5 Kernel Builder"
echo "=================="
echo "  Format:  $FORMAT"
if [ "$LOCAL" = true ]; then
    echo "  Mode:    local (skip repull/repatch)"
elif [ -n "$PATCHES_DIR_ARG" ]; then
    echo "  Mode:    repatch using $PATCHES_DIR_ARG"
else
    echo "  Mode:    repull + repatch ($PATCHES_BRANCH)"
fi
echo "  Logs:    $LOG_FILE"
echo ""

# --- Step 1: Prepare kernel source ---
if [ "$LOCAL" = true ]; then
    printf "  ✓ %-60s\n" "Kernel source (local, skipping repull)"
else
    if [ -n "$PATCHES_DIR_ARG" ]; then
        PATCHES_DIR="$(cd "$PATCHES_DIR_ARG" && pwd)"
        printf "  ✓ %-60s\n" "Patches: $PATCHES_DIR"
    else
        stage_kernel_pull_patches "$PATCHES_DIR" "$PATCHES_REPO" "$PATCHES_TOKEN" "$PATCHES_BRANCH"
    fi
    stage_kernel_clone_and_patch "$KERNEL_SRC" "$PATCHES_DIR"
fi

KERNEL_SRC="$(cd "$KERNEL_SRC" && pwd)"

# --- Step 2: Compile ---
rm -f "$KERNEL_OUT"/*.deb "$KERNEL_OUT"/*.pkg.tar.zst
stage_kernel_compile "$KERNEL_SRC" "$KERNEL_OUT" "$CCACHE_DIR"

# --- Step 3: Package ---
case "$FORMAT" in
    deb)
        stage_kernel_package_deb "$KERNEL_SRC" "$KERNEL_OUT" "$CCACHE_DIR"
        ;;
    arch)
        stage_kernel_package_arch "$KERNEL_OUT"
        ;;
    all)
        stage_kernel_package_deb "$KERNEL_SRC" "$KERNEL_OUT" "$CCACHE_DIR"
        stage_kernel_package_arch "$KERNEL_OUT"
        ;;
    *)
        echo "Unknown format: $FORMAT (use deb, arch, or all)"
        exit 1
        ;;
esac

KVER=$(cat "$KERNEL_OUT/VERSION" 2>/dev/null || echo "unknown")
echo ""
echo "Done! Kernel $KVER packages in $KERNEL_OUT/"
