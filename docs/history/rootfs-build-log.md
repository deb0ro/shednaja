# Own minimal rootfs for the Kobra S1 host (system_a / system_b)

> **Development log, not a how-to.** This page records an experiment or test from the
> development of ShedNaja (the rootfs build log, 2026-10-20/21; the current page is [rootfs-build.md](../rootfs-build.md)). Commands, slot names and file paths in it describe the
> setup at that time and can be wrong or **destructive** on a printer installed today (for
> example, writing "the inactive slot" can overwrite the stock fallback). Paths under `dumps/`,
> `logs/` and `build/` refer to unpublished development files. Current documentation:
> [docs/README.md](../README.md).

Step 1 of the own-OS plan: a reproducible, read-only Buildroot rootfs that boots with our kernel (docs/kernel-build.md) and keeps the stock data partitions. Klipper/Moonraker come in step 2.
**Status (2026-10-20):** `build/rootfs/rootfs.squashfs` (12.8 MiB at step 1) builds. *Correction:* the step-1 "`CLEAN=1` rebuild gave a bit-identical image" check was not a clean rebuild: when the script was started from Git Bash, `CLEAN` did not reach WSL (fixed in step 2; see "Step 2" for the real check). The target binaries and init scripts were smoke-tested under qemu-arm (python imports, dropbear/wpa_supplicant/rtk_hciattach/kobra-abctl run, `busybox sh -n` on all init scripts). It has **not been flashed or booted yet**; see the test plan below.

## Quick start

```bash
bash tools/build_rootfs.sh            # Git Bash or WSL; needs build/kernel/ from tools/build_kernel.sh
```

- The first run downloads about 60 MB of sources into `~/kobra/br-dl` and builds the host tools (about 15 min). Later runs are incremental.
- If `rootfs/configs/kobra_s1_defconfig` or the busybox fragment changes, the script automatically starts from a clean output dir, because Buildroot does not rebuild a package when only its options change.
- No sudo needed: Buildroot uses fakeroot for ownership.
- Overrides: `SDK_DIR`, `BT_DIR`, `BR_OUT` (`~/kobra/rootfs-out`), `BR_DL`, `DUMP`, `JOBS`, `CLEAN=1`. Since step 2 they are passed through when the script re-runs itself in WSL from Git Bash; before that they were silently dropped.

## Inputs (all pinned)

| What | Source |
|---|---|
| Buildroot | `buildroot-2023.02.6.tar.gz` from the Luckfox SDK (`sysdrv/tools/board/buildroot`, SDK @ `824b817f`), sha256 `087d0514…6331`. Extracted pristine, no SDK patches needed. |
| Toolchain | external, the SDK's `arm-rockchip830-linux-uclibcgnueabihf` (gcc 8.3.0, uClibc-ng 1.0.31). Same as the kernel and the stock userspace. |
| Our tree | `rootfs/` = BR2_EXTERNAL `KOBRA`: `configs/kobra_s1_defconfig`, `board/kobra_s1/{overlay,post-build.sh,post-fakeroot.sh,busybox.fragment}`, packages `kobra-abctl` (our code) and `rtk-hciattach` |
| rtk_hciattach | `radxa/rkwifibt` @ `b61a1e84` `tools/rtk_hciattach` (Realtek 3.1.390bad8.20220519; stock runs 3.1.9495cb2.20230413) |
| Kernel modules | `build/kernel/modules-5.10.160.tar.gz` (ours, incl. `extra/RTL8723DS.ko`, `extra/hci_uart.ko`) → `/lib/modules/5.10.160` |
| BT firmware | **stock** `/lib/firmware/rtlbt/rtl8723d_fw` + `rtl8723d_config` from `ac_lib.img` of the official `KS1_2.7.2.7.swu` (`tools/fetch_stock.sh` → `build/stock/rtlbt/`, same files as in the `ac_lib_a` dump). The radxa copies differ: older firmware, and the config lacks two board entries (0x008d/0x008f), so they are only a fallback with a warning. |
| root login | root password hash = stock (`etc/shadow` of `build/stock/system.img`, the official update's rootfs), so the stock root password works on getty/SSH. `/etc/shadow` is a link to `/run/shadow` → `/userdata/shednaja/shadow` (`post-fakeroot.sh`, `S00kobra-mounts` seeds it from `/usr/share/shednaja/shadow.default`), so `passwd` works and the owner's password survives updates; deleting the file restores the default. SSH keys: `/root/.ssh` → `/userdata/shednaja/ssh` (persistent, the owner adds `authorized_keys`). Only a development build bakes a key in: `SSH_KEY=keys/kobra_ed25519.pub bash tools/build_rootfs.sh`, build id `<commit>+devkey` (also in the bundle name), never to be released |

Defconfig decisions: start from the SDK's `luckfox_pico_defconfig` toolchain block and drop everything else in it (openssh, bash, iptables, samba, many python libs…). `BR2_OPTIMIZE_S`, `BR2_REPRODUCIBLE`, squashfs xz with 128K blocks like stock, mdev instead of eudev (the kernel has devtmpfs but no uevent helper, so we use `mdev -df` from Buildroot's S10mdev).

## Outputs (`build/rootfs/`)

| File | Content |
|---|---|
| `rootfs.squashfs` | the image for `system_a` / `system_b` (squashfs 4, xz, 128K) |
| `manifest.txt` | inputs and pins, size report, installed size per package, package versions |
| `buildroot.config`, `kobra_s1_defconfig.saved` | full config and the savedefconfig |
| `build.log`, `SHA256SUMS` | log and checksum |

## Contents

