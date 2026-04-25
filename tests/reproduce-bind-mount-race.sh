#!/usr/bin/env bash

set -xeuo pipefail

srcd=$(cd "$(dirname "$0")" && pwd)

if test "${BWRAP_RACE_IN_MOUNT_NS:-}" != 1 &&
        test "$(id -u)" = 0 &&
        command -v unshare >/dev/null &&
        unshare --mount true 2>/dev/null; then
    export BWRAP_RACE_IN_MOUNT_NS=1
    exec unshare --mount "$0"
fi

. "${srcd}/libtest.sh"

test_count=0
ok () {
    test_count=$((test_count + 1))
    echo ok $test_count "$@"
}
ok_skip () {
    ok "# SKIP" "$@"
}
done_testing () {
    echo "1..$test_count"
}

num_paths="${BWRAP_RACE_NUM_PATHS:-400}"
num_churn_paths="${BWRAP_RACE_NUM_CHURN_PATHS:-80}"
num_tries="${BWRAP_RACE_NUM_TRIES:-100}"
race_dir="${BWRAP_RACE_DIR:-/mnt/bwrap-race}"
spam_pid=

if ! "${is_uidzero}"; then
    ok_skip "requires root to create mount churn"
    done_testing
    exit 0
fi

cleanup_race_mounts () {
    if test -n "${spam_pid}"; then
        kill "${spam_pid}" 2>/dev/null || true
        wait "${spam_pid}" 2>/dev/null || true
    fi

    set +x
    for i in $(seq 0 $((num_paths - 1))); do
        umount -l "${race_dir}/s${i}" 2>/dev/null || true
    done

    umount -l "${race_dir}" 2>/dev/null || true
    cleanup
}
trap cleanup_race_mounts EXIT

if ! mount --make-rshared / 2>/dev/null; then
    ok_skip "cannot make / rshared"
    done_testing
    exit 0
fi

mkdir -p "${race_dir}"
if ! mount -t tmpfs none "${race_dir}"; then
    ok_skip "cannot mount tmpfs race base"
    done_testing
    exit 0
fi

set +x
for i in $(seq 0 $((num_paths - 1))); do
    mkdir -p "${race_dir}/s${i}"
    if ! mount -t tmpfs none "${race_dir}/s${i}"; then
        set -x
        ok_skip "cannot seed tmpfs submounts"
        done_testing
        exit 0
    fi
done

(
    while true; do
        for i in $(seq 0 $((num_churn_paths - 1))); do
            mount -t tmpfs none "${race_dir}/s${i}" 2>/dev/null &
            umount -l "${race_dir}/s${i}" 2>/dev/null &
        done
        wait
    done
) &
spam_pid=$!

fail=0
pass=0
for i in $(seq 1 "${num_tries}"); do
    if "${BWRAP}" --ro-bind / / --proc /proc --dev /dev true 2>err.txt; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        if grep -q -e 'Unable to apply mount flags: remount ' err.txt; then
            sed -e 's/^/# /' < err.txt >&2
            fatal "recursive bind submount race reproduced (${fail}/$((fail + pass)) failures)"
        else
            sed -e 's/^/# /' < err.txt >&2
            fatal "bwrap failed for an unexpected reason"
        fi
    fi
done
set -x

ok "recursive bind survived mount churn (${pass} runs)"

done_testing
