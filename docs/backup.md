# Backing up the printer's eMMC (before installing ShedNaja)

Make this backup **before** the first install, while the printer still runs the stock
firmware. It only reads: nothing on the printer is changed. Keep it somewhere safe; it is
the only copy of your printer's own stock system, bootloader and calibration data.

## What you need

- The printer on stock firmware with **Rinkhals** installed (that is what gives the stock
  firmware SSH). Rinkhals' SSH login: user `root`, password `rockchip`.
- A PC on the same network with `bash`, `ssh`, `dd` and `md5sum`: Linux, WSL, or Git Bash
  on Windows (macOS lacks `md5sum` and GNU `stat`; use a Linux VM there).
- This repository (for `tools/backup_emmc.sh`), about 1.5 GB of free space (7.5 GB with the
  data partition), and a stable Wi-Fi: expect 4–5 MB/s, so about 6 minutes, or about
  30 minutes with the data partition.

## Steps

1. Find the printer's IP address (the printer's network screen, or your router).
2. Check that SSH works, and accept the host key when asked:
   ```
   ssh root@<printer-ip> 'cat /useremain/dev/version; cat /sys/block/mmcblk0/device/cid'
   ```
   This prints the stock firmware version and the eMMC's ID.
3. Optional, saves typing the password: put your own SSH key on the printer once (this
   writes one file into root's home on the printer, nothing else):
   ```
   cat ~/.ssh/id_ed25519.pub | ssh root@<printer-ip> 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'
   ```
4. Run the backup from the repository's root folder:
   ```
   bash tools/backup_emmc.sh <printer-ip>                # everything except the data partition
   bash tools/backup_emmc.sh <printer-ip> --useremain    # also print files, configs, logs
   ```
   Without a key the script asks for the password once (or once per step if your SSH client
   cannot share connections). It reads every partition with `dd`, then compares an md5 sum
   computed on the printer with the one of the copy.
5. It ends with `Done: dumps/emmc_<date>_<time> (all partitions verified)`. Any `MISMATCH`
   means that partition's copy is not usable: run it again (Wi-Fi drops are the usual cause).
   Copy the whole `dumps/emmc_...` folder to a second place (USB drive, cloud).

## What is in it

| File | What |
|---|---|
| `layout.txt` | partition table, kernel command line, eMMC ID, stock version |
| `raw_head_0-32K.img` | the start of the disk before the first partition |
| `env`, `idblock`, `uboot_a/b`, `misc` | U-Boot environment, SPL/U-Boot, the A/B boot data |
| `boot_a/b`, `system_a/b`, `oem_a/b` | kernel, system and oem of both slots (stock) |
| `userdata` | Wi-Fi configuration and stock's printer settings |
| `ac_lib_a/b`, `ac_app_a/b` | Anycubic's application partitions |
| `useremain` (`--useremain`) | print files, logs, Rinkhals, ShedNaja's data later |
| `md5.txt` | size, md5 and result per partition |

`useremain` (and `userdata`) are mounted while they are read: their copy is a live snapshot,
and `useremain`'s md5 is expected to differ ("CHANGED"). Everything a restore of the system
needs (bootloader, slots, `misc`) is read exactly.

## Restoring

Not tested yet. Single partitions can be written back from a running system with `dd` to
`/dev/block/by-name/<name>`, never the slot the printer runs from. A whole-disk restore needs a
way to write the eMMC while nothing runs from it (maskrom, not working yet). Ask before you
try; the safer way back is `REBOOT_TO_STOCK` and the installer stick (docs/update.md).

For developers: `KEY=keys/kobra_ed25519 KNOWN_HOSTS=keys/known_hosts bash tools/backup_emmc.sh <ip>`
uses the project's test key and known_hosts as the script did before.
