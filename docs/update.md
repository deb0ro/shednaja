# Updating ShedNaja

ShedNaja updates itself from the running system: no stock firmware, no Rinkhals, no SSH
into the stock firmware. Until then every write went through `tools/flash_slot.sh`, which
needs stock with Rinkhals for SSH.

## Slot layout and the two variants

| Variant | Slot A | Slot B | Update writes | If the update breaks |
|---|---|---|---|---|
| **inplace** (current) | stock or ShedNaja | the other one | our slot in place | SPL falls back to stock |
| **ab** (planned) | ShedNaja | ShedNaja | the inactive slot | the previous ShedNaja version |

`inplace` (formerly `inplace-b`) works in either slot: the installer puts ShedNaja into the
slot stock is not running from, which is B on a factory printer but A once an official
Anycubic update has moved stock to B. `/usr/libexec/kobra/current-slot` tells the scripts
which slot they run from (U-Boot sets `root=` to `system_a` = p8 or `system_b` = p9).
Both layouts are tested on printers (stock A / ShedNaja B, and stock B / ShedNaja A).

The plan is to offer both variants, so everyone can decide. `inplace` keeps the stock
firmware on the eMMC as the safety net. `ab` gives a real rollback to the previous ShedNaja
version, but stock is gone from the eMMC and has to come back from a backup / stock .swu.
`ab` comes once the printer is fully verified on ShedNaja (`kobra-update --mode ab` is
reserved and refuses for now).

## Update bundle

`tools/make_update_bundle.sh` packs the build outputs into
`build/update/shednaja-update-<build_id>.tar`: an uncompressed tar with

```
manifest       format=1, build_id=..., created=..., one line per image:
               image <boot|oem|system> <file> <size> <sha256>
boot.img       build/kernel/boot.img        -> boot_<slot>   (16 MiB)
system.img     build/rootfs/rootfs.squashfs -> system_<slot> (48 MiB)
```

No oem image by default: ShedNaja does not use the oem partition, and the stock oem in
the slot stays untouched (`--oem build/kernel/oem_ours.img` adds one for development; it is
Anycubic/Rockchip userspace and must not go into a release). `--boot/--oem/--system FILE`
pack only some images. Partitions that already hold exactly the
bundle's image are skipped on the printer, so a full bundle is fine even when only the
rootfs changed.

Bundles are not signed: the sha256 sums in the manifest catch damaged files, not
modified ones. Anyone who can run `kobra-update` as root or plug a USB stick into the
printer can install any system, as with the stock firmware's USB updater.

## Installing

**Over SSH:**
```
scp -O shednaja-update-<id>.tar root@<printer>:/useremain/shednaja/update/
ssh root@<printer> kobra-update /useremain/shednaja/update/shednaja-update-<id>.tar
```
(`scp -O`: our dropbear has no sftp-server; or `ssh ... 'cat > file' < file`.)
`kobra-update --check <bundle>` only verifies and lists what it would write.

**From a USB stick:** copy the bundle (name must start with `shednaja-update`, `.tar`)
into the root folder of a FAT32 or exFAT stick (MBR or GPT; GPT needs a kernel from ae32afc on),
plug it into the printer, power-cycle.
`S27kobra-usbupdate` installs it at boot before Klipper starts and reboots. A bundle whose
manifest equals the last installed one is skipped, so the stick can stay in. With several
bundles the last one by name is used.