| Area | What |
|---|---|
| init | busybox init + Buildroot sysv scripts; inittab with **getty on ttyFIQ0 @115200** (stock had it commented out) |
| `S00kobra-mounts` | `/dev/block/by-name/*` links (from `PARTNAME` in sysfs, fallback: stock's static table). `oem_<slot>` → `/oem` (ro squashfs), `userdata` → `/userdata`, `useremain` → `/useremain` (ext4, noatime). `/data` → `userdata` (symlink, as in stock). `e2fsck -p` (preen only), then rw mount, then ro fallback. **Never formats.** Stock S20linkmount runs `mke2fs` if a mount fails; ours does not. Creates `/userdata/shednaja/{dropbear,seedrng,log}`. |
| `S01seedrng`, `S01syslogd`, `S02klogd`, `S02sysctl`, `S10mdev`, `S40network` (lo) | Buildroot defaults. S10mdev runs the mdev daemon plus a modalias coldplug (`modprobe -abq`); `/etc/modprobe.d/kobra-blacklist.conf` keeps the unused camera/ISP/NPU/RGA/sensor modules from autoloading. The random seed lives in `/userdata/shednaja/seedrng` (symlink). |
| `S30kobra-modules` | `modprobe cfg80211 RTL8723DS` (our modules from `/lib/modules`, not from `/oem/usr/ko`) |
| `S41wifi` | `wpa_supplicant -D nl80211 -i wlan0 -c /userdata/wifi_cfg/wpa_supplicant.conf` (**the stock file**: same `ctrl_interface=/var/run/wpa_supplicant`, `update_config=1`), `udhcpc` on wlan0 and on eth0 if present |
| `S42bluetooth` | as stock S98_bluetooth_connect: rfkill + `/proc/bluetooth/sleep/btwrite` power cycle, `modprobe hci_uart`, `rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5` |
| `S48ntpd` | busybox `ntpd -n -p {0,1,2}.pool.ntp.org` |
| `S50dropbear` | Buildroot's script. Host keys are generated on first boot (`-R`) into `/etc/dropbear` → `/run/dropbear-keys` → `/userdata/shednaja/dropbear`, so they survive reboots. If `/userdata` is not writable, `S00` points the link at a tmpfs dir instead, and SSH still comes up with fresh keys. Root login with our key or the stock password. |
| `S99kobra-bootok` | A/B success marking, see below |
| tools | busybox (+ ntpd, mdev daemon, modprobe/depmod, i2c tools, rfkill, …), dropbear 2022.83, wpa_supplicant 2.10 + wpa_cli (internal crypto, WPA2-PSK), e2fsprogs 1.46.5 (e2fsck), python 3.11.6 (+ zlib, sqlite3, ssl, lzma, ctypes), kobra-abctl, rtk_hciattach |
| `/etc/os-release` | `ID=shednaja`, `VERSION_ID=0.1`, `BUILD_ID=<git describe of this repo>` |

Not included (on purpose): the Anycubic app/UI (`/ac_lib`, `/ac_app` are not mounted, K3SysUi/GoKlipper do not start), bluez userspace (`hciconfig`/`bluetoothctl`; `rtk_hciattach` alone brings up `hci0`), stock vendor modules (rockit, rknpu, mpp…), and rk_ota.

## Sizes

Current numbers are in `build/rootfs/manifest.txt`. **rootfs.squashfs = 12.8 MiB** (33 MB unpacked), leaving **35.2 MiB of the 48 MiB** system partition for step 2.

| Part (unpacked) | Size |
|---|---|
| python3 3.11.6 (stdlib as .pyc) | 9.6 MB |
| libopenssl 1.1.1v (for python ssl) | 2.5 MB |
| toolchain libs (uClibc, libstdc++, libgcc) | 1.6 MB |
| sqlite (python sqlite3) | 1.1 MB |
| e2fsprogs | 1.0 MB |
| busybox | 0.9 MB |
| wpa_supplicant + libnl | 1.5 MB |
| kernel modules 5.10.160 | 3.5 MB |
| xz, zlib, libffi, dropbear, util-linux libs, rest | about 1 MB |

The python extras (zlib/sqlite3/ssl/lzma, plus the OpenSSL/SQLite/xz libraries they pull in) add 1.6 MiB compressed: 11.2 MiB without them, 12.8 MiB with them.

## A/B slots without S99_bootcontrol / rk_ota

Measured by running the stock `/usr/bin/rk_ota` under `qemu-arm-static` on copies of our `misc` dump (`rootfs/package/kobra-abctl/test/compare_with_rk_ota.sh`).

**AvbABData format:** misc offset 2048, 32 bytes:
- magic `\0AB0`, version 1.0
- 2 × {priority, tries_remaining, successful_boot, reserved}
- `last_boot`
- crc32 over the first 28 bytes, stored **big endian**

SPL boots the bootable slot with the highest priority and counts its `tries_remaining` down. If a slot runs out of tries without being marked, SPL falls back to the other slot.

**Stock `S99_bootcontrol`** runs `rk_ota --misc=now --mode=retry` on every boot:
- "now" means the **highest-priority slot**, not the slot in the cmdline.
- It sets that slot's `tries_remaining = 7`, `successful_boot = 0`, `last_boot = slot`.

So the slot stays in retry mode, and every boot that gets that far re-arms 7 tries. In the dump both slots show 7, which matches this.

**`rk_ota --misc=other --mode=retry`** (used by `tools/flash_slot.sh`):
- other slot: priority 15, tries 7, successful 0
- current slot: priority 14 only, its tries and successful flag stay

**Our `kobra-abctl`** (C, about 100 lines, `rootfs/package/kobra-abctl`) implements `now`, `other` and `display`. It writes only when something changes and refuses to touch data with a bad CRC. Its results are byte-identical to `rk_ota` in 12 tested state/command combinations; re-run `compare_with_rk_ota.sh` to check again. `S99kobra-bootok` runs `kobra-abctl now` at the end of rcS, which is where stock runs `S99_bootcontrol`.

Consequence: like stock, a boot counts as good once rcS has finished, even if Wi-Fi or other services failed. A kernel panic (`panic=5`) or a hang before S99 uses up a try. After 7 such boots SPL falls back.

## flash_slot.sh

`tools/flash_slot.sh <ip> <boot.img|-> [oem.img] [--system build/rootfs/rootfs.squashfs] [--write]`
- writes `system_<target>` in addition to boot/oem (`-` skips boot)
- same safety as before: inactive slot only (from `root=` in `/proc/cmdline`), refuses mounted target partitions, saves the old contents of every target partition to `dumps/`, upload md5, readback md5, slot switch only after all readbacks match
- switches the slot with `rk_ota` on the stock rootfs and `kobra-abctl` on ours (identical misc changes)

## Boot / test plan (for the main session with the user)

Current board state: slot B = our kernel + oem_ours + **stock** rootfs (running). Slot A = stock.
1. Build: `bash tools/build_kernel.sh` (if needed), `bash tools/build_rootfs.sh`.
2. Dry run from the running slot B, with A as target:
   `bash tools/flash_slot.sh <printer-ip> build/kernel/boot.img build/kernel/oem_ours.img --system build/rootfs/rootfs.squashfs`
   This saves `boot_a`, `oem_a` and `system_a` to `dumps/`. Slot A then has our kernel with `root=/dev/mmcblk0p8` (U-Boot sets it per slot).
3. Start the J1 logger (115200), then run the same command with `--write`, then reboot.
4. Expected on J1: kernel log → `kobra-mounts: oem_a mounted…`, `userdata mounted on /userdata` → login prompt on ttyFIQ0 → `kobra-bootok: slot re-armed`.
   Then Wi-Fi with the stock config (same IP from DHCP if the router keeps it) and SSH with `keys/kobra_ed25519`. The host key is new, so drop the old entry from `keys/known_hosts`.
5. Check: `cat /etc/os-release`, `kobra-abctl display`, `mount`, `lsmod`, `hciconfig` is not there (check `ls /sys/class/bluetooth` → `hci0`), `python3 -c 'import zlib, sqlite3, ssl'`, `date` after ntpd.
6. The printer UI stays dark and GoKlipper does not run, so the MCUs are idle and the heaters are off. That is expected in step 1.

## Rollback

- **Automatic:** if slot A never reaches S99 (panic, hang, no rcS), SPL falls back to slot B after 7 boots. Power-cycle a few times; `panic=5` reboots by itself.
- **From our rootfs:** `kobra-abctl other && reboot` → slot B (our kernel + stock rootfs).
- **From the stock rootfs:** `rk_ota --misc=other --mode=retry`.
- **Restore partitions:** write the `dumps/*_before_flash_*.img` files back with `flash_slot.sh` (from the other slot) or with `dd` on the board. Full eMMC backups are in `dumps/emmc_*`.
- Nothing on `userdata` / `useremain` is changed except the new directory `/userdata/shednaja/`. Delete it to go fully back to stock.

## Open points / next steps

- Step 2: Klipper + Moonraker (+ Mainsail) and the display/touch UI. Python 3.11 is already there with zlib/sqlite3/ssl.
- Bluez userspace (bluetoothctl) if BT is needed at all. Otherwise drop the BT bring-up.
- Our modules live in the rootfs, so `oem` is only mounted for compatibility (stock data/scripts there are unused). It could be dropped later.
- Watchdog: none is armed yet. A hang after S99 needs a manual power cycle.
- RK630 PHY thermal-zone log spam (kernel side): fixed 2026-10-21, see docs/kernel-build.md "Clean-up round".
- `radxa/rkwifibt` @ `b61a1e84` also has `drivers/rtl8723ds` at **exactly the stock version** `v5.13.5-34-gf315764ad.20220118`. Our kernel build uses the older v5.10.1 copy. Worth switching (kernel task).

## First boot on hardware – WORKS (2026-10-20 19:31, test host board in the printer)
Board switched to stock slot A first, then `tools/flash_slot.sh <printer-ip> build/kernel/boot.img build/kernel/oem_ours.img --system build/rootfs/rootfs.squashfs --write`
→ **slot B = our kernel + oem_ours + our rootfs**, **slot A = untouched stock**. The previous `boot_b` / `oem_b` / `system_b` were saved in `dumps/*_before_flash_20261020_192842.img`.
- J1 console (`logs/bootlog_shednaja_slotB_20261020.log`): kernel → `VFS: Mounted root (squashfs) readonly on 179:9` → `kobra-mounts: oem_b / userdata / useremain mounted` → RTL8723DS loaded → `kobra-bootok: slot re-armed` at 10.8 s → **`kobra-s1 login:` on ttyFIQ0** after about 11 s. No panic or oops.
- SSH with our key works (new host key, kept in `keys/known_hosts_shednaja`). `os-release` = ShedNaja.
- `kobra-abctl display`: B priority 15 / tries 7, A priority 14 / tries 7, last_boot 1. The retry counter is re-armed as on stock.
- Mounts: `/` squashfs ro, `/oem` (oem_b) ro, `/userdata` and `/useremain` ext4 rw. Nothing was formatted.
- Wi-Fi with the stock `/userdata/wifi_cfg/wpa_supplicant.conf`: same IP <printer-ip>, DNS from DHCP. BT: `rtk_hciattach` → `hci0` present.
- RAM: **11 MB used**, 196 MB available (stock with GoKlipper/UI: about 114 MB used). Rootfs 12.9 MB.
- Python 3.11: `zlib`, `sqlite3`, `ssl` import OK.
- Running: wpa_supplicant, udhcpc (wlan0 + eth0), rtk_hciattach, ntpd, dropbear, getty ttyFIQ0.
- Minor: `regulatory.db` missing (cfg80211, harmless, can be added). ntpd had not synced 47 s after boot (clock still 1970), so check later. The UI is dark and GoKlipper does not run (expected in step 1). The MCUs are idle and the heaters are off.
- Rollback: `kobra-abctl other && reboot` → stock slot A.

## Step 2: Klipper + Moonraker + Mainsail (2026-10-20)

**Status:** `build/rootfs/rootfs.squashfs` = **20.7 MiB** (27.3 MiB of the 48 MiB system partition left), sha256 `b8efbcda…`. **Reproducible:** a real `CLEAN=1` rebuild (from host-skeleton on) gave the identical image. Tested offline only: under qemu-arm with the target's own binaries, `rootfs/tests/offline_check.sh` (see below). **Not flashed or booted.**

### Versions (all pinned)

| Component | Version / source | How it is built |
|---|---|---|
| Klipper (klippy) | Kobra-S1/klipper-kobra-s1, branch Kobra-S1-Dev @ `45f35e8c` (`V1.3.1-51-g45f35e8c`), with cs1237, probe_ks1, lis2dw12, load_cell_probe | `rootfs/package/klipper`: git download; `c_helper.so` cross-compiled with the target gcc (same flags/source list as `klippy/chelper/__init__.py`); `.pyc` pre-compiled (`unchecked-hash`); patch `0001`: never rebuild chelper on a read-only install |
| Moonraker | Arksine/moonraker `v0.11.0` | `rootfs/package/moonraker`: git download, package dir copied, `.pyc` pre-compiled |
| Mainsail | `v2.19.0` release `mainsail.zip` (sha256 pinned) | `rootfs/package/mainsail` |
| mainsail.cfg | mainsail-crew/mainsail-config `v1.2.1` | `rootfs/package/mainsail-config` |
| Web server | lighttpd 1.4.69 (Buildroot) + pcre2 for mod_rewrite | config in overlay `/etc/lighttpd/lighttpd.conf` |
| Python deps from Buildroot | greenlet 2.0.2, cffi 1.15.1 (+pycparser), pyserial 3.5, jinja2 3.1.2, markupsafe 2.1.1, tornado 6.2, pillow 9.4.0, distro 1.8.0, libsodium 1.0.18 | Buildroot packages |
| Python deps we add | streaming-form-data 1.16.0 (C extension, cross-built from the PyPI sdist; patch: import `smart_open` only in the unused `S3Target`); inotify-simple 2.0.1, libnacl 2.1.0, importlib-metadata 9.0.0, zipp 3.23.0 (pinned `py3-none-any` wheels); dbus-fast 5.0.22 (pure-Python fallback from the sdist) | `rootfs/package/python-streaming-form-data`, `rootfs/package/kobra-pywheels` (sha256 in `.hash` files) |
| uClibc fix | `/usr/lib/python3.11/site-packages/sitecustomize.py`: `ctypes.util.find_library()` looks in `/lib` and `/usr/lib` (it finds nothing on uClibc without ldconfig/gcc; inotify_simple and libnacl need it) | overlay |

Klipper's pip requirements pin older versions (Jinja2 2.11, pyserial 3.4, cffi 1.14). Mainline Klipper runs on the newer ones from Buildroot, so those are used as-is. Moonraker v0.11.0 asks for pillow ≥ 9.5, distro 1.9 and pyserial 3.4; the Buildroot versions (9.4 / 1.8 / 3.5) pass its imports and start-up. Not included: msgspec (optional JSON speedup), python-can, zeroconf, apprise, ldap3, paho-mqtt, periphery, preprocess-cancellation (optional Moonraker components, off by default), the ACE Pro driver, numpy (see below), KlipperScreen, a webcam streamer.

### Layout

| Path | What |
|---|---|
| `/usr/lib/klipper/klippy` | klippy, read-only, prebuilt `chelper/c_helper.so` |
| `/usr/lib/moonraker/moonraker` | Moonraker, read-only |
| `/usr/share/mainsail` | Mainsail static files |
| `/usr/share/shednaja/printer_data/config` | defaults: `printer.cfg`, `kobra_s1.cfg`, `kobra_macros.cfg`, `kobra_peripherals.cfg`, `mainsail.cfg`, `moonraker.conf` |
| `/useremain/shednaja/printer_data/{config,logs,gcodes,database,comms}` | writable `printer_data`, created on first boot by `/usr/libexec/kobra/printer-data-init`. Missing default files are copied once; existing files are **never overwritten**. `/root/printer_data` is a symlink to it, so `~/printer_data` in the vanilla configs works. |
| `/useremain/shednaja/tmp` | lighttpd upload temp dir (flash, not the RAM `/tmp`) |
| `/userdata/app/gk` | stock GoKlipper tree: **not touched** |

Services (busybox init, all as root like stock):
- **`S60klipper`:** printer_data init, then the MCU reset pulse on GPIO116 as described in the fork README (export, `direction out`, 1 s, `value 1`, plus 2 s for the bootloader), then `python3 klippy.py …/config/printer.cfg -I /tmp/printer -a /tmp/klippy_uds -l …/logs/klippy.log`.
- **`S61moonraker`:** `PYTHONPATH=/usr/lib/moonraker python3 -m moonraker -d /useremain/shednaja/printer_data`.
- **`S62lighttpd`:** port 80, Mainsail plus proxy of `/websocket`, `/printer`, `/api`, `/server`, `/machine`, `/access` to 127.0.0.1:7125 (websocket upgrade on, `X-Forwarded-*` headers). The SPA fallback goes to `index.html`. Request bodies are streamed to Moonraker, not buffered in RAM. Buildroot's `S50lighttpd` is removed.

Logs: klippy rotates at midnight and keeps 5, Moonraker keeps 2, lighttpd writes only an error log. All on `/useremain` (about 6 GB of flash), so none in RAM.

Fixes from the first boot:
- **regulatory.db:** `wireless-regdb` 2023.09.01 is added, giving `/lib/firmware/regulatory.db` + `.p7s`.
- **ntpd:** `S48ntpd` now starts `/usr/libexec/kobra/ntp-start` in the background. It waits until DNS resolves `pool.ntp.org` (up to 5 min), sets the clock once with `ntpd -q`, then runs busybox ntpd. Before, ntpd started before Wi-Fi had DHCP/DNS.

### printer.cfg provenance

- *(until 2026-10-21; replaced by `kobra_s1.cfg` + `kobra_macros.cfg`, see "Plain Klipper configuration")* **`printer_KS1.cfg` / `printer_generic_macros.cfg`:** Kobra-S1/vanilla-klipper-swu @ `b66f3468`, `releases/2026-06-01/config` (latest release).
  - The only change is that `[include ace_KS1.cfg]` is commented out. It needs the separate ACEPRO klippy driver (`[ace]`, `temperature_ace`, `virtual_pins`), which is not in the fork. All ACE macro references in the vanilla files are guarded by `is defined`.
  - `spoolman_logic.cfg` and the ace files are not shipped.
- **Cross-checked against the stock GoKlipper config** (`app/gk/printer.cfg` from `dumps/emmc_20261020_133010/userdata.img`, FW 2.7.2.7), section by section. These are identical:
  - stepper pins, directions, enables, microsteps, rotation distances, endstops and travel limits for X/Y/Z
  - TMC2209 UART pins, addresses, currents and sense resistors
  - extruder (nozzle_mcu PA12/PA11/PC13, 6.5756, heater PB8, NTC on PA0, PID defaults)
  - heater_bed (PA0/PC0, NTC 100K 3950)
  - fans: part PB6 (hardware PWM), heater fan PB9, controller fan PB5, box fan PC6, air filter fan PC7
  - cs1237 (PA7/PA6/PA5, register 60, sensitivities), probe pin PB15, bed_mesh range 5–245
- **Deliberate differences in vanilla** (kept):
  - `probe_ks1` (load-cell probe module of the fork) instead of Anycubic's `probe`
  - lis2dw12 on software SPI (nozzle_mcu PB13/PB15/PB14) instead of `spi_bus: spi2`
  - `homing_override` instead of Anycubic's `safe_z_home` variant
  - bed_mesh `bicubic` + faulty regions
  - `hz_per_sec: 2` for resonance tests
  - no Anycubic-only sections (`filament_hub`, `leviQ3`, `flow_calibration`, `mcu_ota`, …)
- **Our `printer.cfg`:**
  - `[include printer_KS1.cfg]`
  - **`[mcu]` = `/dev/ttyS3`, `[mcu nozzle_mcu]` = `/dev/ttyS5`, 576000 baud, `restart_method: command`**. These are the stock GoKlipper ports; vanilla uses ttyGS0/1 because it runs on an external host.
  - `virtual_sdcard` path in printer_data
  - a no-op `T0` macro: vanilla's start/load macros call `T<n>`, which is otherwise undefined without ACE
  - PID (extruder 19.812/0.905/108.473, bed 34.536/0.564/528.395) and input shaper (x 3hump_ei 84.8 Hz, y mzv 43.0 Hz) from the stock calibration of the test printer (`printer_mutable.cfg`)
  - z_offset left at 0: stock used -0.0825 with its own probe module, so calibrate with PROBE_CALIBRATE / paper test before printing

`moonraker.conf`:
- `[machine] provider: none`: there is no systemd or supervisord, so Mainsail's service restart / reboot buttons may not work; use SSH.
- `trusted_clients`: LAN ranges and localhost (behind the proxy, every client appears as 127.0.0.1).
- also `[history]`, `[octoprint_compat]` (slicer upload), `[announcements]`.
- No `update_manager`: the code is read-only, and updates come as a new rootfs image.

### Offline tests (`bash rootfs/tests/offline_check.sh`, WSL, no board)

1. **klippy batch mode** with the default config against the MCU data dictionaries: `build/mcu/klipper.dict` (v2.0.11, the closest we have to the board's v2.0.12) and `build/mcu/cs1237/klipper.dict` (v2.0.13-cali). Result: **config loads**, `Loaded MCU 'mcu' 102 commands`, `'nozzle_mcu' 109 commands`, about 12.8 KB of MCU commands for a short G-code test (G28 X Y, moves, M104/M140/M106/M107, T0, QUERY_ENDSTOPS).
2. **Moonraker v0.11.0 starts** with the default `moonraker.conf`: `/server/info` reports 24 components, `failed_components: []`, no warnings. That covers all core imports (tornado, pillow, streaming_form_data, libnacl → libsodium, inotify_simple → libc, dbus_fast, importlib_metadata, sqlite).
3. **lighttpd:** `-tt` config check, then live on port 8080: `/` 200, `/history` 200 (SPA fallback), `/server/info` through the proxy 200, `/websocket` upgrade **101**.

### Size and RAM

- Image: **20.7 MiB** squashfs (60 MB unpacked); step 1 was 12.8 MiB. Largest additions unpacked: Mainsail 10.0 MB (8.8 MB of JS, nothing to strip), klipper 5.0 MB, moonraker 3.6 MB, lighttpd + pcre2 1.2 MB, greenlet/pillow/cffi/streaming-form-data/libsodium about 1.4 MB. Details in `build/rootfs/manifest.txt`.
- RAM: **estimate, not measured** (qemu-user numbers are meaningless). On 32-bit ARM, klippy typically uses 30–45 MB RSS and Moonraker 30–40 MB; lighttpd is about 2 MB. With the measured 11 MB base from step 1 that gives about 80–100 MB used of 256 MB, versus about 114 MB for stock with GoKlipper + UI. To be measured on the board (`free`, `ps -o rss`).
- numpy: Buildroot's `python-numpy` cannot be selected with our toolchain: it `depends on BR2_TOOLCHAIN_USES_GLIBC || BR2_TOOLCHAIN_USES_MUSL` because uClibc-ng ships no `fenv.h` for ARM (checked: the Rockchip uClibc-ng 1.0.31 sysroot has no `fenv.h` and no `fe*` symbols), and `make` drops `BR2_PACKAGE_PYTHON_NUMPY=y` without a warning. (An earlier note here gave a size "measured" for that package; it was never built for this toolchain.)
  Since 2026-10-21 the external package `rootfs/package/kobra-numpy` builds the same numpy 1.23.5 with Buildroot's recipe (no BLAS/LAPACK/Fortran, bundled lapack_lite) plus a header-only `fenv.h` for ARM hard-float (`include/fenv.h`, FPSCR via `vmrs`/`vmsr`, same semantics as musl). post-build deletes `numpy/**/tests`. Patch `0001-npymath-use-fenv-on-uclibc.patch`: numpy 1.23.5 puts `__UCLIBC__` in the MSVC/Alpha branch of `ieee754.c.src`, which never defines `npy_get/clear_floatstatus_barrier`, so the first build failed to import on the board (`can't resolve symbol`); with the patch it uses the generic `<fenv.h>` code. Checked on the board from `/tmp`: import, FP error flags (`seterr(all="raise")` → `divide by zero`), rfft of 64k points in 0.034 s, `linalg.inv`; python + numpy 21 MB max RSS. Cost: **+4.3 MiB squashfs** (20.7 → 25.0 MiB), 74 MB unpacked. Needed for `SHAPER_CALIBRATE` / `TEST_RESONANCES` on the printer (accelerometer `lis2dw12`, `[resonance_tester]` in `printer_KS1.cfg`).

### Test plan (main session with the user)

The board currently runs slot B = our kernel + oem_ours + step-1 rootfs.
1. `bash tools/build_rootfs.sh` (and `bash rootfs/tests/offline_check.sh`).
2. Write the inactive slot with `tools/flash_slot.sh <printer-ip> build/kernel/boot.img build/kernel/oem_ours.img --system build/rootfs/rootfs.squashfs` (dry run first, then `--write`), keeping the other slot as fallback. If slot B must stay the target, switch to A first, as for the step-1 boot.
3. J1 logger on. Expect `printer-data-init: installed default …` (first boot only), `klipper: MCU reset pulse on GPIO116`, then the login prompt and `kobra-bootok`.
4. Browse to **http://<printer-ip>**: Mainsail should connect to Moonraker.
5. **klippy `ready` with both MCUs**: Mainsail → Machine → system loads; `klippy.log` shows `mcu` v2.0.12 and `nozzle_mcu` v2.0.13 on ttyS3/ttyS5.
6. The user checks temperatures (bed/nozzle sensible at room temperature), fans, then homing step by step: X/Y first, then Z with the load-cell probe. **Stay at the printer with power within reach**, because this is the first motion under our own Klipper config. Then probe calibrate / z_offset, bed mesh, PID if needed.
7. Report RAM (`free`, `ps -o pid,rss,args`), boot time to `ready`, and anything odd in `printer_data/logs/klippy.log` / `moonraker.log`.

### Rollback

Same as step 1:
- `kobra-abctl other && reboot` → the other slot
- automatic fallback after 7 boots that never reach S99
- old partition contents in `dumps/*_before_flash_*`

New data lives only in `/useremain/shednaja/` (printer_data, tmp) and `/userdata/shednaja/`; delete those to go fully back. The stock GoKlipper tree is untouched, so stock slot A keeps working with its own config.

### Known limits / open

- **MCU dictionary:** the batch test used the v2.0.11 dictionary for the main MCU; the board runs v2.0.12. A v2.0.12 `klipper.dict` from the fork's build would make the offline test exact.
- **No ACE Pro:** ACEPRO driver not packaged yet. No on-screen UI: the touch display stays dark (KlipperScreen or similar is a later step). No webcam stream. (Camera, light/buzzer and the ACE Pro driver came in step 4: docs/peripherals.md.)
- **Root:** all services run as root, like stock. No auth on the LAN (`trusted_clients`).
- **Build host:** WSL2's clock is pulled back by Windows every few tens of seconds (journald: "Time jumped backwards"). That randomly breaks autoconf's "build environment is sane" check and make's stamp ordering. `tools/build_rootfs.sh` now detects these failures, wipes only the affected package's build dir and retries (max 5). It is also why the kernel builds print "clock skew" warnings.

### Step 2 – first boot on hardware (2026-10-20 20:48, slot B, slot A stock)
- Boot to login in about 15 s. `printer-data-init` installed the defaults, the MCU reset pulse fired, and `kobra-bootok` re-armed the slot. Log: `logs/bootlog_shednaja_step2_20261020.log`.
- **Bug 1 – lighttpd did not start:** it drops to `www-data` before opening `logs/lighttpd-error.log` in the root-owned logs dir → `Permission denied`. Fixed in `printer-data-init` (create the file, owned by www-data). On the board it was fixed by hand (chown + `S62lighttpd start`).
- **Bug 2 – Klipper shut down ~1 s after connecting:** `AttributeError: module 'os' has no attribute 'getloadavg'` from `extras/statistics.py`. uClibc has no `getloadavg()`, so Python lacks `os.getloadavg`. Fixed in `sitecustomize.py` (reads `/proc/loadavg`). On the board klippy was restarted by hand through a temporary launcher `/useremain/shednaja/klippy_loadavg_fix.py`, then `FIRMWARE_RESTART`.
- Both fixes are in the rebuilt rootfs (20.7 MiB), written to the board on 2026-10-21 (see below).
- **After the fixes: `Printer is ready`**, `mcu` v2.0.12 + `nozzle_mcu` v2.0.13 on ttyS3/ttyS5, 0 retransmits, temperatures OK (nozzle 29 °C, bed 22.5 °C). Mainsail `http://<printer-ip>/` 200, Moonraker proxy 200.
- RAM measured: klippy 20 MB RSS, Moonraker 25 MB, lighttpd 1 MB. 45 MB used in total, about 162 MB available (stock: about 114 MB used).
- Not tested yet: motion/homing/probing under our config (z_offset is still 0).

### Step 2 – motion test on hardware (2026-10-20, user at the printer)
- **Heating:** nozzle 100 °C (on target, 37 % power, PID holds) and bed 50 °C reached without heater-check errors.
- **Axis directions verified** after `G28 X Y` (head front-left at X-6 Y0): `G1 X10` moves right, `G1 Y10` moves back, away from the door. `G1 X125 Y125` at ACCEL 1000 puts the nozzle over the bed centre. Kinematics, endstops and position_endstop match the stock config.
- **Bug 3 – the whole printer shook during G28:** the vanilla `homing_override` travels to the centre (X125 Y125, 120 mm/s) with the full `max_accel: 20000`. Stock `safe_z_home` uses `home_accel: 1000` for that move.
  Fixed in `printer_KS1.cfg` (defaults): `SET_VELOCITY_LIMIT ACCEL=1000` for the centre travel + Z homing, then restore the previous max_accel.
  Applied on the board by replacing the unmodified default `printer_KS1.cfg` (the old one is kept as `.bak_homingaccel`) and doing a `RESTART`.
- **After the fix: full `G28` homes xyz without shaking**: probe_ks1 (CS1237) Z homing OK, head at X125 Y125 Z6, max_accel back to 20000.
- Still open: z_offset calibration (PROBE_CALIBRATE), probe accuracy, bed mesh, the first print.

### Step 2 – fixed rootfs written (2026-10-21 07:10, slot B, slot A stock)
- Rootfs rebuilt with all three fixes (getloadavg shim, lighttpd log ownership, homing accel in the default `printer_KS1.cfg`); checked in the image before writing. md5 `6d8cfa9da5d9e7e97c44aca7df47d481`, 21688320 B.
- From stock slot A: `bash tools/flash_slot.sh <printer-ip> - --system build/rootfs/rootfs.squashfs --write` (only system_b, boot_b/oem_b unchanged); the old system_b was saved to `dumps/system_b_before_flash_20261021_070952.img`.
- Boot into B without manual steps: klippy started by the init script (`klippy.py` directly), Moonraker and lighttpd (as www-data) running, `os.getloadavg()` works, Klipper reports `Printer is ready`, Mainsail http 200, `Stats` lines with `sysload` keep coming (no shutdown).
- The temporary launcher `/useremain/shednaja/klippy_loadavg_fix.py` was deleted. No console log for this boot (the logger was started with a Python without pyserial).
- **Bug 4 – Mainsail flickered/reconnected about once a minute:** Moonraker logged `Websocket Closed … Pong Time Elapsed: 61` every ~62 s. lighttpd's default `server.max-read-idle = 60` dropped the proxied websocket when the browser sent nothing for a minute. Fixed in `lighttpd.conf` (`max-read-idle`/`max-write-idle` 3600). Checked on the board with lighttpd started from a copy in `/tmp`: no websocket close in 3+ minutes. In the image from the next rootfs build; until then a reboot brings back the old config.

### numpy + HelixScreen image in slot B, SHAPER_CALIBRATE on the printer (2026-10-21)
- Combined image after merging the HelixScreen branch: **45.0 MiB of 48 MiB** (3.0 MiB left), md5 `f9cfc56f0094d1363b913a258fa53fa4`. Written from stock slot A to system_b (old one in `dumps/system_b_before_flash_20261021_082645.img`), boot B: Klipper ready, HelixScreen running, `import numpy` OK, lighttpd idle fix and homing accel fix in place.
- `ACCELEROMETER_QUERY` (lis2dw12): x -199, y -479, z -9639 mm/s².
- `G28` + `SHAPER_CALIBRATE` (user at the printer), 4 min 25 s. **RAM:** klippy RSS 20.1 MB before, **peak 58.5 MB** during the calculation; MemAvailable never below **99.9 MB** (157 MB before); load peak 1.54; no OOM. klippy keeps ~58 MB RSS afterwards (Python does not give the memory back) until a restart; still about 139 MB available. So the on-printer calculation is safe on this board.
- Results (not saved yet, `SAVE_CONFIG` left to the user): X `3hump_ei` 88.8 Hz (0.0 % vibrations, smoothing 0.148, suggested max_accel ≤ 3400); Y recommended `ei` 50.6 Hz (0.4 %, ≤ 3000), `mzv` 42.6 Hz 1.7 % (≤ 3600). The defaults from stock were X 3hump_ei 84.8 Hz, Y mzv 43.0 Hz. Raw CSVs and the RAM log: `logs/shaper_20261021/`.
- **Bug 5 – `SAVE_CONFIG` refused:** `section 'input_shaper' option 'shaper_type_x' conflicts with included value`. Klipper cannot autosave an option that an included file also sets, and `printer_KS1.cfg` (vanilla) set `[input_shaper]`, the extruder/bed `pid_K*` and `[probe_ks1] z_offset`, so PID_CALIBRATE and PROBE_CALIBRATE would have failed the same way. Fixed in the defaults: those values now live only in `printer.cfg`. On the board both files were replaced (old ones kept as `*.bak_saveconfig`, live files were identical to the defaults) and `SAVE_CONFIG` was re-run with the pending results: **saved X 3hump_ei 88.8 Hz, Y ei 50.6 Hz**, Klipper ready after the restart.

### Step 4 image in slot B: camera, light, buzzer, trimmed HelixScreen (2026-10-21)
- Merged `claude/display-ui-fbf92c` (HelixScreen without Chinese/Japanese and the tracker music) and `claude/peripherals-32bd1a` (USB hub enable `S25kobra-usb`/gpio41, mjpg-streamer `S65webcam` + `/webcam/` proxy, `klipper_mcu` for the host-board light and buzzer, ACE Pro driver packaged but not included). Image **43.1 MiB of 48** (4.9 MiB left; the trimming saved ~1.9 MiB compressed). md5 `fa1c488876a1772a6ae878e521a434f7`, old system_b in `dumps/system_b_before_flash_20261021_091546.img`.
- The first clean build failed in `libopenssl` staging install (`mv: cannot stat crypto/bf/bf_cfb64.d.tmp`, a parallel-make race, probably the WSL clock jumps again). Wiping only `build/libopenssl-1.1.1v` and re-running finished the build.
- Boot B: gpio41 = 1, `/dev/video0`, `klipper_mcu`, mjpg_streamer and HelixScreen running, Klipper ready. `/webcam/?action=snapshot` returns a 1280×720 JPEG (~220 kB).
- Existing printer_data on the test printer is never overwritten, so by hand: `[include kobra_peripherals.cfg]` after `[include printer_KS1.cfg]` in `printer.cfg` and `[webcam kobra_s1]` appended to `moonraker.conf` (backups `*.bak_peripherals`), Moonraker restart + `RESTART`. Result: `mcu host` connected (linux, v2.0.11), Moonraker lists webcam `kobra_s1`, `LIGHT_OFF`/`LIGHT_ON` change the camera snapshot (229 kB dark → 269 kB lit), `M300 S1000 P300` beeps (heard by the user). Camera image shows in Mainsail (confirmed by the user).

### z_offset and bed mesh (2026-10-21, user at the printer)
- Bed 60 °C, nozzle 150 °C, then `G28` + `PROBE_CALIBRATE` with a paper test in Mainsail's Manual Probe dialog, `BED_MESH_CALIBRATE` and `SAVE_CONFIG` (run by the user). Checked on the printer afterwards: `save_config_pending` false, Klipper ready, effective settings `[probe_ks1] z_offset = 0.017` (stock GoKlipper used -0.0825 with its own probe module), input shaper still X 3hump_ei 88.8 / Y ei 50.6.
- Saved `[bed_mesh default]` 5×5 over X/Y 5–245: range **+0.254 … -1.103 mm**. Without the corner X5 Y245 (-1.103, next point -0.482) it is +0.254 … -0.482, the bed falls towards the back (Y245 row -0.33 … -0.48). The single corner value looks like an outlier or a real dip; re-probe it (`PROBE_ACCURACY` at X5 Y245) before trusting the mesh there.
- Still open: `PROBE_ACCURACY` at the centre, first test print (first layer check of the z_offset).

### Plain Klipper configuration (2026-10-21)
The printer config no longer uses the vanilla-klipper files (`printer_KS1.cfg`,
`printer_generic_macros.cfg`), which carried Anycubic-slicer shims (`G9111`, `M204 P/T`,
`M900`, `bedTemp=` parameters), ACE "smart logic", their own PAUSE/RESUME and a velocity stack
with the removed `ACCEL_TO_DECEL`. New defaults:
- `kobra_s1.cfg`: hardware only, values unchanged (pins, steppers, TMC, heaters, fans, load
  cell, probe, mesh limits/faulty regions, accelerometer), plus our `homing_override`
  (centre travel at 1000 mm/s²) and `[adc_filament_switch]`. No `[mcu]` ttyGS leftovers.
- `kobra_macros.cfg`: `PRINT_START BED= EXTRUDER= [PROBE_TEMP=140] [PURGE=30]` (heat, home,
  purge into the bin + knock-off at the blade, wipe while cooling to 140 °C, `M190`, 3 min
  settle above 80 °C, `G28 Z`, `BED_MESH_CALIBRATE ADAPTIVE=1`, heat over the wiper, prime
  line), `PRINT_END [CUT=1]`, `LOAD_FILAMENT` / `UNLOAD_FILAMENT` (cutter), runout/insert,
  `CUT_TIP`, `M106/M107 P2/P3` for OrcaSlicer's aux/exhaust fans; temperature waits with
  `TEMPERATURE_WAIT` windows. The toolhead positions (bin X48 Y276, blade Y255, wiper
  X72-96 Y273, cutter X261 Y12) are the vanilla ones.
- PAUSE / RESUME / CANCEL_PRINT: mainsail.cfg, parked at X48 Y250 via `_CLIENT_VARIABLE`,
  `runout_sensor` set so RESUME refuses without filament.
- ACE Pro: ACEPRO's configs need the vanilla macros, see docs/peripherals.md.

On the test printer the old files were moved to `config/old_vanilla/`; `printer.cfg` was
rebuilt from the new default plus its SAVE_CONFIG block. Lesson: options that the SAVE_CONFIG
block sets must be commented out in the main file (Klipper drops autosave values that the main
file also sets, `z_offset` came back as 0 until `#z_offset` / `#shaper_*`).

Checked on the printer (cold): config loads without warnings, z_offset 0.017 / shaper
3hump_ei 88.8, ei 50.6 / mesh `default` kept; `G28`, `_PARK_BIN` (X48 Y276), `_WIPE_NOZZLE`
(ends X75 Y273), `_HEAT_POS` (X75 Y269) move as before.

**False runout during G28:** with filament the toolhead sensor dipped to 2.738 V during homing
(threshold 2.78 V ± 0.04) and paused the printer. `adc_filament_switch` now needs a new state
to hold for `debounce_time` (0.5 s) and reports `voltage_min/max`; 3 rounds of G28 + wipe +
diagonal moves: minimum 2.746 V, no runout. Note: a klippy `RESTART` does not re-import a
changed Python module, restart the service (`/etc/init.d/S60klipper restart`).
Not tested yet: a full `PRINT_START` with heat/purge/mesh, `CUT_TIP`, `UNLOAD_FILAMENT`,
runout during a print.

