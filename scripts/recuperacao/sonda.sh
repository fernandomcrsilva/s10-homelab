#!/usr/bin/env bash
K=~/.ssh/homelab_s10
CMD='echo "=== SONDA ==="
id
echo "--- binarios de privilegio ---"
for b in su sudo doas; do command -v $b 2>/dev/null; done
echo "--- particao boot ---"
ls -l /dev/disk/by-partlabel/boot 2>&1
test -w /dev/disk/by-partlabel/boot && echo "BOOT_GRAVAVEL_DIRETO" || echo "boot NAO gravavel direto"
echo "--- hung_task ---"
cat /proc/sys/kernel/hung_task_panic /proc/sys/kernel/hung_task_timeout_secs 2>&1
echo "--- uname ---"
uname -a
echo "=== FIM_SONDA ==="'
n=0
while true; do
  n=$((n+1)); printf "\rtentativa %d... " "$n"
  out=$(ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -i "$K" fernando@172.16.42.1 "$CMD" 2>&1)
  if grep -q FIM_SONDA <<<"$out"; then echo; echo "$out"; break; fi
  sleep 2
done
