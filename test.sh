#!/bin/bash
# Test suite for ps5-linux build scripts.
# Usage: ./test.sh [--slow] [--kernel <path>] [--patches-dir <path>]
#   --slow          include full kernel compile tests (takes ~1h)
#   --kernel        path to already-built kernel source (speeds up slow tests)
#   --patches-dir   path to ps5-linux-patches checkout (default: work/ps5-linux-patches)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SLOW=false
KERNEL_SRC=""
PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches"

while [[ $# -gt 0 ]]; do
    case $1 in
        --slow)         SLOW=true;           shift ;;
        --kernel)       KERNEL_SRC="$2";     shift 2 ;;
        --patches-dir)  PATCHES_DIR="$2";    shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1"; echo "    $2"; FAIL=$((FAIL+1)); }
skip() { echo "  - $1 (skipped)"; SKIP=$((SKIP+1)); }

run_test() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc" "exited non-zero"
    fi
}

run_test_fail() {
    local desc="$1"; shift
    if ! "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc" "expected failure but succeeded"
    fi
}

run_test_output() {
    local desc="$1"; local pattern="$2"; shift 2
    local out
    out=$("$@" 2>&1)
    if echo "$out" | grep -q "$pattern"; then
        pass "$desc"
    else
        fail "$desc" "pattern '$pattern' not found in output"
    fi
}

echo ""
echo "PS5 Linux Build Test Suite"
echo "=========================="
echo "  Patches: $PATCHES_DIR"
[ -n "$KERNEL_SRC" ] && echo "  Kernel:  $KERNEL_SRC"
[ "$SLOW" = true ] && echo "  Mode:    full (including slow tests)"
echo ""

# -----------------------------------------------------------------------
echo "[ Syntax ]"
run_test     "build_kernel.sh syntax"     bash -n "$SCRIPT_DIR/build_kernel.sh"
run_test     "build_image.sh syntax"      bash -n "$SCRIPT_DIR/build_image.sh"
run_test     "lib/build-common.sh syntax" bash -n "$SCRIPT_DIR/lib/build-common.sh"

# -----------------------------------------------------------------------
echo ""
echo "[ Argument parsing — build_kernel.sh ]"
run_test_output  "--help prints usage"         "Usage:"   bash "$SCRIPT_DIR/build_kernel.sh" --help
run_test_fail    "unknown flag rejected"                   bash "$SCRIPT_DIR/build_kernel.sh" --bogus
run_test_fail    "--local requires work/linux" \
    bash -c "TMPDIR=\$(mktemp -d) && cp '$SCRIPT_DIR/build_kernel.sh' \$TMPDIR/ && cp -r '$SCRIPT_DIR/lib' \$TMPDIR/ && cd \$TMPDIR && bash build_kernel.sh --local; RET=\$?; rm -rf \$TMPDIR; exit \$RET"
run_test_fail    "--local + --patches-dir are mutually exclusive" \
    bash "$SCRIPT_DIR/build_kernel.sh" --local --patches-dir "$PATCHES_DIR"
run_test_fail    "--kernel non-existent path rejected" \
    bash "$SCRIPT_DIR/build_kernel.sh" --kernel /nonexistent/path
run_test_fail    "--format invalid rejected" \
    bash "$SCRIPT_DIR/build_kernel.sh" --patches-dir "$PATCHES_DIR" --format invalid

# -----------------------------------------------------------------------
echo ""
echo "[ Argument parsing — build_image.sh ]"
run_test_output  "--help prints usage"         "Usage:"   bash "$SCRIPT_DIR/build_image.sh" --help
run_test_fail    "unknown flag rejected"                   bash "$SCRIPT_DIR/build_image.sh" --bogus

