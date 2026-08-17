# Boot recovery log (state as of 2026-08-17)

Snapshot taken while the device was still stuck, written to hand the problem over to
another session. It is kept unedited because the reasoning matters more than the outcome:
this is what the middle of the debugging looked like, before the answer was found.

**Nature of the work:** recovering a phone owned by the person working on it, being
converted into a home server with postmarketOS. The bootloader was unlocked voluntarily by
the owner (Knox already blown, a deliberate decision). Nothing here involves offensive
security, bypassing anyone else's protection, or circumventing someone else's
authentication. All access is to the owner's own hardware with the owner's own keys. This
is operating system installation and boot diagnosis.

---

## Goal

Samsung Galaxy S10+ (SM-G975F, Exynos, broken touchscreen) running postmarketOS plus
Docker and Coolify, headless, administered from a Linux desktop over a USB-C cable that
supplies power and networking at the same time. Full plan in
[technical-plan.md](technical-plan.md).

Port in use: **beyond2lte-downstream** (kernel 4.14), revived from `device/archived/`.
The mainline `exynos9820` port was dropped for lack of cpufreq and cpuidle drivers, which
caused a thermal cutoff in under 2 minutes under load. Fatal for a PaaS that runs builds.

> **Later note.** The end state moved away from Coolify to a NAS, which suits the hardware
> far better: idle CPU, no arm64 image problem, no build write amplification.

---

## Where the project stands

The system **boots and sshd comes up**, confirmed by an ED25519 host key answering. The
project is not unfeasible; it is stuck on two concrete, well identified problems.

### Problem 1: no authorized SSH key in the rootfs

Discovered by reading the image with `debugfs`: the user's `.ssh` directory **does not
exist** inside the generated rootfs (the home directory is completely empty; the user is
UID 10000, shell `/bin/ash`, with the correct home in `/etc/passwd`). `pmbootstrap`
embedded no key at all because the desktop had no `~/.ssh/id_*`, only a key with a
different name from another project, which it does not recognize as a default key.

Consequence: even with everything booting perfectly, SSH answers
`Permission denied (publickey,password,keyboard-interactive)`. This is not a boot bug.

**Already solved on disk:** the rootfs image was prepared with the key injected through
`debugfs -w` (`authorized_keys` owned by 10000:10000, mode 0600, directory 0700), followed
by a clean `e2fsck -fy`. All that remains is writing it to the device.

### Problem 2: the boot.img on the device is from an older generation

The `boot` partition holds a debug image whose cmdline is:

```
pmos.debug-shell pmos_boot_uuid=f88bfdf4-... pmos_root_uuid=2d9ffe2f-...
```

Note what is **missing**: `hung_task_panic=0 hung_task_timeout_secs=0`. Without those
parameters the downstream kernel's `CONFIG_BOOTPARAM_HUNG_TASK_PANIC=y` brings the device
down every 2 to 4 minutes. This was the root cause of the original bootloop, diagnosed
through `/proc/last_kmsg`. It is why USB keeps dropping and reappearing: five
disconnections in the last 20 minutes.

The UUIDs are also from the old generation. The `system` partition was already rewritten
with the generation 3 boot filesystem, so the old initramfs looks for a `pmos_boot_uuid`
that no longer exists. The system still comes up sometimes because the initramfs falls back
to matching by LABEL, which explains the erratic behaviour: sometimes it drops to the debug
shell, sometimes it boots the real system, sometimes it resets.

The correct generation 3 `boot.img` is ready on disk, with the hung task parameters and
UUIDs matching the images.

> **What this section got wrong.** The premise that a correct cmdline in `boot.img` would
> fix the panic is false on Samsung devices: the bootloader discards that cmdline entirely
> and injects its own `androidboot.*` parameters. The working fix turned out to be
> `/etc/sysctl.d/99-hungtask.conf` in userspace. This document is kept as written because
> the wrong premise here cost six reflashes, and that is the lesson.

---

## What this session achieved

