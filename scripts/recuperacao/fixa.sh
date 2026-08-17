#!/usr/bin/env bash
# Espera uma janela do S10+ e aplica a correcao definitiva do hung task panic.
# Pede a senha do usuario (sudo). Deixe rodando ate aparecer FIXADO_OK.
K=~/.ssh/homelab_s10
CMD='sudo sh -c "
  sysctl -w kernel.hung_task_panic=0
  sysctl -w kernel.hung_task_timeout_secs=0
  printf \"kernel.hung_task_panic = 0\nkernel.hung_task_timeout_secs = 0\n\" > /etc/sysctl.d/99-hungtask.conf
  sync
"
echo "=== ESTADO ==="
cat /proc/sys/kernel/hung_task_panic /proc/sys/kernel/hung_task_timeout_secs
cat /etc/sysctl.d/99-hungtask.conf
echo "=== FIXADO_OK ==="'
n=0
while true; do
  n=$((n+1)); printf "\rtentativa %d... " "$n"
  out=$(ssh -t -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$K" fernando@172.16.42.1 "$CMD" 2>&1)
  if grep -q FIXADO_OK <<<"$out"; then
    echo; echo "$out"; echo; echo ">>> ESTABILIZADO — avisa o Claude <<<"; break
  fi
  sleep 2
done
