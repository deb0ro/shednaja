# Armbian for the Kobra S1 (experiment)

Everything needed to build an Armbian image (Debian 13 minimal, Rockchip BSP kernel 6.1)
for the Kobra S1 host board (RV1106G3). Background and the reasons for the approach:
[docs/research/armbian-rv1106.md](../docs/research/armbian-rv1106.md).

**Status (2026-10-27): kernel, image and rootfs built, nothing tried on a board.**
- `build.sh kernel` built 6.1.172 (about 13 min on the first run, about 3 min after that)
  with our DTS (`rv1106g-kobra-s1.dtb`, 72 KB with symbols), `8723ds.ko` and every option
  from the `.csc` in the final config. `pack_boot.sh` wrapped it into
  `build/armbian/boot.img`: 6.0 MB of the 16 MiB `boot_<slot>`, zImage 5.1 MB (5.10: about 3 MB).
- `build.sh` built the image (about 2–3 min: Armbian pulls its prebuilt
  `rootfs-armhf-trixie-minimal` from ghcr.io and adds the board packages). `extract_rootfs.sh`
  turned it into `build/armbian/rootfs-trixie.tar.zst`: **560 MB unpacked, 154 MB as tar.zst**,
  Debian 13 (Armbian 26.11.0-trunk), 300 packages, glibc, systemd 257.13, Python 3.13.
  `build/armbian/rootfs-report.txt` lists the enabled units and the Kobra files.
- The first image was 1.1 GB: 525 MB of it was armbian-firmware (now
  `INSTALL_ARMBIAN_FIRMWARE=no`; the RTL8723DS Wi-Fi firmware is inside `8723ds.ko`). Armbian
  also rewrote `/etc/fstab` after `customize-image.sh` (our `/userdata` line was lost, and its
  `UUID=… / ext4 … 0 1` would have made systemd wait for a root partition that does not exist on the
  printer), and it enabled `armbian-resize-filesystem` (it would grow the partition the root
  sits on, i.e. `useremain`) and the `apt-daily` upgrade timers. A `pre_umount_final_image`
  hook in the `.csc` now writes the fstab, masks the resize service and removes the
  apt-daily/man-db timers, `getty@tty1` and the generic `wpa_supplicant.service`.
- Still in the rootfs and worth trimming later: `/boot/dtb-*` (33 MB, every Rockchip DTB
  from linux-dtb; only U-Boot would use them), rsyslog next to journald, `armbian-ramlog` and
  `armbian-zram-config` (switched off in `/etc/default` by `lowmem`, they only start and exit).

Comparing the final config with the 5.10 one showed that Armbian's rv1106 base config has
**no CMA** (`CMA`, `DMA_CMA`, the RK CMA heap). The VOP has no IOMMU, so the display needs
contiguous memory, and our DT reserves `linux,cma`. The `.csc` now enables it as 5.10 does,
plus some smaller leftovers (AF_ALG, usbmon, hiddev, rfkill-gpio, generic USB serial). What
5.10 still has and 6.1 does not are the camera, ISP, NPU and RGA drivers, which ShedNaja
blacklists anyway.

This `boot.img` on its own does not make a complete system: its modules (`8723ds.ko`, UVC,
USB serial) are in `/lib/modules/6.1.172-vendor-rockchip-rv1106` of the Debian rootfs. With
ShedNaja's Buildroot root (5.10 modules) only the built-in drivers would work: display,
touch, eMMC, the MCU UARTs and USB storage, but no Wi-Fi.

## Phases

1. **Kernel and userspace without touching the bootloader** (this folder). Armbian builds
   the 6.1 kernel and a Debian rootfs. `BOOTCONFIG="none"`: no U-Boot is built or written.
   `scripts/pack_boot.sh` packs the kernel into our FIT `boot.img`, which stock U-Boot boots
   from our slot like ShedNaja's 5.10 kernel. The rootfs goes into a directory on
   `useremain`, started by a loader in the system slot (research page, section 3 and plan in
   section 5). The stock slot stays as it is.
