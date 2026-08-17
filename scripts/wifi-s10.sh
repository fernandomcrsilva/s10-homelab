#!/usr/bin/env bash
# Conecta o S10+ no WiFi de casa. Roda no desktop (funciona em fish, zsh, bash).
# A senha do WiFi nunca trafega em linha de comando: vira hash aqui e vai por scp.
set -u
K=~/.ssh/homelab_s10
H=fernando@172.16.42.1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT   # ponytail: apaga o PSK ao sair, aconteca o que acontecer

read -r -p "SSID do WiFi: " SSID
read -r -s -p "Senha do WiFi: " PSK; echo

wpa_passphrase "$SSID" "$PSK" > "$TMP/wpa_supplicant.conf" || { echo "wpa_passphrase falhou"; exit 1; }
unset PSK
sed -i '/^\s*#psk=/d' "$TMP/wpa_supplicant.conf"        # tira a senha em texto que o wpa_passphrase deixa
sed -i '/^\s*ssid=/a\\tscan_ssid=1' "$TMP/wpa_supplicant.conf"  # acha rede oculta e 5GHz
printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n\n' | cat - "$TMP/wpa_supplicant.conf" > "$TMP/wsc" && mv "$TMP/wsc" "$TMP/wpa_supplicant.conf"
echo ">>> config gerada:"; sed 's/psk=.*/psk=<hash oculto>/' "$TMP/wpa_supplicant.conf"

echo ">>> enviando config..."
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "$K" "$TMP/wpa_supplicant.conf" "$H:/tmp/wsc" || { echo "scp falhou"; exit 1; }

echo ">>> aplicando no aparelho (vai pedir a senha do sudo)"
ssh -t -i "$K" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$H" '
sudo sh -c "
  mkdir -p /etc/wpa_supplicant
  cp /tmp/wsc /etc/wpa_supplicant/wpa_supplicant.conf
  chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
  rm -f /tmp/wsc
  ip link set wlan0 up
  rc-update add wpa_supplicant default 2>/dev/null
  rc-service wpa_supplicant restart
  sleep 10
  udhcpc -i wlan0 -n -q 2>&1 | tail -3
  echo \"=== IP DO WLAN0 ===\"
  ip addr show wlan0 | grep inet
  echo \"=== ROTAS ===\"
  ip route | head -4
"'
