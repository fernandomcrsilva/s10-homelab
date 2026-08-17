#!/usr/bin/env bash
# Connects the phone to a WiFi network. Run this on the desktop; it works under
# fish, zsh and bash because it re-executes itself with bash.
#
# The WiFi passphrase never travels on a command line: wpa_passphrase hashes it
# locally and only the hash is copied over.
#
#   PHONE_HOST=172.16.42.1 PHONE_USER=user ./wifi-setup.sh
set -u

HOST="${PHONE_HOST:-172.16.42.1}"
USER_NAME="${PHONE_USER:-user}"
KEY="${PHONE_KEY:-$HOME/.ssh/homelab}"
IFACE="${PHONE_WIFI_IFACE:-wlan0}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT   # wipe the PSK on exit, whatever happens

read -r -p "WiFi SSID: " SSID
read -r -s -p "WiFi passphrase: " PSK; echo

wpa_passphrase "$SSID" "$PSK" > "$TMP/wpa_supplicant.conf" || {
  echo "wpa_passphrase failed"; exit 1; }
unset PSK

# wpa_passphrase leaves the plaintext passphrase in a comment. Drop it.
sed -i '/^\s*#psk=/d' "$TMP/wpa_supplicant.conf"
# scan_ssid=1 finds hidden networks, and 5 GHz ones missed by a passive scan.
sed -i '/^\s*ssid=/a\\tscan_ssid=1' "$TMP/wpa_supplicant.conf"
printf 'ctrl_interface=/var/run/wpa_supplicant\nupdate_config=1\n\n' \
  | cat - "$TMP/wpa_supplicant.conf" > "$TMP/out" \
  && mv "$TMP/out" "$TMP/wpa_supplicant.conf"

echo ">>> generated config:"
sed 's/psk=.*/psk=<hash hidden>/' "$TMP/wpa_supplicant.conf"

echo ">>> copying to the phone..."
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -i "$KEY" "$TMP/wpa_supplicant.conf" "$USER_NAME@$HOST:/tmp/wsc" || {
  echo "scp failed"; exit 1; }

echo ">>> applying (will ask for the sudo password)"
ssh -t -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$USER_NAME@$HOST" "
sudo sh -c '
  mkdir -p /etc/wpa_supplicant
  cp /tmp/wsc /etc/wpa_supplicant/wpa_supplicant.conf
  chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
  rm -f /tmp/wsc
  ip link set $IFACE up
  rc-update add wpa_supplicant default 2>/dev/null
  rc-service wpa_supplicant restart
  sleep 10
  udhcpc -i $IFACE -n -q 2>&1 | tail -3
  echo \"=== ADDRESS ===\"
  ip addr show $IFACE | grep inet
  echo \"=== ROUTES ===\"
  ip route | head -4
'"
