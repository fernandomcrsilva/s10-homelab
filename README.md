# Phone Homelab

A Samsung Galaxy S10+ (SM-G975F, Exynos 9820) with a broken screen, turned into a
headless home server running postmarketOS.

It serves files over Samba, exposes a web file manager, blocks ads for the whole network
and reports its own health. It pushes **60 MB/s over WiFi**, draws **0.39 W** at idle, and
lasts roughly a day unplugged, because the phone battery doubles as a built-in UPS.

## What runs on it

| Service | Purpose |
|---|---|
| Samba | file sharing on the local network |
| filebrowser | web file manager (upload, preview, download) |
| AdGuard Home | network-wide DNS ad blocking |
| netdata | real-time monitoring (CPU, temperature, network, disk) |
| Tailscale | remote access without opening router ports |

Everything starts on boot, verified through a full reboot.

## Measured numbers

- **Write:** 60.8 MB/s · **Read:** 49.3 MB/s (5 GHz WiFi, over SSH)
- **Latency:** 4 ms, down from 70 to 255 ms before disabling WiFi power save
- **Power draw:** 91 mA at 4.28 V = 0.39 W idle
- **Temperature:** 30 to 36 °C under normal operation
- **Storage:** 103 GB usable out of the 128 GB internal

For comparison, an idle Raspberry Pi 4 draws 3 to 5 W.

## The three traps that cost hours

This repository exists mostly because of these. Each one burned significant time, and none
is documented anywhere obvious.

### 1. Samsung's bootloader discards the boot.img cmdline

The downstream kernel ships `CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y`, which killed the device
every few minutes. The obvious fix is passing `hung_task_panic=0` in the `boot.img`
cmdline, and it **does not work**. The bootloader throws that cmdline away and injects its
own (`androidboot.*`), as `/proc/cmdline` plainly shows.

Six reflashes were done on that wrong assumption before anyone read `/proc/cmdline`. The
fix that works lives in userspace:

```sh
# /etc/sysctl.d/99-hungtask.conf
kernel.hung_task_panic = 0
kernel.hung_task_timeout_secs = 0
```

The `sysctl` service is already in the `boot` runlevel, and the 120 s timeout leaves plenty
of room for it to apply before the first panic.

### 2. The WiFi driver doesn't speak the old API

`iwlist` and `iwconfig` return `no wireless extensions` and `Interface doesn't support
scanning` on Samsung's `bcmdhd`. That looks like broken hardware, but it isn't. The driver
uses nl80211, so the right tool is `iw`:

```sh
apk add iw
iw dev wlan0 scan | grep SSID
```

The firmware (`firmware-samsung-beyond2lte`) ships preinstalled in the right place. The
interface was simply `down`.

Once connected, **disable power save**. Without it, ping swings between 70 and 255 ms:

```sh
iw dev wlan0 set power_save off   # persist via /etc/local.d/
```

### 3. OpenRC's conf.d loses to the init script

OpenRC sources `/etc/conf.d/<service>` **before** running the init script. Any variable the
init script sets directly overrides whatever you put in `conf.d`.

`/etc/init.d/filebrowser` hardcodes `command_user="filebrowser:filebrowser"`, so the
service ignored the configuration and ran as the wrong user. It failed to reach its files
and logged nothing at all. The only symptom was `status: crashed`.

To surface the real error, declare log targets in `conf.d`:

```sh
output_log="/var/log/service/out.log"
error_log="/var/log/service/err.log"
```

## Per-service notes

- **AdGuard Home:** the router advertises *itself* as an IPv6 DNS server via Router
  Advertisement, and clients prefer IPv6, so blocking is silently bypassed even with DHCP
  pointing at AdGuard. ISP-provided routers often won't let you disable this. The way out
  is pinning DNS per client (`ipv4.ignore-auto-dns yes` plus `ipv6.ignore-auto-dns yes`
  under NetworkManager).
- **filebrowser 2.27.0:** the bundled CSS ships a literal `__VITE_ASSET__` placeholder where
  the icon font URL should be, so icons render as their own names in plain text. Work
  around it with `--branding.files` and a `custom.css` embedding the font. Its database is
  BoltDB, which allows a single process at a time, so running `config set` while the
  service is up fails with a silent timeout.
- **Battery:** `echo 60 > /sys/class/power_supply/battery/batt_full_capacity` caps charging.
  It's the same mechanism behind One UI's "Protect battery", and it matters for a device
  that stays plugged in permanently.
- **netdata:** configured with `[db] mode = ram`. The internal storage can't be replaced,
  so it isn't worth spending write cycles on metrics.

## About the load average

The system reports a load average around 11 while the CPU sits 97% idle and the device runs
at 30 °C. Those are Samsung TrustZone kernel threads (`tz_worker_thread`, `tz_iwsock`,
`ree_time`) stuck in `D` state, waiting on a secure world postmarketOS never initializes.
`D` state counts toward load without consuming CPU. It's cosmetic.

## Flashing tools

`odin4` fails on large files (`ioctl bulk write Fail` around 50% of a 503 MB image) but
handles small images fine. For everything else, TWRP in recovery is the reliable path:
passwordless root, `adb push` at ~35 MB/s and `dd` at 157 MB/s.

Button combos (blind, with a broken screen):

- **Download Mode:** Volume Down + Bixby + Power
- **Recovery:** Volume Up + Bixby + Power

## Layout

```
docs/
  plano-tecnico.md      mainline vs downstream analysis, topology, phases
  recuperacao-boot.md   bootloop diagnosis and flashing techniques
scripts/
  wifi-s10.sh           connects the device to WiFi (passphrase hashed locally)
  recuperacao/          scripts from the era when the system rebooted on its own
```

The documents under `docs/` are written in Brazilian Portuguese.

The scripts in `recuperacao/` were built to catch two-minute connectivity windows between
spontaneous reboots. Once `sysctl.d` fixed the root cause they became obsolete. They remain
here as a record of the technique, which may help anyone fighting an unstable device.

## Caveats

Network addresses in these documents were replaced with examples. Adjust them for your own
network before running any script.

This is the record of one specific device. An unlocked bootloader means permanently blown
Knox and a voided warranty, a deliberate choice by the owner of the hardware.

## License

MIT. See [LICENSE](LICENSE).
