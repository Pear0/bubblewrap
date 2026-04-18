#!/bin/bash
# Reproducer for bwrap TOCTOU race in recursive bind-mount remount loop.
#
# Race: bwrap does --ro-bind / /, which:
#   1. mount("/oldroot", "/newroot", MS_BIND|MS_REC)   -- snapshot of mounts
#   2. parse_mountinfo()                                -- read list of submounts
#   3. for each entry: mount(MS_BIND|MS_REMOUNT|RDONLY) -- apply flags
#
# A concurrent process that rapidly mounts+lazy-umounts under / causes a mount
# to appear in step 2's snapshot but be in a detached/zombie state by step 3,
# making the kernel reject the remount with EINVAL.
#
# Requires: root, cap_sys_admin, shared mount propagation (run make-rshared first)

set -euo pipefail

BWRAP=${BWRAP:-$(dirname "$0")/_build/bwrap}
RACE_DIR=/mnt/base
NUM_PATHS=20
NUM_TRIES=200

if [ ! -x "$BWRAP" ]; then
    echo "bwrap not found at $BWRAP (run: meson setup _build && meson compile -C _build)"
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "Must run as root"
    exit 1
fi

cleanup() {
    kill "$SPAM_PID" 2>/dev/null || true
    wait "$SPAM_PID" 2>/dev/null || true
    for i in $(seq 0 $((NUM_PATHS - 1))); do
        umount -l "$RACE_DIR/s$i" 2>/dev/null || true
    done
    umount -l "$RACE_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== bwrap TOCTOU mount race reproducer ==="
echo "bwrap: $BWRAP"

# Ensure shared propagation (required for slave ns to receive mount events)
mount --make-rshared / 2>/dev/null || true

# Base tmpfs so inner mounts are single clean entries (avoid 9p stacking)
mkdir -p "$RACE_DIR"
mount -t tmpfs none "$RACE_DIR"
for i in $(seq 0 $((NUM_PATHS - 1))); do
    mkdir -p "$RACE_DIR/s$i"
done

echo "Spawning mount spammer ($NUM_PATHS paths under $RACE_DIR)..."
bash -c "
    while true; do
        for i in \$(seq 0 $((NUM_PATHS - 1))); do
            mount -t tmpfs none $RACE_DIR/s\$i 2>/dev/null &
            umount -l $RACE_DIR/s\$i 2>/dev/null &
        done
        wait
    done
" &
SPAM_PID=$!

echo "Running bwrap in a loop ($NUM_TRIES iterations)..."
FAIL=0
PASS=0
for i in $(seq 1 $NUM_TRIES); do
    err=$("$BWRAP" --ro-bind / / --proc /proc --dev /dev true 2>&1) && {
        PASS=$((PASS + 1))
    } || {
        FAIL=$((FAIL + 1))
        echo "  [iter $i] RACE HIT: $err"
    }
done

echo ""
echo "Results: $FAIL failures / $((FAIL + PASS)) runs ($(( FAIL * 100 / (FAIL + PASS) ))% hit rate)"
if [ "$FAIL" -gt 0 ]; then
    echo "REPRODUCED"
else
    echo "No failures observed (try increasing NUM_TRIES or NUM_PATHS)"
fi
