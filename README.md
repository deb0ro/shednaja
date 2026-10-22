# ShedNaja

An open operating system for the **Anycubic Kobra S1**: our own Linux kernel and
Buildroot system on the printer's host board, with mainline-style **Klipper**,
**Moonraker**, **Mainsail** and **HelixScreen** on the printer's own display. No
Anycubic cloud, no GoKlipper.

ShedNaja installs **next to** the stock firmware. The Kobra S1 has two system slots (A/B):
stock stays in one, ShedNaja goes into the other, and you can switch between them at any time.

> **Status: alpha.** It runs and prints on the developer's printer. It has not been tested
> on many printers, and some things do not work yet (see below). Only use it if you are
> comfortable with Klipper and SSH, and keep the way back to stock in mind.

## What works

| | |
|---|---|
| Motion | CoreXY, homing with endstops, 600 mm/s / 20 000 mm/s² limits as stock |
| Probe | Load-cell (CS1237) nozzle probe: Z homing, `BED_MESH_CALIBRATE`, `PROBE_ACCURACY` |
| Input shaper | `SHAPER_CALIBRATE` with the LIS2DW12 accelerometer in the toolhead |
| Heaters, fans | Nozzle, bed, part / auxiliary / exhaust fans, controller fan |
| Sensors | Toolhead filament runout sensor: pauses the print on runout, loads new filament on insertion, then `RESUME` |
| Display | HelixScreen on the 800×480 touch screen |
| Web | Mainsail + Moonraker on port 80, camera stream (MJPEG, 640×480, 15 fps) |
| Extras | Chamber light, buzzer (`M300`), Wi-Fi (uses your stock Wi-Fi settings). The Bluetooth controller comes up, but nothing uses it yet (no pairing tools) |
| Updates | Over SSH or from a USB stick, with a progress screen; reads back what it wrote |
| Power-loss recovery | `RESUME_INTERRUPTED` continues a print after a power cut from the layer it stopped in; Z is re-measured with the probe next to the print (needs the layer info the ShedNaja OrcaSlicer profile writes) |
| Back to stock | `REBOOT_TO_STOCK` macro (Mainsail / HelixScreen), one tap |

## What does not work (yet)