**First install from the stock firmware (USB installer):**
`bash tools/make_install_swu.sh [bundle.tar]` wraps a bundle into
`build/install/aGVscF9zb3Nf/update.swu` (the stock USB update format, see
docs/history/test-board-access.md). Copy the `aGVscF9zb3Nf` folder to the root of a FAT32 stick and
plug it into the printer running stock. The stock `channel.sh` unpacks it to
`/useremain/update_swu` and runs `swu/shednaja_install/update.sh`, which requires a complete
bundle (boot and system, so a first install never leaves a mix of stock and ShedNaja;
`tools/make_install_swu.sh` refuses partial bundles too; oem only if the bundle has one),
logs a warning if stock is not 2.7.2.7 (`/useremain/dev/version`; it installs anyway),
checks the images (md5, stock busybox has no sha256sum), writes the ones that differ into the partitions of
the slot stock is not running from (`root=` p8 → slot B, p9 → slot A) with readback,
writes `installed.manifest`, switches to that slot with `rk_ota --misc=other --mode=retry`,
checks in `misc` that the slot now has the highest priority, and reboots. The stock slot
and /userdata are not written; on any error it beeps 5 times and stays on stock. Log: `shednaja-install.log` on the stick.
Since unchanged images are not rewritten, the same stick also brings a printer back to
ShedNaja after `REBOOT_TO_STOCK`.

## What kobra-update does (mode inplace)

1. Takes the lock `/useremain/shednaja/update/.lock` (one kobra-update at a time) and
   refuses while an earlier update is handed over and waits for its reboot. Finds the
   running slot (`current-slot`); all writes go to that slot's partitions.
2. Unpacks the bundle to `/useremain/shednaja/update/stage`, checks format, sizes, sha256 of
   every image and that it fits its partition; skips images identical to the partition.
   Manifest lines are strict: images must be named `<part>.img`, sizes numeric, sha256 64
   hex digits, each partition once. The bundle may only hold `manifest` and `<part>.img`,
   each once and as plain files (no paths, links or devices). If the update stops before the handover (a failed
   check, no confirmation, Ctrl-C), the unpacked images are removed again.
3. Printer must be idle: with Klipper not running (USB update at boot) nothing can print;
   with Klipper running the Moonraker print state must be readable and not `printing` /
   `paused` (unless `--force`). Asks for confirmation unless `--yes`, and checks the state
   again after the answer.
4. Writes the plan (images, slot, target devices, useremain device) to
   `/dev/.kobra-update-pending` (devtmpfs, RAM) and sends `SIGQUIT` to init. Stage 2 and the
   writer read that file as data (allowed keys and characters only), not as a shell script.
5. busybox init runs its `::shutdown` actions (`rcK` stops every service, `umount-all`),
   kills all processes and execs `/usr/libexec/kobra/update-stage2` as PID 1 (inittab
   `::restart:`). During boot (USB update) init holds the signal until `rcS` has finished,
   so the services start once and are stopped again. `umount-all` replaces busybox
   `umount -a -r` because that also unmounts `/dev` when nothing holds it open: init then
   cannot open `/dev/console` for stage 2 and halts (the board resets), and the pending
   file is gone. Over SSH the open session kept `/dev` busy, so this only showed at boot.
6. `update-stage2` remounts `/useremain` rw, builds a 1.3 MB busybox + uClibc + kobra-abctl
   chroot on a tmpfs and `exec chroot`s into it: from now on PID 1 runs from RAM and nothing
   reads the squashfs root.
7. `update-writer` (PID 1 in the chroot) writes each partition with `dd conv=fsync`, drops
   the page cache and compares the sha256 read back from the eMMC (one retry). All OK: saves
   the manifest as `installed.manifest`. Any failure: switches the A/B metadata to the
   other slot (stock) with `kobra-abctl other --slot=<our slot>`. Then `reboot -f`. PID 1 never exits on an error path.

Log: `/useremain/shednaja/update/last-update.log` (also on the console and in `dmesg`).
`trace.log` next to it records the handover milestones with uptime (handover, `rcS`
finished, `rcK` reached S27, stage 2 steps, writer start and each partition) and
`stage2-dmesg.log` the kernel log at stage 2, for when an update stops without a message.
A USB bundle is tried once (`usb-tried.manifest`): if it fails, the next boot skips it.
The display shows "Updating firmware" from step 6 and "Update complete" / "Update failed" for
3 s before the reboot: pre-rendered frames in `/usr/share/shednaja/splash/*.fb.gz`
(`tools/make_update_splash.py`: 800x480 BGRX, rotated 180° like the panel), written with
`zcat > /dev/fb0`. Stage 2 first unblanks and pans fb0 (sysfs `blank`, `pan`), as
HelixScreen's fbdev backend does: during a USB update at boot HelixScreen is stopped before
it took over the display, and until then the Rockchip DRM driver scans out the U-Boot logo
(`Freeing drm_logo memory` in dmesg marks the takeover), so plain writes to fb0 stay
invisible.
SSH drops at step 5; the printer is back after about 1.5 min.

