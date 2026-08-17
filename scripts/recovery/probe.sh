#!/usr/bin/env bash
# Waits for a connectivity window on an unstable phone and dumps the facts you
# need before deciding what to do: privilege escalation available, partition
# access, hung-task settings, kernel version.
#
# Uses key authentication only, so it needs no interaction and can run
# unattended while you wait for the device to come back.
#
#   PHONE_HOST=172.16.42.1 PHONE_USER=user PHONE_KEY=~/.ssh/homelab ./probe.sh
set -u

HOST="${PHONE_HOST:-172.16.42.1}"
USER_NAME="${PHONE_USER:-user}"
KEY="${PHONE_KEY:-$HOME/.ssh/homelab}"

CMD='echo "=== PROBE ==="
id
echo "--- privilege escalation ---"
for b in su sudo doas; do command -v $b 2>/dev/null; done
echo "--- boot partition ---"
ls -l /dev/disk/by-partlabel/boot 2>&1
test -w /dev/disk/by-partlabel/boot && echo "BOOT_WRITABLE" || echo "boot not writable directly"
echo "--- hung task (1 = the reboot loop is armed) ---"
cat /proc/sys/kernel/hung_task_panic /proc/sys/kernel/hung_task_timeout_secs 2>&1
echo "--- kernel ---"
uname -a
echo "=== END_PROBE ==="'

n=0
while true; do
  n=$((n+1))
  printf '\rattempt %d... ' "$n"
  out=$(ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -i "$KEY" "$USER_NAME@$HOST" "$CMD" 2>&1)
  if grep -q END_PROBE <<<"$out"; then echo; echo "$out"; break; fi
  sleep 2
done
