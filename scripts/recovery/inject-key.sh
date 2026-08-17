#!/usr/bin/env bash
# Installs your SSH public key on a phone that keeps rebooting.
#
# Written for a device stuck in a hung-task panic loop, where SSH is only
# reachable for a couple of minutes at a time. It retries every 2 seconds until
# one attempt lands, then asks for the password once and sets everything up.
#
# Also fixes the permission problem that silently rejects valid keys: sshd's
# StrictModes refuses a key when the home directory is group or world writable.
#
#   PHONE_HOST=172.16.42.1 PHONE_USER=user PHONE_PUBKEY=~/.ssh/homelab.pub ./inject-key.sh
set -u

HOST="${PHONE_HOST:-172.16.42.1}"
USER_NAME="${PHONE_USER:-user}"
PUBKEY_FILE="${PHONE_PUBKEY:-$HOME/.ssh/homelab.pub}"

[ -r "$PUBKEY_FILE" ] || { echo "public key not found: $PUBKEY_FILE"; exit 1; }
PUBKEY=$(cat "$PUBKEY_FILE")

CMD="mkdir -p ~/.ssh
grep -qF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUBKEY' >> ~/.ssh/authorized_keys
chmod 755 \$HOME          # StrictModes: sshd rejects keys if this is writable by others
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
sync; sleep 1; sync       # survive the next spontaneous reboot
echo '=== DIAGNOSTICS ==='
ls -ldn \$HOME \$HOME/.ssh \$HOME/.ssh/authorized_keys
id
echo '=== INJECTED_OK ==='"

n=0
while true; do
  n=$((n+1))
  printf '\rattempt %d... ' "$n"
  out=$(ssh -t -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null "$USER_NAME@$HOST" "$CMD" 2>&1)
  if grep -q INJECTED_OK <<<"$out"; then
    echo; echo "$out"; echo; echo ">>> SUCCESS"; break
  fi
  sleep 2
done
