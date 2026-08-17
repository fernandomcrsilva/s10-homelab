# Galaxy S10+ (Exynos) as a Coolify server

Headless server running postmarketOS plus Docker and Coolify, administered from a desktop.
The phone is the server; the PC is the client.

**Success criteria:** Coolify UI reachable from the desktop, device stable while plugged in
for a week without physical intervention, battery never above roughly 70%.

> **Note on the outcome.** This plan targets Coolify. During execution the goal changed to
> a NAS, which fits this hardware much better: the CPU stays idle, the arm64 image problem
> disappears, and there are no build writes wearing out the storage. The document is kept
> as written because the port analysis, the kernel work and the flashing procedure all
> apply regardless of what runs on top. See the README for what was actually built.

> **Revision of 2026-08-15.** The original plan assumed porting `beyond1lte` to
> `beyond2lte` on the downstream 4.14 kernel. Discovered during execution: pmaports
> consolidated everything into `device-samsung-exynos9820`, a **generic mainline** port
> that already declares `provides="device-samsung-beyond2lte"`. There is no porting to do.
> In exchange, the mainline kernel ships without several things the downstream had ready.
> See Phase 2.

## Choosing the port, read this first

| | `exynos9820` (mainline) | `beyond2lte-downstream` (archived) |
|---|---|---|
| Status | `testing`, added **2026-07-11**, 1 commit | archived 2026-07-12 |
| Kernel | 7.2.0 mainline | 4.14 Android (2021), unpatched |
| Docker | **missing** OVERLAY_FS, BRIDGE, netfilter, fixable by config | all present out of the box |
| WiFi | `BRCMFMAC` not compiled, uncertain | `BCM_DHD_WLAN` plus `BCM4375` ready |
| Charge limit | `constant_charge_voltage` (by voltage) | `store_mode` (60 to 70% hysteresis) |
| Init | OpenRC (the `systemd-boot` dependency is a bootloader, not an init) | OpenRC |
| Maintenance | active but embryonic | none |

**Chosen: downstream** (revised 2026-08-16, during execution).

The initial choice was mainline, for safety. It fell apart when the port's merge request
([pmaports!8999](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/8999))
revealed two blockers that no kernel config discloses:

1. **Thermal cutoff.** In the author's words: *"there is no cpuidle, cpufreq or cpuhp
   support. Stressing all 8 cores (...) bakes the SoC very quickly and it goes into thermal
   protection (hard power cutoff) (...) in under 2 minutes."* Hence `maxcpus=6` in the
   cmdline. For a PaaS that constantly runs `docker build`, this hits precisely the use
   case. Careful when reading the kconfig: `CPU_FREQ`, `CPU_IDLE` and `THERMAL` show up as
   `=y` in **both** configs, but that is only the framework. It is the Exynos 9820 drivers
   that are missing from mainline.
2. **Booting requires a custom u-boot.** Mainline boots over EFI from a custom u-boot with
   a UFS driver (`chiffathefox/u-boot`, branch `exynos9820`), compiled separately and
   written to the `boot` partition. There is no `boot.img` in the rootfs, which is exactly
   where the recovery-zip installer failed (`dd: can't open /mnt/pmOS/boot/boot.img`).

The downstream port, by contrast: complete Samsung thermal drivers, WiFi confirmed working
by the port author, `flash_method="heimdall-bootimg"` with `generate_bootimg="true"` (so
the recovery zip completes), and a 4.14 kernel that already ships nearly every container
requirement.

**Accepted cost:** a 2021 kernel without security patches, and an archived port. Mitigated
by this being a home server behind NAT.

**How to revive it** (done): copy `device-samsung-beyond2lte-downstream`,
`linux-samsung-beyond2lte-downstream` and `firmware-samsung-beyond2lte` from
`device/archived/` into `device/testing/` and **delete the originals**. A package present
in two folders makes pmbootstrap abort with "found in multiple aports subfolders".

## Topology

USB-C cable from the phone to a **rear** motherboard port: power and the administration
link on the same cable. Phone in gadget mode, `172.16.42.1`, SSH by default.

- **Power**: the USB-C port. Validated on Android, where the battery charged under load.
- **Administration**: USB gadget, point to point link. Always available.
- **Internet**: without `BRCMFMAC` compiled, WiFi is uncertain. The primary plan becomes
  **NAT on the PC** (see the appendix), which is consistent with the topology since the
  device lives plugged in. If WiFi works once enabled, better still: it becomes independent
  of the PC.
