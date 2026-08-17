#!/usr/bin/env bash
K=~/.ssh/homelab_s10
CMD='if sudo -n true 2>/dev/null; then
  sudo -n sysctl -w kernel.hung_task_panic=0 >/dev/null
  sudo -n sysctl -w kernel.hung_task_timeout_secs=0 >/dev/null
  echo "SUDO_NOPASSWD_OK panic=$(cat /proc/sys/kernel/hung_task_panic) timeout=$(cat /proc/sys/kernel/hung_task_timeout_secs)"
else
  echo "SUDO_PEDE_SENHA"
fi
echo "=== FIM ==="'
n=0
while true; do
  n=$((n+1)); printf "\rtentativa %d... " "$n"
  out=$(ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -i "$K" fernando@172.16.42.1 "$CMD" 2>&1)
  if grep -q "=== FIM ===" <<<"$out"; then echo; echo "$out"; break; fi
  sleep 2
done
