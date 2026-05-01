#!/bin/bash
# Shared build library sourced by build_kernel.sh and build_image.sh.
# Callers must set: SCRIPT_DIR, LOG_FILE, DOCKER_NAME, BUILD_PID

LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

cleanup() {
    echo ""
    echo "Interrupted. Cleaning up..."
    docker kill "$DOCKER_NAME" 2>/dev/null || true
    [ -n "$BUILD_PID" ] && kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
    exit 130
}

# run_stage <name> <cmd...>
# In CI (GitHub Actions) streams output directly with log groups instead of a spinner.
run_stage() {
    local name="$1"
    shift

    if [ "${CI:-}" = "true" ]; then
        echo "::group::$name"
        local rc=0
        "$@" || rc=$?
        echo "::endgroup::"
        if [ $rc -ne 0 ]; then
            echo "::error::Build failed at: $name"
            exit $rc
        fi
        return
    fi

    local status_msg="$name"
    local spin_i=0

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

# Clone or pull-reset the patches repo.
# Args: patches_dir patches_repo [patches_token [patches_ref]]
# patches_ref: optional branch or tag to pin (e.g. "v1.0"); defaults to remote HEAD.
# patches_token: injected into https:// URL for private repo access.
stage_kernel_pull_patches() {
    local patches_dir="$1"
    local patches_repo="$2"
    local patches_token="${3:-}"
    local patches_ref="${4:-}"
    local repo_url="$patches_repo"

    if [ -n "$patches_token" ]; then
        repo_url="${patches_repo/https:\/\//https:\/\/${patches_token}@}"
    fi

    mkdir -p "$(dirname "$patches_dir")"
    if [ ! -d "$patches_dir/.git" ]; then
        local branch_arg=""
        [ -n "$patches_ref" ] && branch_arg="--branch $patches_ref"
        run_stage "Clone ps5-linux-patches" \
            bash -c "git clone --depth 1 $branch_arg $(printf '%q' "$repo_url") $(printf '%q' "$patches_dir")"
    else
        if [ -n "$patches_ref" ]; then
            run_stage "Update ps5-linux-patches" bash -c '
                git -C "'"$patches_dir"'" fetch --depth 1 origin tag "'"$patches_ref"'"
                git -C "'"$patches_dir"'" reset --hard "'"$patches_ref"'"'
        else
            run_stage "Update ps5-linux-patches" bash -c '
                git -C "'"$patches_dir"'" fetch --depth 1 origin
                git -C "'"$patches_dir"'" reset --hard FETCH_HEAD'
        fi
    fi
}

# Wipe kernel_src if present, clone fresh at the version from patches/.config, apply patches.
# Args: kernel_src patches_dir
stage_kernel_clone_and_patch() {
    local kernel_src="$1"
    local patches_dir="$2"
    local tmp_dir="${kernel_src}.tmp"

    local linux_version
    linux_version="v$(grep -m1 "^# Linux/" "$patches_dir/.config" | grep -oP '\d+\.\d+(\.\d+)?')"

    rm -rf "$tmp_dir"

    run_stage "Clone kernel $linux_version" \
        git clone --branch "$linux_version" --depth 1 "$LINUX_REPO" "$tmp_dir"

    run_stage "Apply patches" bash -c '
        set -e
        shopt -s nullglob
        patches=("'"$patches_dir"'"/*.patch)
        [ ${#patches[@]} -eq 0 ] && { echo "No .patch files found in '"$patches_dir"'"; exit 1; }
        for p in "${patches[@]}"; do
            echo "Applying $p"
            git -C "'"$tmp_dir"'" apply --exclude=Makefile "$p"
        done'

    run_stage "Copy kernel config" \
        cp "$patches_dir/.config" "$tmp_dir/.config"

    rm -rf "$kernel_src"
    mv "$tmp_dir" "$kernel_src"
}

# Build ps5-kernel-builder image and compile the kernel; stage artifacts to kernel_out/staging.
# Writes kernel_out/VERSION with the built kernel version string.
# Args: kernel_src kernel_out ccache_dir
stage_kernel_compile() {
    local kernel_src="$1"
    local kernel_out="$2"
    local ccache_dir="$3"

    run_stage "Build kernel builder image" \
        docker build -t ps5-kernel-builder \
            -f "$SCRIPT_DIR/docker/kernel-builder/Dockerfile" "$SCRIPT_DIR"

    run_stage "Compile kernel" \
        docker run --rm --name "$DOCKER_NAME" \
            -v "$kernel_src":/src \
            -v "$kernel_out":/out \
            -v "$ccache_dir":/ccache \
            ps5-kernel-builder

    ls "$kernel_out/staging/lib/modules/" | head -1 > "$kernel_out/VERSION"
}

# Package staged artifacts as .deb files.
# Args: kernel_src kernel_out ccache_dir
stage_kernel_package_deb() {
    local kernel_src="$1"
    local kernel_out="$2"
    local ccache_dir="$3"

    run_stage "Package kernel (.deb)" \
        docker run --rm --name "$DOCKER_NAME" \
            -v "$kernel_src":/src \
            -v "$kernel_out":/out \
            -v "$ccache_dir":/ccache \
            ps5-kernel-builder \
            bash -c 'make -j$(nproc) DPKG_FLAGS=-d bindeb-pkg && cp /*.deb /out/'
}

# Package staged artifacts as a pacman .pkg.tar.zst.
# Args: kernel_out
stage_kernel_package_arch() {
    local kernel_out="$1"

    run_stage "Build arch packager image" \
        docker build --platform linux/amd64 -t ps5-kernel-packager-arch \
            -f "$SCRIPT_DIR/docker/kernel-builder-arch/Dockerfile" "$SCRIPT_DIR"

    run_stage "Package kernel (.pkg.tar.zst)" \
        docker run --rm --platform linux/amd64 --name "$DOCKER_NAME" \
            -v "$kernel_out":/out \
            ps5-kernel-packager-arch
}