**Why PID 1 has to leave the squashfs:** the first version only ran the writer in a chroot
and left init, dropbear and wpa_supplicant running from the old root. The write and the
readback were correct, but those processes then faulted on pages of the overwritten
system_b, init died, and the board hung until it was power-cycled.

A power loss while an update is being written leaves the ShedNaja slot broken; see
[If ShedNaja does not start](#if-shednaja-does-not-start).

## Back to stock

The other slot still holds the stock firmware: `kobra-abctl other` + reboot boots it (until the next
switch back with `kobra-abctl other` or `rk_ota --misc=other` on stock).

The `REBOOT_TO_STOCK` macro (kobra_peripherals.cfg: `[kobra_slot]` provides the hidden
`_REBOOT_TO_STOCK` command, the macro wraps it so Mainsail and HelixScreen list it) does the
same after a confirmation dialog; it is refused while a print is running or paused. Before
the reboot it resets the MCUs like `FIRMWARE_RESTART`: after a plain warm reboot stock
stopped with error 11407 (printhead board did not start) until the printer was
power-cycled, because the MCUs were still running in the state Klipper left them in.
`printer.kobra_slot.slot` reports the running slot.

## If ShedNaja does not start

How the fallback works: SPL boots the slot with the highest priority and counts its
`tries_remaining` down (7). `S99kobra-bootok`, the last init script, marks the boot good and
re-arms the 7 tries. A slot that never gets that far runs out of tries and SPL boots the
other slot (stock). ShedNaja re-arms the slot it runs from (`kobra-abctl now --slot=`, slot
from `/proc/cmdline`), so after a fallback to ShedNaja the failed stock slot is not tried
again; stock's own `rk_ota` re-arms the highest-priority slot, the failed one included.

- **Kernel panic or hang before `S99kobra-bootok`:** the board does **not** reboot by itself
  (a panic hangs it, `panic=5` notwithstanding). Power-cycle the printer; each power cycle
  uses one try, so after **up to 7 power cycles** stock comes up. Then run the installer
  stick again to rewrite the ShedNaja slot.
- **ShedNaja boots but something does not work** (Klipper, Wi-Fi, display): the boot still
  reaches `S99kobra-bootok`, so **there is no automatic fallback**. Ways back to stock:
  - `REBOOT_TO_STOCK` in Mainsail or HelixScreen, if either works;
  - over SSH: `kobra-abctl other && reboot`;
  - on the serial console (J1, 115200, [hardware.md](hardware.md)): log in as root, same
    command.

  Without network, display and serial console there is no way back yet (TODO: a recovery
  trigger from a USB stick or a button).
- **Hang after `S99kobra-bootok`:** no watchdog yet, power-cycle.

Stock itself is never written by ShedNaja, so once it runs it works as before; its own
updates may move it to the other slot (the installer handles either layout).

## Test log

- 2026-10-21, first version (writer in a chroot, init still on the squashfs): bundle
  `6dc2a04`, system_b written and verified in 8 s, then the board hung instead of rebooting
  (power-cycled by the user; it booted the new build fine).
- 2026-10-21, PID 1 handover: from `710878c` to bundle `30b7bc3` over SSH
  (`scp -O` + `kobra-update --yes`): boot_b/oem_b identical and skipped, system_b written and
  verified, **rebooted by itself**; back on SSH 2 min 7 s after the handover, Klipper ready,
  `BUILD_ID=30b7bc3`.
- 2026-10-21, `97a9600` (first build with the update screens) installed over SSH from `32aee64`:
  OK, rebooted by itself. The screens show from the next update on (stage 2 runs from the
  installed system).
- 2026-10-21, USB update at boot: first tries (`e0cb58c` from a stick) looped (handover,
  then reset, then the same bundle again) because `umount -a -r` unmounted `/dev` (see step 5).
  With `umount-all` (`4ed6e35`) and unblank + pan (`b3ce31d`): `e0cb58c` installed from the
  stick, update screen visible, about 5 min from power-on.
- 2026-10-21, GPT stick (`ae32afc`): before, the kernel saw only the protective partition;
  now `sda1` mounts as vfat.
- 2026-10-21, `REBOOT_TO_STOCK` (`d4d3f01`): slot A, MCUs reset, reboots by itself; stock
  starts without error 11407 (it showed after a plain warm reboot). Back with the stock
  installer (`update.swu` from `ae32afc`): slot B already identical, only the slot switch,
  3 long beeps, ShedNaja boots.
- 2026-10-22, first install as a new user: release build (no SSH key) from a fresh clone of
  the public repository with fresh SDK and download dirs (`cb8a86f`), on a second host board
  with stock 2.7.2.7 running from **slot B** (Rinkhals installed, MCUs v1.4.3). The stock
  USB updater ran the installer, which wrote **slot A** and switched to it; ShedNaja came
  up with the default config: Klipper ready, `kobra_slot` A, no config warnings, Mainsail and
  the camera answered, HelixScreen wizard on the display, `passwd` over SSH kept on
  `/userdata`. `REBOOT_TO_STOCK` brought stock back from slot B.
- 2026-10-23, release `efe6943`, then `e434813` (no oem image, `kobra-abctl --slot`, strict
  bundle members, login password prompt), over SSH on slot A: bundle members accepted, the
  stage removed after the handover, `kobra-bootok` re-armed slot A (tries 7), Klipper ready,
  no failed Moonraker components. With the default hash in place every interactive SSH
  login asked for a new password, Ctrl-C skipped it, plain SSH commands were not asked.
  `REBOOT_TO_STOCK` set B 15 / A 14 and stock came up; back with the stick, 1 short and
  3 long beeps. The `efe6943` installer logged "cannot read the A/B data in misc": stock's
  busybox 1.27.2 `od` has no `-A`/`-t`, so it went by rk_ota's exit status. `e434813` reads
  it with `hexdump`, and its slot check ran on stock and passed.
- 2026-10-27, release `44d9f9e` (Klipper config shipped in the image, `kobra-config-migrate`,
  `webcam.conf` read as data, filament macros refused while printing) over SSH on slot A,
  on the config of the 2026-10-22 install: the migration moved the unmodified
  `mainsail.cfg`, `kobra_s1.cfg` and `kobra_macros.cfg` to `config/backup-*` and switched
  their includes; `kobra_peripherals.cfg` (a hand-edited comment) was kept until `--force`.
  Klipper ready, no failed Moonraker components; `config/shednaja/` listed by Moonraker,
  uploads and deletes there fail (read-only). A `webcam.conf` with `;`, `$(...)` and a
  bare command line ran nothing, the bad lines were logged and ignored, a valid
  `WEBCAM_FPS` was applied. `LOAD_FILAMENT`, `UNLOAD_FILAMENT` and `CUT_TIP` during a
  print (a file with only `G4`) were refused without motion. Found on the way: the
  `mainsail.cfg` sum in `known-versions.sha256` was that of the upstream symlink, and an
  incremental build kept the old default configs and the old `S65webcam` (the first
  build, `863a946`, reinstalled the copies after migrating and still sourced
  `webcam.conf`); fixed in the list, `post-build.sh` and `build_rootfs.sh`.
  Backup folders are named by the clock at boot, before NTP (`backup-19700101-000017`).