2. **Whole eMMC** (the project's goal, research page section 7): only after maskrom recovery
   works. Then a new partition table under the stock SPL/U-Boot (layout A) with big A/B slots.

## Layout

| Path | In git | What |
|---|---|---|
| `userpatches/config-kobra-s1.conf` | yes | build switches: `BOARD=kobra-s1 BRANCH=vendor RELEASE=trixie BUILD_MINIMAL=yes`, `SHARE_LOG=no` |
| `userpatches/config/boards/kobra-s1.csc` | yes | board: family `rockchip-rv1106`, `BOOTCONFIG=none`, `lowmem` extension, kernel pin, kernel options (Kobra hardware + systemd) |
| `userpatches/kernel/rv1106-vendor-6.1/0000.patching_config.yaml` | yes | copies `dt/*.dts` into `arch/arm/boot/dts` and adds them to the Makefile |
| `userpatches/kernel/rv1106-vendor-6.1/0001-wireless-add-rtl8723ds.patch` | no, generated | RTL8723DS SDIO driver (armbian/rtl8723ds). Armbian's driver harness adds it only for rockchip64/d1 |
| `userpatches/kernel/rv1106-vendor-6.1/dt/rv1106g-kobra-s1.dts` | no, copied | from `kernel/dts/`, so there is one DTS for 5.10 and 6.1 |
| `userpatches/customize-image.sh`, `userpatches/overlay/` | yes | in the image: `/dev/block/by-name` udev rule, Wi-Fi module options (`8723ds`, no power saving), BSP camera/NPU blacklist, volatile journal, `/userdata` mount, `wpa_supplicant@wlan0` on the stock Wi-Fi config, networkd DHCP |
| `scripts/prepare.sh` | yes | in WSL: pinned `armbian/build` to `~/kobra/armbian-build`, sources to `~/kobra/armbian-src`, generates the patch, copies the DTS, checks it with `dtc`, syncs `userpatches` |
| `scripts/build.sh` | yes | `./compile.sh kobra-s1` (image) or `... kernel` (kernel .deb only) |
| `scripts/pack_boot.sh` | yes | kernel .deb → `build/armbian/boot.img` (`tools/mkboot_kernel.py`, stock FIT template, our logo) |
| `scripts/extract_rootfs.sh` | yes | image → `build/armbian/rootfs-<release>.tar.zst` (+ `.sha256`, `.packages.txt` with the exact Debian package versions, `rootfs-report.txt`), as root (loop mount read-only, numeric owners, xattrs, ACLs) |
| `scripts/make_rtl8723ds_patch.sh`, `scripts/dtcheck.sh` | yes | helpers used by `prepare.sh` |
| `armbian-build/`, `sources/` | no | reference clones for reading on Windows (the same pins); the build does not use them |

## Pins

| What | Pin |
|---|---|
| armbian/build | `fac57a02f1c6ff2221a3f3099a1094dcdf41be26` (main, 2026-10-23) |
| kernel | armbian/linux-rockchip `d3d527fca68e0db93aa802692e82b9e3b10cef8d` (`rk-6.1-rkr7.2`, 2026-10-23), pinned in the `.csc` (the family follows the branch head) |
| RTL8723DS | armbian/rtl8723ds `b5c8a00c52918c2f98c000551b0c5fc5e365f87e` (the same commit as Armbian's harness) |

Bump them together in `scripts/prepare.sh` and the `.csc`, and rerun `prepare.sh` (it checks
the DTS and regenerates the patch). The kernel branch gets force-pushed: the first pin
(`31366010`, 2026-10-23) disappeared within days, and the fetch fails with "not our ref". Then
pick a commit that is on the branch again and rerun `prepare.sh`.

## Running it (later)

```bash
bash armbian_build/scripts/prepare.sh          # sources + userpatches into WSL, no build
bash armbian_build/scripts/build.sh kernel     # kernel .deb (needs sudo, downloads toolchain)
bash armbian_build/scripts/pack_boot.sh        # -> build/armbian/boot.img
bash armbian_build/scripts/build.sh            # full image -> ~/kobra/armbian-build/output/images/
bash armbian_build/scripts/extract_rootfs.sh   # -> build/armbian/rootfs-trixie.tar.zst (runs as WSL root)
```

- Runs in WSL `Ubuntu-24.04` (from Git Bash the scripts re-run themselves there, like
  `tools/build_kernel.sh`). The build tree has to be on the Linux filesystem: Armbian's chroot
  needs device nodes and file ownership that `/mnt/d` does not have.
- Armbian needs root (or Docker). WSL's `sudo` asks for a password, so the kernel was built
  with `wsl -d Ubuntu-24.04 -u root -- env AB=/home/adam/kobra/armbian-build bash
  armbian_build/scripts/build.sh kernel`. Armbian warns "don't run ./compile.sh as root" and
  carries on. On the first run it installs about 37 host packages into the WSL distro
  (cross gcc, dtc, u-boot-tools, …), downloads several GB into `~/kobra/armbian-build/cache`
  and needs about 20 GB of free space. The output under `output/` belongs to root and is
  world-readable.
- The image from `build.sh` is **not** for writing to the eMMC: it has no bootloader and
  an MBR. It only carries the rootfs (`ext4` partition) for the directory on `useremain`.
- `pack_boot.sh` needs `build/stock/boot.img` (`tools/fetch_stock.sh`).

## Open items before a first boot

- **Kernel config check:** `build.sh kernel` writes the final `.config`. Compare it with
  `build/kernel/config` (5.10) for drivers the board needs (display, touch, MMC, USB host,
  UART3/5, PWM, SARADC) and with the systemd list in the research page.
- **Bluetooth:** the 5.10 build uses Realtek's vendor `hci_uart.ko` + `rtk_hciattach` with the
  `bluetooth-platdata` node. For 6.1 the kernel options are set for mainline serdev + `hci_h5`
  + `btrtl`, which needs a `bluetooth { compatible = "realtek,rtl8723ds-bt"; ... }` node under
  `&uart1` (enable GPIO0_A4, the RTS pin as in the platdata) and `rtl_bt/rtl8723ds_{fw,config}.bin`.
  The stock config bin has two board entries that linux-firmware's lacks
  ([rootfs-build.md](../docs/rootfs-build.md)). Bluetooth is off in the image until then.
- **Loader:** the busybox loader for the system slot (mount `useremain`, bind it into the
  Debian root, `pivot_root`, `exec /sbin/init`, one-shot flag) is not written yet. It belongs
  in `rootfs/` as a ShedNaja build variant, see research page section 3.
- **Boot marking:** a systemd unit that does what `S99kobra-bootok` does (`kobra-abctl`),
  left out for the first boots so that power cycles still count toward the stock fallback.
- **Kernel cmdline:** stock U-Boot appends `blkdevparts=` and sets `root=`; `CMDLINE_PARTITION=y`
  is in the options. The DTS bootargs are those of 5.10 (`rk_dma_heap_cma=18M`, `console=ttyFIQ0`);
  whether the 6.1 BSP reads `rk_dma_heap_cma` the same way is not checked.
- **Armbian first login:** Armbian asks for a root password and a user on the first console
  login (serial J1). For headless tests, preseed it (`/root/.not_logged_in_yet`).
- **Klipper stack:** not in the image. Klipper (Kobra-S1 fork), Moonraker, HelixScreen and the
  camera come after the first boot works.

## Handing out binaries (GPL)

The repository is private. Whoever receives an Armbian installer or bundle has to get the
corresponding source too (GPLv2 for the kernel, busybox, kexec-tools; GPLv3 for Klipper,
Moonraker, Mainsail), with the binaries or by a written offer:

- **Kernel:** armbian/linux-rockchip at the pinned commit (see Pins), our patches
  (`userpatches/kernel/rv1106-vendor-6.1/`, including the generated RTL8723DS driver patch:
  armbian/rtl8723ds at its commit), the DTS (`kernel/dts/`, `dts/`) and the final `.config`
  (`build/armbian/config`).
- **Armbian build:** armbian/build at the pinned commit and `userpatches/` (board, config,
  customize-image.sh, overlay).
- **Loader:** busybox and e2fsprogs from ShedNaja's Buildroot (their sources, Buildroot's
  `make legal-info`), `kobra-abctl` (this repository).
- **Klipper stack:** the Klipper fork at `KLIPPER_VERSION` (`rootfs/package/klipper/klipper.mk`)
  plus `rootfs/package/klipper/*.patch`, Moonraker, Mainsail, mainsail-config, HelixScreen
  and ACEPRO at the versions in their `rootfs/package/*/*.mk`, ShedNaja's extras and configs.
- **Debian packages:** unchanged from Debian; pointing to Debian's source archive for the
  exact versions (`build/armbian/rootfs-<release>.packages.txt`, `dpkg -l` in the image) is the
  usual way, or ship the `.dsc` sources. They are not pinned: a build takes the current trixie
  mirror, so two builds of one commit can differ there (compare their `.packages.txt`).
- Stock firmware parts are never in an Armbian image (only Anycubic's RTL8723DS Bluetooth
  firmware blobs, `rtl_bt/`, which need their own redistribution check).

Simplest: make the repository (or a source release of the tagged commit) public with the beta.

## Safety

Nothing in this folder writes to a board. A first boot test follows the plan in the research
page, section 5: serial console attached, only our slot written through the normal update
path, stock slot, `userdata`, the existing data on `useremain` and the MCU firmware untouched.

## Test log

- 2026-10-27, test board (eMMC CID `d6010330…`, full eMMC backup in
  `D:\KobraS1_backups\testboard-2413b6a471f91e6b\backup-1` beforehand), stock in slot A:
  - `install_test.sh --write`: rootfs to `/useremain/armbian/root`, boot.img + loader to slot B through
    `kobra-update` (written and verified). **First boot hung right after DDR init**, nothing on the UART at
    115200 or 1.5M: Armbian's gzip zImage (5.1 MB) overwrote the DTB that stock U-Boot loads at 0xC00000
    (zImage at 0x808000). XZ fixed the zImage, but the second boot hung the same way: the decompressed
    kernel (8.47 MB) reached the zImage, so the decompressor relocated itself onto the DTB. Trimmed
    kernel (7.14 MB / 3.44 MB zImage) written to `boot_b` from stock with `tools/flash_boot_slot.sh`,
    modules replaced in the rootfs. Each failed attempt meant power-cycling until SPL fell back to stock.
  - Rinkhals on stock disables itself when the board is outside the printer (no MCUs: gklib timeout,
    `.disable-rinkhals` stays, no SSH on the next boots). Stock has no UART console. Fixed by putting the
    board back in the printer with a USB stick holding `.enable-rinkhals`.
  - **Third boot: Armbian runs** (board in the printer). 6.1 kernel → loader → `pivot_root` → systemd;
    `8723ds` Wi-Fi (DHCP 192.168.10.248, new client ID), SSH with the dev key, `/dev/fb0` 800x480 + DRM,
    backlight, `fts_ts` touch on event0, UART3/5 present. 160 MB available at idle (45 MB used).
    `/userdata` failed to mount (systemd ignores `/dev/block/` links; fixed with `/dev/disk/by-partname`),
    `lowmem-mkswap` failed (`fallocate` not supported on useremain). The CPU serial in `/proc/cpuinfo`
    differs from 5.10 (`6144af1d523a9757`); the board is identified by its eMMC CID.
  - Reboot after the fixes: SSH back in 35 s, `Startup finished in 1.4 s (kernel) + 41.7 s (userspace)`,
    no failed units; `e2scrub_reap` alone takes 28 s.
  - Open: boot not marked good (SPL counts the tries of slot B down, then stock), Bluetooth (serdev DT
    node), display/touch not checked by eye, swap, mask `e2scrub_reap`, Klipper stack.
- 2026-10-27, continued (board in the printer, Armbian at 192.168.10.248):
  - `e2scrub_reap` masked, swap in zram instead of the lowmem swapfile (useremain has no extents and no
    journal: `fallocate` fails, and a swapfile would wear the eMMC).
  - Boot marking: `kobra-bootok.service` (static `kobra-abctl now --slot=<root>`) re-arms slot B's tries.
    The branch needed `main`'s `kobra-abctl --slot` (merged).
  - Bluetooth: `dts/rv1106g-kobra-s1-armbian.dts` (serdev `realtek,rtl8723ds-bt` on UART1) + stock firmware
    as `rtl_bt/rtl8723ds_{fw,config}.bin`: `hci0`, firmware 0xbab76f72. No BlueZ userspace in the image yet.
  - Display: colour bars drawn on fb0 without errors; not checked by eye, touch not tested (nobody at the
    printer).
  - Klipper stack (`stack/`, `scripts/stage_stack.sh`): same pinned sources as Lite, built in the image
    chroot (7:52 min image build). First try failed (`pip --prefix` put streaming-form-data outside Debian's
    path). Rootfs 670 MB / 190 MB tar.zst. Installed with `update_rootfs.sh`: **Klipper ready** with `mcu`,
    `nozzle_mcu` (stock v1.4.3, not flashed) and the host MCU; Moonraker, Mainsail (HTTP 200), camera
    snapshot (100 KB), HelixScreen running; no failed units. **107–110 MB available** with everything
    running (Lite ~155 MB); RSS: Moonraker 24 MB, klippy 21 MB, HelixScreen 16 MB, mjpg-streamer 9 MB.
    Boot to SSH 50 s (first boot of a new root: Armbian's firstrun regenerated the SSH host keys and
    `armbian-apt-updates` ran `apt-get upgrade -s` from cron, 60 MB).
  - Fixed in the image config afterwards: hook order so zram swap stays on (lowmem's
    hook rewrote `SWAP=false`), Armbian cron jobs removed (apt update check, battery, e2scrub), no
    dpkg-db-backup timer; `update_rootfs.sh` keeps the host keys (disables firstrun in the new root).
  - Open: rebuild + check those fixes, display/touch by eye, `SHAPER_CALIBRATE` and a print, an update
    path for this variant (whole-image A/B), BlueZ if needed.
  - Rebuilt image (7:21 min) installed with `update_rootfs.sh`: SSH host key unchanged (strict check, same
    fingerprint before and after), back in 44 s, `Startup finished in 1.4 s + 49.4 s`; zram swap on
    (82.6 MB, zswap off), only `armbian-truncate-logs` left in cron.d, no apt/dpkg running, firstrun
    disabled, no failed units; Klipper ready, all stack services active, slot B tries 7, `hci0` present,
    108 MB available.
- 2026-10-27, A/B of the Debian root on the test board (in the printer):
  - `ab_update.sh loader --write`: A/B loader into system_b (verified); next boot the loader renamed
    `root` to `root_a` (`ACTIVE=a`).
  - `ab_update.sh install --write`: the image from 13:17 into `root_b` in 214 s, reboot → **booted `root_b`**
    (`TRY=b`, `TRIES=2`), Klipper ready, no failed units, same SSH host key.
  - **Rollback:** that image predates `kobra-ab`, so its `kobra-bootok` does not confirm: three boots of
    `root_b` (tries 2 → 1 → 0), then the loader went back to `root_a` and wrote `last-rollback: b`.
  - **Confirm:** with the current `kobra-ab`/`kobra-bootok` copied into `root_b` and `TRY=b` set again,
    the next boot came up on `root_b` and `kobra-bootok` made it `ACTIVE=b`.
  - **Manual rollback:** `kobra-ab rollback` → reboot → `root_a`, `ACTIVE=a`. SPL A/B untouched
    throughout (slot B, 7 tries).
  - Found: the loader's kmsg lines are not in `dmesg`: the ring buffer starts at ~3 s because
    `cpu cpu0: Failed to get leakage` repeats every ~110 ms during boot (cpufreq without the OTP
    nvmem cells our DTS removes). To fix: silence/avoid that (or a bigger `LOG_BUF_SHIFT`).
  - Next image build carries `kobra-ab` and the confirming `kobra-bootok`; `kobra-ab install` records
    the install time in `/etc/kobra-ab-installed`.
- 2026-10-27, RAM and boot log (board in the printer):
  - Touch: the driver covers the full 0..799 x 0..479 range; the corners map rotated by 180° (top left →
    (761,427), top right → (9,469), bottom right → (3,38), bottom left → (743,49)) as the panel is mounted.
    Lite's old calibration (5.10 raw range) is dropped; whether the HelixScreen UI hits the right spots
    still has to be confirmed at the printer.
  - PSS per process: Debian's base (systemd, resolved, networkd, journald, udevd, logind, dbus,
    timesyncd, sshd) costs ~20 MB; rsyslog/cron/`MALLOC_ARENA_MAX` changed MemAvailable by < 1 MB.
    The real reserve was CMA: 16 MB "inactive" `linux,cma` + 18 MB `rk_dma_heap_cma` (ISP/rockit chain,
    unused: UVC camera), 2 MB of it in use.
  - Kernel/DT (Armbian only): no RK CMA heap, `linux,cma` 8 MB and not inactive, no cpufreq
    (`vdd_arm` is disabled as in stock; rockchip-cpufreq retried 50 times, "Failed to get leakage" every
    ~110 ms, which pushed the early boot messages out of the log). Image: rsyslog and cron off.
  - Installed together (boot_b written from Armbian, rootfs via `ab_update.sh install`): `root_b`
    confirmed itself (`ACTIVE=b`), Klipper ready, all stack services active, no failed units, `hci0`,
    fb0, camera. **MemTotal 241 MB (was 214), MemAvailable 138 MB (was 105–108)** with the whole stack;
    CMA 8 MB, 2 MB allocated. Loader lines are in `dmesg` again, no leakage messages.
  - Limitation (fixed by the kernel A/B below): the kernel (boot_b) was not part of the root A/B, so
    a rollback to an older root could lose modules (Wi-Fi).
  - Follow-up for Lite and Armbian (shared `S65webcam`): after a USB re-enumeration the camera can come
    back as `/dev/video1` while the script insists on `/dev/video0`, so the webcam does not start.
