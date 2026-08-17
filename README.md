# Phone as a Homelab

Turn an old Android phone into a real home server with postmarketOS: network file storage,
a web file manager, network-wide ad blocking, remote access and monitoring.

This is a step by step guide, written from an actual build on a Samsung Galaxy S10+
(SM-G975F, Exynos 9820) with a broken touchscreen. Every command here was run on that
device. Where something failed, the failure is documented too, because the failures cost
far more time than the successes.

## What you end up with

| Service | Purpose | Port |
|---|---|---|
| Samba | file sharing on the local network | 445 |
| filebrowser | web file manager (upload, preview, download) | 8080 |
| AdGuard Home | network-wide DNS ad blocking | 80, 53 |
| netdata | real-time monitoring | 19999 |
| Tailscale | remote access without opening router ports | n/a |

Measured on the finished build:

- **Write:** 60.8 MB/s · **Read:** 49.3 MB/s (5 GHz WiFi, over SSH)
- **Latency:** 4 ms
- **Power draw:** 0.39 W idle (an idle Raspberry Pi 4 draws 3 to 5 W)
- **Temperature:** 30 to 36 °C
- **Battery:** roughly a day unplugged, so the phone is its own UPS

## Before you start

**Hardware.** A phone with a [postmarketOS port](https://wiki.postmarketos.org/wiki/Devices),
a USB cable, and a Linux desktop. A broken screen is fine. A broken *charging port* is not.

**Accept these costs.** Unlocking the bootloader permanently blows Knox on Samsung devices
and voids the warranty. Your data on the phone will be erased. The phone must be yours.

**Know the limitation.** Most Docker images have no `arm64` build. This guide sets up
services that exist as native packages. If your plan depends on Docker images, check
architecture support first, because this is the constraint people discover last.

**Battery warning.** A phone charging 24/7 will swell over months. Step 13 caps charging,
and it is not optional for a device you intend to forget about.

---

## Step 1: Install postmarketOS

Install `pmbootstrap` from your distribution, then:

```sh
pmbootstrap init      # pick your device, choose "none" for the UI
pmbootstrap install   # set the user password when asked; remember it
```

**Add your SSH key before installing.** `pmbootstrap` embeds `~/.ssh/id_*` into the image.
If you only have keys with other names, it silently embeds nothing and you get a system
that boots but refuses every login:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/homelab -N "" -C "homelab"
cp ~/.ssh/homelab.pub ~/.ssh/id_ed25519.pub   # so pmbootstrap finds it
```

**If your device port lives in `device/archived/`,** copy the three packages
(`device-*`, `linux-*`, `firmware-*`) into `device/testing/` and **delete the originals**.
A package present in two folders makes `pmbootstrap` abort with "found in multiple aports
subfolders".

## Step 2: Flash the device

Enter Download Mode. On Samsung: **Volume Down + Bixby + Power**, held for about 10
seconds. With a broken screen this is blind, so watch the desktop instead:

```sh
watch -n1 'lsusb | grep -i samsung'
```

Flash with `heimdall` or `odin4`. Then generate the images and write them:

```sh
pmbootstrap export
```

**`odin4` fails on large files.** It dies with `ioctl bulk write Fail: Connection timed
out` around 50% of a 503 MB image, leaving a corrupted partition. It handles small images
(under ~60 MB) fine. So use it only for the boot image and TWRP, and flash everything
larger through TWRP itself:

```sh
odin4 -a twrp.tar -d /dev/bus/usb/XXX/YYY   # odin4 -l lists the device
```

Reboot into recovery (**Volume Up + Bixby + Power**), then push the big images over ADB.
TWRP gives passwordless root, `adb push` at ~35 MB/s and `dd` at 157 MB/s:

```sh
adb push rootfs.img /tmp/rootfs.img
adb shell 'dd if=/tmp/rootfs.img of=/dev/block/by-name/userdata bs=4M; sync'
```

**Always verify by reading back**, because a silent corruption here costs an entire
debugging session later:

```sh
sha256sum rootfs.img
adb shell 'dd if=/dev/block/by-name/userdata bs=1 count=SIZE | sha256sum'
```

## Step 3: Stop the reboot loop

**Symptom:** the system boots, SSH answers, then the device resets every two to four
minutes, forever.

**Cause:** downstream Android kernels ship `CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y`. Any task
blocked longer than the timeout panics the kernel.

**The trap:** the obvious fix is `hung_task_panic=0` in the boot image cmdline. It does not
work on Samsung devices. The bootloader discards your cmdline and injects its own. Check
with `cat /proc/cmdline`: you will see only `androidboot.*` parameters. Six reflashes were
spent on this before anyone read that file.

**The fix that works** is in userspace. From TWRP recovery, mount the root partition and
write the file directly:

```sh
adb shell
mkdir -p /mnt/r && mount -t ext4 /dev/block/by-name/userdata /mnt/r
mkdir -p /mnt/r/etc/sysctl.d
printf 'kernel.hung_task_panic = 0\nkernel.hung_task_timeout_secs = 0\n' \
  > /mnt/r/etc/sysctl.d/99-hungtask.conf
sync && umount /mnt/r
```

The `sysctl` service already runs in the `boot` runlevel, well within the 120 s timeout.
Reboot and confirm:

```sh
cat /proc/sys/kernel/hung_task_panic   # must print 0
uptime                                  # must keep growing past 5 minutes
```

## Step 4: Get SSH working

The phone comes up on `172.16.42.1` over the USB cable. If key authentication is refused
even with the right key, the cause is almost always **home directory permissions**: sshd's
`StrictModes` rejects keys when the home directory is group or world writable.

```sh
ssh user@172.16.42.1    # password from pmbootstrap install
mkdir -p ~/.ssh
echo "ssh-ed25519 AAAA... your-key" >> ~/.ssh/authorized_keys
chmod 755 ~            # this line is the one people miss
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
sync
```

## Step 5: Expand the filesystem

The installed root filesystem is far smaller than the partition. Expand it in place:

```sh
sudo resize2fs /dev/sda31    # use your root partition
df -h /
```

Do this **online, on the running system**. TWRP ships `e2fsprogs` from 2016, which refuses
modern filesystem features.

## Step 6: Give the phone internet (temporarily)

Over USB the phone reaches only your desktop. To install packages before WiFi works, share
the connection from the desktop:

```sh
# on the desktop, replace eth0 with your internet interface
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 172.16.42.0/24 -o eth0 -j MASQUERADE
sudo iptables -I FORWARD -i usb0 -o eth0 -j ACCEPT
sudo iptables -I FORWARD -i eth0 -o usb0 -j ACCEPT
```

```sh
# on the phone
sudo ip route add default via 172.16.42.2
echo nameserver 1.1.1.1 | sudo tee /etc/resolv.conf
sudo apk update
```

These rules vanish on reboot, which is fine. They are scaffolding for the next step.

## Step 7: Connect to WiFi

**The trap:** `iwlist` and `iwconfig` report `no wireless extensions` and `Interface
doesn't support scanning`. This looks exactly like broken hardware and is not. Samsung's
`bcmdhd` driver speaks nl80211, not the old wireless extensions API. Use `iw`:

```sh
sudo apk add iw wpa_supplicant
sudo ip link set wlan0 up
sudo iw dev wlan0 scan | grep SSID
```

Firmware usually ships preinstalled (check `/lib/firmware/postmarketos/`). The interface is
just down.

Generate the configuration on your **desktop**, so the passphrase becomes a hash and never
appears in a remote command or shell history:

```sh
wpa_passphrase "YOUR_SSID" > wpa.conf     # prompts for the passphrase
sed -i '/^\s*#psk=/d' wpa.conf            # remove the plaintext comment it leaves
sed -i '/^\s*ssid=/a\\tscan_ssid=1' wpa.conf   # finds hidden and 5 GHz networks
scp wpa.conf user@172.16.42.1:/tmp/
```

```sh
# on the phone
sudo cp /tmp/wpa.conf /etc/wpa_supplicant/wpa_supplicant.conf
sudo chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
sudo rc-update add wpa_supplicant default
sudo rc-service wpa_supplicant start
```

**Disable WiFi power save.** Without this, ping swings between 70 and 255 ms, which makes
the NAS feel broken:

```sh
printf '#!/bin/sh\niw dev wlan0 set power_save off\n' \
  | sudo tee /etc/local.d/wifi-powersave.start
sudo chmod 755 /etc/local.d/wifi-powersave.start
sudo rc-update add local default
sudo /etc/local.d/wifi-powersave.start
```

## Step 8: Make the address stable

Nothing requests an IP at boot yet: the earlier `udhcpc` run was manual. Declare the
interface so networking starts on its own:

```sh
printf 'auto lo\niface lo inet loopback\n\nauto wlan0\niface wlan0 inet dhcp\n' \
  | sudo tee /etc/network/interfaces
sudo rc-update add networking default
```

Then reserve the address **on your router** (look for "DHCP reservation" or "IP binding")
using the phone's MAC. Prefer this over a static IP on the device: the router then knows
the address is taken and will never hand it to anything else.

From here on, use the LAN address instead of the USB one.

## Step 9: Samba file sharing

```sh
sudo apk add samba
sudo install -d -o $USER -g $USER -m 755 /srv/nas
```

`/etc/samba/smb.conf`:

```ini
[global]
   workgroup = WORKGROUP
   server string = Phone NAS
   netbios name = PHONENAS
   security = user
   map to guest = never
   server min protocol = SMB2
   use sendfile = yes
   load printers = no

[nas]
   path = /srv/nas
   browseable = yes
   read only = no
   valid users = YOUR_USER
   create mask = 0644
   directory mask = 0755
```

Keep `netbios name` at 15 characters or fewer, or Samba warns and network discovery
misbehaves.

```sh
sudo smbpasswd -a YOUR_USER      # this password is separate from the system one
sudo rc-update add samba default
sudo rc-service samba start
```

**If Samba refuses to start** with `cannot start samba as networking would not start`, the
`ifupdown` package pulled in by `wpa_supplicant-openrc` created a dependency on a
`networking` service that has no configuration. Step 8 already fixes this by creating
`/etc/network/interfaces`.

Test from the desktop:

```sh
smbclient -L //PHONE_IP -N
```

## Step 10: Web file manager

```sh
sudo apk add filebrowser
sudo mkdir -p /var/lib/filebrowser
sudo filebrowser config init -d /var/lib/filebrowser/filebrowser.db
sudo filebrowser config set -d /var/lib/filebrowser/filebrowser.db \
  --address 0.0.0.0 --port 8080 --root /srv/nas
sudo filebrowser users add admin admin --perm.admin -d /var/lib/filebrowser/filebrowser.db
```

**Trap A: the database allows one process at a time.** It is BoltDB. Running `config set`
while the service is up fails with a silent `timeout` and your change is lost. Always stop
the service first:

```sh
sudo rc-service filebrowser stop
sudo filebrowser config set ...
sudo rc-service filebrowser start
```

**Trap B: OpenRC's `conf.d` loses to the init script.** OpenRC sources
`/etc/conf.d/<service>` *before* running the init script, so any variable the init script
sets directly wins. `/etc/init.d/filebrowser` hardcodes
`command_user="filebrowser:filebrowser"`, so the service runs as the wrong user, cannot
read your files, and dies logging nothing at all. The only symptom is `status: crashed`.

```sh
sudo sed -i 's/^command_user=.*/command_user="YOUR_USER:YOUR_USER"/' /etc/init.d/filebrowser
```

**When a service crashes with an empty log,** declare log targets in `conf.d` to see the
real error, and point them at a directory the service user can write:

```sh
output_log="/var/log/filebrowser/out.log"
error_log="/var/log/filebrowser/err.log"
```

**Trap C: the icons render as words.** filebrowser 2.27.0 ships a CSS bundle containing a
literal `__VITE_ASSET__` placeholder where the icon font URL belongs, so the UI shows
`folder`, `file_upload` as text. Fix it with a branding override that embeds the font:

```sh
# on the desktop
curl -s -A "Mozilla/5.0" "https://fonts.googleapis.com/icon?family=Material+Icons" \
  | grep -oE 'https://[^)]*\.woff2' | head -1 | xargs curl -s -o mi.woff2
{ printf "@font-face{font-family:'Material Icons';font-style:normal;font-weight:400;font-display:block;src:url(data:font/woff2;base64,"
  base64 -w0 mi.woff2
  printf ") format('woff2');}\n"; } > custom.css
scp custom.css user@PHONE_IP:/tmp/
```

```sh
# on the phone
sudo install -d -o $USER -g $USER /var/lib/filebrowser/branding
sudo install -o $USER -g $USER /tmp/custom.css /var/lib/filebrowser/branding/custom.css
sudo rc-service filebrowser stop
sudo filebrowser config set -d /var/lib/filebrowser/filebrowser.db \
  --branding.files /var/lib/filebrowser/branding
sudo rc-service filebrowser start
```

Open `http://PHONE_IP:8080` and change the `admin`/`admin` password immediately.

## Step 11: Network-wide ad blocking

```sh
sudo apk add adguardhome
sudo rc-update add adguardhome default
sudo rc-service adguardhome start
```

This package is well built: it creates its own user, uses `supervise-daemon`, and declares
`cap_net_bind_service` so it can bind ports 53 and 80 without root. It works unmodified.

Open `http://PHONE_IP:3000` and complete the wizard. Port 3000 only exists during setup;
afterwards the interface moves to the port you chose. Seeing `NetworkError` in the browser
at that moment is the expected result of that move, not a failure.

**Turn off the query log** in Settings, General. It writes thousands of lines per day, and
phone storage cannot be replaced when it wears out. Keep statistics on: they are aggregated
and cheap.

Then point your router's DHCP at the phone: set both primary and secondary DNS to its
address. Use the same address twice rather than adding a public resolver, otherwise clients
alternate between them and blocking works only half the time, which is miserable to debug.

**The IPv6 trap.** Most routers advertise *themselves* as an IPv6 DNS server via Router
Advertisement, and clients prefer IPv6. Your blocking is then bypassed silently while
everything looks correctly configured. Verify:

```sh
resolvectl dns              # look for a stray fe80:: address
nslookup doubleclick.net    # must answer 0.0.0.0
```

ISP-supplied routers often expose no IPv6 setting at all. The reliable fix is pinning DNS
per client:

```sh
sudo nmcli con mod "Your Connection" ipv4.dns PHONE_IP \
  ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes
sudo nmcli con up "Your Connection"
```

On Android: WiFi, edit network, IP settings Static, DNS 1 set to the phone address. Do not
use the phone's global IPv6 address as your DNS: that prefix is delegated by your ISP and
can change without warning.

**Know the tradeoff.** The phone is now a single point of failure for name resolution. If
it goes down, nothing on the network resolves and it looks like the internet died. Recovery
is one field in the router, but tell the household first.

## Step 12: Remote access

```sh
sudo apk add tailscale
sudo rc-update add tailscale default
sudo rc-service tailscale start
sudo tailscale up --hostname=phonenas --accept-dns=false
```

Open the printed URL to authorize. Every service above becomes reachable from anywhere at
the Tailscale address, with no router ports opened. Expect around 34 MB/s instead of 60,
which is the WireGuard encryption overhead.

`--accept-dns=false` is deliberate: it stops Tailscale from rewriting `/etc/resolv.conf`.

## Step 13: Monitoring

```sh
sudo apk add netdata
sudo rc-update add netdata default
```

`/etc/netdata/netdata.conf`:

```ini
[db]
    mode = ram

[web]
    bind to = 0.0.0.0
```

`mode = ram` keeps metrics in memory instead of writing them continuously to storage that
cannot be replaced. You lose history across reboots and keep about an hour of live graphs.
Switch to `dbengine` only if you truly need long history.

Open `http://PHONE_IP:19999` for temperatures, per-core CPU, network and disk.

## Step 14: Cap the battery

A phone held at 100% charge forever will swell. On Samsung devices:

```sh
printf '#!/bin/sh\necho 60 > /sys/class/power_supply/battery/batt_full_capacity\n' \
  | sudo tee /etc/local.d/batt-limit.start
sudo chmod 755 /etc/local.d/batt-limit.start
sudo /etc/local.d/batt-limit.start
cat /sys/class/power_supply/battery/status   # becomes "Not charging"
```

This is the same mechanism as One UI's "Protect battery". Writing `0` removes the cap. If
your device lacks `batt_full_capacity`, look for `store_mode` in the same directory.

Other vendors expose different paths. Check `ls /sys/class/power_supply/battery/`.

## Step 15: Verify it survives a reboot

Nothing is proven until it comes back on its own, because that is what happens on the first
power cut:

```sh
sudo reboot
```

Then confirm every piece:

```sh
uptime                                   # grows past a few minutes
cat /proc/sys/kernel/hung_task_panic     # 0
ip addr show wlan0 | grep "inet "        # same address as before
iw dev wlan0 get power_save              # off
rc-service samba status                  # started
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080
```

Measure the real throughput while you are at it:

```sh
dd if=/dev/zero bs=1M count=200 | ssh -o Compression=no user@PHONE_IP \
  'dd of=/srv/nas/speedtest.bin bs=1M'
```

## Notes

**A load average around 11 with an idle CPU is normal here.** On Samsung downstream
kernels, TrustZone threads (`tz_worker_thread`, `tz_iwsock`, `ree_time`) sit in `D` state
forever, waiting on a secure world postmarketOS never initializes. `D` state counts toward
load without consuming CPU. Confirm with `top` (idle percentage) and thermal zones (cool)
before chasing it.

**Diagnose before reflashing.** The single most expensive mistake in this build was six
reflashes based on a theory, when `/proc/last_kmsg` and `/proc/cmdline` held the answer the
whole time. Opening visibility is always cheaper than another flash cycle.

**There is no backup.** A single phone holds a single copy of your files, on storage that
cannot be swapped if it fails. Mirror `/srv/nas` somewhere else before trusting it with
anything that matters.

## Layout

```
docs/
  technical-plan.md     mainline vs downstream analysis, topology, phases
  boot-recovery.md      bootloop diagnosis and flashing techniques
scripts/
  wifi-setup.sh         connects the device to WiFi (passphrase hashed locally)
  recovery/             scripts for catching connectivity windows on an unstable device
    inject-key.sh       installs your SSH key, fixing StrictModes permissions
    probe.sh            dumps privilege, partition and hung-task state
    stabilize.sh        disables the panic via passwordless sudo, if available
    fix.sh              writes the permanent sysctl.d fix
```

Every script reads its target from environment variables, so nothing is hardcoded:

```sh
PHONE_HOST=172.16.42.1 PHONE_USER=user PHONE_KEY=~/.ssh/homelab ./scripts/recovery/probe.sh
```

The documents under `docs/` are written in Brazilian Portuguese.

Network addresses throughout are examples. Substitute your own.

## License

MIT. See [LICENSE](LICENSE).
