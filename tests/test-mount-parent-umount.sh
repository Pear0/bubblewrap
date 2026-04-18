#!/usr/bin/env bash
# Test that:
#   (a) the parent can umount a mount while bwrap is running (no EBUSY), and
#   (b) the bwrap child can still access the bind-mounted content afterwards.
#
# This exercises the MS_PRIVATE fix in bind_mount(): making the bound subtree
# private disconnects it from the parent's peer group so the parent's umount
# succeeds, while bwrap retains its own private copy.

set -xeuo pipefail

srcd=$(cd $(dirname "$0") && pwd)
. "${srcd}/libtest.sh"

echo "1..2"

test_count=0
ok() {
    test_count=$((test_count + 1))
    echo "ok ${test_count} $*"
}
ok_skip() {
    test_count=$((test_count + 1))
    echo "ok ${test_count} # SKIP $*"
}

if ! $is_uidzero; then
    ok_skip "requires root to create mounts"
    ok_skip "requires root to create mounts"
    exit 0
fi

# Ensure shared propagation so bwrap's namespace is a real slave of ours
mount --make-rshared / 2>/dev/null || true

# Set up a tmpfs with a sentinel file
MOUNT_SRC=$(mktemp -d /var/tmp/bwrap-mount-test.XXXXXX)
mount -t tmpfs none "$MOUNT_SRC"
echo "sentinel-content" > "$MOUNT_SRC/sentinel"

# child_ready: child writes here when it is set up and waiting
# child_proceed: parent writes here to let the child read the file
mkfifo child_ready child_proceed

# Run bwrap: bind the tmpfs at /mnt/test, then:
#   1. signal the parent we are ready
#   2. wait for the parent's go-ahead
#   3. read the file (AFTER the parent has umounted the source)
$RUN --bind "$MOUNT_SRC" /mnt/test \
    sh -c 'echo x > child_ready; read x < child_proceed; cat /mnt/test/sentinel' \
    > child_output &
BWRAP_PID=$!

# Wait for child to be ready
read x < child_ready

# (a) Parent umounts while bwrap is running -- must not get EBUSY
if umount "$MOUNT_SRC" 2>umount_err; then
    ok "parent can umount while bwrap is running"
else
    test_count=$((test_count + 1))
    echo "not ok ${test_count} - parent can umount while bwrap is running # $(cat umount_err)"
fi

# Signal child to proceed, then wait for it to finish
echo x > child_proceed
wait $BWRAP_PID

# (b) Child must have read the sentinel successfully
assert_file_has_content child_output "sentinel-content"
ok "child can read bind-mounted file after parent umount"

rmdir "$MOUNT_SRC" 2>/dev/null || true
