# Armbian / Debian userspace on the Kobra S1 host board

Research on paper (2026-10-22): what would it take to run Armbian, or another
Debian/Ubuntu userspace, on the RV1106G3 host board instead of the Buildroot rootfs?
Nothing was built, flashed or run on a board for this page. FreeDi, the community OS for
QIDI printers, is built on Armbian, which is what raised the question.

**Short answer:** the Armbian *image* cannot be used. It brings its own bootloader, GPT
layout and a 6.1 kernel without the Kobra drivers, and installing it would overwrite the
stock fallback. A Debian *userspace* (debootstrap, or the rootfs taken out of an Armbian
image) can run on **our** kernel from a directory on `useremain`, started by a small
loader in our system slot. That needs about 15 kernel config options, costs about
30–45 MB of the ~155 MB of free RAM, and gives up the read-only image and power-loss
safety. It is feasible, but it is not worth it as the default. Details and a cheaper
middle ground are in [Recommendation](#6-recommendation).

Sections 1–6 assume today's layout with stock kept in the other slot. The project's goal
is to replace the Anycubic data on the eMMC completely; what changes then (the storage
limit goes, RAM and the missing maskrom recovery stay) is in
[section 7](#7-without-the-stock-firmware-whole-emmc).

## 1. Who supports RV1106 at all

### Armbian

Armbian has had a **community** `rockchip-rv1106` family since November 2025
([family config](https://github.com/armbian/build/blob/main/config/sources/families/rockchip-rv1106.conf),
first commit [`dfe371a0`](https://github.com/armbian/build/commit/dfe371a0)):

| | |
|---|---|
| Boards | [Luckfox Pico Pro / Max](https://github.com/armbian/build/blob/main/config/boards/luckfox-pico-max.csc) (RV1106, 128/256 MB, no maintainer listed), [Luckfox Pico Mini](https://github.com/armbian/build/blob/main/config/boards/luckfox-pico-mini.csc) (RV1103, 64 MB). `.csc` = community supported, no Armbian guarantees |
| Kernel | `vendor` branch: Rockchip BSP **6.1** (`armbian/linux-rockchip` `rk-6.1-rkr7.2`, 6.1.172 since Sep 2026), `vendor-next`: 6.12 ([rockchip_vendor_common.inc](https://github.com/armbian/build/blob/main/config/sources/families/include/rockchip_vendor_common.inc)). No mainline kernel |
| Bootloader | its own: Radxa U-Boot `next-dev-buildroot` + boot script, written raw at sectors 0x40 (idblock) and 0x440 (`u-boot.itb`); GPT partition table |
| Userspace | armhf, glibc, systemd. Images on [armbian.com/boards/luckfox-pico-max](https://www.armbian.com/boards/luckfox-pico-max): Debian 13 trixie minimal (283 MB), Ubuntu 26.04 minimal (293 MB), Ubuntu 26.04 Xfce (753 MB), all with 6.1.172, built 2026-10-20 |
| Low-memory work | `lowmem` extension ([lowmem.sh](https://github.com/armbian/build/blob/main/extensions/lowmem.sh)): swapfile service, fixed 20 MB `/run` ("systemd throws errors when <16MB is free … during daemon-reload"), ramlog and zram off. Commits "Limit udev children to prevent early OOM" ([`91228407`](https://github.com/armbian/build/commit/91228407)) and "Reduce kernel memory footprint" ([`c8cae80e`](https://github.com/armbian/build/commit/c8cae80e), RV1103 stopped booting after a config change) show how close to the edge these boards are |

The Armbian kernel config for the family
([linux-rockchip-rv1106-vendor.config](https://github.com/armbian/build/blob/main/config/kernel/linux-rockchip-rv1106-vendor.config))
is a useful reference for what a systemd userspace wants on this SoC: `CGROUPS`, `MEMCG`,
`CGROUP_{SCHED,PIDS,FREEZER,DEVICE,CPUACCT,BPF}`, `BPF_SYSCALL`, `NAMESPACES`, `USER_NS`,
`EXT4_FS_POSIX_ACL`, `ZSWAP`, `ZRAM=m`, `OVERLAY_FS=m`, `BLK_DEV_INITRD`.

### Luckfox

- The Luckfox Pico SDK (the one we build the kernel and rootfs from) shipped an **Ubuntu
  22.04.3** rootfs from December 2023 ([`226c3fbd`](https://github.com/LuckfoxTECH/luckfox-pico/commit/226c3fbd)
  "ubuntu: add ubuntu support") until **May 2025**, when commit
  [`d2da6f0f`](https://github.com/LuckfoxTECH/luckfox-pico/commit/d2da6f0f) removed all
  `BoardConfig-*-Ubuntu-*` files. The SDK we pin (`824b817f`) only offers Buildroot and
  Busybox.
- The rootfs is a prebuilt tarball in the submodule
  [luckfox-eng33/pico_ubuntu](https://github.com/luckfox-eng33/pico_ubuntu):
  `luckfox-ubuntu-22.04.3.tar.gz`, about **308 MiB compressed**, armhf, **glibc 2.35**,
  systemd 249.
- Kernel: the same SDK kernel we use, **Rockchip 5.10.160**, with
  `luckfox_rv1106_linux_defconfig`. That defconfig has `CONFIG_CGROUPS=y` but no
  namespaces, no autofs, no memcg. So Ubuntu 22.04's systemd booted on a 5.10.160 BSP
  kernel with only the bare cgroup option: good evidence for section 2.
- Layout on the Pico Ultra (eMMC, removed config, still visible at
  [`485f09ec`](https://github.com/LuckfoxTECH/luckfox-pico/blob/485f09ec/project/cfg/BoardConfig_IPC/BoardConfig-EMMC-Ubuntu-RV1106_Luckfox_Pico_Ultra-IPC.mk)):
  `32M(boot),512M(oem),256M(userdata),6G(rootfs)`, rootfs ext4, `rk_dma_heap_cma=36M`.
  Luckfox gave Ubuntu a **6 GB** root partition.
- RAM at idle: no figure for the 256 MB board. The one measurement found is from a Pico Pro
  (128 MB, 66 MB CMA reserved, so 56 MB visible) running the Luckfox Ubuntu SD image:
  **12 MB used**, 42 MB buff/cache, 40 MB available, 25 MB already in swap
  ([LuckfoxTECH/luckfox-pico#69](https://github.com/LuckfoxTECH/luckfox-pico/issues/69):
  "Even an apt upgrade was torture with 64MB"). So a stripped systemd Ubuntu idles in a few
  tens of MB, but `apt` needs swap on these boards. Luckfox's FAQ gives ~181 MB available
  for the Pico Max with the camera CMA reduced ([FAQ](https://wiki.luckfox.com/Luckfox-Pico-RV1106/FAQ/)).

### Why FreeDi can do it

FreeDi runs on QIDI's Makerbase boards (X-Plus 3, X-Max 3, Q1 Pro, Plus 4), which Armbian
supports as `mkspi` / `qidi-x6` / `qidi-x7`: **RK3328, quad Cortex-A53, 1 GB RAM**, eMMC
with a normal GPT and no A/B scheme
([mkspi.csc](https://github.com/armbian/build/blob/main/config/boards/mkspi.csc),
[FreeDi](https://github.com/Phil1988/FreeDi)). That is four cores and four times the RAM of
the Kobra S1 host, and nothing on the eMMC has to be kept for a vendor fallback.

## 2. Kernel

**Armbian's kernel is not an option.** Its 6.1 BSP kernel has no Kobra S1 device tree and
lacks two of our patches (FocalTech touch built in, RTL8723DS vendor driver on the newer
kernel), and the Realtek BT `hci_uart.ko` would have to be ported again. Its U-Boot cannot
be installed without replacing the stock SPL/U-Boot that both slots share. Re-doing the
whole bring-up on 6.1 is possible, but it is a separate project with no benefit for the
userspace question.

**Our kernel can boot a Debian userspace** after a config change. The kernel does not
care which libc the userspace uses (ours is built with the uClibc toolchain, Debian armhf is
glibc; the syscall ABI is the same EABI hard-float). Cortex-A7 with VFPv4/NEON meets the
Debian armhf baseline (ARMv7 + VFPv3-D16). The modules from
`modules-5.10.160.tar.gz` and `oem_ours.img` load the same way under Debian.

What the current config (`build/kernel/config`, `rv1106_defconfig` + `rv1106-evb.config` +
[kobra_s1.config](../../kernel/configs/kobra_s1.config)) has and lacks against the
[systemd v257 README](https://github.com/systemd/systemd/blob/v257/README) (Debian 13 ships
systemd 257):

| Option | Ours | Needed for |
|---|---|---|
| `DEVTMPFS`, `INOTIFY_USER`, `SIGNALFD`, `TIMERFD`, `EPOLL`, `UNIX`, `SYSFS`, `PROC_FS`, `FHANDLE` | y | required, present |
| `SECCOMP_FILTER`, `KCMP` | y | recommended, present |
| **`CGROUPS`** | **not set** | **required: systemd does not start without it** ("it is OK to disable all controllers") |
| `MEMCG`, `CGROUP_PIDS`, `CGROUP_SCHED` (+`FAIR_GROUP_SCHED`) | not set | `MemoryMax=` / OOM handling per service (useful to protect klippy), `TasksMax=`, `CPUWeight=` |
| `BPF_SYSCALL`, `CGROUP_BPF` | not set | `DevicePolicy=` and `IPAddressDeny=` on cgroup v2; several Debian units use `DeviceAllow=` |
| `AUTOFS_FS` | not set | recommended (binfmt_misc automount, `x-systemd.automount` in fstab) |
| `NAMESPACES` + `UTS_NS`, `IPC_NS`, `PID_NS`, `NET_NS` (`USER_NS` optional) | not set | `PrivateNetwork=`, `ProtectHostname=`, `PrivateIPC=` in Debian's own units (logind, timesyncd, resolved). systemd skips most of these when unsupported, but some units then fail with `226/NAMESPACE`; cheaper to enable them than to debug unit by unit |
| `TMPFS_XATTR`, `TMPFS_POSIX_ACL`, `EXT4_FS_POSIX_ACL` | not set | recommended; journald sets ACLs on journal files |
| `IPV6` | m | recommended built in (or loaded early); networkd/resolved expect it |
| `POSIX_MQUEUE` | not set | some packages; cheap |
| **`SWAP`** (+ `ZRAM`, `ZSMALLOC`, `CRYPTO_LZ4`) | not set | `apt` on 190 MB (see section 4); Armbian's `lowmem` relies on a swapfile |
| `BLK_DEV_LOOP`, `OVERLAY_FS` | not set | only for the image + overlay variant in section 6 |
| `BLK_DEV_INITRD` | not set | not needed with the loader in section 3 |
| `VT` | not set | fine: getty runs on `ttyFIQ0` (`serial-getty@ttyFIQ0`, from `console=`) |

These go into a fragment on top of `kobra_s1.config`. The Buildroot rootfs boots with them
as well (busybox ignores cgroups), so one kernel can serve both userspaces. Costs: a few
hundred KB of zImage (the boot partition is 16 MiB, our boot.img about 4 MB) and around
1 MB of RAM for memcg bookkeeping. A new kernel is the riskiest part of any test and
falls under the normal [A/B fallback](../update.md#if-shednaja-does-not-start).

## 3. Storage and `root=`

The system slot (`system_a` p8 / `system_b` p9) is 48 MiB and holds our 43 MiB squashfs.
A Debian rootfs does not fit: Armbian's trixie *minimal* image is 283 MB, Luckfox's Ubuntu
tarball 308 MiB compressed; with Python, Klipper, Moonraker, Mainsail and HelixScreen a
usable system is about **0.6–1 GB** unpacked. Even as xz squashfs it would be well over
100 MB.

The only space is **`useremain`** (mmcblk0p17, ext4, about 6 GB), which already holds
`printer_data`, logs, gcode and update bundles, and which stock uses too. Re-partitioning
is out: the eMMC layout comes from `blkdevparts=` in the U-Boot env, which both slots share,
and the project rule is never to format `userdata` / `useremain`.

**How it would boot without touching U-Boot:** U-Boot keeps setting `root=` to the
active system partition. The ShedNaja squashfs in that slot becomes a loader:

1. The kernel mounts our squashfs as `/` as today; `/sbin/init` is a short busybox script.
2. It mounts `/proc`, `/sys`, `/dev`, runs `e2fsck -p` on `useremain` and mounts it rw (the
   same steps `S00kobra-mounts` does today).
3. If `/useremain/shednaja/debian/sbin/init` exists **and** a boot flag is set, it bind-mounts
   that directory, `pivot_root`s into it (old root under `/run/shednaja-loader`, unmounted
   later) and `exec`s `/sbin/init` = systemd as PID 1. (`switch_root` only works from an
   initramfs, `pivot_root` from a real root is fine.)
4. Otherwise it `exec`s busybox init and the normal Buildroot ShedNaja comes up.

Consequences:
- **No U-Boot env, partition or `root=` change.** The stock slot is not touched; SPL A/B
  works as before.
- **A/B covers only kernel, oem and the loader.** `kobra-update` keeps writing
  `boot_<slot>`, `oem_<slot>` and `system_<slot>`; the Debian root on `useremain` is updated
  with `apt` and has **no** rollback. Two root directories (`debian-a`, `debian-b`) would
  give one, but ext4 has no snapshots, so that doubles the space and every update means
  copying the whole tree.
- **The Buildroot system stays on the eMMC** as a fallback between Debian and stock
  (step 4). With a one-shot flag (step 3 consumes it, Debian sets it again once booted)
  a Debian that hangs comes back as Buildroot ShedNaja after one power cycle.
- **`S99kobra-bootok` does not run under Debian.** A systemd unit has to call
  `kobra-abctl` (rebuilt for glibc, or static) to mark the slot good, or SPL falls back to
  stock after 7 boots. `REBOOT_TO_STOCK`, `kobra_slot`, `kobra-update`, the USB update at
  boot and the camera/Wi-Fi/BT start scripts all need systemd units.
- **The root shares an ext4 with stock.** Stock's `S20linkmount` runs `mke2fs` when a mount
  fails ([rootfs-build.md](../rootfs-build.md)). That would wipe a Debian root together with
  `printer_data` (the latter is already at risk today). A stock factory reset may clear
  `useremain` too (not checked).
- `udev` instead of `mdev`: `/dev/block/by-name/*` needs a rule
  (`ENV{PARTNAME}=="?*", SYMLINK+="block/by-name/$env{PARTNAME}"`), because the eMMC uses
  `blkdevparts=`, not GPT, and udev's by-partlabel links come from GPT.

## 4. Memory and CPU

Today: 215 MB visible, about **155 MB available** after boot with Klipper, Moonraker,
HelixScreen and the camera; `SHAPER_CALIBRATE` peaks klippy at about **60 MB RSS**
([rootfs-build.md](../rootfs-build.md)). Base processes today: busybox init, syslog, ntpd,
dropbear, lighttpd, wpa_supplicant, udhcpc, a few MB in total.

Estimated Debian 13 base with systemd (typical RSS on armhf, no swap; measure on the board):

| Process | MB | Notes |
|---|---|---|
| systemd (PID 1) | 8–10 | |
| systemd-journald | 5–8 | `Storage=volatile`, `RuntimeMaxUse=8M`, or forward to a file on useremain |
| systemd-udevd | 3–4 | `children-max=1`, as Armbian does |
| dbus-daemon, systemd-logind | 4–6 | logind is pulled in by `libpam-systemd` |
| network: systemd-networkd + resolved, or ifupdown + wpa_supplicant | 5–8 | NetworkManager would add ~15 MB more: avoid |
| sshd (openssh) | 3–4 | dropbear is ~1 MB and still available in Debian |
| cron/timers, getty | 1–2 | |
| `/run` tmpfs | ≤ 20 | Armbian pins 20 MB; only used space costs RAM |
| **Total base** | **~30–45** | vs ~5–10 today |

Applications: Python 3.13 (Debian) instead of 3.11 on uClibc. glibc's malloc arenas make
threaded Python processes larger (`MALLOC_ARENA_MAX=2` for klippy and Moonraker brings
that back close); Moonraker with the Debian dependency set is about the same. HelixScreen is
a static binary and does not change. mjpg-streamer is not in Debian; it would be built from
source (as crowsnest does) or replaced by `ustreamer` (in Debian).

**Estimate: about 110–125 MB available** with the same services instead of ~155 MB.
`SHAPER_CALIBRATE` (+40–45 MB over idle klippy) still fits with roughly 60–80 MB to
spare. Tight spots:
- **`apt`.** `apt update` on trixie main loads ~40–60 MB of package lists/cache, `apt
  upgrade` with dpkg triggers (man-db, initramfs) more. Running that while printing risks the
  OOM killer picking klippy. Needs `CONFIG_SWAP` + zram (CPU cost on one core) or a swapfile
  on the eMMC (wear), and in practice "no apt while printing".
- **KIAUH / pip builds.** KIAUH installs Klipper and Moonraker into virtualenvs and compiles
  wheels that piwheels does not cover for Debian (greenlet, cffi, numpy for
  `SHAPER_CALIBRATE`). On one Cortex-A7 at 1.4 GHz that takes tens of minutes for numpy
  alone and needs swap. Using Debian's `python3-numpy` etc. with `--system-site-packages`
  avoids it.
- **CPU.** systemd boot adds maybe 10–30 s on one core (generators, udev coldplug,
  journald). At runtime journald and logind are idle. The CPU is already busy during prints
  (klippy, camera decode on the display), so the extra base load matters less than the RAM.

## 5. Plan for a first boot test (not executed)

On the spare host board (no MCUs attached, so no real print or `SHAPER_CALIBRATE` there;
the memory test with prints comes later on a printer). Pre-conditions: the board runs
ShedNaja in one slot and stock in the other, `REBOOT_TO_STOCK` works, there is an eMMC
backup ([test-board-access.md](../history/test-board-access.md)), and **the serial console
on J1 is connected** ([hardware.md](../hardware.md)).

1. **Kernel.** Add a fragment (`kernel/configs/kobra_s1_systemd.config`) with the options from
   section 2, build `boot.img`, install it through the normal update path and check that
   Buildroot ShedNaja still boots and Klipper, Wi-Fi, BT, display, camera work. If the kernel
   does not boot: power-cycle up to 7 times and SPL boots stock; reinstall the old bundle.
2. **Rootfs on the host (WSL).** `mmdebstrap --arch=armhf --variant=minbase trixie` with
   `systemd systemd-sysv udev dbus iproute2 wpasupplicant openssh-server (or dropbear) e2fsprogs
   python3 python3-venv ca-certificates sudo git`, using qemu-user-static, as a tar. Add:
   `/lib/modules/5.10.160` from `modules-5.10.160.tar.gz`; `/etc/modprobe.d/kobra-wifi.conf`;
   the by-name udev rule; `serial-getty@ttyFIQ0`; journald volatile config; a root password or
   SSH key; `wpa_supplicant` pointed at the shared `/userdata/wifi_cfg/wpa_supplicant.conf`;
   `/etc/fstab` with `/oem`, `/userdata` (and `useremain` already mounted by the loader);
   a unit that marks the boot good with `kobra-abctl`, **left out for the first boots** so
   that power cycles still count toward the stock fallback. Alternative source: the rootfs
   partition of Armbian's trixie minimal image, with the Armbian kernel/U-Boot/BSP packages
   removed.
3. **Loader.** A ShedNaja build whose `/sbin/init` is the script from section 3 with a
   one-shot flag (`/useremain/shednaja/debian.boot-once`, renamed before `pivot_root`).
   Without the flag it boots Buildroot ShedNaja unchanged. Installed with `kobra-update`
   like any build, so only our slot is written.
4. **Unpack** the tar to `/useremain/shednaja/debian` over SSH from Buildroot ShedNaja
   (check free space first: keep gigabytes for gcode). Nothing else on `useremain` changes.
5. **First boot:** set the flag, reboot, watch J1. Expect: kernel → loader → systemd →
   `multi-user.target`, login on `ttyFIQ0`. Collect `systemd-analyze`,
   `systemctl --failed`, `journalctl -b -p warning`, `free -m`, `ps -eo rss,comm`, Wi-Fi up,
   SSH.
6. **Then** Klipper (the Kobra-S1 fork, not mainline: mainline lacks the Anycubic CS1237 and
   other printer modules), Moonraker, HelixScreen, the camera; measure RAM again.

Ways back, from the least to the most drastic:
- Debian hangs or fails: power-cycle once, the consumed flag boots Buildroot ShedNaja.
- Loader or kernel broken: power-cycle until SPL has used up the 7 tries, stock boots;
  run the installer stick again for ShedNaja.
- Anything up: `REBOOT_TO_STOCK` / `kobra-abctl other && reboot` from ShedNaja.
- Remove the experiment: `rm -rf /useremain/shednaja/debian` from Buildroot ShedNaja.

Risks: a kernel that does not boot (covered by A/B); `useremain` filling up; an `e2fsck` that
finds damage on the shared filesystem after a crash during apt; stock's `mke2fs` on a
failed mount (see section 3). The stock slot, `userdata`, `useremain`'s existing data and the
MCUs are not written by any step.

## 6. Recommendation

**Not worth it as ShedNaja's default; possible later as an opt-in "Debian mode" for
tinkerers.**

| Users would gain | Users would lose |
|---|---|
| `apt` and the whole Debian archive | the read-only root: any package install can break the printer, and support gets much harder ("what did you install?") |
| KIAUH, familiar paths (`~/klipper`, `~/moonraker`, systemd units) and guides that assume them | A/B updates for the system: only kernel/loader stay atomic, the root has no rollback |
| Moonraker's update manager for Klipper/Moonraker/Mainsail (git) and system packages (apt) | power-loss safety: an interrupted `apt upgrade` on a printer that gets switched off leaves a half-configured system |
| Klipper plugins with their own pip dependencies | ~30–45 MB of RAM headroom, slower boot, swap needed for apt |
| | a known image to reproduce bugs against |

Most of what users would gain is reachable without a second OS:
- **Moonraker update manager for ShedNaja images:** `kobra-update` already installs
  verified bundles atomically. Publishing bundles and letting Moonraker / HelixScreen offer
  "update available" keeps the A/B safety.
- **Plugins:** a writable Python extras directory on `useremain`
  (`printer_data/klippy_extras`, a venv for pip packages) loaded by klippy covers the common
  case (extra Klipper modules) without changing the root.
- **Debian for tools, without booting it:** the same `/useremain/shednaja/debian` tree can be
  entered with `chroot` from Buildroot ShedNaja for `apt install` of command-line tools.
  It needs no kernel change and no loader, and costs no RAM when unused.
- If an apt-able system is wanted later: a Debian-based **read-only image** (squashfs file on
  `useremain`, loop-mounted, with an overlayfs upper layer that a "reset" deletes) keeps
  atomic updates and a way back. That needs `BLK_DEV_LOOP` + `OVERLAY_FS` and more build
  work than the plain directory, and it is the variant to try if this is ever done for real.

FreeDi's approach fits QIDI's 1 GB quad-core boards with no vendor fallback to keep. On a
single Cortex-A7 with 215 MB, whose main job is running klippy in time, the Buildroot image
is the better trade.

## 7. Without the stock firmware (whole eMMC)

Goal of the project: ShedNaja replaces the Anycubic data on the eMMC completely, with no
stock slot and the whole disk available. That removes the storage problem of section 3,
not the RAM and CPU budget of section 4.

**Space.** Stock's partitions without `useremain` are about 1.4 GB (backup in
[phase0.md](../history/phase0.md)): boot/oem/system A and B, `userdata`, `ac_lib`/`ac_app`
A and B. Together with `useremain` the whole 8 GB eMMC (about 7.3 GB usable) can be laid
out freely, so the 48 MiB system limit goes away.

**Two ways to lay it out:**

| | A: keep SPL + U-Boot, new partition table | B: Armbian-style disk |
|---|---|---|
| Bootloader | stock SPL/U-Boot stays (idblock, `uboot_a/b`, `misc`, `env` at the same offsets) | Armbian's Radxa U-Boot `next-dev-buildroot` + boot script, written at sectors 0x40 / 0x440 |
| Partitions | new `blkdevparts=` in the U-Boot env: e.g. `boot_a/b` 16 MiB, `rootfs_a/b` 1–1.5 GiB each, `data` the rest (~4 GB) | GPT, one ext4 root (plus maybe a boot partition) |
| A/B with tries counter | kept (SPL `ab_data_spl` + `misc`), now ShedNaja/ShedNaja: the planned `ab` mode with big slots | gone; Armbian has no A/B. A broken kernel or root = serial console or reflash |
| Kernel | ours (5.10.160) as today | Armbian's 6.1 lacks the Kobra DT, touch, RTL8723DS and BT drivers; either port them or build Armbian with our kernel as a custom kernel (then Armbian's kernel packages and their updates do not apply) |
| Not verified | whether U-Boot falls back to a built-in env with stock partitions when the env CRC is bad; that a longer `blkdevparts` is accepted | the Kobra board with Armbian's DDR blob (v1.18; stock uses V1.11; the RV1106G3 DRAM is in the package, so likely fine) and a U-Boot DT with eMMC (Armbian's RV1106 boards boot from SD/NAND; the eMMC Pico Ultra is not in Armbian) |
| Bricking risk | low: the bootloader is not written; only `env` and the partitions behind it | high: a bootloader that does not start needs maskrom |

**Maskrom first, either way.** Maskrom recovery does not work yet (`TODO.md`: SW1 and the
SoC's USB lines before the GL852G hub are not found). Today a broken ShedNaja always has
stock in the other slot; without stock, a bad `env` (A) or bootloader (B) leaves only
maskrom. Getting back to stock then means restoring the backup partitions and the old env,
from a ShedNaja tool while ShedNaja still boots, otherwise over maskrom.

**What has to be saved or moved before stock's data goes:**
- `/userdata/wifi_cfg/wpa_supplicant.conf` (shared with stock today) and `/userdata/shednaja`
  (SSH keys, `shadow`) move to the new data partition.
- `oem_<slot>` is the stock oem image with our three modules; the modules and anything else
  used from `/oem` go into our rootfs. That also settles the redistribution question in
  `TODO.md` for oem.
- The BT firmware already comes from the official update file at build time, not from the
  eMMC.
- Anything printer-specific in `/userdata/app/gk` (GoKlipper's config with this printer's
  values) should be kept with the eMMC backup. The MCU board ID lives in MCU flash and is not
  affected.
- Stock OTA updates and Anycubic's own recovery are gone; going back to stock is a
  restore from backup.

**What this means for Debian/Armbian.** With room on the disk, the variant from
section 6 becomes practical: a **Debian-based read-only image** (squashfs of 150–300 MB)
in `rootfs_a/b` with layout A, with the same `kobra-update` A/B updates as today, and an
overlay or the data partition for user changes. That keeps atomic updates and the A/B
fallback, and gives Debian's packages at build time. A plain Armbian install (layout B,
writable root, `apt` on the printer) is now possible too, but it keeps every loss from
section 6 and adds the bootloader risk, while the RAM cost of section 4 (about 30–45 MB of
~155 MB) does not change.

Order that follows from this: maskrom recovery → the `ab` mode (ShedNaja in both slots,
stock only as a backup) → a new partition table with layout A → then decide whether the
image stays Buildroot or becomes a Debian-based image. Layout B only if Armbian itself is
wanted and maskrom works.

## Sources

- Armbian build framework: [rockchip-rv1106.conf](https://github.com/armbian/build/blob/main/config/sources/families/rockchip-rv1106.conf),
  [luckfox-pico-max.csc](https://github.com/armbian/build/blob/main/config/boards/luckfox-pico-max.csc),
  [linux-rockchip-rv1106-vendor.config](https://github.com/armbian/build/blob/main/config/kernel/linux-rockchip-rv1106-vendor.config),
  [lowmem.sh](https://github.com/armbian/build/blob/main/extensions/lowmem.sh),
  [rockchip_vendor_common.inc](https://github.com/armbian/build/blob/main/config/sources/families/include/rockchip_vendor_common.inc),
  [mkspi.csc](https://github.com/armbian/build/blob/main/config/boards/mkspi.csc)
- Armbian download page: [Luckfox Pico Pro / Max](https://www.armbian.com/boards/luckfox-pico-max)
- Luckfox SDK: [LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico),
  Ubuntu added in [`226c3fbd`](https://github.com/LuckfoxTECH/luckfox-pico/commit/226c3fbd),
  removed in [`d2da6f0f`](https://github.com/LuckfoxTECH/luckfox-pico/commit/d2da6f0f),
  [Ultra Ubuntu BoardConfig @ 485f09ec](https://github.com/LuckfoxTECH/luckfox-pico/blob/485f09ec/project/cfg/BoardConfig_IPC/BoardConfig-EMMC-Ubuntu-RV1106_Luckfox_Pico_Ultra-IPC.mk),
  [luckfox_rv1106_linux_defconfig](https://github.com/LuckfoxTECH/luckfox-pico/blob/824b817f/sysdrv/source/kernel/arch/arm/configs/luckfox_rv1106_linux_defconfig),
  rootfs [luckfox-eng33/pico_ubuntu](https://github.com/luckfox-eng33/pico_ubuntu),
  [issue #69](https://github.com/LuckfoxTECH/luckfox-pico/issues/69) (Ubuntu RAM on 128 MB),
  [Luckfox RV1106 FAQ](https://wiki.luckfox.com/Luckfox-Pico-RV1106/FAQ/)
- systemd kernel requirements: [README v257](https://github.com/systemd/systemd/blob/v257/README)
- FreeDi: [Phil1988/FreeDi](https://github.com/Phil1988/FreeDi)
- This repo: [update.md](../update.md), [kernel-build.md](../kernel-build.md),
  [rootfs-build.md](../rootfs-build.md), `build/kernel/config` (the config of the current
  kernel, also `/proc/config.gz` on the printer)
