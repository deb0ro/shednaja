# ShedNaja Armbian (beta)

**Beta. Tested on one host board only.** The Armbian variant replaces ShedNaja Lite's small
busybox system with Debian 13 (Armbian, kernel 6.1) and the same Klipper stack: Klipper,
Moonraker, Mainsail, HelixScreen and the camera, with the same configuration. Stock stays
in the other slot as the fallback, exactly as with Lite. Builders: `armbian_build/README.md`.

## Before you install

**Back up the eMMC first**, while the printer runs stock with Rinkhals: [backup.md](backup.md)
(read-only, about 6 minutes over Wi-Fi).

Known limits of the beta:

- **The Debian root is writable and lives on useremain, which has no journal.** A power cut
  while the printer writes (during a print, during an update) can leave the filesystem
  inconsistent. The loader repairs it at the next boot (`e2fsck -fy`, as stock does), but
  files that were being written can be lost. Lite's root is read-only and does not have this
  risk.
- **RAM:** 256 MB on this board. With the whole stack idle about 150 MB stay available;
  during `SHAPER_CALIBRATE` it went down to 100 MB (the same as Lite).
- **ACE Pro:** packaged but inactive, as in Lite; not tested.
- **Camera:** after a USB re-enumeration it can come back as `/dev/video1` and the webcam
  does not start until the next reboot (shared with Lite).
- **Bluetooth:** the adapter starts, nothing uses it.
- The first boot after an install takes a few minutes longer (the root is unpacked).

Space: about 1.5 GB on useremain (two Debian roots plus an update), your print files stay.

## Install

### From the stock firmware (USB stick)

1. Copy the `aGVscF9zb3Nf` folder of the Armbian installer (`build/install-armbian/`) to the
   root of a FAT32 stick, plug it into the printer running stock.
2. The stock updater runs the installer: 1 short beep, then 3 long beeps and a reboot. It
   writes the base kernel and the loader into the slot stock does **not** run from, puts the
   Debian root on useremain and switches to that slot. Stock itself is never written.
   5 short beeps = error, nothing switched, the printer stays on stock; the log is
   `shednaja-install.log` on the stick.
3. First boot: the loader unpacks the root (a few minutes), then Klipper starts. Wi-Fi uses
   the stock Wi-Fi configuration.

### From ShedNaja Lite

Over SSH, with a complete Armbian bundle (`shednaja-armbian-update-<id>.tar` that holds
rootfs, boot and system):

```
scp -O shednaja-armbian-update-<id>.tar root@<printer>:/useremain/shednaja/update/
ssh root@<printer> kobra-update --to-armbian /useremain/shednaja/update/shednaja-armbian-update-<id>.tar
```

Lite stages the root, writes the base kernel and loader into its own slot and reboots. Armbian
keeps Lite's SSH host keys and root password, and copies Lite's `printer_data` once into its
own copy (`/useremain/armbian/shednaja`); Lite's data stays untouched for a way back.

## After the install

- **Password:** root's password is `rockchip` (as on Lite and stock) unless it came from Lite.
  Every login asks for a new one until you set it.
- **SSH host key:** a printer installed from stock makes its own key on the first connection
  (your SSH client warns that the key changed if it knew this address before).
- **IP address:** DHCP like stock and Lite; the printer usually keeps the address it had.

## Updates

All updates install the new system next to the running one; the printer restarts into it,
and if the new system does not come up three times in a row, the previous one comes back by
itself.

- **Mainsail:** Machine tab → upload the bundle into a folder `updates` → run the macro
  `SHEDNAJA_UPDATE` → Install. The printer restarts when it is done (about 5 minutes).
- **USB stick:** `shednaja-armbian-update*.tar` in the root folder of a FAT32/exFAT stick,
  power-cycle; the update runs before Klipper starts. The stick can stay in.
- **SSH:** `kobra-update /path/to/shednaja-armbian-update-<id>.tar`.

Updates are refused while a print is running or paused.

## Going back

- **To the previous version:** macro `ROLLBACK_SYSTEM` (Mainsail, HelixScreen), or
  `kobra-ab rollback` over SSH.
- **To stock:** macro `REBOOT_TO_STOCK`. Back from stock: the Armbian installer stick again
  (only the slot switch and a fresh root; your printer data stays).
- **To Lite:** a Lite update bundle with `kobra-update --to-lite <shednaja-update-<id>.tar>`
  over SSH. Lite starts with its own, older data (the configuration from before Armbian).
- **Removing Armbian's files** once you are back on Lite or stock for good (about 1.5 GB):
  `rm -rf /useremain/armbian` over SSH. Without them the Armbian loader in the slot would
  switch to stock by itself, so only do this when you do not boot Armbian any more.

## Reporting a problem

Please send, with a short description of what you did and what happened:

```
ssh root@<printer> 'kobra-ab status; kobra-abctl display; uptime; free -m; df -h /useremain;
  journalctl -b --no-pager | tail -300; dmesg | tail -200' > report.txt
scp -O root@<printer>:/useremain/shednaja/printer_data/logs/klippy.log .
scp -O root@<printer>:/useremain/shednaja/printer_data/logs/moonraker.log .
scp -O root@<printer>:/useremain/shednaja/update/last-update.log .     # after an update
```

If the printer came up on stock unexpectedly, note the time; the reason is usually in the
loader's messages, which only a serial console (pad J1, see `docs/hardware.md`) shows.
