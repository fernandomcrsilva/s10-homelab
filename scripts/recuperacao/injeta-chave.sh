#!/usr/bin/env bash
# Fica tentando SSH no S10+ até pegar uma janela; quando conectar, pede a senha
# e injeta a chave homelab_s10 com permissões corretas + sync.
# Rode num terminal e deixe rodando. Digite a senha quando ele pedir.

CMD='mkdir -p ~/.ssh
grep -q homelab-s10 ~/.ssh/authorized_keys 2>/dev/null || echo "ssh-ed25519 SUA_CHAVE_PUBLICA_AQUI homelab-s10" >> ~/.ssh/authorized_keys
chmod 755 /home/fernando; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys
sync; sleep 1; sync
echo "=== DIAGNOSTICO ==="
ls -ldn /home/fernando /home/fernando/.ssh /home/fernando/.ssh/authorized_keys
cat ~/.ssh/authorized_keys
id
echo "=== INJETADO_OK ==="'

n=0
while true; do
  n=$((n+1))
  printf '\rtentativa %d... ' "$n"
  out=$(ssh -t -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        fernando@172.16.42.1 "$CMD" 2>&1)
  if grep -q INJETADO_OK <<<"$out"; then
    echo; echo "$out"; echo; echo ">>> SUCESSO — avisa o Claude <<<"; break
  fi
  sleep 2
done