- 2026-10-27, touch: without a calibration HelixScreen's taps were off by up to ~20 px ("reacts
  strangely"). `helix-launcher.sh --calibrate-touch --debug-touches` (temporary unit, same environment
  as S70helixscreen) → calibration on the display → `a=1.0201 b=-0.0173 c=-19.16 d=-0.0038 e=1.0491
  f=-1.04`, saved, **touch correct** (checked at the printer). `kobra-data-seed` now writes this
  calibration instead of Lite's (5.10 raw range) on a fresh install.
- 2026-10-27, **kernel A/B with the root** (kexec). Slot A is stock, so Armbian has only `boot_b`;
  it now holds a base kernel and each root brings its own (`/boot/zImage` + DTB + `/lib/modules`).
  - Loader (`loader/init`, "kernel of the chosen root"): after choosing the root (tries as before) it
    compares the root's zImage and DTB with the sha256 in the FIT header of `boot_<slot>`. Equal → boot
    on. Different → DTB copy with U-Boot's fixups (memory, serial number, MAC via `fdtput`),
    `kexec -l` with the same cmdline plus `kobra.root=<x>`, useremain read-only, `kexec -e`. The second
    pass sees `kobra.root=` and boots that root without spending a try. kexec and fdtput come from the
    root (Debian `kexec-tools`, `device-tree-compiler`; `kexec-load.service` masked so reboots stay
    real). `ab/kexec-fails` counts kexec boots, `kobra-ab confirm` clears it; after 2 unconfirmed ones
    a root that is not on trial boots with the base kernel. 20 qemu tests (`loader/test_ab.sh`).
  - Watchdog: DW WDT enabled in the Armbian DTS, `CONFIG_KEXEC=y`, systemd `RuntimeWatchdogSec=30s`
    (hardware timeout 44 s). The loader starts it only right before `kexec -e` and only if the new DTB
    enables it; it keeps running across kexec and the new kernel pings it until systemd takes over.
    **First attempt started it at the top of the loader: closed without the magic close nothing pings
    it, and the old `root_b` (no systemd watchdog config) rebooted every ~60 s** until the config was
    added there by hand (`systemctl daemon-reexec`).
  - `ab_update.sh boot --write`: base kernel into the running boot slot, old slot saved to
    `build/armbian/boot_b_before_*.img` first. Kernel updates normally come with the root now.
  - Test board: new `boot_b` + loader, new root via `install` into `root_a` → no kexec (same hashes),
    confirmed. `kobra-ab rollback` → `root_b` (old kernel, no `CONFIG_KEXEC`, kexec/fdtput copied in
    from `root_a` for the test) → **loader kexec'd root_b's kernel**: `kobra.root=b`, serial number and
    256 MB memory node carried over, Wi-Fi, all modules, Klipper/Moonraker/HelixScreen, fb0. Its DTB has
    no watchdog, so the loader left it off. Then `root_a` with a test property in its DTB → kexec of the
    new kernel, systemd took over the watchdog 1.6 s after kexec. DTB restored → `root_a` without kexec.
  - Not tested: an actual hang after kexec (watchdog reset + tries), and the extra boot time (no UART).
    `root_b` reinstalled from the rebuilt image afterwards (no hand-copied tools or config left):
    booted without kexec, confirmed, `ACTIVE=b`, watchdog via systemd, stack active, 140 MB available.