- **Access**: SSH and Coolify (`:8000`) at `172.16.42.1`.

---

# Phase 0: before touching anything

## What is irreversible

Unlocking the bootloader **blows the Knox e-fuse permanently**. There is no undo, not even
by reflashing stock firmware. Gone for good: Samsung Pay, Secure Folder, and banking apps
that check Knox.

Enabling the "OEM Unlocking" toggle blows **nothing**. The e-fuse only goes in Phase 3,
when you confirm the warning in Download Mode.

## Checklist

| Check | Status |
|---|---|
| Model is Exynos | confirmed |
| OEM Unlock enabled | done |
| PC port supplies enough power | battery charged under load on Android |
| Battery healthy (no swelling) | visual inspection |
| Stock firmware downloaded | **pending, and it is the only way back** |
| TWRP for `beyond2lte` downloaded | pending |

**Stock firmware (Linux):** get the CSC via `*#1234#` in the dialer (Brazil is usually
`ZTO`), then use the [samloader](https://github.com/samloader/samloader/releases) binary:

```bash
./samloader -m SM-G975F -r <CSC> checkupdate
./samloader -m SM-G975F -r <CSC> download -v <version> -O ~/Downloads/stock
```

**TWRP:** `twrp-*-beyond2lte.img.tar` from
<https://twrp.me/samsung/samsunggalaxys10plus.html>. Check the codename carefully:
beyond0lte (S10e) and beyond1lte (S10) are listed too, and the wrong one will not boot.

---

# Phase 1: prepare the desktop

```bash
sudo pacman -S --needed pmbootstrap heimdall android-tools
pmbootstrap init
```

Put the work path on a disk with room to spare. A root filesystem with 14 GB free will fill
up during the build.

Answers: channel `edge`, vendor `samsung`, codename **`exynos9820`**, UI `none`, extra
`openssh`, SSH key `y`, full disk encryption **`n`** (with no screen, you cannot type a
passphrase at boot).

The init asks for providers of more than one package. Read the package name before
answering:

| Provider for | Answer |
|---|---|
| `postmarketos-base-ui-audio-backend` | Enter (`pulseaudio`). Irrelevant without a UI. |
| `postmarketos-base-ui-wifi` | Enter (`wpa_supplicant`). |
| `postmarketos-usb-moded-default-profile` | **`developer`**, which is already the default |

Under "Additional options", answer `y` and set **`sudo timer: True`** to avoid retyping the
password during builds. Accept the rest with Enter.

Service manager: **OpenRC**. The `systemd-boot` in the device dependencies is a bootloader,
not an init system.

The `developer` profile is critical: the `charging` profile requires enabling USB
networking by hand, which on a screenless device is circular, since you would need access
in order to create access.

---

# Phase 2: adjust the kernel

Kernel `7.2.0-r0` compiled and verified in the `.apk`'s `boot/config`: `OVERLAY_FS=m`,
`NF_TABLES_IPV4=y`, `NFT_COMPAT=m`, `NF_NAT=y`, `BRIDGE=m`, `VETH=y`, complete cgroups and
namespaces, USB gadget (RNDIS/NCM/DWC3), `BRCMFMAC=m`, `CHARGER_MAX77705=y`.

It took **two** build rounds. The first passed `kconfig check` and still produced a kernel
with no container networking. Read the legacy iptables section below before repeating this
on another device.

This replaces the old "port the package" step: there is no porting to do, but the mainline
config was trimmed for phone use and lacks what Docker needs.

**Do not assemble the list by hand.** pmbootstrap already ships the official container
requirements in `kconfigcheck.toml` (category `containers`, around 70 options, far more
than the 9 obvious ones):

```bash
pmbootstrap kconfig check --categories containers linux-postmarketos-exynos9820
```

In the original state **44** were missing. They were applied to
`config-postmarketos-exynos9820.aarch64` by reading values straight from the TOML, plus
`BRCMFMAC`, `BRCMFMAC_SDIO` and `BRCMUTIL` as a WiFi attempt. Five options ended as `y`
where the TOML asked for `m` (`VETH`, `NF_NAT`, `NETFILTER_XT_MARK`, `XT_MATCH_CONNTRACK`,
`NET_CLS_CGROUP`). `y` is stronger, and the check accepts it as INFO.

Keep a backup of the original config, but **not inside the package directory**: the
validator tries to parse a stray `.bak` as a config and fails.

The config is listed in the APKBUILD `source=`, so it carries a `sha512sum`. **Editing the
config without regenerating the checksum makes the build fail.** And `build` without
`--force` does nothing at all, because pmbootstrap compares versions rather than content
and considers the package up to date:

```bash
pmbootstrap checksum linux-postmarketos-exynos9820 && \
pmbootstrap build linux-postmarketos-exynos9820 --force
```

**Gate:** it compiles **and** the options survived. Do not trust `kconfig check` for this:
it validates the text file, not the kernel's real Kconfig. Extract `boot/config` from the
generated `.apk` and compare. That is the only source of truth.

### Legacy iptables does not exist in kernel 7.2

On the first round, 16 of the 44 options vanished from the compiled kernel. They were not
disabled: they **do not exist** in the 7.2 Kconfig. The legacy iptables tables
(`IP_NF_FILTER`, `IP_NF_NAT`, `IP_NF_MANGLE`, `IP_NF_RAW`, `IP_NF_TARGET_MASQUERADE`,
`IP_NF_TARGET_REDIRECT`, their `IP6_NF_*` equivalents, plus `NFT_NAT`, `NFT_FIB*` and
`BRIDGE_VLAN_FILTERING`) were removed. Only isolated matches remain.

The pmaports `kconfigcheck.toml` was written for kernels with legacy iptables and does not
reflect this, which is why the check "passed" while the real kernel had none of it.

In 7.2 everything goes through **nftables**, with `NFT_COMPAT` translating userspace calls.
What actually needs to be enabled, and came disabled:

```
CONFIG_NF_TABLES_IPV4=y      # without this there is NO ipv4 NAT, so Docker cannot port map
CONFIG_NF_TABLES_IPV6=y
CONFIG_NF_TABLES_INET=y
CONFIG_NF_TABLES_BRIDGE=m
CONFIG_NFT_REDIR=m
CONFIG_NFT_REJECT=m
CONFIG_NFT_LOG=m
CONFIG_NFT_LIMIT=m
CONFIG_VLAN_8021Q=m
```

Already correct: `NF_TABLES=m`, `NFT_COMPAT=m`, `NFT_MASQ=m`, `NFT_CT=m`,
`NF_NAT_MASQUERADE=y`, `IP_NF_IPTABLES=y`, `IP6_NF_IPTABLES=y`.

The 16 nonexistent options remain written in the config. Kbuild ignores them, so they are
harmless. They stay only to keep `kconfig check` from blocking future builds. **They prove
nothing.**

---

# Phase 3: install and flash

Point of no return. From here on, going back means flashing stock firmware.

**The rootfs does not go through heimdall** (`flash_method="none"`: *"Heimdall fails
mid-transfer when flashing rootfs. Use TWRP instead"*). It goes as a **zip via ADB sideload
in TWRP**, per the device wiki. Heimdall is only used to put TWRP into recovery.

## 3.1 Generate the zip

```bash
pmbootstrap install --android-recovery-zip --recovery-install-partition data
```

Installing to the `data` partition is what gives Docker room, since it is the largest on
the device at around 100 GB.

## 3.2 Unlock the bootloader, where Knox blows

Download Mode (powered off, then Volume Down plus Bixby plus Power, or plug in while
holding Volume Down plus Bixby), then Volume Up to confirm the warning. The device factory
resets.

After that, **go through Android setup and re-enable OEM Unlocking** in developer options.
VaultKeeper blocks flashing until you do, and heimdall fails with an error that does not
explain the cause.

## 3.3 TWRP into recovery

Heimdall with the TWRP image for `beyond2lte`
(<https://twrp.me/samsung/samsunggalaxys10plus.html>). Boot straight into TWRP afterwards:
**Volume Up plus Bixby plus Power**.

## 3.4 Sideload postmarketOS

In TWRP, in this order:

1. **Mount, then uncheck `Data`.** The wiki is emphatic: the partition must be unmounted.
2. Advanced, then ADB Sideload

```bash
adb sideload pmos-samsung-exynos9820.zip
```

**Gate:** SSH to `172.16.42.1` answers. A dark screen with SSH alive means success.

---

# Phase 4: calibration on real hardware

## 4.1 Charge limit, always first

Mainline lacks Samsung's `store_mode`. The `max77705_charger` driver exposes
`CONSTANT_CHARGE_VOLTAGE`, a float voltage limit, which is the classic method:

```bash
ls /sys/class/power_supply/*/
# look for constant_charge_voltage (µV). 4400000 is roughly 100%, 3950000 roughly 65%
echo 3950000 > /sys/class/power_supply/<charger>/constant_charge_voltage
```

Persist it in a service. Confirm it took effect by watching `capacity` level off.

If the property is read only, the fallback is a userspace script toggling `ONLINE` and
`STATUS` by hysteresis, at which point the downstream port (with `store_mode`) becomes
tempting again.

> **What was actually used:** the downstream port, and therefore
> `echo 60 > /sys/class/power_supply/battery/batt_full_capacity`, which is the same
> mechanism as One UI's "Protect battery". Status turns to `Not charging` at the cap.

## 4.2 Input current

Validated in Phase 0 (battery charged under load). If you change port or cable, the knob is
`input_current_limit` in the same directory. Check it once under a real `docker build`.

## 4.3 Internet

Try WiFi first, now that `BRCMFMAC` has been compiled:

```bash
nmcli device wifi connect "<SSID>" password "<passphrase>" && ping -c3 1.1.1.1
```

If it works, the server becomes independent of the PC. Reserve its IP on the router by MAC.
If it does not, go to the NAT appendix. The USB link is point to point and does **not**
provide internet on its own, and without internet nothing in Phase 5 runs.

> **On the downstream port** the tools differ: `iwlist` and `iwconfig` report
> `no wireless extensions` because `bcmdhd` speaks nl80211. Use `iw`. Also disable WiFi
> power save, or latency swings between 70 and 255 ms.

## 4.4 Power cycle test

`poweroff`, reconnect power, see whether it comes back on its own. Find out now, not at
3 in the morning.

---

# Phase 5: Docker and Coolify

## 5.1 Log limits, before the first container

The storage is soldered UFS; if it dies, the server dies. `/etc/docker/daemon.json`:

```json
{ "log-driver": "local", "log-opts": { "max-size": "10m", "max-file": "3" } }
```

## 5.2 Coolify

The official installer nominally supports `postmarketos`, with a dedicated branch for
OpenRC (`apk add docker docker-cli-compose` plus `rc-update add docker default`):

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sh
```

UI at `http://172.16.42.1:8000`.

**Gate:** the UI loads from the desktop and a test deployment (an `arm64` image) comes up.

ARM64 caveat: part of the one-click catalog publishes no `arm64` image. Those need building
by hand. This caveat is the main reason the project moved to a NAS instead.

---

# Phase 6: operation

- **Away from home**: `tailscale` gives a stable address without opening a port.
- **Published apps**: Cloudflare Tunnel, integrated into Coolify.
- **Backup**: `/data/coolify` off the device. The UFS is the single point of failure.

---

# Rollback

| Situation | Way out |
|---|---|
| Did not boot, no SSH | Download Mode, then heimdall with the Phase 0 stock firmware |
| Mainline unworkable (Docker, WiFi, battery) | Revive `device/archived/*beyond2lte-downstream` |
| Kernel broken after a rebuild | Reflash the previous kernel |

---

# Known risks

| Risk | Status |
|---|---|
| Knox blown | Consciously accepted. Irreversible. |
| Mainline port one month old | **Accepted**, the central risk of the project. Fallback documented. |
| Charge limit by voltage | **Open**, Phase 4.1. Reassess if the property is read only. |
| WiFi on mainline | **Open**, Phase 4.3. NAT covers it. |
| TWRP flashing not documented here | **Open**, confirm on the wiki before Phase 3. |
| Does not power on by itself | **Open**, Phase 4.4. |
| Battery drains while cabled | Ruled out, tested on Android. |
| UFS wear | Mitigated by log limits and external backup. |
| Screen does not light up | Irrelevant when headless. |

---

# Appendix: internet over the cable (NAT on the PC)

Likely the main path, given uncertain WiFi. Cost: no internet while the PC is off.

On the desktop, with `eth0` standing in for your internet interface and `ufw` active, set
in `/etc/default/ufw`:

```
DEFAULT_FORWARD_POLICY="ACCEPT"
```

At the top of `/etc/ufw/before.rules`, before `*filter`:

```
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 172.16.42.0/24 -o eth0 -j MASQUERADE
COMMIT
```

```bash
sudo ufw reload
```

On the phone:

```bash
ip route add default via 172.16.42.2
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

---

# References

- mainline device: `device/testing/device-samsung-exynos9820` in pmaports
- kernel: https://github.com/chiffathefox/exynos-9820-mainline-linux
- S10+ wiki: https://wiki.postmarketos.org/wiki/Samsung_Galaxy_S10%2B_(samsung-beyond2lte)
- Coolify: https://coolify.io/docs/get-started/installation
