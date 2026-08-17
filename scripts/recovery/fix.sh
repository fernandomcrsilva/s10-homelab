#!/usr/bin/env bash
# Applies the permanent fix for the hung-task reboot loop, over SSH.
#
# Writes /etc/sysctl.d/99-hungtask.conf so the setting survives reboots. Do not
# try to fix this through the boot image cmdline on Samsung devices: the
# bootloader discards it and injects its own (check /proc/cmdline).
#
# Retries until it catches a connectivity window, then asks for the sudo
# password. If the device is already stable, prefer doing this from a recovery
# shell with the partition mounted, which needs no password at all.
#
#   PHONE_HOST=172.16.42.1 PHONE_USER=user PHONE_KEY=~/.ssh/homelab ./fix.sh
set -u

HOST="${PHONE_HOST:-172.16.42.1}"
USER_NAME="${PHONE_USER:-user}"
KEY="${PHONE_KEY:-$HOME/.ssh/homelab}"

CMD='sudo sh -c "
  sysctl -w kernel.hung_task_panic=0
  sysctl -w kernel.hung_task_timeout_secs=0
  printf \"kernel.hung_task_panic = 0\nkernel.hung_task_timeout_secs = 0\n\" > /etc/sysctl.d/99-hungtask.conf
  sync
"
echo "=== STATE ==="
cat /proc/sys/kernel/hung_task_panic /proc/sys/kernel/hung_task_timeout_secs
cat /etc/sysctl.d/99-hungtask.conf
echo "=== FIXED_OK ==="'

n=0
while true; do
  n=$((n+1))
  printf '\rattempt %d... ' "$n"
  out=$(ssh -t -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -i "$KEY" "$USER_NAME@$HOST" "$CMD" 2>&1)
  if grep -q FIXED_OK <<<"$out"; then
    echo; echo "$out"; echo; echo ">>> STABILIZED"; break
  fi
  sleep 2
done