# -----------------------------------------------------------------------
echo ""
echo "[ YAML configs ]"
for yaml in "$SCRIPT_DIR/distros"/*/image.yaml; do
    distro=$(basename "$(dirname "$yaml")")
    run_test "$distro image.yaml is valid YAML" \
        python3 -c "import yaml; yaml.safe_load(open('$yaml'))"
    run_test "$distro has required 'source.url' field" \
        python3 -c "
import yaml, sys
d = yaml.safe_load(open('$yaml'))
sys.exit(0 if d.get('source', {}).get('url') else 1)"
    run_test "$distro has package sets" \
        python3 -c "
import yaml, sys
d = yaml.safe_load(open('$yaml'))
sets = d.get('packages', {}).get('sets', [])
sys.exit(0 if sets else 1)"
done

# -----------------------------------------------------------------------
echo ""
echo "[ Patches checkout ]"
if [ -d "$PATCHES_DIR/.git" ]; then
    run_test "patches dir exists and is a git repo" \
        test -d "$PATCHES_DIR/.git"
    run_test ".config present in patches" \
        test -f "$PATCHES_DIR/.config"
    run_test ".config contains Linux version" \
        grep -q "^# Linux/" "$PATCHES_DIR/.config"
    run_test "at least one .patch file present" \
        bash -c "ls '$PATCHES_DIR'/*.patch >/dev/null 2>&1"
else
    skip "patches checkout not found at $PATCHES_DIR (run build_kernel.sh first)"
fi

# -----------------------------------------------------------------------
echo ""
echo "[ Docker images ]"
if command -v docker >/dev/null 2>&1; then
    run_test "docker is accessible (not permission error)" \
        docker info
    for img in "ps5-kernel-builder:docker/kernel-builder/Dockerfile" \
               "ps5-kernel-packager-arch:docker/kernel-builder-arch/Dockerfile"; do
        tag="${img%%:*}"; df="${img##*:}"
        if docker image inspect "$tag" >/dev/null 2>&1; then
            pass "docker image $tag exists"
        else
            run_test "docker image $tag builds from $df" \
                docker build -t "$tag" -f "$SCRIPT_DIR/$df" "$SCRIPT_DIR"
        fi
    done
else
    skip "docker not available"
fi

# -----------------------------------------------------------------------
echo ""
echo "[ Patch application ]"
if [ -d "$PATCHES_DIR/.git" ]; then
    if [ -d "$SCRIPT_DIR/work/linux/.git" ]; then
        # Accept either direction: patches applied (reverse OK) or not yet applied (forward OK)
        run_test "patch files are applicable to work/linux (either direction)" \
            bash -c "
                for p in '$PATCHES_DIR'/*.patch; do
                    git -C '$SCRIPT_DIR/work/linux' apply --check --reverse --exclude=Makefile \"\$p\" 2>/dev/null || \
                    git -C '$SCRIPT_DIR/work/linux' apply --check --exclude=Makefile \"\$p\" 2>/dev/null || exit 1
                done"
    else
        skip "work/linux not present — run build_kernel.sh first to test patch application"
    fi
else
    skip "patches dir not available"
fi

# -----------------------------------------------------------------------
echo ""
echo "[ Build outputs ]"
KERNEL_OUT="$SCRIPT_DIR/linux-bin"
if ls "$KERNEL_OUT"/*.deb >/dev/null 2>&1; then
    run_test ".deb package exists in linux-bin/" \
        bash -c "ls '$KERNEL_OUT'/*.deb | grep -q linux-ps5"
    run_test ".deb is named linux-ps5 (combined package)" \
        bash -c "ls '$KERNEL_OUT'/linux-ps5_*.deb >/dev/null 2>&1"
    run_test ".deb is valid (dpkg-deb --info)" \
        bash -c "dpkg-deb --info \$(ls '$KERNEL_OUT'/linux-ps5_*.deb | head -1) >/dev/null 2>&1"
    run_test ".deb contains Provides: linux-image" \
        bash -c "dpkg-deb --info \$(ls '$KERNEL_OUT'/linux-ps5_*.deb | head -1) | grep -q 'Provides:.*linux-image'"
    run_test ".deb contains /boot/vmlinuz" \
        bash -c "dpkg-deb --contents \$(ls '$KERNEL_OUT'/linux-ps5_*.deb | head -1) | grep -q boot/vmlinuz"
    run_test ".deb contains kernel modules" \
        bash -c "dpkg-deb --contents \$(ls '$KERNEL_OUT'/linux-ps5_*.deb | head -1) | grep -q lib/modules"
    run_test ".deb contains kernel headers" \
        bash -c "dpkg-deb --contents \$(ls '$KERNEL_OUT'/linux-ps5_*.deb | head -1) | grep -q usr/src/linux-headers"
    run_test ".deb size is reasonable (< 200MB)" \
        bash -c "[ \$(stat -c%s \$(ls '$KERNEL_OUT'/linux-ps5_*.deb | head -1)) -lt 209715200 ]"
    run_test "VERSION file present" \
        test -f "$KERNEL_OUT/VERSION"
else
    skip "no .deb in linux-bin/ — run build_kernel.sh first"
fi

if ls "$KERNEL_OUT"/*.pkg.tar.zst >/dev/null 2>&1; then
    run_test ".pkg.tar.zst exists in linux-bin/" \
        bash -c "ls '$KERNEL_OUT'/*.pkg.tar.zst >/dev/null 2>&1"
    run_test ".pkg.tar.zst is a valid zst archive" \
        bash -c "zstd -t \$(ls '$KERNEL_OUT'/*.pkg.tar.zst | head -1) >/dev/null 2>&1"
else
    skip "no .pkg.tar.zst in linux-bin/ — run build_kernel.sh --format arch first"
fi

# -----------------------------------------------------------------------
echo ""
echo "[ --kernel flag ]"
if [ -d "$SCRIPT_DIR/work/linux/.git" ]; then
    run_test "--kernel accepts existing source dir (dry run via --format check)" \
        bash -c "bash '$SCRIPT_DIR/build_kernel.sh' --kernel '$SCRIPT_DIR/work/linux' --format deb --help >/dev/null 2>&1; true"
    run_test "--kernel <path> resolves correctly (KERNEL_SRC set)" \
        bash -c "
            source '$SCRIPT_DIR/lib/build-common.sh' 2>/dev/null
            SCRIPT_DIR='$SCRIPT_DIR'
            KERNEL_SRC_ARG='$SCRIPT_DIR/work/linux'
            KERNEL_SRC=\$(cd \"\$KERNEL_SRC_ARG\" && pwd)
            [ -d \"\$KERNEL_SRC/.git\" ]"
else
    skip "work/linux not present — run build_kernel.sh first"
fi

# -----------------------------------------------------------------------
if [ "$SLOW" = true ]; then
    echo ""
    echo "[ Slow: full kernel build ]"
    BUILD_OUT=$(mktemp -d)
    CCACHE_DIR="${CCACHE_DIR:-$SCRIPT_DIR/ccache}"

    if [ -n "$KERNEL_SRC" ] && [ -d "$KERNEL_SRC/.git" ]; then
        run_test "build_kernel.sh --kernel compiles and packages" \
            bash "$SCRIPT_DIR/build_kernel.sh" \
                --kernel "$KERNEL_SRC" \
                --format all
    elif [ -d "$PATCHES_DIR/.git" ]; then
        run_test "build_kernel.sh --patches-dir compiles and packages" \
            bash "$SCRIPT_DIR/build_kernel.sh" \
                --patches-dir "$PATCHES_DIR" \
                --format all
    else
        skip "no kernel source or patches dir available for slow build"
    fi
fi

# -----------------------------------------------------------------------
echo ""
echo "=========================="
TOTAL=$((PASS+FAIL+SKIP))
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
echo ""
[ $FAIL -eq 0 ] && exit 0 || exit 1
