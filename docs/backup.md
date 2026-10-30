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

## Restoring stock into both slots

**Not tested yet.** This puts the stock system from the backup back into both slots and
removes ShedNaja. The slot the printer runs from is never written: stock is started from its
own slot (ShedNaja never writes it), and the other slot, the one ShedNaja ran from, is
written from the backup.

Never write `idblock`, `uboot_*`, `env`, `userdata` or `useremain`: ShedNaja does not change
them. `misc` only holds the A/B data, which stock manages itself. A whole-disk restore would
need a way to write the eMMC while nothing runs from it (maskrom, not working yet).

1. **Start stock:** run the macro `REBOOT_TO_STOCK` (Mainsail or the display). The printer
   comes up on stock with Rinkhals (SSH `root` / `rockchip`). With your SSH key on the
   printer (step 3 of the backup) the following steps do not ask for the password every time.
2. **Find the slot stock runs from:**
   ```
   ssh root@<printer-ip> 'tr " " "\n" < /proc/cmdline | grep ^root='
   ```
   `root=/dev/mmcblk0p8` means stock runs from slot A, and you restore slot **b**.
   `p9` means slot B, and you restore slot **a**.
3. **Write that slot from the backup and check it.** Run this from the repository's root
   folder. The images go straight over SSH, so no space is needed on the printer:
   ```
   D=dumps/emmc_YYYYMMDD_HHMMSS; IP=<printer-ip>; T=b    # T = the slot from step 2
   for p in boot system oem ac_lib ac_app; do
     n=${p}_$T
     ssh root@$IP "d=\$(readlink -f /dev/block/by-name/$n); grep -q \"^\$d \" /proc/mounts && { echo '$n is mounted - STOP'; exit 1; }; dd of=\$d bs=64k conv=fsync" < $D/$n.img || break
     want=$(awk -v n=$n '$1==n{print $5}' $D/md5.txt)
     got=$(ssh root@$IP "sync; echo 3 > /proc/sys/vm/drop_caches; md5sum /dev/block/by-name/$n" | cut -d' ' -f1)
     [ "$want" = "$got" ] && echo "$n OK" || { echo "$n FAILED - write it again"; break; }
   done
   ```
   Go on only when all five say `OK`. If one fails, write it again, and do not restart into
   that slot until it is OK. Stock keeps running from its own slot in the meantime.
4. **Check the running slot against the backup** (read-only; S is the other slot):
   ```
   S=a; for p in boot system oem ac_lib ac_app; do n=${p}_$S; echo "$n $(ssh root@$IP md5sum /dev/block/by-name/$n | cut -d' ' -f1) $(awk -v n=$n '$1==n{print $5}' $D/md5.txt)"; done
   ```
   The same two sums on each line mean both slots now hold the stock from the backup.
   Different sums mean stock was updated (OTA) after the backup. Keep it that way (the newer
   stock), or switch to the other slot (step 6) and repeat step 3 for slot S.
5. **Remove ShedNaja's files** (download `printer_data` first if you want your
   configuration):
   ```
   ssh root@$IP 'rm -rf /useremain/armbian /useremain/shednaja /useremain/shednaja-install.log; sync'
   ```
   Print files and Rinkhals stay; Rinkhals has its own uninstall.
6. **Optional, try the restored slot:**
   ```
   ssh root@$IP 'rk_ota --misc=other --mode=retry && reboot'
   ```
   The printer should come up on stock again; step 2 shows the other slot now. If that slot
   does not start, the bootloader returns to the first one after its tries.

To go back to ShedNaja later, use the installer stick again (docs/update.md).

For developers: `KEY=keys/kobra_ed25519 KNOWN_HOSTS=keys/known_hosts bash tools/backup_emmc.sh <ip>`
uses the project's test key and known_hosts as the script did before.