- 2026-10-27, **RAM diet 2** (whole stack running, one measuring SSH session; MemAvailable / PSS sum):
  - Baseline `root_b`: **138.1 MB** available, PSS 113.0 MB (28 processes).
  - Klipper protection (no RAM change): `klipper` and `klipper-mcu` with `MemorySwapMax=0` (cgroup v2
    `memory.swap.max` = 0, never in zram) and `OOMScoreAdjust=-900`; Moonraker 300, HelixScreen 200,
    camera 500 (killed first). Swappiness stays 60 (zram).
  - Network: busybox `udhcpc` (`kobra-dhcp@wlan0`, 0.5 MB; USB Ethernet via `81-kobra-dhcp.rules`; checked with an AX88179 adapter, 2026-10-30)
    instead of systemd-networkd + systemd-resolved; `NETWORKING_STACK=none` (Armbian's networkd stack
    pulls netplan, whose generator re-enables networkd every boot). → **143.8 MB (+5.7)**. udhcpc
    identifies by MAC like stock/Lite: the board is now **192.168.10.247** (networkd's DUID got .248).
    Kernel SLAAC replaces networkd's IPv6. resolv.conf is written by the udhcpc script (resolved's
    `/sbin/resolvconf` would hijack it, so systemd-resolved is purged). timesyncd came with that stack:
    `systemd-timesyncd` added back explicitly (the clock was 47 min behind without it).
  - No logind sessions: `pam_systemd` off (`pam-auth-update --disable systemd`), so a root login starts
    no `user@0` (`systemd --user` + sd-pam); logind dropped from `multi-user.target.wants` (a `/dev/null`
    link), not masked: masked, `systemctl reboot` printed "Call to Reboot failed" (it still rebooted via
    the fallback); now logind is D-Bus-activated only for a reboot. Moonraker has `provider: none`.
    → **148.5 MB (+4.7)**. SSH login 0.6 s, HelixScreen fine.
  - Python 3.13: `PYTHONNODEBUGRANGES=1` −0.06 MB per process, `MALLOC_ARENA_MAX=1` −0.06 MB: not kept.
    The `.pyc` are already in the image (202 Klipper, 72 Moonraker).
  - Kernel: **`RT_GROUP_SCHED` off** (bug: once systemd enables the cpu controller, cgroups get no RT
    runtime and `klipper_mcu -r` failed with EPERM on any restart after boot; Armbian's
    `enable_docker_support` sets it, so `kernel_config_force_n`), bridge off (same hook), no EHCI,
    `nls_cp936` and `configs` (`/proc/config.gz`) as modules. vmlinux 7 298 870 → 7 005 722 B,
    decompressed 7.14 → 6.84 MB (1.5 MB margin), MemTotal +0.3 MB. klipper-mcu restart now keeps
    SCHED_FIFO 49. No `/proc/slabinfo` (SLUB without debug): Slab 14 MB, 7.8 MB unreclaimable.
  - Image rebuilt, installed into `root_a` (new kernel kexec'd from the old `boot_b` → confirmed), new
    kernel then written to `boot_b`; final image into `root_b`: boots, confirms, no failed units,
    Klipper ready, time synced, `systemctl reboot` clean. **Final: 148.0 MB available (+9.9 MB), PSS
    104.0 MB (23 processes).**
  - Serial console: Armbian's `--autologin root` overrides (written by the build, removed only by
    `armbian-firstlogin`, which our installs skip) removed in the .csc final hook: `agetty` with a login
    prompt (root password), no root shell on UART. On the board (both roots): 148.9 → 149.7 MB.