- **ACE Pro** (multi-colour unit): not supported yet. The ACEPRO driver is in the image for
  later integration, inactive ([docs/peripherals.md](docs/peripherals.md#ace-pro)).
- Anycubic cloud, Anycubic app and the Anycubic slicer's printer integration: not supported,
  and not planned. Use Mainsail / Moonraker (OrcaSlicer, Klipper-compatible slicers).
- Tested with stock firmware **2.7.2.7** and the Anycubic MCU firmware **v1.4.3** that
  comes with it. Other versions: unknown. ShedNaja does not flash the MCUs ([docs/mcu.md](docs/mcu.md)).
- Tested in both slot layouts: stock in A with ShedNaja in B, and stock in B with ShedNaja
  in A (install, display, password change, `REBOOT_TO_STOCK`).
- If ShedNaja boots but Klipper, Wi-Fi and the display all fail, there is no automatic way
  back to stock yet: you need SSH or the serial console ([docs/update.md](docs/update.md#if-shednaja-does-not-start)).

## Requirements

- Anycubic Kobra S1 on stock firmware **2.7.2.7** (Settings → About).
- A USB stick, FAT32, MBR or GPT.
- The printer on your Wi-Fi network (set it up in the stock firmware first; ShedNaja uses
  the same settings).

## Install

1. Get a release (`aGVscF9zb3Nf/update.swu`), or build it yourself (see below).
2. Copy the `aGVscF9zb3Nf` folder to the root of the USB stick.
3. With the printer on and running stock, plug in the stick. The stock updater runs the
   ShedNaja installer:
   - it writes ShedNaja into the slot stock is **not** running from and checks what it wrote,
   - it does not touch the stock slot or your data,
   - it beeps **3 times** and restarts into ShedNaja;
   - on an error it beeps **5 times** and stays on stock (log: `shednaja-install.log` on
     the stick).
4. Open `http://<printer IP>/` for Mainsail. HelixScreen comes up on the display.

The first boot puts a default Klipper configuration into
`/useremain/shednaja/printer_data/config/`. Calibrate before you print: `PROBE_CALIBRATE`
(Z offset), `PID_CALIBRATE`, `SHAPER_CALIBRATE`.

## Going back to stock, and back again

- **To stock:** run the `REBOOT_TO_STOCK` macro (Mainsail macros or HelixScreen) and
  confirm. The printer resets its MCUs and restarts into the stock firmware.
- **Back to ShedNaja:** plug in the same installer stick while stock is running. Images that
  are already installed are not written again; it only switches the slot (3 beeps).

ShedNaja never changes the stock slot, so stock keeps working as before.

## SSH and the root password

- `ssh root@<printer IP>`, password: the stock one (`rockchip`).
- **Change it** with `passwd`. It is stored on `/userdata` and survives updates. To reset
  it to the default, delete `/userdata/shednaja/shadow` and reboot.
- SSH keys go into `/userdata/shednaja/ssh/authorized_keys`.

## Updating

Put `shednaja-update-<version>.tar` into the root folder of a USB stick and power-cycle
the printer, or over SSH:

```
scp -O shednaja-update-<version>.tar root@<printer>:/useremain/shednaja/update/
ssh root@<printer> kobra-update /useremain/shednaja/update/shednaja-update-<version>.tar
```

Updates refuse to run while printing. Details: [docs/update.md](docs/update.md).

## Building from source

Everything is built from public sources at pinned versions. The only files taken from
Anycubic come from the **official stock update KS1_2.7.2.7.swu**. This repository does not
contain them: `tools/fetch_stock.sh` downloads that file and checks its sha256.

**Host:** Linux (tested: Ubuntu 24.04, also under WSL2 on Windows; the scripts re-run
themselves in WSL when started from Git Bash). About 15 GB of disk space.

```
sudo apt install build-essential git curl unzip zip python3 python3-pip bc rsync cpio \
    file wget squashfs-tools e2fsprogs device-tree-compiler libssl-dev flex bison \
    u-boot-tools qemu-user-static
```

```
bash tools/fetch_stock.sh             # stock boot/oem/system images, BT firmware, MCU dictionary -> build/stock/
bash tools/build_kernel.sh            # kernel 5.10.160, Wi-Fi/BT modules, boot.img -> build/kernel/
bash tools/build_oem_ours.sh          # stock oem image with our kernel's modules -> build/kernel/oem_ours.img
bash tools/build_rootfs.sh            # Buildroot rootfs (squashfs) -> build/rootfs/
bash rootfs/tests/offline_check.sh    # optional: klippy, Moonraker, lighttpd under qemu
bash tools/make_update_bundle.sh      # -> build/update/shednaja-update-<id>.tar
bash tools/make_install_swu.sh        # -> build/install/aGVscF9zb3Nf/update.swu
```

The first kernel and rootfs builds download the sources and take a while (about 1 to 2 hours
in total).

### Sources

| Part | Source | Version |
|---|---|---|
| Kernel 5.10.160, toolchain, Buildroot 2023.02.6 | [LuckfoxTECH/luckfox-pico](https://github.com/LuckfoxTECH/luckfox-pico) | `824b817` |
| Bluetooth driver, `rtk_hciattach` | [radxa/rkwifibt](https://github.com/radxa/rkwifibt) | `b61a1e8` |
| Klipper (Kobra S1 fork) | [Kobra-S1/klipper-kobra-s1](https://github.com/Kobra-S1/klipper-kobra-s1) | `45f35e8` + `rootfs/package/klipper/*.patch` |
| Moonraker | [Arksine/moonraker](https://github.com/Arksine/moonraker) | v0.11.0 |
| Mainsail, mainsail-config | [mainsail-crew](https://github.com/mainsail-crew) | 2.19.0, v1.2.1 |
| HelixScreen | [prestonbrown/helixscreen](https://github.com/prestonbrown/helixscreen) | 1.0.6 |
| numpy (input shaper) | [numpy/numpy](https://github.com/numpy/numpy) | 1.23.5 |
| Stock files (boot template, oem image, BT firmware, root hash, MCU dictionary) | official Anycubic update `KS1_2.7.2.7.swu`, via the [Rinkhals firmware archive](https://rinkhals.firmwareforge.org/) | sha256 `e3f22184…` |

Other packages come from Buildroot itself. Every version and checksum is pinned in
`tools/build_*.sh` and `rootfs/package/*/`.

### What comes from the stock firmware

- **boot.img:** our kernel and device tree, packed into the stock FIT layout. Only the
  stock image's structure is reused, and our own boot logo replaces the stock one.
- **oem image:** the stock `oem` squashfs (Rockchip userspace libraries, kernel modules
  loaded from `/oem`). The three modules that must match our kernel (RTL8723DS, hci_uart,
  cfg80211) are replaced with our builds; everything else is unchanged Anycubic/Rockchip
  content. It is built on your machine from the downloaded stock file and is not part of
  this repository.
- **Bluetooth firmware** of the RTL8723DS and the stock root password hash.
- The MCUs keep running Anycubic's firmware v1.4.3; ShedNaja does not flash them.

## Repository layout

| Path | Content |
|---|---|
| `kernel/` | device tree, kernel config fragment, patches, boot logo |
| `rootfs/` | Buildroot external tree: defconfig, packages, overlay, default printer config, tests |
| `swu/shednaja_install/` | the installer that runs from the stock USB updater |
| `tools/` | build scripts, update bundle and installer packers, flashing and backup helpers |
| `slicer/` | OrcaSlicer profile converter for ShedNaja's `PRINT_START` / `PRINT_END` |
| `docs/` | how things work; `docs/history/` the development log with test results |

Documentation index: [docs/README.md](docs/README.md). The current pages describe how
things are now; `docs/history/` holds the development logs, which are not instructions.

## Safety

- ShedNaja does not write the stock slot, `/userdata` contents of the stock firmware, or the
  MCUs. The installer and updates write only the ShedNaja slot and check every write.
- If ShedNaja does not boot, the bootloader falls back to the stock slot after a few tries
  (power-cycle the printer if it hangs).
- You use this at your own risk. It is not affiliated with or endorsed by Anycubic.

## Licence

ShedNaja's own code is GPL-3.0 ([LICENSE](LICENSE)), except where a file or package says
otherwise (`kobra-abctl` and `kobra-webcam` are MIT). Kernel parts (device tree, patches)
are GPL-2.0 like the Linux kernel. The components built from the sources above keep their
own licences.