1. **A working flash channel without odin4.** Serial (`/dev/ttyACM0`, 115200) as the
   control channel, plus TCP over USB networking (`ncm0` on the phone against the matching
   interface on the desktop, `172.16.42.1` and `172.16.42.2`) as the data channel. `nc`
   listening on the phone, `dd` writing straight to the partition, bash `/dev/tcp` pushing
   from the desktop. Runs at about 30 MB/s.

2. **The `system` partition written and verified by sha256** with that method, confirmed by
   reading it back. Proof that the path works end to end.

3. **The odin4 failure confirmed.** The previous night's log shows
   `ioctl bulk write Fail: Connection timed out` at 50% of a 503 MB file. odin4 cannot
   sustain large transfers, and that is what corrupted the boot filesystem earlier. Do not
   persist with it for large files.

4. **Two shell traps solved**, both of which cost several attempts:
   - `busybox nc -l` **does not terminate on client EOF**. The `nc | dd` pipeline hangs
     forever. Solution: `dd` with an exact `count=` and `iflag=fullblock`, which finishes on
     its own.
   - The command echo on the serial line contains the marker text, so `grep DONE_system`
     matches the echo rather than the execution. Solution: `echo "DONE_"$part`, where the
     quotes break the literal in the echo, combined with `grep "^DONE_"`.

---

## The current obstacle

The device stopped exposing the serial console (`/dev/ttyACM0` disappeared) because it now
boots the real system instead of stopping at the initramfs debug shell. It **responds to
ping**, but:

- no serial means no shell to run `dd` in
- no key in the rootfs means SSH refuses
- port 22 flickers between open and closed, following the hung task panic resets

In other words: the flash channel that works depends on the debug shell, and the device
stopped falling into it. Either the debug shell has to be recovered, or another route
opened.

---

## Images prepared on disk

| File | What it is | Target | Status |
|---|---|---|---|
| boot filesystem, ext2, 503 MB | generation 3 | `system` partition | already written, sha verified |
| rootfs, ext4, 344 MB, **with the SSH key** | generation 3 | `userdata` partition | pending |
| rootfs, ext4, 344 MB, without the key | generation 3 | n/a | spare |
| `boot.img`, 52 MB | generation 3 cmdline | `boot` partition | pending |
| `boot-pad.img` | same, padded to a 4096 byte block | `boot` partition | pending |

Session scripts keep per-partition state in a file, so they resume where they stopped.

Device partition map: `system` is `/dev/sda25`, `userdata` is `/dev/sda31` (116 GB), `boot`
is `/dev/sda14`, `recovery` is `/dev/sda15`. All reachable through
`/dev/disk/by-partlabel/<name>`.

---

## Possible ways forward (undecided at the time)

1. **Wait for or force a debug shell window.** The device still resets on its own from the
   hung task panic; if the initramfs stops at the debug shell on some cycle, the transfer
   script catches that window and writes `userdata` plus `boot` in about 40 seconds. This
   already worked for the `system` partition.

2. **Download Mode plus odin4 for the boot image only.** It is 52 MB, below the size where
   odin4 fails, and writing only the boot image would address Problem 2. Obstacle: entering
   Download Mode without a screen. Busybox `reboot download` **does not work**, since the
   applet ignores the argument. It would need the physical buttons (Volume Down, Bixby,
   Power) or writing the reboot reason some other way.

3. **TWRP in recovery.** Notes say `adb push` plus `dd` through TWRP runs at 235 MB/s
   without failures, making it the preferred path for large files. Also depends on Download
   Mode and buttons.

4. **A boot.img with a modified initramfs** that injects the key before mounting the
   rootfs. Solves everything at once and fits within odin4's limit, but still depends on
   Download Mode.

Path 1 is the only one that needs no physical intervention. The others require someone to
hold the buttons.

> **What actually happened:** path 3. The buttons were pressed, TWRP went in through odin4
> (small file, no failure), and from the recovery shell everything else became trivial:
> root without a password, the partition mounted directly, the fix written as a file.

---

## Method (a lesson this project already paid for)

The decisive information about the bootloop sat in `/proc/last_kmsg` the entire time, and
was only read after six reflashes based on theory. Diagnosis before attempts: opening
visibility (a debug shell, logs, read-back with sha) is worth more than one more flash
cycle. Every write in this session was verified by read-back plus sha256 for exactly that
reason.