- 2026-10-28, **SSH: dropbear instead of OpenSSH** (as in Lite). Debian `dropbear`, root with key and
  password (`Permission denied (publickey,password)` offers both), `-R`. Host keys: dropbear's postinst
  converted the board's OpenSSH keys, so the fingerprint stays (`SHA256:H4j5nX8X…`, strict
  known_hosts passes); the image has none (final hook deletes them, `-R` creates per-board keys on the
  first connection) and `kobra-ab install` / `update_rootfs.sh` carry `/etc/dropbear` and the old
  `/etc/ssh` keys into the new root. `openssh-sftp-server` explicitly in PACKAGE_LIST_BOARD (purging
  openssh-server let the autoremove take it, and OpenSSH 10's scp uses SFTP): scp, `scp -O`, uploads
  and downloads, `ab_update.sh status/install` work.
  - Same conditions (one SSH session, after a reboot): OpenSSH listener 1.6 MB + session 3.9 MB PSS →
    dropbear 0.5 + 0.8 MB; **MemAvailable 148.9 → 151.9 MB (+3.0)**. Live switch on `root_b` with an
    automatic fallback to OpenSSH, then the rebuilt image into `root_a`: boots, confirms, no failed
    units, Klipper ready, 152.2 MB available.
- 2026-10-28, **SHAPER_CALIBRATE on Armbian: MCU shutdown "Timer too close"** (user at the printer).
  `G28` (Moonraker `gcode/script`, returns once the moves are queued) then `SHAPER_CALIBRATE` right
  away: klippy's reactor was busy for 0.821 s in that request (`Reactor 142.058 busy for 0.821`), the
  tail of the homing moves went out late, MCU `mcu` shut down (toolhead at 125,125,4.66). Cause: Klipper
  imports numpy only when SHAPER_CALIBRATE starts (`shaper_calibrate.py`), and `import numpy` (2.2,
  Python 3.13) takes **1.03 s** on this board, in the reactor. Not RAM: klippy 27.2 → 33.9 MB RSS (numpy
  loaded), MemAvailable min 138.4 MB, no swap, load ≤ 0.89. Klippy then hung with the request pending
  (FIRMWARE_RESTART queued behind it); `systemctl restart klipper-mcu klipper` brought it back (RT fix).
  Fix candidates: `toolhead.wait_moves()` before the numpy import in the Klipper fork (or `M400` between
  G28 and SHAPER_CALIBRATE as a workaround), or importing numpy at klippy start (~7 MB resident). Lite's
  run (58.5 MB peak, 99.9 MB min available, 4 min 25 s) did not hit it.
  - **Rerun with `G28` + `M400`, then SHAPER_CALIBRATE: done, no errors** (239 s, Lite 265 s). The
    numpy import still blocked the reactor (0.66 s) but with the toolhead idle; the fits block it
    1.4–1.7 s each, also idle. klippy RSS 27.4 → **64.6 MB peak** → 43.6 MB after (Lite 58.5 MB peak),
    **MemAvailable min 100.1 MB** (Lite 99.9), klippy swap 0, zram untouched (SwapFree min 95.1 of
    95.3 MB), load ≤ 2.76, Klipper ready afterwards. Recommended: X `3hump_ei` 89.0 Hz (as configured),
    Y `2hump_ei` 63.0 Hz (configured: `ei` 50.6 Hz). Saved with the user's OK (SAVE_CONFIG into Armbian's
    printer_data copy, backup `printer-20261028_141200.cfg`; Lite's config untouched), Klipper ready.
- 2026-10-29, **user updates without apt** (docs/update.md, "Armbian variant"): one `kobra-update`
  for both variants (image type `rootfs`, Armbian path through `kobra-ab install`, no PID 1
  handover), `make_update_bundle.sh --rootfs`, `S27kobra-usbupdate` on both (systemd unit before
  Klipper, `shednaja-armbian-update*.tar`), `ROLLBACK_SYSTEM` in `kobra_slot`, `zstd` in the image.
  Test board (192.168.10.247): image via `ab_update.sh` into `root_b` (boots, confirms, USB unit runs
  and finds no stick); then bundle `shednaja-armbian-update-rootfs-943bb1bd31b4.tar` (200 MB) over SSH:
  `scp -O` 60 s, `kobra-update --check` OK, `--yes` installed into `root_a` in 3 min and rebooted,
  `root_a` confirmed, Klipper ready. `ROLLBACK_SYSTEM`: dialog names `root_b` and its install date,
  `CONFIRM=1` → reboot into `root_b`, `ACTIVE=b`, Klipper ready. `REBOOT_TO_STOCK` dialog shows on
  Armbian (not confirmed). Not tested yet: a USB stick, a bundle with boot/system, Lite with the
  changed `kobra-update` / `S27kobra-usbupdate` / `kobra_slot.py` (Lite needs a retest), and the
  numpy patch on the printer (G28 + SHAPER_CALIBRATE, needs the user at the printer).
- 2026-10-29, **numpy patch (0003) on the printer**: `G28` and right after it `SHAPER_CALIBRATE`, no
  `M400` (user at the printer): **no "Timer too close"**, 240 s, Klipper ready. The numpy import still
  holds the reactor (0.818 s at 200.7) but after the toolhead has finished; the fits 1.3–1.7 s each
  with the toolhead idle. klippy RSS 27.2 → 64.0 MB peak → 43.0 MB, MemAvailable min 101.2 MB, klippy
  swap 0, load ≤ 2.54. Result as saved before (X 3hump_ei 89.4 Hz, Y 2hump_ei 63.2 Hz), not saved
  again. Lite still needs a retest with the patch.
- 2026-10-29, **USB update** (user plugged a vfat stick with `shednaja-armbian-update-usbtest.tar`,
  power-cycled): `kobra-usbupdate.service` found it at boot, `kobra-update --yes` installed the root into
  `root_a` (07:14:38 → 07:18:56) and rebooted; `root_a` confirmed itself, Klipper ready, no failed
  units. Next boot with the stick still in: "already installed", skipped.
- 2026-10-29, **update from Mainsail**: `SHEDNAJA_UPDATE` (kobra_slot) + `kobra-update --remove-bundle`.
  Without a bundle: clear error. 200 MB upload to `config/updates` (Moonraker HTTP, as Mainsail does)
  first failed: Moonraker buffers uploads in `/tmp` (117 MB tmpfs), "No space left on device", and the
  partial `/tmp/moonraker.upload-*.mru` filled `/tmp` (removed by hand). `S61moonraker` now sets
  `TMPDIR=/useremain/shednaja/tmp`: upload in 46 s. Dialog with name and build id, "Install" →
  `kobra-update.service` (systemd-run), bundle removed after verification, root into `root_b` in
  2 min 44 s, reboot, confirmed, `BUILD_ID=rootfs-943bb1bd31b4` in os-release, Klipper ready.
  Lite needs a retest of the shared changes (`S61moonraker`, `kobra_slot.py`, `kobra_peripherals.cfg`,
  `kobra-update`, `S27kobra-usbupdate`).
- 2026-10-29, **filament runout during a print** (user's PETG calibration cube, filament cut by hand):
  at 15:58:10 `adc_filament_switch filament_runout_nozzle` went absent (2.874 V), "runout event
  detected", the print paused (`pause_resume.is_paused`), the macro's message "Filament runout: print
  paused. Insert filament (it is loaded automatically), then RESUME." Nozzle kept at 260 °C, bed 70 °C.
  The `filament_runout_rdm` sensor read "no filament" the whole time (also while printing).
- 2026-10-29, **power cut after the runout test → the printer came up on stock.** misc: A prio 15
  tries 7, B prio 14 tries 6 = the loader's own `to_stock` (`kobra-abctl other --slot=b`) on the first
  boot after the cut. useremain has no journal; the loader's `e2fsck -p` refused (rc ≥ 4, it was the
  only check before the switch that could fail: stock then mounted it after its own `e2fsck -y` in
  `S20linkmount`, `e2fsck -n` afterwards: consistent, Armbian state ACTIVE=b intact). Lite logs rc ≥ 4
  and mounts anyway. Fix: the loader repairs with `e2fsck -fy` after a refused `-p` and only goes to
  stock if useremain still does not mount.
  Back to Armbian: on stock `rk_ota --misc=other --mode=retry` (B prio 15, tries 7) + reboot →
  `root_b`, bootok, Klipper ready; then the fixed loader (`6aaa7e07…`) with `ab_update.sh loader
  --write` (sha256 verified), boots, no failed units. A power cut during a print with the fixed loader
  is not tested yet.
- 2026-10-30, **beta image + full bundle.** Image check: root has Lite's default hash
  (`$1$shednaja$…`, = `shadow.default`), `shednaja-password.sh` in profile.d, no `.not_logged_in_yet`,
  no armbian-firstrun. Installed into `root_a` via `ab_update.sh` (the old root's kobra-update did not know
  tar.gz yet): boots, confirms, Klipper ready; root's password is now the default `rockchip` (the old
  kobra-ab did not carry passwords). Then the **full bundle** `shednaja-armbian-update-armbian-88f494f77938.tar`
  (rootfs.tar.gz 267 MB + boot + loader, `variant=armbian`) over SSH with `kobra-update --yes
  --remove-bundle`: rootfs into `root_b`, `boot_b` identical and skipped, `system_b` (loader with the
  first-install block) written and verified, reboot → new loader, `root_b` tried and confirmed,
  `BUILD_ID=armbian-88f494f77938`, host key and root password carried over, Klipper ready.
  Stock installer built: `build/install-armbian/aGVscF9zb3Nf/update.swu` (268 MB), not tested yet.
