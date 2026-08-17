#!/usr/bin/env bash
# Tries to disable the hung-task panic without a password, using passwordless
# sudo if the system grants it. Stops the reboot loop immediately when it works.
#
# This only changes the running kernel. Run fix.sh afterwards to make it
# survive a reboot.
#
#   PHONE_HOST=172.16.42.1 PHONE_USER=user PHONE_KEY=~/.ssh/homelab ./stabilize.sh
set -u

HOST="${PHONE_HOST:-172.16.42.1}"
USER_NAME="${PHONE_USER:-user}"
KEY="${PHONE_KEY:-$HOME/.ssh/homelab}"

CMD='if sudo -n true 2>/dev/null; then
  sudo -n sysctl -w kernel.hung_task_panic=0 >/dev/null
  sudo -n sysctl -w kernel.hung_task_timeout_secs=0 >/dev/null
  echo "PASSWORDLESS_SUDO_OK panic=$(cat /proc/sys/kernel/hung_task_panic)"
else
  echo "SUDO_NEEDS_PASSWORD (use fix.sh instead)"
fi
echo "=== END ==="'

n=0
while true; do
  n=$((n+1))
  printf '\rattempt %d... ' "$n"
  out=$(ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -i "$KEY" "$USER_NAME@$HOST" "$CMD" 2>&1)
  if grep -q "=== END ===" <<<"$out"; then echo; echo "$out"; break; fi
  sleep 2
done
