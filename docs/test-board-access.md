# Getting access to the test host board (variant A: backup + Wi-Fi → Rinkhals → SSH)

## Why over USB
- The firmware has **no recovery AP**. `hostapd`/`dnsmasq` exist (Rockchip SDK), but the Anycubic app never starts them. `wifi_start.sh` only connects as a client.
- On USB insertion (udev `61-udisk-auto-mount.rules`), the stock firmware runs `/userdata/channel.sh`. That script takes `<usb>/aGVscF9zb3Nf/update.swu` (zip with a fixed password), extracts `update_swu/setup.tar.gz` and **runs `update.sh` as root**. There is no signature check. Rinkhals installs the same way.

## Package `build/ks1_backup_wifi.swu`
Source in `swu/ks1_backup_wifi/`, built with `bash tools/make_swu.sh swu/ks1_backup_wifi build/ks1_backup_wifi.swu`.
Tested on the printer: extracts with the stock `unzip -P` and passes busybox `sh -n` (only extracted in /tmp, nothing run).

What it does:
1. Backs up the whole eMMC (all partitions except `useremain`, ~1.4 GB) to `<usb>/kobra_backup_<CPU-serial>/`, with md5 checked against the source (`md5.txt`). It stops on any mismatch.
2. Copies the bundled `wpa_supplicant.conf` (the printer's Wi-Fi) to `/userdata/wifi_cfg/` and keeps the old one as `.bak_tool`. **This is the only write to the eMMC.**
3. Starts `wpa_supplicant` + `udhcpc` and writes the IP to `ip.txt` on the USB stick.
4. Log: `tool.log`. Beeps: 1 = start, 2 = backup done, **3 long = all done**, 5 short = error.

## Hardware: where to plug in the USB stick
Neither the upper nor the lower board has a USB connector. USB from the RV1106 goes through the GL850G hub (camera on port 3) to a separate PCB in the printer body. The simplest way:
1. Turn the printer off and **temporarily put the test upper board in place of the original** (same connectors: display FPC, harness to the lower board, the USB/camera cable).
2. USB stick: FAT32 (MBR), ≥ 2 GB free, file at `aGVscF9zb3Nf/update.swu`.
3. Turn on, wait for the boot, insert the stick. Wait for **3 long beeps** (the backup takes about 3–5 min).
4. Pull the stick and check `kobra_backup_*/md5.txt` (16× OK) and `ip.txt`.
5. Then install Rinkhals the same way (`update-ks1.swu` → `aGVscF9zb3Nf/update.swu`). After that SSH works and `tools/flash_boot_slot.sh` can be used.
